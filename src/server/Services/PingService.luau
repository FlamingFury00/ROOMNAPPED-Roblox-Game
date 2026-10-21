--!strict
--[[
	PingService: chat-free coordination (U11). Help / Here / Use room markers are broadcast to the squad,
	validated for range and throttled (cooldown + burst window) so rapid ping spam is impossible.

	A downed squad member pings Help automatically for as long as they can be revived, so teammates can
	find them in time; the marker clears the moment they are back up or out.
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
	if entry.health.status == "Eliminated" then
		-- Spectators watch through a teammate's camera: anywhere inside the level counts.
		local b = run.runtime.bounds
		if
			position.X < b.min.X
			or position.Y < b.min.Y
			or position.Z < b.min.Z
			or position.X > b.max.X
			or position.Y > b.max.Y
			or position.Z > b.max.Z
		then
			return
		end
	else
		local origin = Registry.get("Characters").position(player)
		if not origin or (position - origin).Magnitude > P.MaxDistance then
			return
		end
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

-- Send a marker (or a clear) from `entry` to everyone else in the run.
local function toSquad(run: any, entry: any, marker: { [string]: any })
	local recipients = {}
	for _, other in Registry.get("Expedition").participants(run) do
		if other ~= entry then
			table.insert(recipients, other.player)
		end
	end
	if #recipients > 0 then
		Net.fireList(recipients, "PingMarker", marker)
	end
end

-- `at` overrides where the marker stands (a player knocked out by a fall is about to be put back on the floor).
function PingService.helpFor(run: any, entry: any, seconds: number, at: Vector3?)
	local position = at or Registry.get("Characters").position(entry.player)
	if not position then
		return
	end
	toSquad(run, entry, {
		from = entry.key,
		name = entry.display,
		kind = "help",
		position = position,
		expires = workspace:GetServerTimeNow() + seconds,
	})
end

function PingService.clearFor(run: any, entry: any)
	toSquad(run, entry, { from = entry.key, kind = "help", position = Vector3.zero, clear = true })
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
