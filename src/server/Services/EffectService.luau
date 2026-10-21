--!strict
--[[
	EffectService: drives the run's EffectModel (S08, S09, R01-R04, R07, R09, R10, R13).

	Every frame it feeds occupancy (players and cargo standing on ice, vines and gates) and pressure plates into
	the model, steps it, applies the resulting collision state to the server-owned colliders and replicates
	each changed zone. Because collision is set on the server and replicated, all clients agree on water, ice
	and hazards after any room change. Clients only add visuals on top of the replicated state.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.Config.GameConfig)
local MathUtil = require(Shared.Util.MathUtil)
local Registry = require(script.Parent.Parent.Core.Registry)
local StateServer = require(script.Parent.Parent.Core.StateServer)
local RunTypes = require(script.Parent.Parent.Core.RunTypes)

type Run = RunTypes.Run

local EffectService = {}

local global = StateServer.global("global")

type Scratch = {
	ice: { [string]: { BasePart } },
	vines: { [string]: BasePart },
	gates: { [string]: BasePart },
	plates: { [string]: BasePart },
	levers: { [string]: BasePart },
	leverState: { [string]: boolean },
	leverCooldown: { [string]: number },
	plateState: { [string]: boolean },
	iceVisited: { [string]: boolean },
	wasElectrified: { [string]: boolean },
}

local function scratch(run: Run): Scratch
	return run.scratch.effects
end

local function serverNow(): number
	return workspace:GetServerTimeNow()
end

local function publishZone(run: Run, id: string)
	local snapshot = run.effect:snapshotZone(id)
	if not snapshot then
		return
	end
	local out = table.clone(snapshot) :: any
	if out.since then
		out.since = serverNow() - (run.effect.now - out.since)
	end
	global:Set({ "zones", id }, out)
end

local function applyColliders(run: Run, id: string)
	local s = scratch(run)
	local parts = s.ice[id]
	if parts then
		local solid = run.effect:basinSolid(id)
		for _, part in parts do
			part.CanCollide = solid
			part:SetAttribute("Solid", solid)
		end
	end
	local vine = s.vines[id]
	if vine then
		vine.CanCollide = run.effect:vineSolid(id)
	end
	local gate = s.gates[id]
	if gate then
		local open = run.effect:gateOpen(id)
		gate.CanCollide = not open
		gate:SetAttribute("Open", open)
	end
end

local function combo(run: Run, comboId: string, entry: any?)
	if run.stats.combos[comboId] then
		return
	end
	run.stats.combos[comboId] = true
	table.insert(run.stats.comboOrder, comboId)
	global:Set({ "run", "combos" }, run.stats.comboOrder)
	Registry.get("Expedition").fireRun("combo", { combo = comboId })
	Registry.get("Telemetry").combo(run, comboId, entry)
end
EffectService.combo = combo

function EffectService.startRun(run: Run)
	local s: Scratch = {
		ice = {},
		vines = {},
		gates = {},
		plates = {},
		levers = {},
		leverState = {},
		leverCooldown = {},
		plateState = {},
		iceVisited = {},
		wasElectrified = {},
	}
	run.scratch.effects = s
	for _, d in run.model:GetDescendants() do
		if d:IsA("BasePart") then
			if d:HasTag("RN_IceCollider") then
				local id = d:GetAttribute("ZoneId") :: string
				s.ice[id] = s.ice[id] or {}
				table.insert(s.ice[id], d)
			elseif d:HasTag("RN_VineCollider") then
				s.vines[d:GetAttribute("ZoneId") :: string] = d
			elseif d:HasTag("RN_GateCollider") then
				s.gates[d:GetAttribute("GateId") :: string] = d
			elseif d:HasTag("RN_Plate") then
				s.plates[d:GetAttribute("PlateId") :: string] = d
			elseif d:HasTag("RN_Lever") then
				s.levers[d:GetAttribute("LeverId") :: string] = d
			end
		end
	end
	local zones = {}
	for _, id in run.effect:allZoneIds() do
		local snap = run.effect:snapshotZone(id)
		if snap then
			local out = table.clone(snap) :: any
			if out.since then
				out.since = serverNow()
			end
			zones[id] = out
		end
		applyColliders(run, id)
		if run.effect:basinElectrified(id) then
			s.wasElectrified[id] = true
		end
	end
	global:Set({ "zones" }, zones)
	local levers = {}
	for id in run.runtime.levers do
		levers[id] = false
		s.leverState[id] = false
	end
	global:Set({ "levers" }, levers)
	local plates = {}
	for id in run.runtime.plates do
		plates[id] = false
		s.plateState[id] = false
	end
	global:Set({ "plates" }, plates)
end

function EffectService.endRun(run: Run)
	run.scratch.effects = nil
end

-- Called by RoomService whenever the set of deployed rooms changes.
function EffectService.setSources(run: Run, sources: { [string]: string })
	run.effect:setSources(sources :: any)
end

-- Called by HazardService with the current pressure plate states.
function EffectService.setPlate(run: Run, plateId: string, active: boolean)
	local s = scratch(run)
	if not s or s.plateState[plateId] == active then
		return
	end
	s.plateState[plateId] = active
	run.effect:setPlate(plateId, active)
	global:Set({ "plates", plateId }, active)
	local part = s.plates[plateId]
	if part then
		part:SetAttribute("Active", active)
	end
	if active then
		combo(run, "crate_plate")
	end
end

function EffectService.leverPosition(run: Run, leverId: string): Vector3?
	local lever = run.runtime.levers[leverId]
	return if lever then lever.cf.Position else nil
end

-- Toggle a power lever (validated by InteractionService).
function EffectService.toggleLever(run: Run, entry: any, leverId: string): boolean
	local s = scratch(run)
	if not s or s.leverState[leverId] == nil then
		return false
	end
	local now = os.clock()
	if (s.leverCooldown[leverId] or 0) > now then
		return false
	end
	s.leverCooldown[leverId] = now + GameConfig.Effects.PowerSwitchCooldownSeconds
	local flipped = not s.leverState[leverId]
	s.leverState[leverId] = flipped
	-- Was any powered basin electrified before the flip?
	local electrifiedBefore = false
	for id in run.runtime.basins do
		if run.effect:basinElectrified(id) then
			electrifiedBefore = true
		end
	end
	run.effect:setLever(leverId, flipped)
	run.effect:step(0)
	global:Set({ "levers", leverId }, flipped)
	local part = s.levers[leverId]
	if part then
		part:SetAttribute("Flipped", flipped)
	end
	local electrifiedAfter = false
	for id in run.runtime.basins do
		if run.effect:basinElectrified(id) then
			electrifiedAfter = true
		end
	end
	for _, id in run.effect:allZoneIds() do
		publishZone(run, id)
		applyColliders(run, id)
	end
	if electrifiedBefore and not electrifiedAfter then
		combo(run, "power_off", entry)
	end
	Registry.get("Expedition").fireRun("lever", { lever = leverId, flipped = flipped })
	Registry.get("Caretaker").noise(run, run.runtime.levers[leverId].cf.Position, GameConfig.Noise.Lever)
	return true
end

local function occupied(run: Run, b: { cf: CFrame, size: Vector3 }): boolean
	local Characters = Registry.get("Characters")
	for _, entry in Registry.get("Expedition").participants(run) do
		local position = Characters.position(entry.player)
		if position and MathUtil.pointInBox(b.cf, b.size, position, 0.4) then
			return true
		end
	end
	local cargo = Registry.get("Cargo").droppedPosition(run)
	if cargo and MathUtil.pointInBox(b.cf, b.size, cargo, 0.4) then
		return true
	end
	return false
end

local function updateOccupancy(run: Run)
	local rt = run.runtime
	for id, basin in rt.basins do
		local isOccupied = occupied(run, basin.occupancy)
		run.effect:setOccupied(id, isOccupied)
		local s = scratch(run)
		-- Combo: someone walks across a frozen deep basin.
		if isOccupied and basin.deep and run.effect:basinSolid(id) and not s.iceVisited[id] then
			s.iceVisited[id] = true
			combo(run, "ice_bridge")
		end
	end
	for id, vine in rt.vines do
		local b = { cf = vine.bridge.cf * CFrame.new(0, 3, 0), size = vine.bridge.size + Vector3.new(1, 6, 0) }
		run.effect:setOccupied(id, occupied(run, b))
	end
	for id, gate in rt.gates do
		run.effect:setOccupied(id, occupied(run, gate.box))
	end
end

function EffectService.step(run: Run, dt: number)
	local s = scratch(run)
	if not s then
		return
	end
	updateOccupancy(run)
	local beforeFire: { [string]: string } = {}
	for id in run.runtime.fires do
		beforeFire[id] = run.effect:firePhase(id) or ""
	end
	local changed = run.effect:step(dt)
	for _, id in changed do
		publishZone(run, id)
		applyColliders(run, id)
		local fire = run.runtime.fires[id]
		if fire then
			local phase = run.effect:firePhase(id)
			if beforeFire[id] == "Burning" and phase == "Out" then
				Registry.get("Expedition").fireRun("extinguish", { zone = id })
				if #run.effect:sourcesFor(fire.pool, "water") > 0 then
					combo(run, "extinguish")
				end
			elseif phase == "Burning" and beforeFire[id] == "Warning" then
				Registry.get("Expedition").fireRun("ignite", { zone = id })
			end
		end
		local basin = run.runtime.basins[id]
		if basin then
			local electrified = run.effect:basinElectrified(id)
			if s.wasElectrified[id] and not electrified and run.effect:basinSolid(id) then
				combo(run, "frozen_safe")
			end
			s.wasElectrified[id] = electrified
		end
		if run.runtime.vines[id] and run.effect:vineSolid(id) then
			combo(run, "vine_bridge")
		end
	end
end

-- Active cold regions (caretaker slow-down) from deployed Freezer rooms.
function EffectService.coldFields(run: Run): { { cf: CFrame, size: Vector3 } }
	local out = {}
	for socketId, effect in run.effect.sources do
		if effect == "cold" then
			local socket = run.runtime.sockets[socketId]
			if socket then
				for _, field in socket.coldFields do
					table.insert(out, field)
				end
			end
		end
	end
	return out
end

function EffectService.Init()
	Registry.add("Effects", EffectService)
end

function EffectService.Start() end

return EffectService
