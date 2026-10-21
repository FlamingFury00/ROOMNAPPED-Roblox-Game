--!strict
--[[
	HealthService: hearts, damage grace, downed window, revives and solo self-recovery (S16, U03, U12).

	* Damage is applied only by the server (hazards, caretaker); clients just play hit feedback.
	* A downed player cannot move or act; a nearby active teammate revives them with a 3 second hold.
	* Solo players get one automatic recovery per run at their last safe checkpoint.
	* When the downed window expires the player is eliminated and spectates (camera handled client-side).
	* Players learn their state through replicated roster data and Player attributes (Downed, Status,
	  Spectating) that the movement controller uses to lock input.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.Config.GameConfig)
local HealthModel = require(Shared.Logic.HealthModel)
local Net = require(Shared.Net.Net)
local Registry = require(script.Parent.Parent.Core.Registry)
local RunTypes = require(script.Parent.Parent.Core.RunTypes)

type Run = RunTypes.Run
type RosterEntry = RunTypes.RosterEntry

local HealthService = {}

local config = HealthModel.configFrom(GameConfig)

local function setAttributes(entry: RosterEntry)
	local player = entry.player
	if player.Parent ~= Players then
		return
	end
	local status = entry.health.status
	player:SetAttribute("Status", status)
	player:SetAttribute("Downed", status == "Downed" or status == "Recovering")
	player:SetAttribute("Spectating", status == "Eliminated")
	player:SetAttribute("Hearts", entry.health.hearts)
end

local function clearAttributes(player: Player)
	if player.Parent ~= Players then
		return
	end
	player:SetAttribute("Status", nil)
	player:SetAttribute("Downed", nil)
	player:SetAttribute("Spectating", nil)
	player:SetAttribute("Hearts", nil)
end

local function spectatorSpot(run: Run): CFrame
	-- A sealed box under the level keeps eliminated characters out of the way while they spectate.
	return run.runtime.origin * CFrame.new(0, -150, 0)
end

local function ensureSpectatorBox(run: Run)
	if run.scratch.spectatorBox then
		return
	end
	local cf = spectatorSpot(run)
	local box = Instance.new("Model")
	box.Name = "SpectatorBox"
	for _, spec in
		{
			{ Vector3.new(0, -3.5, 0), Vector3.new(14, 1, 14) },
			{ Vector3.new(0, 8, 0), Vector3.new(14, 1, 14) },
			{ Vector3.new(7, 2, 0), Vector3.new(1, 12, 14) },
			{ Vector3.new(-7, 2, 0), Vector3.new(1, 12, 14) },
			{ Vector3.new(0, 2, 7), Vector3.new(14, 12, 1) },
			{ Vector3.new(0, 2, -7), Vector3.new(14, 12, 1) },
		}
	do
		local part = Instance.new("Part")
		part.Anchored = true
		part.Size = spec[2]
		part.CFrame = cf * CFrame.new(spec[1])
		part.Transparency = 1
		part.CanQuery = false
		part.CanTouch = false
		part.Parent = box
	end
	box.Parent = run.model
	run.scratch.spectatorBox = box
end

local function onDowned(run: Run, entry: RosterEntry, result: string)
	run.stats.anyDowns = true
	Registry.get("Cargo").onCarrierDowned(run, entry)
	Registry.get("Interaction").cancelFor(entry.player)
	-- The client drops its selection when downed; keep the server in step so the next pick re-equips.
	entry.selectedSlot = 0
	Registry.get("Rooms").clearHeld(entry.player)
	Registry.get("Expedition").fireRun("downed", { userId = entry.key, solo = result == "Recovering" })
	Registry.get("Telemetry").downed(run, entry)
	if result == "Downed" then
		-- Call for help automatically while a revive is still possible.
		Registry.get("Pings").helpFor(run, entry, config.DownedWindowSeconds)
	end
end

-- Apply damage. Returns true if the hit landed (not absorbed by grace or state).
function HealthService.damage(
	run: Run,
	entry: RosterEntry,
	amount: number,
	source: string,
	knockback: Vector3?
): boolean
	if run.ended or not entry.connected or entry.left then
		return false
	end
	local result = HealthModel.damage(config, entry.health, amount, os.clock())
	if result == "Ignored" then
		return false
	end
	entry.damageTaken += 1
	if knockback and knockback.Magnitude > 0 then
		Net.fire(entry.player, "Knockback", knockback.Unit, knockback.Magnitude)
	end
	Registry.get("Expedition").fireRun("hit", { userId = entry.key, source = source })
	if result == "Downed" or result == "Recovering" then
		run.stats.lastKnockout = source
		onDowned(run, entry, result)
	end
	setAttributes(entry)
	Registry.get("Expedition").publishRosterEntry(run, entry)
	return true
end

function HealthService.canRevive(run: Run, target: RosterEntry): boolean
	return not run.ended and target.connected and not target.left and HealthModel.canRevive(target.health)
end

function HealthService.revive(run: Run, target: RosterEntry, by: RosterEntry): boolean
	if not HealthService.canRevive(run, target) then
		return false
	end
	if not HealthModel.revive(config, target.health, os.clock()) then
		return false
	end
	setAttributes(target)
	Registry.get("Expedition").publishRosterEntry(run, target)
	Registry.get("Pings").clearFor(run, target)
	Registry.get("Expedition").fireRun("revived", { userId = target.key, by = by.key })
	Registry.get("Telemetry").revived(run, target, by)
	return true
end

function HealthService.forceDown(run: Run, entry: RosterEntry)
	local result = HealthModel.forceDown(config, entry.health, os.clock())
	if result ~= "Ignored" then
		onDowned(run, entry, result)
		setAttributes(entry)
		Registry.get("Expedition").publishRosterEntry(run, entry)
	end
end

function HealthService.heal(run: Run, entry: RosterEntry)
	local h = entry.health
	if h.status == "Downed" or h.status == "Recovering" then
		HealthModel.revive(config, h, os.clock())
	end
	h.status = "Active"
	h.hearts = h.max
	setAttributes(entry)
	Registry.get("Expedition").publishRosterEntry(run, entry)
end

function HealthService.isWiped(run: Run): boolean
	local states = {}
	for _, entry in Registry.get("Expedition").participants(run) do
		table.insert(states, entry.health)
	end
	if #states == 0 then
		return false -- handled as "Abandoned" by the expedition
	end
	return HealthModel.isTeamWiped(states)
end

function HealthService.isActive(entry: RosterEntry): boolean
	return entry.health.status == "Active"
end

function HealthService.startRun(run: Run)
	for _, entry in run.roster do
		setAttributes(entry)
	end
end

function HealthService.step(run: Run, _dt: number)
	local now = os.clock()
	for _, entry in Registry.get("Expedition").participants(run) do
		local events = HealthModel.update(config, entry.health, now)
		for _, event in events do
			if event == "SelfRecovered" then
				local target = entry.lastSafe or run.runtime.spawns[1]
				Registry.get("Characters").teleport(entry.player, target)
				Registry.get("Expedition").fireRun("selfRecovered", { userId = entry.key })
			elseif event == "Eliminated" then
				ensureSpectatorBox(run)
				Registry.get("Characters").teleport(entry.player, spectatorSpot(run))
				Registry.get("Pings").clearFor(run, entry)
				Registry.get("Expedition").fireRun("eliminated", { userId = entry.key })
			end
		end
		if #events > 0 then
			setAttributes(entry)
			Registry.get("Expedition").publishRosterEntry(run, entry)
		end
	end
end

function HealthService.onCharacterSpawned(run: Run, entry: RosterEntry)
	setAttributes(entry)
	if entry.health.status == "Eliminated" then
		ensureSpectatorBox(run)
		Registry.get("Characters").teleport(entry.player, spectatorSpot(run))
	end
end

function HealthService.onPlayerLeft(run: Run, entry: RosterEntry)
	clearAttributes(entry.player)
	-- A downed player who leaves stops calling for help.
	if entry.health.status == "Downed" then
		Registry.get("Pings").clearFor(run, entry)
	end
end

function HealthService.endRun(run: Run)
	for _, entry in run.roster do
		clearAttributes(entry.player)
	end
	run.scratch.spectatorBox = nil
end

function HealthService.Init()
	Registry.add("Health", HealthService)
end

function HealthService.Start() end

return HealthService
