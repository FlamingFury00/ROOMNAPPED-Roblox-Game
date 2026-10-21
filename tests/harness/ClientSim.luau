--[[
	ClientSim: runs the real ROOMNAPPED client next to the real server inside the Sim engine.

	One bot of a running Sim becomes the "local player". Its client gets its own module runtime (separate
	module state, like a separate VM) over the same DataModel the server uses, so every instance the server
	builds is visible to the client immediately (perfect replication). Remotes are routed both ways:
	FireServer reaches the server's OnServerEvent as that bot, and anything the server fires to the bot is
	delivered to the client's OnClientEvent. Input is simulated through the client's ContextActionService
	bindings (`press`, `release`) and GUI buttons can be clicked by name.

	Engine features the headless DOM lacks are provided here: computed properties are seeded when the client
	creates instances (Instance.new wrapper), client-only services are small proxies (input, GUI service,
	tweens that apply instantly, CollectionService tag signals that are polled), and camera projection,
	Model:ScaleTo and Workspace:BulkMoveTo are implemented. Every error - thrown at start-up, in a spawned
	thread or in a signal handler - lands in `sim.errors` (or `sim.warnings` for logged start failures).
]]

local roblox = require("@lune/roblox")
local luau = require("@lune/luau")

local Env = require("./Env")
local Events = require("./Events")

local ClientSim = {}
ClientSim.__index = ClientSim

local V3 = roblox.Vector3
local V2 = roblox.Vector2
local CF = roblox.CFrame

local shimsInstalled = false
local activeClient: any = nil

local function installShims()
	if shimsInstalled then
		return
	end
	shimsInstalled = true
	Events.install(Events.GUI_MEMBERS)
	local function noop() end
	for _, name in { "Play", "Stop", "Pause", "Resume" } do
		roblox.implementMethod("Sound", name, noop)
	end
	roblox.implementMethod("ParticleEmitter", "Emit", noop)
	roblox.implementMethod("ParticleEmitter", "Clear", noop)
	roblox.implementMethod("Humanoid", "SetStateEnabled", noop)
	roblox.implementMethod("Humanoid", "ChangeState", noop)
	roblox.implementMethod("Humanoid", "GetState", function()
		return roblox.Enum.HumanoidStateType.Running
	end)
	roblox.implementMethod("Workspace", "BulkMoveTo", function(_, parts: { any }, cframes: { any })
		for i, part in parts do
			local cf = cframes[i]
			if cf then
				part.CFrame = cf
			end
		end
	end)
	-- Uniform scale around the model pivot (enough for the unfold / fold animations to run).
	roblox.implementMethod("Model", "GetScale", function(model: any)
		local s = model:GetAttribute("ClientSimScale")
		return if type(s) == "number" then s else 1
	end)
	roblox.implementMethod("Model", "ScaleTo", function(model: any, scale: number)
		assert(type(scale) == "number" and scale > 0, "ScaleTo expects a positive number")
		local current = model:GetAttribute("ClientSimScale")
		local from = if type(current) == "number" then current else 1
		local factor = scale / from
		local pivot = model:GetPivot().Position
		for _, d in model:GetDescendants() do
			if d:IsA("BasePart") then
				local cf = d.CFrame
				local offset = cf.Position - pivot
				d.Size = d.Size * factor
				d.CFrame = cf.Rotation + (pivot + offset * factor)
			end
		end
		model:SetAttribute("ClientSimScale", scale)
	end)
	roblox.implementMethod("Model", "GetBoundingBox", function(model: any)
		local minV, maxV = nil, nil
		for _, d in model:GetDescendants() do
			if d:IsA("BasePart") then
				local cf, size = d.CFrame, d.Size
				for _, sx in { -0.5, 0.5 } do
					for _, sy in { -0.5, 0.5 } do
						for _, sz in { -0.5, 0.5 } do
							local p = cf * V3.new(size.X * sx, size.Y * sy, size.Z * sz)
							minV = if minV then minV:Min(p) else p
							maxV = if maxV then maxV:Max(p) else p
						end
					end
				end
			end
		end
		if not minV then
			return CF.new(), V3.zero
		end
		return CF.new((minV + maxV) / 2), maxV - minV
	end)
	-- Pinhole camera projection.
	local function project(camera: any, point: any): (any, boolean)
		local viewport = camera.ViewportSize
		local relative = camera.CFrame:PointToObjectSpace(point)
		local depth = -relative.Z
		local tanHalf = math.tan(math.rad(camera.FieldOfView) / 2)
		local aspect = viewport.X / viewport.Y
		local safeDepth = if math.abs(depth) < 1e-4 then 1e-4 else depth
		local nx = relative.X / (safeDepth * tanHalf * aspect)
		local ny = relative.Y / (safeDepth * tanHalf)
		local x = (nx + 1) / 2 * viewport.X
		local y = (1 - ny) / 2 * viewport.Y
		local onScreen = depth > 0 and x >= 0 and x <= viewport.X and y >= 0 and y <= viewport.Y
		return V3.new(x, y, depth), onScreen
	end
	roblox.implementMethod("Camera", "WorldToViewportPoint", project)
	roblox.implementMethod("Camera", "WorldToScreenPoint", project)
	local function ray(camera: any, x: number, y: number)
		local viewport = camera.ViewportSize
		local tanHalf = math.tan(math.rad(camera.FieldOfView) / 2)
		local aspect = viewport.X / viewport.Y
		local nx = (x / viewport.X) * 2 - 1
		local ny = 1 - (y / viewport.Y) * 2
		local direction = camera.CFrame:VectorToWorldSpace(V3.new(nx * tanHalf * aspect, ny * tanHalf, -1).Unit)
		return roblox.Ray.new(camera.CFrame.Position, direction)
	end
	roblox.implementMethod("Camera", "ViewportPointToRay", ray)
	roblox.implementMethod("Camera", "ScreenPointToRay", ray)
	-- Client -> server remotes.
	roblox.implementMethod("RemoteEvent", "FireServer", function(remote: any, ...)
		activeClient:toServer(remote, ...)
	end)
	roblox.implementMethod("UnreliableRemoteEvent", "FireServer", function(remote: any, ...)
		activeClient:toServer(remote, ...)
	end)
	roblox.implementMethod("RemoteFunction", "InvokeServer", function(remote: any, ...)
		local handler = activeClient.sim.invokeHandlers[remote]
		assert(handler, "no OnServerInvoke for " .. remote.Name)
		return handler(activeClient.player, ...)
	end)
