--!strict
--[[
	StateServer: authoritative replicated state channels.

	Game services write with channel:Set(path, value) / channel:Delete(path). Writes apply immediately to the
	server copy and are batched into one StatePatch per channel per frame. Clients bootstrap with the
	GetSnapshot remote function and then apply patches in sequence (see client/Core/ClientState).

	Channels:
	  global  - broadcast to everyone (run phase, roster, sockets, zones, cargo, caretaker mode...)
	  me      - one private channel per player (profile view, personal results)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Net = require(ReplicatedStorage.Shared.Net.Net)
local StatePath = require(ReplicatedStorage.Shared.Net.StatePath)
local Tables = require(ReplicatedStorage.Shared.Util.Tables)

export type Channel = {
	name: string,
	data: { [string]: any },
	seq: number,
	pending: { StatePath.Patch },
	player: Player?,
	Set: (self: Channel, path: StatePath.Path, value: any) -> (),
	Delete: (self: Channel, path: StatePath.Path) -> (),
	Get: (self: Channel, path: StatePath.Path) -> any,
}

local StateServer = {}

local globalChannels: { [string]: Channel } = {}
local privateChannels: { [Player]: Channel } = {}
local started = false

local function queue(channel: Channel, patch: StatePath.Patch)
	local pending = channel.pending
	-- Drop earlier writes made redundant by this one (same path or a descendant of it).
	for i = #pending, 1, -1 do
		if StatePath.isPrefix(patch.p, pending[i].p) then
			table.remove(pending, i)
		end
	end
	table.insert(pending, patch)
end

local function newChannel(name: string, player: Player?): Channel
	local channel = {
		name = name,
		data = {},
		seq = 0,
		pending = {},
		player = player,
	} :: any

	function channel.Set(self: Channel, path: StatePath.Path, value: any)
		assert(#path > 0, "State path must not be empty")
		local stored = Tables.deepCopy(value)
		StatePath.apply(self.data, { p = path, v = stored })
		queue(self, { p = table.clone(path), v = Tables.deepCopy(stored) })
	end

	function channel.Delete(self: Channel, path: StatePath.Path)
		assert(#path > 0, "State path must not be empty")
		StatePath.apply(self.data, { p = path, d = true })
		queue(self, { p = table.clone(path), d = true })
	end

	function channel.Get(self: Channel, path: StatePath.Path): any
		return StatePath.get(self.data, path)
	end

	return channel :: Channel
end

local function flush(channel: Channel)
	if #channel.pending == 0 then
		return
	end
	channel.seq += 1
	local patches = channel.pending
	channel.pending = {}
	local player = channel.player
	if player then
		if player.Parent == Players then
			Net.fire(player, "StatePatch", channel.name, channel.seq, patches)
		end
	else
		Net.fireAll("StatePatch", channel.name, channel.seq, patches)
	end
end

function StateServer.global(name: string): Channel
	local channel = globalChannels[name]
	if not channel then
		channel = newChannel(name, nil)
		globalChannels[name] = channel
	end
	return channel
end

function StateServer.private(player: Player): Channel
	local channel = privateChannels[player]
	if not channel then
		channel = newChannel("me", player)
		-- Never retain channels for players who already left (avoids leaking state after PlayerRemoving).
		if player.Parent == Players then
			privateChannels[player] = channel
		end
	end
	return channel
end

function StateServer.snapshotFor(player: Player): { [string]: { seq: number, data: any } }
	local out = {}
	for name, channel in globalChannels do
		out[name] = { seq = channel.seq, data = channel.data }
	end
	local private = privateChannels[player]
	if private then
		out.me = { seq = private.seq, data = private.data }
	else
		out.me = { seq = 0, data = {} }
	end
	return out
end

-- Flush all pending patches immediately (used before teleports/results so ordering is obvious).
function StateServer.flushAll()
	for _, channel in globalChannels do
		flush(channel)
	end
	for _, channel in privateChannels do
		flush(channel)
	end
end

function StateServer.start()
	if started then
		return
	end
	started = true
	Net.setFunction("GetSnapshot", function(player: Player)
		return StateServer.snapshotFor(player)
	end)
	RunService.Heartbeat:Connect(function()
		StateServer.flushAll()
	end)
	Players.PlayerRemoving:Connect(function(player)
		privateChannels[player] = nil
	end)
end

return StateServer
