--!strict
--[[
	Net: thin, validated wrapper around RemoteEvents (S20 network authority).

	Server:
	  Net.initServer()                        creates the remotes folder
	  Net.on(name, handler)                   handler(player, ...) runs only for schema-valid, rate-allowed calls
	  Net.fire(player, name, ...) / fireAll / fireList / fireUnreliableAll
	  Net.setFunction(name, handler)          handler(player, ...) for RemoteFunctions
	Client:
	  Net.initClient()
	  Net.send(name, ...) / Net.listen(name, handler) / Net.invoke(name, ...)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local GameConfig = require(script.Parent.Parent.Config.GameConfig)
local RateLimiter = require(script.Parent.Parent.Util.RateLimiter)
local Remotes = require(script.Parent.Remotes)

local FOLDER_NAME = "RoomnappedRemotes"
local MAX_STRING = 64
local MAX_LONG_STRING = 512

local Net = {}

local folder: Folder? = nil
local remoteEvents: { [string]: RemoteEvent } = {}
local unreliableEvents: { [string]: UnreliableRemoteEvent } = {}
local remoteFunctions: { [string]: RemoteFunction } = {}
local limiters: { [string]: RateLimiter.RateLimiter } = {}
local rejectCounts: { [Player]: number } = {}

Net.rejected = 0

local function isFinite(n: number): boolean
	return n == n and n ~= math.huge and n ~= -math.huge
end

-- Validate a call against a schema. Exposed for tests.
function Net.validate(schema: { string }, ...: any): boolean
	local count = select("#", ...)
	-- Extra arguments are rejected unless they are trailing nils (harmless padding).
	for i = #schema + 1, count do
		if select(i, ...) ~= nil then
			return false
		end
	end
	for i, token in schema do
		local value = select(i, ...)
		local optional = string.sub(token, -1) == "?"
		local base = if optional then string.sub(token, 1, -2) else token
		if value == nil then
			if not optional then
				return false
			end
		elseif base == "string" then
			if type(value) ~= "string" or #value > MAX_STRING then
				return false
			end
		elseif base == "longstring" then
			if type(value) ~= "string" or #value > MAX_LONG_STRING then
				return false
			end
		elseif base == "number" then
			if type(value) ~= "number" or not isFinite(value) then
				return false
			end
		elseif base == "integer" then
			if
				type(value) ~= "number"
				or not isFinite(value)
				or math.floor(value) ~= value
				or math.abs(value) > 2 ^ 31
			then
				return false
			end
		elseif base == "boolean" then
			if type(value) ~= "boolean" then
				return false
			end
		elseif base == "table" then
			if type(value) ~= "table" then
				return false
			end
		elseif base == "Vector3" then
			if typeof(value) ~= "Vector3" then
				return false
			end
			local v = value :: Vector3
			if not (isFinite(v.X) and isFinite(v.Y) and isFinite(v.Z)) then
				return false
			end
		elseif base ~= "any" then
			error("Unknown schema token " .. token)
		end
	end
	return true
end

local function limiterFor(bucket: string): RateLimiter.RateLimiter
	local limiter = limiters[bucket]
	if not limiter then
		local spec = (GameConfig.RateLimits :: any)[bucket] or GameConfig.RateLimits.Default
		limiter = RateLimiter.new(spec[1], spec[2])
		limiters[bucket] = limiter
	end
	return limiter
end

local function noteReject(player: Player, name: string, reason: string)
	Net.rejected += 1
	rejectCounts[player] = (rejectCounts[player] or 0) + 1
	if RunService:IsStudio() then
		warn(string.format("[Net] rejected %s from %s: %s", name, player.Name, reason))
	end
end

-- Server ------------------------------------------------------------------------------------------

function Net.initServer()
	assert(RunService:IsServer(), "Net.initServer must run on the server")
	if folder then
		return
	end
	local existing = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
	if existing then
		existing:Destroy()
	end
	local f = Instance.new("Folder")
	f.Name = FOLDER_NAME
	for name in Remotes.ClientEvents do
		local remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = f
		remoteEvents[name] = remote
	end
	for _, name in Remotes.ServerEvents do
		local remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = f
		remoteEvents[name] = remote
	end
	for _, name in Remotes.UnreliableEvents do
		local remote = Instance.new("UnreliableRemoteEvent")
		remote.Name = name
		remote.Parent = f
		unreliableEvents[name] = remote
	end
	for _, name in Remotes.Functions do
		local remote = Instance.new("RemoteFunction")
		remote.Name = name
		remote.Parent = f
		remoteFunctions[name] = remote
	end
	f.Parent = ReplicatedStorage
	folder = f

	Players.PlayerRemoving:Connect(function(player)
		rejectCounts[player] = nil
		for _, limiter in limiters do
			limiter:Reset(player)
		end
	end)
end

function Net.on(name: string, handler: (Player, ...any) -> ())
	local def = Remotes.ClientEvents[name]
	assert(def, "Unknown client event " .. name)
	local remote = remoteEvents[name]
	assert(remote, "Net.initServer has not created " .. name)
	local limiter = limiterFor(def.rate)
	remote.OnServerEvent:Connect(function(player: Player, ...: any)
		if not limiter:Allow(player) then
			noteReject(player, name, "rate")
			return
		end
		if not Net.validate(def.schema, ...) then
			noteReject(player, name, "schema")
			return
		end
		handler(player, ...)
	end)
end

function Net.fire(player: Player, name: string, ...: any)
	local remote = remoteEvents[name]
	assert(remote, "Unknown server event " .. name)
	remote:FireClient(player, ...)
end

function Net.fireAll(name: string, ...: any)
	local remote = remoteEvents[name]
	assert(remote, "Unknown server event " .. name)
	remote:FireAllClients(...)
end

function Net.fireList(players: { Player }, name: string, ...: any)
	local remote = remoteEvents[name]
	assert(remote, "Unknown server event " .. name)
	for _, player in players do
		if player.Parent == Players then
			remote:FireClient(player, ...)
		end
	end
end

function Net.fireUnreliableAll(name: string, ...: any)
	local remote = unreliableEvents[name]
	assert(remote, "Unknown unreliable event " .. name)
	remote:FireAllClients(...)
end

function Net.setFunction(name: string, handler: (Player, ...any) -> ...any)
	local remote = remoteFunctions[name]
	assert(remote, "Unknown remote function " .. name)
	local limiter = limiterFor("Default")
	remote.OnServerInvoke = function(player: Player, ...: any)
		if not limiter:Allow(player) then
			noteReject(player, name, "rate")
			return nil
		end
		return handler(player, ...)
	end
end

function Net.rejectCount(player: Player): number
	return rejectCounts[player] or 0
end

-- Client ------------------------------------------------------------------------------------------

local function clientRemote(name: string): Instance
	local f = folder
	if not f then
		f = ReplicatedStorage:WaitForChild(FOLDER_NAME) :: Folder
		folder = f
	end
	return (f :: Folder):WaitForChild(name)
end

function Net.initClient()
	assert(RunService:IsClient(), "Net.initClient must run on the client")
	local f = ReplicatedStorage:WaitForChild(FOLDER_NAME) :: Folder
	folder = f
end

function Net.send(name: string, ...: any)
	assert(Remotes.ClientEvents[name], "Unknown client event " .. name)
	local remote = remoteEvents[name]
	if not remote then
		remote = clientRemote(name) :: RemoteEvent
		remoteEvents[name] = remote
	end
	remote:FireServer(...)
end

function Net.listen(name: string, handler: (...any) -> ()): RBXScriptConnection
	local remote = remoteEvents[name] :: Instance?
	if not remote then
		remote = clientRemote(name)
	end
	if (remote :: Instance):IsA("UnreliableRemoteEvent") then
		return ((remote :: any) :: UnreliableRemoteEvent).OnClientEvent:Connect(handler)
	end
	remoteEvents[name] = remote :: RemoteEvent
	return (remote :: RemoteEvent).OnClientEvent:Connect(handler)
end

function Net.invoke(name: string, ...: any): ...any
	local remote = remoteFunctions[name]
	if not remote then
		remote = clientRemote(name) :: RemoteFunction
		remoteFunctions[name] = remote
	end
	return remote:InvokeServer(...)
end

return Net