end

-- Size every GuiBase2d reports (the safe-area size of the simulated screen).
local guiScreen = V2.new(1280, 720)

-- Seed properties the engine computes (Lune only returns values that were written first).
local function seed(inst: any)
	if inst:IsA("GuiBase2d") then
		inst.AbsoluteSize = guiScreen
		inst.AbsolutePosition = V2.zero
	end
	if inst:IsA("Sound") then
		inst.IsPlaying = false
		inst.TimeLength = 1
		inst.IsLoaded = true
	end
	if inst:IsA("BasePart") then
		inst.AssemblyLinearVelocity = V3.zero
	end
end

local function proxyOf(real: any, fields: { [string]: any }): any
	return setmetatable(fields, {
		__index = function(_, key)
			local value = real[key]
			if type(value) == "function" then
				return function(_self, ...)
					return value(real, ...)
				end
			end
			return value
		end,
	})
end

-- Options: `device` picks the simulated input family ("keyboard" by default, "touch" or "gamepad");
-- `viewport` is the screen size (1280x720 by default) and `safeArea` the size the HUD guis get inside the
-- device and top-bar insets (defaults to the viewport).
function ClientSim.attach(sim: any, bot: any, options: { device: string?, viewport: any?, safeArea: any? }?)
	installShims()
	local opts = options or {}
	local kind = opts.device or "keyboard"
	local viewport = opts.viewport or V2.new(1280, 720)
	guiScreen = opts.safeArea or viewport
	local self = setmetatable({}, ClientSim)
	activeClient = self
	Events.setDispatcher(function(fn, ...)
		sim.task.spawn(fn, ...)
	end)
	self.sim = sim
	self.bot = bot
	self.player = bot.player
	self.binds = {}
	self.tagWatchers = {}
	local game = sim.game
	local player = bot.player

	-- Local player setup.
	player.LocaleId = "en-us"
	local playerGui = player:FindFirstChild("PlayerGui")
	if not playerGui then
		playerGui = roblox.Instance.new("PlayerGui")
		playerGui.Parent = player
	end
	self.playerGui = playerGui
	local workspace = sim.workspace
	local camera = workspace:FindFirstChildOfClass("Camera")
	if not camera then
		camera = roblox.Instance.new("Camera")
		camera.Parent = workspace
	end
	camera.ViewportSize = viewport
	camera.FieldOfView = 70
	camera.CFrame = CF.new(0, 20, 30)
	workspace.CurrentCamera = camera
	if not workspace:FindFirstChildOfClass("Terrain") then
		local terrain = roblox.Instance.new("Terrain")
		terrain.Parent = workspace
	end
	self.camera = camera

	local function signal()
		return Events.newSignal()
	end
	local RunServiceReal = game:GetService("RunService")
	local services = {}
	services.Players = proxyOf(game:GetService("Players"), {
		LocalPlayer = player,
		GetUserThumbnailAsync = function(_, userId: number)
			return "rbxthumb://type=AvatarHeadShot&id=" .. tostring(userId) .. "&w=150&h=150"
		end,
	})
	services.RunService = proxyOf(RunServiceReal, {
		IsClient = function()
			return true
		end,
		IsServer = function()
			return false
		end,
		IsStudio = function()
			return true
		end,
		BindToRenderStep = function() end,
		UnbindFromRenderStep = function() end,
	})
	local lastInput = if kind == "touch"
		then roblox.Enum.UserInputType.Touch
		elseif kind == "gamepad" then roblox.Enum.UserInputType.Gamepad1
		else roblox.Enum.UserInputType.Keyboard
	services.UserInputService = proxyOf(game:GetService("UserInputService"), {
		TouchEnabled = kind == "touch",
		KeyboardEnabled = kind == "keyboard",
		GamepadEnabled = kind == "gamepad",
		MouseEnabled = kind == "keyboard",
		LastInputTypeChanged = signal(),
		InputBegan = signal(),
		InputChanged = signal(),
		InputEnded = signal(),
		WindowFocusReleased = signal(),
		WindowFocused = signal(),
		GetLastInputType = function()
			return lastInput
		end,
		GetImageForKeyCode = function()
			return ""
		end,
		GetMouseLocation = function()
			return V2.new(640, 360)
		end,
		GetGamepadState = function()
			return {}
		end,
	})
	services.GuiService = proxyOf(game:GetService("GuiService"), {
		SelectedObject = nil,
		IsTenFootInterface = function()
			return false
		end,
		GetGuiInset = function()
			return V2.zero, V2.zero
		end,
	})
	local binds = self.binds
	services.ContextActionService = proxyOf(game:GetService("ContextActionService"), {
		BindAction = function(_, name: string, fn: any, _touch: boolean, ...)
			binds[name] = { fn = fn, inputs = { ... }, priority = 0 }
		end,
		BindActionAtPriority = function(_, name: string, fn: any, _touch: boolean, priority: number, ...)
			binds[name] = { fn = fn, inputs = { ... }, priority = priority }
		end,
		UnbindAction = function(_, name: string)
			binds[name] = nil
		end,
	})
	services.TweenService = proxyOf(game:GetService("TweenService"), {
		Create = function(_, instance: any, _info: any, goal: { [string]: any })
			local completed = signal()
			local tween = { Completed = completed, PlaybackState = roblox.Enum.PlaybackState.Begin }
			function tween:Play()
				for key, value in goal do
					instance[key] = value
				end
				sim.task.defer(function()
					completed:Fire(roblox.Enum.PlaybackState.Completed)
				end)
			end
			function tween:Cancel() end
			function tween:Pause() end
			function tween:Destroy() end
			return tween
		end,
		GetValue = function(_, alpha: number)
			return alpha
		end,
	})
	local tagWatchers = self.tagWatchers
	services.CollectionService = proxyOf(game:GetService("CollectionService"), {
		GetTagged = function(_, tag: string)
			local out = {}
			for _, d in game:GetDescendants() do
				if d:HasTag(tag) then
					table.insert(out, d)
				end
			end
			return out
		end,
		GetInstanceAddedSignal = function(_, tag: string)
			local watcher = tagWatchers[tag]
			if not watcher then
				watcher = { added = signal(), removed = signal(), seen = {} }
				for _, d in game:GetDescendants() do
					if d:HasTag(tag) then
						watcher.seen[d] = true
					end
				end
				tagWatchers[tag] = watcher
			end
			return watcher.added
		end,
		GetInstanceRemovedSignal = function(_, tag: string)
			local watcher = tagWatchers[tag]
			if not watcher then
				watcher = { added = signal(), removed = signal(), seen = {} }
				tagWatchers[tag] = watcher
			end
			return watcher.removed
		end,
	})
	services.ContentProvider = proxyOf(game:GetService("ContentProvider"), {
		PreloadAsync = function(_, list: any, callback: any)
			if callback then
				for _, item in list do
					callback(tostring(item), roblox.Enum.AssetFetchStatus.Success)
				end
			end
		end,
	})
	services.StarterGui = proxyOf(game:GetService("StarterGui"), {
		SetCore = function() end,
		SetCoreGuiEnabled = function() end,
		GetCore = function()
			return nil
		end,
	})
	-- Friend invites: always allowed; prompts are counted.
	self.invitePrompts = 0
	services.SocialService = proxyOf(game:GetService("SocialService"), {
		CanSendGameInviteAsync = function()
			return true
		end,
		PromptGameInvite = function()
			self.invitePrompts += 1
		end,
	})
	services.Debris = proxyOf(game:GetService("Debris"), {
		AddItem = function(_, item: any, lifetime: number?)
			sim.task.delay(lifetime or 10, function()
				if item.Parent then
					item:Destroy()
				end
			end)
		end,
	})
	self.services = services

	local gameProxy = setmetatable({
		GetService = function(_, name: string)
			return services[name] or game:GetService(name)
		end,
		IsLoaded = function()
			return true
		end,
		Loaded = signal(),
	}, {
		__index = function(_, key)
			local value = game[key]
			if type(value) == "function" then
				return function(_self, ...)
					return value(game, ...)
				end
			end
			return value
		end,
	})

	local InstanceReal = roblox.Instance
	local InstanceWrapper = {
		new = function(className: string, parent: any?)
			local inst = InstanceReal.new(className)
			seed(inst)
			if parent then
				inst.Parent = parent
			end
			return inst
		end,
	}

	local runtime = Env.runtime(game, {
		game = gameProxy,
		workspace = workspace,
		Instance = InstanceWrapper,
		task = sim.task,
		os = sim.fakeOs,
		tick = sim.fakeOs.clock,
		time = sim.fakeOs.clock,
		wait = sim.task.wait,
		delay = sim.task.delay,
		spawn = sim.task.spawn,
		warn = function(...)
			local parts = {}
			for i = 1, select("#", ...) do
				table.insert(parts, tostring((select(i, ...))))
			end
			table.insert(sim.warnings, table.concat(parts, " "))
		end,
		print = function() end,
		RaycastParams = sim.loaded.env.RaycastParams,
		TweenInfo = {
			new = function(time: number?, style: any?, direction: any?)
				return { Time = time or 1, EasingStyle = style, EasingDirection = direction }
			end,
		},
		typeof = typeof,
	})
	self.runtime = runtime
	self.clientScript = Env.find(game, "StarterPlayer.StarterPlayerScripts.Client")
	sim.client = self
	return self
