--[[
	ClientEnv: a headless stand-in for the Roblox client used to smoke-test the interface.

	Loads the built place with Env and runs the real client modules (UI kit, UIRoot, screens, HUD) against
	proxy services: a fake LocalPlayer with a real PlayerGui, scriptable input/run-service signals, a
	TweenService that applies goals instantly (so every tweened property is still validated by Lune's
	reflection database), and a scripted Net stub that serves a state snapshot and records every remote the
	UI sends (validated against the real remote schemas).

	Device, Responsive and AudioController are replaced by small stubs: they read engine-computed
	properties (viewport and absolute sizes, input capabilities) or play audio, none of which exist
	headlessly. Errors raised anywhere - including inside spawned threads and signal handlers - are
	collected in `client.errors` so a spec can assert the interface ran cleanly.
]]

local roblox = require("@lune/roblox")
local task = require("@lune/task")

local Env = require("./Env")
local Events = require("./Events")

local ClientEnv = {}
ClientEnv.__index = ClientEnv

-- xpcall handler that never fails itself (error objects may be userdata).
local function handler(err: any): string
	local ok, text = pcall(tostring, err)
	local message = if ok then text else "<unprintable error>"
	local traced, trace = pcall(debug.traceback, message, 2)
	return if traced and type(trace) == "string" then trace else message
end

-- Signals ------------------------------------------------------------------------------------------------------

local function newSignal(errors: { string })
	local signal = { listeners = {} }
	function signal:Connect(fn)
		local connection = { Connected = true }
		local record = { fn = fn, connection = connection }
		table.insert(signal.listeners, record)
		function connection:Disconnect()
			connection.Connected = false
			local index = table.find(signal.listeners, record)
			if index then
				table.remove(signal.listeners, index)
			end
		end
		return connection
	end
	function signal:Once(fn)
		local connection
		connection = signal:Connect(function(...)
			connection:Disconnect()
			fn(...)
		end)
		return connection
	end
	function signal:Wait()
		local thread = coroutine.running()
		local connection
		connection = signal:Connect(function(...)
			connection:Disconnect()
			task.spawn(thread, ...)
		end)
		return coroutine.yield()
	end
	function signal:Fire(...)
		for _, record in table.clone(signal.listeners) do
			if record.connection.Connected then
				local ok, err = xpcall(record.fn, handler, ...)
				if not ok then
					table.insert(errors, tostring(err))
				end
			end
		end
	end
	return signal
end

local shimsInstalled = false

local function eventFor(inst: any, name: string)
	return Events.eventFor(inst, name)
end

local function installShims()
	if shimsInstalled then
		return
	end
	shimsInstalled = true
	-- Shared with ClientSim: one registry, dispatched by whichever harness is active.
	Events.install(Events.GUI_MEMBERS)
	Events.install({
		{ "Instance", "Destroying" },
		{ "Instance", "ChildAdded" },
		{ "Instance", "ChildRemoved" },
		{ "Instance", "DescendantAdded" },
		{ "Instance", "AncestryChanged" },
	})
	-- Model:GetBoundingBox (used by the 3D previews). Another harness may already have implemented it.
	pcall(roblox.implementMethod, "Model", "GetBoundingBox", function(model: any)
		local minV, maxV = nil, nil
		for _, d in model:GetDescendants() do
			if d:IsA("BasePart") then
				local cf, size = d.CFrame, d.Size
				for _, sx in { -0.5, 0.5 } do
					for _, sy in { -0.5, 0.5 } do
						for _, sz in { -0.5, 0.5 } do
							local p = cf * roblox.Vector3.new(size.X * sx, size.Y * sy, size.Z * sz)
							minV = if minV then minV:Min(p) else p
							maxV = if maxV then maxV:Max(p) else p
						end
					end
				end
			end
		end
		if not minV then
			return roblox.CFrame.new(), roblox.Vector3.zero
		end
		return roblox.CFrame.new((minV + maxV) / 2), maxV - minV
	end)
end

