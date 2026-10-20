--[[
	Events: one registry for engine events that the headless DOM does not implement (GuiButton.Activated,
	Sound.Ended, ...), shared by every harness in a test run.

	Lune lets a member be implemented once per process, so the harnesses must not each install their own:
	the first install wins and a later harness would silently keep the earlier one's dispatch. Here the
	members are installed once and every Fire goes through the *currently active* dispatcher, which each
	harness sets when it starts (ClientEnv dispatches immediately and records errors, ClientSim schedules on
	the simulation's task scheduler).

	Lune can hand out a new userdata wrapper for an instance after the old one is collected, so signals are
	keyed by a stable id stored as an attribute on the instance.
]]

local roblox = require("@lune/roblox")

local Events = {}

local dispatcher: (fn: (...any) -> (), ...any) -> () = function(fn, ...)
	fn(...)
end

function Events.setDispatcher(fn: (fn: (...any) -> (), ...any) -> ())
	dispatcher = fn
end

function Events.newSignal(): any
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
			coroutine.resume(thread, ...)
		end)
		return coroutine.yield()
	end
	function signal:Fire(...)
		for _, record in table.clone(signal.listeners) do
			if record.connection.Connected then
				dispatcher(record.fn, ...)
			end
		end
	end
	return signal
end

local nextId = 0
local registry: { [number]: { [string]: any } } = {}

local function idOf(inst: any): number
	local id = inst:GetAttribute("HarnessEventId")
	if type(id) ~= "number" then
		nextId += 1
		id = nextId
		inst:SetAttribute("HarnessEventId", id)
	end
	return id
end

function Events.eventFor(inst: any, name: string): any
	local key = idOf(inst)
	local perInstance = registry[key]
	if not perInstance then
		perInstance = {}
		registry[key] = perInstance
	end
	local signal = perInstance[name]
	if not signal then
		signal = Events.newSignal()
		perInstance[name] = signal
	end
	return signal
end

local installed: { [string]: boolean } = {}

-- Implement `class.member` as a registry event (once per process).
function Events.install(members: { { string } })
	for _, pair in members do
		local key = pair[1] .. "." .. pair[2]
		if not installed[key] then
			installed[key] = true
			pcall(function()
				roblox.implementProperty(pair[1], pair[2], function(inst: any)
					return Events.eventFor(inst, pair[2])
				end)
			end)
		end
	end
end

Events.GUI_MEMBERS = {
	{ "GuiButton", "Activated" },
	{ "GuiButton", "MouseButton1Click" },
	{ "GuiObject", "MouseEnter" },
	{ "GuiObject", "MouseLeave" },
	{ "GuiObject", "InputBegan" },
	{ "GuiObject", "InputChanged" },
	{ "GuiObject", "InputEnded" },
	{ "GuiObject", "SelectionGained" },
	{ "GuiObject", "SelectionLost" },
	{ "TextBox", "FocusLost" },
	{ "TextBox", "Focused" },
	{ "BindableEvent", "Event" },
	{ "Sound", "Ended" },
	{ "Sound", "Played" },
	{ "Player", "CharacterRemoving" },
	{ "Instance", "Changed" },
}

return Events