end

-- Start the shipped client bootstrap LocalScript.
function ClientSim.start(self: any)
	local env = table.clone(self.runtime.env)
	env.script = self.clientScript
	env.require = self.runtime.require
	local fn = luau.load(self.clientScript.Source, { debugName = "Client", environment = env, injectGlobals = true })
	self.sim.task.spawn(fn)
end

function ClientSim.module(self: any, path: string): any
	local target = self.clientScript
	for segment in string.gmatch(path, "[^%.]+") do
		target = target:FindFirstChild(segment)
		assert(target, "missing client module " .. path)
	end
	return self.runtime.require(target)
end

-- Remote routing --------------------------------------------------------------------------------------------

function ClientSim.toServer(self: any, remote: any, ...)
	self.sim:fireServerEvent(remote, self.player, ...)
end

-- Called by Sim.deliver for the attached player.
function ClientSim.toClient(self: any, remoteName: string, ...)
	local remote = self.sim.game.ReplicatedStorage.RoomnappedRemotes:FindFirstChild(remoteName)
	if remote then
		self.sim:fireClientEvent(remote, ...)
	end
end

-- Input ------------------------------------------------------------------------------------------------------

local function inputObject(keyCode: any): any
	return {
		KeyCode = keyCode,
		UserInputType = roblox.Enum.UserInputType.Keyboard,
		UserInputState = roblox.Enum.UserInputState.Begin,
		Position = V3.zero,
		Delta = V3.zero,
	}
