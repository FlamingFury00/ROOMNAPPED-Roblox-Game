--!strict
--[[
	AssetLibraryService: dresses the hotel with curated free Creator Store models (A01, A10).

	At startup every AssetManifest entry is loaded with AssetService:LoadAssetAsync (falling back to
	InsertService:LoadAsset, which still loads models the experience owner has in their inventory) and turned
	into a template in ReplicatedStorage.RN_Assets/<key>/<n>:

	  * cleaned: no scripts, sounds, GUIs, prompts, click detectors, humanoids, joints, constraints or legacy
	    effects; every part anchored, non-colliding, untouchable, invisible to raycasts and locked (collision
	    stays with the builders' simple proxies); seats disabled; the model's own lights and particles only
	    when the entry asks for them, never casting shadows;
	  * turned so its front faces -Z: seats say which way a piece of furniture faces, part names ("Door",
	    "Handle", "Screen" ...) and a taller back (sofas, beds, chairs) vote too, and Roblox models usually face
	    +Z (towards Studio's default camera) when nothing else decides;
	  * scaled uniformly into the entry's size and pivoted by its mount (bottom / back / top centre).

	Slots the builders already filled with procedural fallbacks are upgraded as each key arrives
	(World/Assets.upgrade), so the lobby that exists before any model loads is dressed too. Loading needs the
	experience's Security setting "Allow Loading Third Party Assets"; when models cannot load the hotel keeps
	its procedural props and admins are told why (publishing checklist). The `assets` feature flag switches
	the whole library off live.
]]

local AssetService = game:GetService("AssetService")
local InsertService = game:GetService("InsertService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local AssetManifest = require(Shared.Content.AssetManifest)
local Assets = require(Shared.World.Assets)
local Log = require(Shared.Util.Log)
local Signal = require(Shared.Util.Signal)
local Registry = require(script.Parent.Parent.Core.Registry)

local AssetLibraryService = {}

AssetLibraryService.Loaded = Signal.new() -- (key)
AssetLibraryService.Finished = Signal.new() -- (loadedKeys, failedKeys)

local log = Log.new("Assets")

local CONCURRENCY = 6
local ATTEMPTS = 2

type Status = "pending" | "loading" | "ready" | "failed"

local status: { [string]: Status } = {}
local failures: { [string]: string } = {}
local finished = false
local loadedCount, failedCount = 0, 0
local root: Folder

-- Cleaning ----------------------------------------------------------------------------------------------------

local REMOVE: { string } = {
	"LuaSourceContainer",
	"Sound",
	"SoundGroup",
	"ClickDetector",
	"ProximityPrompt",
	"DragDetector",
	"Tool",
	"Humanoid",
	"AnimationController",
	"Animator",
	"Animation",
	"Camera",
	"LayerCollector", -- ScreenGui / BillboardGui / SurfaceGui: no text or images from strangers' GUIs
	"JointInstance",
	"WeldConstraint",
	"Constraint",
	"BodyMover",
	"Explosion",
	"ForceField",
	"Fire",
	"Smoke",
	"Sparkles",
	"Dialog",
	"Configuration",
	"ValueBase",
	"BindableEvent",
	"BindableFunction",
	"RemoteEvent",
	"RemoteFunction",
	"UnreliableRemoteEvent",
	"Model", -- never: nested models are flattened instead (handled below)
}

local function shouldRemove(instance: Instance, entry: AssetManifest.Entry): boolean
	for _, class in REMOVE do
		if class ~= "Model" and instance:IsA(class) then
			return true
		end
	end
	if instance:IsA("Light") then
		return entry.lights ~= true
	end
	if instance:IsA("ParticleEmitter") or instance:IsA("Beam") or instance:IsA("Trail") then
		return entry.particles ~= true
	end
	return false
end

-- Move every part (and what hangs off it) into one flat model; drop everything else.
local function clean(loaded: Instance, entry: AssetManifest.Entry): Model?
	local model = Instance.new("Model")
	for _, d in loaded:GetDescendants() do
		if d.Parent ~= nil and shouldRemove(d, entry) then
			d:Destroy()
		end
	end
	local parts: { BasePart } = {}
	for _, d in loaded:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(parts, d)
		end
	end
	if #parts == 0 then
		loaded:Destroy()
		return nil
	end
	for _, part in parts do
		part.Anchored = true
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = false
		part.Locked = true
		part.Massless = true
		part.CastShadow = false
		if part:IsA("Seat") or part:IsA("VehicleSeat") then
			(part :: any).Disabled = true
		end
		part.Parent = model
	end
	for _, d in model:GetDescendants() do
		if d:IsA("Light") then
			d.Shadows = false
		end
	end
	loaded:Destroy()
	return model
end

-- Bounds --------------------------------------------------------------------------------------------------------

-- World-axis bounding box of a model's parts: (centre, size).
local function bounds(model: Model): (Vector3, Vector3)
	local minV = Vector3.new(math.huge, math.huge, math.huge)
	local maxV = -minV
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			local cf, size = part.CFrame, part.Size / 2
			for _, sx in { -1, 1 } do
				for _, sy in { -1, 1 } do
					for _, sz in { -1, 1 } do
						local p = cf * Vector3.new(size.X * sx, size.Y * sy, size.Z * sz)
						minV = minV:Min(p)
						maxV = maxV:Max(p)
					end
				end
			end
		end
	end
	return (minV + maxV) / 2, maxV - minV
end

-- Facing --------------------------------------------------------------------------------------------------------

local FRONT_WORDS = {
	"door",
	"handle",
	"knob",
	"screen",
	"display",
	"front",
	"glass",
	"button",
	"drawer",
	"dial",
	"keypad",
	"window",
	"cushion",
	"seat",
	"face",
}

local DIRECTIONS: { { dir: Vector3, yaw: number } } = {
	-- yaw turns that direction onto -Z (the hotel's "front" convention).
	{ dir = Vector3.new(0, 0, 1), yaw = math.pi },
	{ dir = Vector3.new(0, 0, -1), yaw = 0 },
	{ dir = Vector3.new(1, 0, 0), yaw = math.pi / 2 },
	{ dir = Vector3.new(-1, 0, 0), yaw = -math.pi / 2 },
}

local function frontYaw(model: Model): (number, string)
	local centre, size = bounds(model)
	local votes = { 0.5, 0, 0, 0 } -- Roblox models usually face +Z (towards Studio's default camera)
	local reasons = { "default +Z" }
	local function vote(direction: Vector3, weight: number)
		local flat = Vector3.new(direction.X, 0, direction.Z)
		if flat.Magnitude < 1e-3 then
			return
		end
		flat = flat.Unit
		for i, d in DIRECTIONS do
			local dot = flat:Dot(d.dir)
			if dot > 0.7 then
				votes[i] += weight * dot
			end
		end
	end
	for _, part in model:GetDescendants() do
		if part:IsA("Seat") or part:IsA("VehicleSeat") then
			vote(part.CFrame.LookVector, 3)
			table.insert(reasons, "seat")
		elseif part:IsA("BasePart") then
			local name = string.lower(part.Name)
			for _, word in FRONT_WORDS do
				if string.find(name, word, 1, true) then
					local offset = part.Position - centre
					local reach = Vector3.new(math.max(size.X / 2, 1e-3), 1, math.max(size.Z / 2, 1e-3))
					vote(Vector3.new(offset.X / reach.X, 0, offset.Z / reach.Z), 1)
					break
				end
			end
		end
	end
	-- A taller back (sofa, bed, armchair): the lower half faces forwards.
	for _, axis in { Vector3.new(1, 0, 0), Vector3.new(0, 0, 1) } do
		local half = (if axis.X > 0 then size.X else size.Z) / 2
		if half > 0.5 then
			local topNeg, topPos = -math.huge, -math.huge
			for _, part in model:GetDescendants() do
				if part:IsA("BasePart") then
					local along = (part.Position - centre):Dot(axis)
					local top = part.Position.Y + part.Size.Magnitude * 0.3
					if along < -half * 0.35 then
						topNeg = math.max(topNeg, top)
					elseif along > half * 0.35 then
						topPos = math.max(topPos, top)
					end
				end
			end
			if topNeg > -math.huge and topPos > -math.huge and math.abs(topNeg - topPos) > size.Y * 0.25 then
				vote(if topNeg > topPos then axis else -axis, 1.5)
				table.insert(reasons, "taller back")
			end
		end
	end
	local best, bestVote = 1, -math.huge
	for i, v in votes do
		if v > bestVote then
			best, bestVote = i, v
		end
	end
	return DIRECTIONS[best].yaw, table.concat(reasons, "+")
end

-- Normalising -----------------------------------------------------------------------------------------------------

local function normalise(model: Model, entry: AssetManifest.Entry, id: number): Model
	local centre, _ = bounds(model)
	model.WorldPivot = CFrame.new(centre)
	-- Turn the front onto -Z.
	local yaw = 0
	local why = "fixed"
	if entry.facing == "auto" then
		yaw, why = frontYaw(model)
	elseif type(entry.facing) == "number" then
		yaw = math.rad(entry.facing)
	end
	model:PivotTo(CFrame.new(centre) * CFrame.Angles(0, yaw, 0))
	model.WorldPivot = CFrame.new(centre)
	-- Uniform scale into the target size.
	local _, size = bounds(model)
	local target = entry.size
	local ratio: number
	if entry.fit == "height" then
		ratio = target.Y / math.max(size.Y, 1e-3)
	elseif entry.fit == "width" then
		ratio = target.X / math.max(size.X, 1e-3)
	else
		ratio = math.min(
			target.X / math.max(size.X, 1e-3),
			target.Y / math.max(size.Y, 1e-3),
			target.Z / math.max(size.Z, 1e-3)
		)
	end
	ratio = math.clamp(ratio, 0.02, 50)
	model:ScaleTo(model:GetScale() * ratio)
	-- Pivot by mount, at the origin.
	local c, s = bounds(model)
	local pivot: CFrame
	if entry.mount == "wall" then
		pivot = CFrame.new(c.X, c.Y, c.Z + s.Z / 2)
	elseif entry.mount == "ceiling" then
		pivot = CFrame.new(c.X, c.Y + s.Y / 2, c.Z)
	else
		pivot = CFrame.new(c.X, c.Y - s.Y / 2, c.Z)
	end
	model.WorldPivot = pivot
	model:PivotTo(CFrame.new())
	-- Big pieces cast shadows; trinkets do not (S27).
	if entry.shadows ~= false then
		for _, part in model:GetDescendants() do
			if part:IsA("BasePart") and part.Size.Magnitude > 3 and part.Transparency < 0.5 then
				part.CastShadow = true
			end
		end
	end
	model:SetAttribute("SourceId", id)
	model:SetAttribute("Facing", why)
	return model
end

-- Loading ---------------------------------------------------------------------------------------------------------

local function fetch(id: number): (Instance?, string?)
	local ok, result = pcall(function()
		return AssetService:LoadAssetAsync(id)
	end)
	if ok and typeof(result) == "Instance" then
		return result, nil
	end
	local problem = tostring(result)
	-- Models the experience owner has in their inventory (or Roblox's own) still load the classic way.
	local okInsert, inserted = pcall(function()
		return InsertService:LoadAsset(id)
	end)
	if okInsert and typeof(inserted) == "Instance" then
		return inserted, nil
	end
	return nil, problem
end

local function loadKey(key: string)
	local entry = AssetManifest.get(key)
	if not entry then
		return
	end
	status[key] = "loading"
	local holder = Instance.new("Folder")
	holder.Name = key
	local made = 0
	local lastProblem = "no ids"
	for index, id in entry.ids do
		local loaded, problem = nil, nil
		for attempt = 1, ATTEMPTS do
			loaded, problem = fetch(id)
			if loaded then
				break
			end
			if attempt < ATTEMPTS then
				task.wait(1.5 * attempt)
			end
		end
		if loaded then
			local ok, result = pcall(function(): Model?
				local model = clean(loaded :: Instance, entry)
				return if model then normalise(model, entry, id) else nil
			end)
			if ok and result then
				local model = result :: Model
				model.Name = string.format("%02d", index)
				model.Parent = holder
				made += 1
			else
				lastProblem = if ok then "no parts" else tostring(result)
			end
		else
			lastProblem = problem or "unknown"
		end
	end
	if made > 0 then
		holder.Parent = root
		status[key] = "ready"
		loadedCount += 1
		local upgraded = Assets.upgrade(key)
		log:Debug(string.format("%s: %d model(s), %d slot(s) upgraded", key, made, upgraded))
		AssetLibraryService.Loaded:Fire(key)
	else
		holder:Destroy()
		status[key] = "failed"
		failures[key] = lastProblem
		failedCount += 1
	end
end

-- Keys that failed and why (for the admin notice and the debug screen).
function AssetLibraryService.failures(): { [string]: string }
	return failures
end

function AssetLibraryService.summary(): (number, number, boolean)
	return loadedCount, failedCount, finished
end

function AssetLibraryService.isFinished(): boolean
	return finished
end

-- True when nothing at all could load: almost always the "Allow Loading Third Party Assets" setting.
function AssetLibraryService.blocked(): boolean
	return finished and loadedCount == 0 and failedCount > 0
end

function AssetLibraryService.Init()
	Registry.add("AssetLibrary", AssetLibraryService)
	local existing = ReplicatedStorage:FindFirstChild(Assets.FOLDER)
	if existing then
		existing:Destroy()
	end
	root = Instance.new("Folder")
	root.Name = Assets.FOLDER
	root.Parent = ReplicatedStorage
end

function AssetLibraryService.Start()
	local flags = Registry.get("Flags")
	local function applyFlag()
		Assets.setEnabled(flags.feature("assets"))
	end
	applyFlag()
	flags.Changed:Connect(applyFlag)
	if not flags.feature("assets") then
		finished = true
		log:Info("asset library off (feature flag)")
		return
	end
	local keys = AssetManifest.keys()
	-- Headless test engines have no asset loading at all: they keep the procedural props.
	local canLoad = pcall(function(): any
		return (AssetService :: any).LoadAssetAsync
	end)
	if #keys == 0 or not canLoad or not RunService:IsServer() then
		finished = true
		AssetLibraryService.Finished:Fire({}, {})
		return
	end
	task.spawn(function()
		local started = os.clock()
		local queue = table.clone(keys)
		local running = 0
		local done = 0
		local function nextKey()
			local key = table.remove(queue, 1)
			if not key then
				return
			end
			running += 1
			task.spawn(function()
				local ok, problem = pcall(function(): any
					loadKey(key)
					return nil
				end)
				if not ok then
					status[key] = "failed"
					failures[key] = tostring(problem)
					failedCount += 1
				end
				running -= 1
				done += 1
				nextKey()
			end)
		end
		for _ = 1, CONCURRENCY do
			nextKey()
		end
		while done < #keys do
			task.wait(0.1)
		end
		finished = true
		local failedKeys = {}
		for key in failures do
			table.insert(failedKeys, key)
		end
		table.sort(failedKeys)
		log:Info(
			string.format(
				"asset library: %d/%d props ready in %.1fs%s",
				loadedCount,
				#keys,
				os.clock() - started,
				if #failedKeys > 0 then " (fallbacks: " .. table.concat(failedKeys, ", ") .. ")" else ""
			)
		)
		if AssetLibraryService.blocked() then
			local sample = failures[failedKeys[1]] or ""
			log:Warn(
				"no Creator Store model could load ("
					.. sample
					.. "). Turn on Game Settings > Security > "
					.. "Allow Loading Third Party Assets, then restart the server; until then the hotel uses its "
					.. "built-in props."
			)
		end
		AssetLibraryService.Finished:Fire(keys, failedKeys)
	end)
end

return AssetLibraryService