-- Proxy services ---------------------------------------------------------------------------------------------------

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

function ClientEnv.new(placePath: string)
	installShims()
	local self = setmetatable({}, ClientEnv)
	self.errors = {}
	local errors0 = self.errors
	Events.setDispatcher(function(fn, ...)
		local ok, err = xpcall(fn, handler, ...)
		if not ok then
			table.insert(errors0, tostring(err))
		end
	end)
	self.sent = {}
	self.handlers = {}
	self.binds = {}
	self.snapshot = { global = { seq = 0, data = {} }, me = { seq = 0, data = {} } }
	self.seq = { global = 0, me = 0 }

	-- GUI objects report a 1280x720 screen at the origin (Lune only returns computed properties once written).
	local InstanceWrapper = {
		new = function(className: string, parent: any?)
			local inst = roblox.Instance.new(className)
			if inst:IsA("GuiBase2d") then
				inst.AbsoluteSize = roblox.Vector2.new(1280, 720)
				inst.AbsolutePosition = roblox.Vector2.zero
			end
			if parent then
				inst.Parent = parent
			end
			return inst
		end,
	}
	local loaded = Env.load(placePath, {
		Instance = InstanceWrapper,
		-- A client module that fails to start (logged, then skipped by the bootstrap) is a test failure.
		warn = function(...)
			local parts = {}
			for i = 1, select("#", ...) do
				table.insert(parts, tostring((select(i, ...))))
			end
			local text = table.concat(parts, " ")
			print("[warn]", text)
			if string.find(text, "failed to start", 1, true) then
				table.insert(errors0, text)
			end
		end,
		TweenInfo = {
			new = function(time: number?, style: any?, direction: any?)
				return { Time = time or 1, EasingStyle = style, EasingDirection = direction }
			end,
		},
		typeof = typeof,
		RaycastParams = {
			new = function()
				return {
					FilterType = roblox.Enum.RaycastFilterType.Exclude,
					FilterDescendantsInstances = {},
					IgnoreWater = false,
				}
			end,
		},
	})
	self.loaded = loaded
	local game = loaded.game
	self.game = game
	local errors = self.errors

	-- Error-capturing task library: failures in spawned threads become test failures.
	local function wrap(fn: any): any
		if type(fn) ~= "function" then
			return fn
		end
		return function(...)
			local ok, err = xpcall(fn, handler, ...)
			if not ok then
				table.insert(errors, tostring(err))
			end
		end
	end
	loaded.env.task = {
		spawn = function(fn, ...)
			return task.spawn(wrap(fn), ...)
		end,
		defer = function(fn, ...)
			return task.defer(wrap(fn), ...)
		end,
		delay = function(t, fn, ...)
			return task.delay(t, wrap(fn), ...)
		end,
		wait = task.wait,
		cancel = task.cancel,
	}

	local function signal()
		return newSignal(errors)
	end
	self.signal = signal

	-- Local player with a real PlayerGui.
	local playerGui = roblox.Instance.new("PlayerGui")
	self.playerGui = playerGui
	local attributes = {}
	local localPlayer = {
		Name = "Tester",
		DisplayName = "Tester",
		UserId = 1001,
		LocaleId = "en-us",
		Character = nil,
		CharacterAdded = signal(),
		CharacterRemoving = signal(),
	}
	function localPlayer:WaitForChild(name: string)
		if name == "PlayerGui" then
			return playerGui
		end
		error("LocalPlayer:WaitForChild(" .. tostring(name) .. ") is not available in ClientEnv")
	end
	function localPlayer:FindFirstChild(name: string)
		return if name == "PlayerGui" then playerGui else nil
	end
	function localPlayer:GetAttribute(key: string)
		return attributes[key]
	end
	function localPlayer:SetAttribute(key: string, value: any)
		attributes[key] = value
	end
	function localPlayer:GetAttributeChangedSignal()
		return signal()
	end
	self.localPlayer = localPlayer

	local realWorkspace = game:GetService("Workspace")
	local camera = { ViewportSize = roblox.Vector2.new(1280, 720), FieldOfView = 70 }
	function camera:GetPropertyChangedSignal()
		return signal()
	end
	local clockStart = os.clock()

	local services = {}
	services.Players = proxyOf(game:GetService("Players"), {
		LocalPlayer = localPlayer,
		GetPlayerByUserId = function()
			return nil
		end,
		GetPlayers = function()
			return {}
		end,
		GetUserThumbnailAsync = function(_, userId: number)
			return "rbxthumb://type=AvatarHeadShot&id=" .. tostring(userId) .. "&w=150&h=150"
		end,
	})
	services.RunService = proxyOf(game:GetService("RunService"), {
		Heartbeat = signal(),
		RenderStepped = signal(),
		PreSimulation = signal(),
		Stepped = signal(),
		IsStudio = function()
			return false
		end,
		IsClient = function()
			return true
		end,
		IsServer = function()
			return false
		end,
		BindToRenderStep = function() end,
		UnbindFromRenderStep = function() end,
	})
	services.UserInputService = proxyOf(game:GetService("UserInputService"), {
		TouchEnabled = false,
		KeyboardEnabled = true,
		GamepadEnabled = false,
		MouseEnabled = true,
		LastInputTypeChanged = signal(),
		InputBegan = signal(),
		InputChanged = signal(),
		InputEnded = signal(),
		WindowFocusReleased = signal(),
		WindowFocused = signal(),
		GetLastInputType = function()
			return roblox.Enum.UserInputType.Keyboard
		end,
		GetImageForKeyCode = function()
			return ""
		end,
	})
	services.GuiService = proxyOf(game:GetService("GuiService"), {
		SelectedObject = nil,
		IsTenFootInterface = function()
			return false
		end,
		GetGuiInset = function()
			return roblox.Vector2.zero, roblox.Vector2.zero
		end,
	})
	local binds = self.binds
	services.ContextActionService = proxyOf(game:GetService("ContextActionService"), {
		BindAction = function(_, name: string, fn: any, _touch: boolean, ...)
			binds[name] = { fn = fn, inputs = { ... } }
		end,
		BindActionAtPriority = function(_, name: string, fn: any, _touch: boolean, _priority: number, ...)
			binds[name] = { fn = fn, inputs = { ... } }
		end,
		UnbindAction = function(_, name: string)
			binds[name] = nil
		end,
	})
	services.TweenService = proxyOf(game:GetService("TweenService"), {
		Create = function(_, instance: any, _info: any, goal: { [string]: any })
			local completed = signal()
			local tween = { Completed = completed, PlaybackState = "Begin" }
			function tween:Play()
				for key, value in goal do
					instance[key] = value
				end
				task.defer(function()
					completed:Fire(roblox.Enum.PlaybackState.Completed)
				end)
			end
			function tween:Cancel() end
			function tween:Pause() end
			function tween:Destroy() end
			return tween
		end,
	})
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
		GetInstanceAddedSignal = function()
			return signal()
		end,
		GetInstanceRemovedSignal = function()
			return signal()
		end,
	})
	services.Workspace = proxyOf(realWorkspace, {
		CurrentCamera = camera,
		GetServerTimeNow = function()
			return 1000 + (os.clock() - clockStart)
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
	loaded.env.game = gameProxy
	loaded.env.workspace = services.Workspace

	-- Module stubs ------------------------------------------------------------------------------------------------
	local client = Env.find(game, "StarterPlayer.StarterPlayerScripts.Client")
	self.clientRoot = client
	local shared = Env.find(game, "ReplicatedStorage.Shared")

	-- Keep the real Net for schema validation, then stub it for the UI.
	local realNet = loaded.require(shared.Net.Net)
	local Remotes = loaded.require(shared.Net.Remotes)
	local sent = self.sent
	local handlers = self.handlers
	local selfRef = self
	loaded.overrides[shared.Net.Net] = {
		initClient = function() end,
		send = function(name: string, ...)
			local def = Remotes.ClientEvents[name]
			if not def then
				table.insert(errors, "UI sent unknown remote " .. tostring(name))
			elseif not realNet.validate(def.schema, ...) then
				table.insert(errors, "UI sent remote " .. name .. " with arguments that fail its schema")
			end
			table.insert(sent, { name = name, args = table.pack(...) })
		end,
		listen = function(name: string, handler: any)
			handlers[name] = handlers[name] or {}
			table.insert(handlers[name], handler)
			return { Connected = true, Disconnect = function() end }
		end,
		invoke = function(name: string)
			if name == "GetSnapshot" then
				return selfRef.snapshot
			end
			return nil
		end,
	}
	loaded.overrides[client.Core.Device] = {
		Changed = signal(),
		kind = function()
			return "keyboard"
		end,
		isTouch = function()
			return false
		end,
		isGamepad = function()
			return false
		end,
		isKeyboard = function()
			return true
		end,
		hasTouch = function()
			return false
		end,
		isSmallScreen = function()
			return false
		end,
		hintSuffix = function()
			return "keyboard"
		end,
	}
	local responsiveChanged = signal()
	loaded.overrides[client.UI.Responsive] = {
		Changed = responsiveChanged,
		root = function(gui: any, name: string?)
			local frame = roblox.Instance.new("Frame")
			frame.Name = name or "Root"
			frame.BackgroundTransparency = 1
			frame.Size = roblox.UDim2.fromScale(1, 1)
			frame.Parent = gui
			return frame
		end,
		scaleOf = function()
			return 1
		end,
		canvasSize = function()
			return roblox.Vector2.new(1280, 720)
		end,
		setUserScale = function() end,
		isCompact = function()
			return false
		end,
		toCanvas = function(_gui: any, point: any)
			return point
		end,
	}
	local function noop() end
	loaded.overrides[client.Controllers.AudioController] = {
		play = noop,
		ui = noop,
		at = noop,
		loop = function()
			return nil
		end,
		setMuffled = noop,
		setMusic = noop,
		setDuck = noop,
		setAmbience = noop,
		playSting = noop,
		refreshMusic = noop,
		start = noop,
	}
	return self
end

-- Require a client module by dotted path below the Client script (e.g. "UI.Screens.Results").
function ClientEnv:module(path: string): any
	local target = self.clientRoot
	for segment in string.gmatch(path, "[^%.]+") do
		target = target:FindFirstChild(segment)
		assert(target, "missing client module " .. path)
	end
	return self.loaded.require(target)
end

function ClientEnv:shared(path: string): any
	return self.loaded.require(Env.find(self.game, "ReplicatedStorage.Shared." .. path))
end

-- Fire a server->client remote into the UI.
function ClientEnv:fire(name: string, ...)
	for _, listener in self.handlers[name] or {} do
		local ok, err = xpcall(listener, handler, ...)
		if not ok then
			table.insert(self.errors, tostring(err))
		end
	end
end

-- Apply a state patch (path list, value) on a channel the way the server's StatePatch does.
function ClientEnv:patch(channel: string, path: { string }, value: any)
	self.seq[channel] = (self.seq[channel] or 0) + 1
	self:fire("StatePatch", channel, self.seq[channel], { { p = path, v = value } })
end

-- Press a GUI button (fires Activated like a click / tap / gamepad A).
function ClientEnv:press(button: any)
	eventFor(button, "Activated"):Fire()
end

function ClientEnv:event(inst: any, name: string): any
	return eventFor(inst, name)
end

-- All descendants of the player's interface whose Name matches.
function ClientEnv:findAll(name: string): { any }
	local out = {}
	for _, d in self.playerGui:GetDescendants() do
		if d.Name == name then
			table.insert(out, d)
		end
	end
	return out
end

function ClientEnv:find(name: string): any
	return self:findAll(name)[1]
end

function ClientEnv:sentNamed(name: string): { any }
	local out = {}
	for _, entry in self.sent do
		if entry.name == name then
			table.insert(out, entry)
		end
	end
	return out
end

return ClientEnv