end

-- Send a Begin to the highest-priority binding of `actionName` (e.g. "RN_Use").
function ClientSim.press(self: any, actionName: string)
	local bind = self.binds[actionName]
	assert(bind, "no ContextActionService binding named " .. actionName)
	self.sim.task.spawn(bind.fn, actionName, roblox.Enum.UserInputState.Begin, inputObject(bind.inputs[1]))
end

function ClientSim.release(self: any, actionName: string)
	local bind = self.binds[actionName]
	assert(bind, "no ContextActionService binding named " .. actionName)
	self.sim.task.spawn(bind.fn, actionName, roblox.Enum.UserInputState.End, inputObject(bind.inputs[1]))
end

function ClientSim.tap(self: any, actionName: string)
	self:press(actionName)
	self.sim:run(1 / 30)
	self:release(actionName)
end

-- GUI: find descendants of the PlayerGui by name and click buttons.
function ClientSim.findAll(self: any, name: string): { any }
	local out = {}
	for _, d in self.playerGui:GetDescendants() do
		if d.Name == name then
			table.insert(out, d)
		end
	end
	return out
end

function ClientSim.find(self: any, name: string): any
	return self:findAll(name)[1]
end

function ClientSim.click(self: any, button: any)
	Events.eventFor(button, "Activated"):Fire()
