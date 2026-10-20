--!strict
--[[
	PingService: chat-free coordination (U11). Help / Here / Use room markers are broadcast to the squad,
	validated for range and throttled (cooldown + burst window) so rapid ping spam is impossible.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.Config.GameConfig)
local RateLimiter = require(Shared.Util.RateLimiter)
local Net = require(Shared.Net.Net)
local Registry = require(script.Parent.Parent.Core.Registry)

local PingService = {}

local KINDS: { [string]: boolean } = { help = true, here = true, room = true, danger = true }
local P = GameConfig.Pings
local burst = RateLimiter.new(P.Burst, P.Burst / P.BurstWindowSeconds)
local lastPing: { [Player]: number } = {}

local function onPing(player: Player, kind: string, position: Vector3, targetId: string?)
	if not KINDS[kind] or not Registry.get("Flags").feature("pings") then
		return
	end
	local Expedition = Registry.get("Expedition")
	local entry = Expedition.entry(player)
	local run = Expedition.current()
	if not entry or not run then
		return
	end
	local now = os.clock()
	if (lastPing[player] or 0) + P.CooldownSeconds > now or not burst:Allow(player) then
		return
	end
	lastPing[player] = now
	local origin = Registry.get("Characters").position(player)
	if not origin or (position - origin).Magnitude > P.MaxDistance then
		return
	end
	if kind == "room" and (targetId == nil or run.runtime.sockets[targetId :: string] == nil) then
		targetId = nil
	end
	local marker = {
		from = entry.key,
		name = entry.display,
		kind = kind,
		position = position,
		target = targetId,
		expires = workspace:GetServerTimeNow() + P.LifetimeSeconds,
	}
	local recipients = {}
	for _, other in Expedition.participants(run) do
		table.insert(recipients, other.player)
	end
	Net.fireList(recipients, "PingMarker", marker)
	Registry.get("Telemetry").ping(player, kind)
end

function PingService.Init()
	Registry.add("Pings", PingService)
end

function PingService.Start()
	Net.on("Ping", onPing)
	Players.PlayerRemoving:Connect(function(player)
		lastPing[player] = nil
		burst:Reset(player)
	end)
end

return PingService
