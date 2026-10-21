--[[
	Headless Roblox environment for Lune.

	Loads the Rojo-built place file into Lune's DOM and runs the game's real ModuleScripts with a
	Roblox-compatible `require`, `script`, `game` and `workspace`. Engine behaviour that Lune does not
	provide (signals, task scheduling, a handful of methods) is shimmed here so that pure gameplay
	modules and the procedural world builders can be exercised exactly as they ship.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local task = require("@lune/task")

local Env = {}

local DATATYPES = {
	"Axes",
	"BrickColor",
	"CFrame",
	"Color3",
	"ColorSequence",
	"ColorSequenceKeypoint",
	"Content",
	"Faces",
	"Font",
	"Instance",
	"NumberRange",
	"NumberSequence",
	"NumberSequenceKeypoint",
	"PhysicalProperties",
	"Ray",
	"Rect",
	"Region3",
	"Region3int16",
	"UDim",
	"UDim2",
	"Vector2",
	"Vector2int16",
	"Vector3",
	"Vector3int16",
}

local shimsInstalled = false

local function installShims()
	if shimsInstalled then
		return
	end
	shimsInstalled = true

	-- Model pivots: Lune exposes WorldPivotData only, so emulate the engine API.
	local function modelPivot(model: any): any
		local primary = model.PrimaryPart
		if primary then
			return primary.CFrame
		end
		local ok, pivot = pcall(function()
			return model.WorldPivotData
		end)
		if ok and typeof(pivot) == "CFrame" then
			return pivot
		end
		return roblox.CFrame.new()
	end
	roblox.implementMethod("Model", "GetPivot", function(model: any)
		return modelPivot(model)
	end)
	roblox.implementMethod("Model", "PivotTo", function(model: any, target: any)
		local current = modelPivot(model)
		local delta = target * current:Inverse()
		for _, d in model:GetDescendants() do
			if d:IsA("BasePart") then
				d.CFrame = delta * d.CFrame
			end
		end
		pcall(function()
			model.WorldPivotData = target
		end)
	end)
	roblox.implementMethod("BasePart", "GetPivot", function(part: any)
		return part.CFrame
	end)
	roblox.implementMethod("BasePart", "PivotTo", function(part: any, target: any)
		part.CFrame = target
	end)
	-- Derived BasePart properties the engine computes from CFrame.
	roblox.implementProperty("BasePart", "Position", function(part: any)
		return part.CFrame.Position
	end, function(part: any, value: any)
		part.CFrame = part.CFrame.Rotation + value
	end)
	roblox.implementProperty("BasePart", "Orientation", function(part: any)
		local rx, ry, rz = part.CFrame:ToOrientation()
		return roblox.Vector3.new(math.deg(rx), math.deg(ry), math.deg(rz))
	end)
	roblox.implementMethod("Instance", "GetAttributeChangedSignal", function()
		return Env.fakeSignal()
	end)
	roblox.implementMethod("Instance", "GetPropertyChangedSignal", function()
		return Env.fakeSignal()
	end)
	roblox.implementMethod("Instance", "WaitForChild", function(inst: any, name: string)
		local child = inst:FindFirstChild(name)
		assert(child, "WaitForChild would yield forever in the harness: " .. tostring(name))
		return child
	end)
	roblox.implementMethod("Instance", "IsPropertyModified", function()
		return false
	end)
	-- Tag queries walk the DataModel (the headless DOM keeps tags but has no tag index). The client harnesses
	-- wrap CollectionService in proxies of their own.
	roblox.implementMethod("CollectionService", "GetTagged", function(service: any, tag: string)
		local out = {}
		for _, d in service.Parent:GetDescendants() do
			if d:HasTag(tag) then
				table.insert(out, d)
			end
		end
		return out
	end)
end

-- A do-nothing RBXScriptSignal stand-in used where modules only connect for runtime behaviour.
function Env.fakeSignal(): any
	local signal = {}
	function signal:Connect(_fn)
		return {
			Connected = true,
			Disconnect = function(self)
				self.Connected = false
			end,
		}
	end
	function signal:Once(fn)
		return self:Connect(fn)
	end
	function signal:Wait()
		error("Signal:Wait() is not supported in the harness")
	end
	return signal
end

export type Loaded = {
	game: any,
	require: (any) -> any,
	env: { [string]: any },
	overrides: { [any]: any },
}

function Env.load(placePath: string, extraGlobals: { [string]: any }?): Loaded
	installShims()
	local game = roblox.deserializePlace(fs.readFile(placePath))
	return Env.runtime(game, extraGlobals)
end

-- A module runtime (globals + require with its own module cache) over an existing DataModel. Two runtimes
-- over the same place behave like a server and a client VM: same instances, separate module state.
function Env.runtime(game: any, extraGlobals: { [string]: any }?): Loaded
	installShims()
	local cache: { [any]: any } = {}
	local loading: { [any]: boolean } = {}
	local overrides: { [any]: any } = {}

	local baseEnv: { [string]: any } = {
		game = game,
		workspace = game:GetService("Workspace"),
		Enum = roblox.Enum,
		task = task,
		tick = os.clock,
		time = os.clock,
		wait = task.wait,
		delay = task.delay,
		spawn = task.spawn,
		warn = function(...)
			print("[warn]", ...)
		end,
	}
	for _, name in DATATYPES do
		baseEnv[name] = (roblox :: any)[name]
	end
	if extraGlobals then
		for k, v in extraGlobals do
			baseEnv[k] = v
		end
	end

	local requireModule

	-- Globals are copied raw into every module environment: Luau resolves imported globals with raw
	-- lookups, so an __index fallback would silently yield nil for names such as `task`.
	local function makeEnv(scriptInstance: any)
		local env = table.clone(baseEnv)
		env.script = scriptInstance
		env.require = requireModule
		return env
	end

	requireModule = function(target: any): any
		if type(target) == "string" then
			error("String requires are not used by ROOMNAPPED modules: " .. target)
		end
		if overrides[target] ~= nil then
			return overrides[target]
		end
		if cache[target] ~= nil then
			return cache[target]
		end
		assert(typeof(target) == "Instance", "require expects a ModuleScript, got " .. typeof(target))
		assert(target.ClassName == "ModuleScript", "require expects a ModuleScript, got " .. target.ClassName)
		if loading[target] then
			error("Cyclic require detected for " .. target:GetFullName())
		end
		loading[target] = true
		local ok, result = pcall(function()
			local fn = luau.load(target.Source, {
				debugName = target:GetFullName(),
				environment = makeEnv(target),
				injectGlobals = true,
			})
			return fn()
		end)
		loading[target] = nil
		if not ok then
			error(result, 0)
		end
		if result == nil then
			error("Module returned nil: " .. target:GetFullName())
		end
		cache[target] = result
		return result
	end

	return {
		game = game,
		require = requireModule,
		env = baseEnv,
		overrides = overrides,
	}
end

-- Resolve a dotted path such as "ReplicatedStorage.Shared.Logic.ZoneSolver" to an instance.
function Env.find(game: any, path: string): any
	local current = game
	for segment in string.gmatch(path, "[^%.]+") do
		local nextInstance = current:FindFirstChild(segment)
		assert(nextInstance, "Missing instance '" .. segment .. "' while resolving " .. path)
		current = nextInstance
	end
	return current
end

return Env