end

-- Finger down / up on a GUI object (fires its InputBegan / InputEnded with a Touch input).
local function touchInput(state: any): any
	return {
		UserInputType = roblox.Enum.UserInputType.Touch,
		UserInputState = state,
		Position = V3.zero,
		Delta = V3.zero,
	}
end

function ClientSim.touchDown(self: any, gui: any)
	Events.eventFor(gui, "InputBegan"):Fire(touchInput(roblox.Enum.UserInputState.Begin))
end

function ClientSim.touchUp(self: any, gui: any)
	Events.eventFor(gui, "InputEnded"):Fire(touchInput(roblox.Enum.UserInputState.End))
end

-- Per-frame upkeep (called by Sim.run): tag signals and the camera following the character.
function ClientSim.step(self: any)
	local character = self.player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root then
		local p = root.CFrame.Position
		self.camera.CFrame = CF.lookAt(p + V3.new(0, 9, 14), p)
	end
	self.tagTimer = (self.tagTimer or 0) + 1
	if self.tagTimer % 15 ~= 0 then
		return
	end
	local game = self.sim.game
	for tag, watcher in self.tagWatchers do
		local present = {}
		for _, d in game:GetDescendants() do
			if d:HasTag(tag) then
				present[d] = true
				if not watcher.seen[d] then
					watcher.seen[d] = true
					watcher.added:Fire(d)
				end
			end
		end
		for inst in watcher.seen do
			if not present[inst] then
				watcher.seen[inst] = nil
				watcher.removed:Fire(inst)
			end
		end
	end
end

return ClientSim
