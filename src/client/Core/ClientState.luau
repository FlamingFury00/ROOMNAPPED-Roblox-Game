--!strict
--[[
	ClientState: read-only mirror of the server's replicated state channels.

	ClientState.observe("global", "run.phase", fn) calls fn(value) immediately and whenever that path,
	one of its ancestors or one of its descendants changes. Patches that arrive before the initial
	snapshot are buffered and replayed in sequence.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage.Shared.Net.Net)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local StatePath = require(ReplicatedStorage.Shared.Net.StatePath)

type ChannelState = { seq: number, data: { [string]: any } }
type Observer = { channel: string, path: StatePath.Path, fn: (any) -> (), connected: boolean }

local ClientState = {}

local channels: { [string]: ChannelState } = {}
local buffered: { { name: string, seq: number, patches: { StatePath.Patch } } } = {}
local observers: { Observer } = {}
local ready = false

ClientState.Ready = Signal.new()
ClientState.Changed = Signal.new() -- (channelName, path)

local function notify(channelName: string, paths: { StatePath.Path })
	local toCall: { Observer } = {}
	for _, observer in observers do
		if observer.connected and observer.channel == channelName then
			for _, path in paths do
				if StatePath.isPrefix(observer.path, path) or StatePath.isPrefix(path, observer.path) then
					table.insert(toCall, observer)
					break
				end
			end
		end
	end
	local channel = channels[channelName]
	for _, observer in toCall do
		if observer.connected then
			local value = if channel then StatePath.get(channel.data, observer.path) else nil
			task.spawn(observer.fn, value)
		end
	end
	for _, path in paths do
		ClientState.Changed:Fire(channelName, path)
	end
end

local function applyPatches(name: string, seq: number, patches: { StatePath.Patch }, silent: boolean?)
	local channel = channels[name]
	if not channel then
		channel = { seq = 0, data = {} }
		channels[name] = channel
	end
	if seq <= channel.seq then
		return
	end
	channel.seq = seq
	local paths = {}
	for _, patch in patches do
		StatePath.apply(channel.data, patch)
		table.insert(paths, patch.p)
	end
	if not silent then
		notify(name, paths)
	end
end

function ClientState.init()
	Net.listen("StatePatch", function(name: string, seq: number, patches: { StatePath.Patch })
		if not ready then
			table.insert(buffered, { name = name, seq = seq, patches = patches })
			return
		end
		applyPatches(name, seq, patches)
	end)

	task.spawn(function()
		local attempt = 0
		while not ready do
			attempt += 1
			local ok, snapshot = pcall(Net.invoke, "GetSnapshot")
			if ok and type(snapshot) == "table" then
				for name, payload in snapshot :: { [string]: any } do
					channels[name] = { seq = payload.seq or 0, data = payload.data or {} }
				end
				ready = true
				local pending = buffered
				buffered = {}
				table.sort(pending, function(a, b)
					return a.seq < b.seq
				end)
				for _, entry in pending do
					applyPatches(entry.name, entry.seq, entry.patches, true)
				end
				-- Fire every observer once with the bootstrapped values.
				for _, observer in observers do
					if observer.connected then
						local channel = channels[observer.channel]
						local value = if channel then StatePath.get(channel.data, observer.path) else nil
						task.spawn(observer.fn, value)
					end
				end
				ClientState.Ready:Fire()
			else
				task.wait(math.min(5, attempt))
			end
		end
	end)
end

function ClientState.isReady(): boolean
	return ready
end

function ClientState.waitUntilReady()
	if not ready then
		ClientState.Ready:Wait()
	end
end

function ClientState.get(channelName: string, pathText: string?): any
	local channel = channels[channelName]
	if not channel then
		return nil
	end
	if pathText == nil or pathText == "" then
		return channel.data
	end
	return StatePath.get(channel.data, StatePath.parse(pathText))
end

export type ObserverConnection = { Disconnect: (self: ObserverConnection) -> (), Connected: boolean }

function ClientState.observe(channelName: string, pathText: string, fn: (any) -> ()): ObserverConnection
	local observer: Observer = {
		channel = channelName,
		path = StatePath.parse(pathText),
		fn = fn,
		connected = true,
	}
	table.insert(observers, observer)
	if ready then
		task.spawn(fn, ClientState.get(channelName, pathText))
	end
	local connection = {} :: ObserverConnection
	connection.Connected = true
	function connection.Disconnect(conn: ObserverConnection)
		if not conn.Connected then
			return
		end
		conn.Connected = false
		observer.connected = false
		local index = table.find(observers, observer)
		if index then
			table.remove(observers, index)
		end
	end
	return connection
end

return ClientState
