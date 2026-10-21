--!strict
--[[
	EffectModel: deterministic room-effect engine (S08, S09, R01-R04, R07, R09, R10, R13).

	Pure Luau - no Instances. The server owns one model per expedition, feeds it the current set of active
	room sources, levers, plates and occupancy, and steps it every frame. Clients only render the
	replicated snapshot.

	Resolution order (S09): water and cold are resolved first (basins), then everything that depends on
	water (fires, floats/switches, vine watering, electricity), then gates. Wind and magnet movement are
	geometric and resolved afterwards by the hazard layer using these results.

	Determinism / order independence (R07, R13): every zone's *target* is a pure function of the current
	source set, so any deploy/recall order with the same final set converges to the same states. Timed
	transitions only change how fast a zone gets there. Removing a source recomputes targets from the
	remaining sources; nothing stacks (two Freezers on one basin are the same as one).

	Safety rules:
	  * Ice never disappears under a player: a thawing basin holds until it is unoccupied for
	    IceExitGraceSeconds, then melts (R01/R07).
	  * Fire never re-ignites without a visible Warning phase first (R09).
	  * A grown vine bridge never retracts under a player (R04).
	  * A gate never closes on a player.
]]

export type Effect = "cold" | "water" | "wind" | "vine" | "magnet"

export type BasinDef = {
	id: string,
	baseWet: boolean,
	deep: boolean,
	power: string?,
}
export type FireDef = { id: string, pools: { string } }
export type VineDef = { id: string, waterBasin: string? }
export type PowerDef = { id: string, default: boolean, levers: { string } }
export type GateDef = { id: string, signals: { string }, mode: ("any" | "all")? }
export type SocketLinks = { cold: { string }?, water: string?, vine: string? }

export type Defs = {
	basins: { [string]: BasinDef },
	fires: { [string]: FireDef },
	vines: { [string]: VineDef },
	powers: { [string]: PowerDef },
	gates: { [string]: GateDef },
	links: { [string]: SocketLinks },
}

export type Timings = {
	FillSeconds: number,
	DrainSeconds: number,
	FreezeSeconds: number,
	MeltSeconds: number,
	IceExitGraceSeconds: number,
	FireWarningSeconds: number,
	VineGrowSeconds: number,
	VineRetractSeconds: number,
}

export type BasinPhase = "Dry" | "Filling" | "Water" | "Draining" | "Freezing" | "Ice" | "Thawing" | "Melting"
export type FirePhase = "Burning" | "Out" | "Warning"
export type VinePhase = "Retracted" | "Growing" | "Paused" | "Grown" | "Holding" | "Retracting"

type BasinState = {
	phase: BasinPhase,
	fill: number,
	timer: number,
	unoccupiedFor: number,
	occupied: boolean,
	since: number,
	fill0: number,
	electrified: boolean,
}
type FireState = { phase: FirePhase, timer: number, since: number }
type VineState = { phase: VinePhase, progress: number, occupied: boolean, since: number, progress0: number }
type GateState = { open: boolean, progress: number, occupied: boolean, since: number }

local GATE_SECONDS = 1

local EffectModel = {}
EffectModel.__index = EffectModel

export type Model = typeof(setmetatable(
	{} :: {
		defs: Defs,
		timings: Timings,
		now: number,
		sources: { [string]: Effect },
		levers: { [string]: boolean },
		plates: { [string]: boolean },
		basins: { [string]: BasinState },
		fires: { [string]: FireState },
		vines: { [string]: VineState },
		gates: { [string]: GateState },
		powers: { [string]: boolean },
		_dirty: { [string]: boolean },
	},
	EffectModel
))

local function sortedKeys(t: { [string]: any }): { string }
	local keys = {}
	for k in t do
		table.insert(keys, k)
	end
	table.sort(keys)
	return keys
end

function EffectModel.new(defs: Defs, timings: Timings, now: number?): Model
	local start = now or 0
	local self: Model = setmetatable(
		{
			defs = defs,
			timings = timings,
			now = start,
			sources = {},
			levers = {},
			plates = {},
			basins = {},
			fires = {},
			vines = {},
			gates = {},
			powers = {},
			_dirty = {},
		} :: any,
		EffectModel
	)

	for id, def in defs.basins do
		local wet = def.baseWet
		self.basins[id] = {
			phase = (if wet then "Water" else "Dry") :: BasinPhase,
			fill = if wet then 1 else 0,
			timer = 0,
			unoccupiedFor = 0,
			occupied = false,
			since = start,
			fill0 = if wet then 1 else 0,
			electrified = false,
		}
	end
	for id in defs.fires do
		self.fires[id] = { phase = "Burning" :: FirePhase, timer = 0, since = start }
	end
	for id in defs.vines do
		self.vines[id] =
			{ phase = "Retracted" :: VinePhase, progress = 0, occupied = false, since = start, progress0 = 0 }
	end
	for id in defs.gates do
		self.gates[id] = { open = false, progress = 0, occupied = false, since = start }
	end
	for id, def in defs.powers do
		self.powers[id] = def.default
	end
	-- Settle the initial configuration instantly (base-wet pools start with their fire out, etc.).
	self:_resolveInstant(true)
	table.clear(self._dirty)
	return self
end

-- Sources --------------------------------------------------------------------------------------------

-- Replace the full set of active sources: socketId -> effect channel.
function EffectModel.setSources(self: Model, sources: { [string]: Effect })
	self.sources = table.clone(sources)
end

function EffectModel.setLever(self: Model, id: string, flipped: boolean)
	self.levers[id] = flipped
end

function EffectModel.setPlate(self: Model, id: string, active: boolean)
	self.plates[id] = active
end

function EffectModel.setOccupied(self: Model, zoneId: string, occupied: boolean)
	local basin = self.basins[zoneId]
	if basin then
		basin.occupied = occupied
	end
	local vine = self.vines[zoneId]
	if vine then
		vine.occupied = occupied
	end
	local gate = self.gates[zoneId]
	if gate then
		gate.occupied = occupied
	end
end

-- Lists the sockets currently feeding `effect` into `zoneId` (sorted, deterministic).
function EffectModel.sourcesFor(self: Model, zoneId: string, effect: Effect): { string }
	local out = {}
	for _, socketId in sortedKeys(self.sources) do
		if self.sources[socketId] == effect then
			local links = self.defs.links[socketId]
			local feeds = links ~= nil
				and (
					(effect == "cold" and links.cold ~= nil and table.find(links.cold, zoneId) ~= nil)
					or (effect == "water" and links.water == zoneId)
					or (effect == "vine" and links.vine == zoneId)
				)
			if feeds then
				table.insert(out, socketId)
			end
		end
	end
	return out
end

-- Queries ------------------------------------------------------------------------------------------

local LIQUID_PHASES: { [string]: boolean } = { Water = true, Freezing = true }
local FROZEN_PHASES: { [string]: boolean } = { Ice = true, Thawing = true, Melting = true }

function EffectModel.basinWet(self: Model, id: string): boolean
	local b = self.basins[id]
	if not b then
		return false
	end
	if b.phase == "Dry" then
		return false
	elseif b.phase == "Filling" or b.phase == "Draining" then
		return b.fill >= 0.5
	end
	return true
end

function EffectModel.basinSolid(self: Model, id: string): boolean
	local b = self.basins[id]
	return b ~= nil and FROZEN_PHASES[b.phase] == true
end

function EffectModel.basinPhase(self: Model, id: string): BasinPhase?
	local b = self.basins[id]
	return if b then b.phase else nil
end

function EffectModel.basinElectrified(self: Model, id: string): boolean
	local b = self.basins[id]
	return b ~= nil and b.electrified
end

function EffectModel.fireLit(self: Model, id: string): boolean
	local f = self.fires[id]
	return f ~= nil and f.phase == "Burning"
end

function EffectModel.firePhase(self: Model, id: string): FirePhase?
	local f = self.fires[id]
	return if f then f.phase else nil
end

function EffectModel.vineSolid(self: Model, id: string): boolean
	local v = self.vines[id]
	return v ~= nil and v.progress >= 1
end

function EffectModel.vineProgress(self: Model, id: string): number
	local v = self.vines[id]
	return if v then v.progress else 0
end

function EffectModel.gateOpen(self: Model, id: string): boolean
	local g = self.gates[id]
	return g ~= nil and g.progress >= 0.5
end

function EffectModel.powerOn(self: Model, id: string): boolean
	return self.powers[id] == true
end

function EffectModel.signalActive(self: Model, signal: string): boolean
	local kind, id = string.match(signal, "^(%a+):(.+)$")
	if kind == "lever" then
		return self.levers[id :: string] == true
	elseif kind == "plate" then
		return self.plates[id :: string] == true
	elseif kind == "float" then
		return self:basinWet(id :: string)
	elseif kind == "power" then
		return self.powers[id :: string] == true
	end
	return false
end

-- Targets --------------------------------------------------------------------------------------------

function EffectModel.basinTarget(self: Model, id: string): BasinPhase
	local def = self.defs.basins[id]
	local wet = def.baseWet or #self:sourcesFor(id, "water") > 0
	if not wet then
		return "Dry"
	end
	if #self:sourcesFor(id, "cold") > 0 then
		return "Ice"
	end
	return "Water"
end

local function fireShouldBurn(self: Model, id: string): boolean
	for _, pool in self.defs.fires[id].pools do
		if self:basinWet(pool) then
			return false
		end
	end
	return true
end

local function vineWatered(self: Model, id: string): boolean
	if #self:sourcesFor(id, "water") > 0 then
		return true
	end
	local basin = self.defs.vines[id].waterBasin
	return basin ~= nil and self:basinWet(basin)
end

-- State machines -------------------------------------------------------------------------------------

function EffectModel._mark(self: Model, id: string)
	self._dirty[id] = true
end

local function setBasinPhase(self: Model, id: string, b: BasinState, phase: BasinPhase)
	if b.phase ~= phase then
		b.phase = phase
		b.timer = 0
		b.since = self.now
		b.fill0 = b.fill
		self:_mark(id)
	end
end

-- Instant (zero-duration) basin transitions. Returns true if anything changed.
local function basinInstant(self: Model, id: string, b: BasinState, target: BasinPhase): boolean
	local before = b.phase
	if (b.phase == "Dry" or b.phase == "Draining") and target ~= "Dry" then
		setBasinPhase(self, id, b, "Filling")
	elseif b.phase == "Filling" and target == "Dry" then
		setBasinPhase(self, id, b, "Draining")
	elseif b.phase == "Water" then
		if target == "Dry" then
			setBasinPhase(self, id, b, "Draining")
		elseif target == "Ice" then
			setBasinPhase(self, id, b, "Freezing")
		end
	elseif b.phase == "Freezing" and target ~= "Ice" then
		setBasinPhase(self, id, b, "Water")
	elseif b.phase == "Ice" and target ~= "Ice" then
		setBasinPhase(self, id, b, "Thawing")
		b.unoccupiedFor = 0
	elseif b.phase == "Thawing" and target == "Ice" then
		setBasinPhase(self, id, b, "Ice")
	elseif b.phase == "Melting" then
		if target == "Ice" then
			setBasinPhase(self, id, b, "Ice")
		elseif b.occupied then
			setBasinPhase(self, id, b, "Thawing")
			b.unoccupiedFor = 0
		end
	end
	return b.phase ~= before
end

local function basinTimed(self: Model, id: string, b: BasinState, dt: number)
	local t = self.timings
	if b.phase == "Filling" then
		b.fill = math.min(1, b.fill + dt / t.FillSeconds)
		if b.fill >= 1 then
			setBasinPhase(self, id, b, "Water")
		end
	elseif b.phase == "Draining" then
		b.fill = math.max(0, b.fill - dt / t.DrainSeconds)
		if b.fill <= 0 then
			setBasinPhase(self, id, b, "Dry")
		end
	elseif b.phase == "Freezing" then
		b.timer += dt
		if b.timer >= t.FreezeSeconds then
			setBasinPhase(self, id, b, "Ice")
		end
	elseif b.phase == "Thawing" then
		if b.occupied then
			b.unoccupiedFor = 0
		else
			b.unoccupiedFor += dt
			if b.unoccupiedFor >= t.IceExitGraceSeconds then
				setBasinPhase(self, id, b, "Melting")
			end
		end
	elseif b.phase == "Melting" then
		b.timer += dt
		if b.timer >= t.MeltSeconds then
			b.fill = 1
			setBasinPhase(self, id, b, "Water")
		end
	end
end

local function updateElectrified(self: Model, id: string, b: BasinState)
	local def = self.defs.basins[id]
	local powered = def.power ~= nil and self.powers[def.power :: string] == true
	local liquid = LIQUID_PHASES[b.phase] == true or ((b.phase == "Filling" or b.phase == "Draining") and b.fill >= 0.3)
	local electrified = powered and liquid
	if electrified ~= b.electrified then
		b.electrified = electrified
		self:_mark(id)
	end
end

local function setFirePhase(self: Model, id: string, f: FireState, phase: FirePhase)
	if f.phase ~= phase then
		f.phase = phase
		f.timer = 0
		f.since = self.now
		self:_mark(id)
	end
end

local function fireStep(self: Model, id: string, f: FireState, dt: number, initial: boolean)
	local burn = fireShouldBurn(self, id)
	if f.phase == "Burning" and not burn then
		setFirePhase(self, id, f, "Out")
	elseif f.phase == "Out" and burn then
		setFirePhase(self, id, f, if initial then "Burning" else "Warning")
	elseif f.phase == "Warning" then
		if not burn then
			setFirePhase(self, id, f, "Out")
		else
			f.timer += dt
			if f.timer >= self.timings.FireWarningSeconds then
				setFirePhase(self, id, f, "Burning")
			end
		end
	end
end

local function setVinePhase(self: Model, id: string, v: VineState, phase: VinePhase)
	if v.phase ~= phase then
		v.phase = phase
		v.since = self.now
		v.progress0 = v.progress
		self:_mark(id)
	end
end

local function vineStep(self: Model, id: string, v: VineState, dt: number)
	local t = self.timings
	local grow = #self:sourcesFor(id, "vine") > 0 and vineWatered(self, id)
	local cold = #self:sourcesFor(id, "cold") > 0
	if grow then
		if v.progress >= 1 then
			setVinePhase(self, id, v, "Grown")
		elseif cold then
			setVinePhase(self, id, v, "Paused")
		else
			setVinePhase(self, id, v, "Growing")
			v.progress = math.min(1, v.progress + dt / t.VineGrowSeconds)
			if v.progress >= 1 then
				setVinePhase(self, id, v, "Grown")
			end
		end
	else
		if v.progress <= 0 then
			setVinePhase(self, id, v, "Retracted")
		elseif v.progress >= 1 and v.occupied then
			setVinePhase(self, id, v, "Holding")
		else
			setVinePhase(self, id, v, "Retracting")
			v.progress = math.max(0, v.progress - dt / t.VineRetractSeconds)
			if v.progress <= 0 then
				setVinePhase(self, id, v, "Retracted")
			end
		end
	end
end

local function gateStep(self: Model, id: string, g: GateState, dt: number)
	local def = self.defs.gates[id]
	local mode = def.mode or "any"
	local wantOpen
	if mode == "all" then
		wantOpen = #def.signals > 0
		for _, signal in def.signals do
			if not self:signalActive(signal) then
				wantOpen = false
				break
			end
		end
	else
		wantOpen = false
		for _, signal in def.signals do
			if self:signalActive(signal) then
				wantOpen = true
				break
			end
		end
	end
	local before = g.open
	if wantOpen then
		g.open = true
		g.progress = math.min(1, g.progress + dt / GATE_SECONDS)
	elseif not g.occupied then
		g.open = false
		g.progress = math.max(0, g.progress - dt / GATE_SECONDS)
	end
	if g.open ~= before then
		g.since = self.now
		self:_mark(id)
	end
end

local function powerStep(self: Model)
	for id, def in self.defs.powers do
		local flips = 0
		for _, lever in def.levers do
			if self.levers[lever] then
				flips += 1
			end
		end
		local on = def.default
		if flips % 2 == 1 then
			on = not on
		end
		if self.powers[id] ~= on then
			self.powers[id] = on
			self:_mark(id)
		end
	end
end

function EffectModel._resolveInstant(self: Model, initial: boolean)
	powerStep(self)
	-- Water/cold first (S09).
	for _ = 1, 4 do
		local changed = false
		for _, id in sortedKeys(self.basins) do
			local b = self.basins[id]
			if basinInstant(self, id, b, self:basinTarget(id)) then
				changed = true
			end
		end
		if not changed then
			break
		end
	end
	for _, id in sortedKeys(self.basins) do
		updateElectrified(self, id, self.basins[id])
	end
	for _, id in sortedKeys(self.fires) do
		fireStep(self, id, self.fires[id], 0, initial)
	end
end

-- Advance the simulation. Returns the ids of zones whose replicated state changed.
function EffectModel.step(self: Model, dt: number): { string }
	self.now += dt
	self:_resolveInstant(false)
	for _, id in sortedKeys(self.basins) do
		local b = self.basins[id]
		basinTimed(self, id, b, dt)
		basinInstant(self, id, b, self:basinTarget(id))
		updateElectrified(self, id, b)
	end
	for _, id in sortedKeys(self.fires) do
		fireStep(self, id, self.fires[id], dt, false)
	end
	for _, id in sortedKeys(self.vines) do
		vineStep(self, id, self.vines[id], dt)
	end
	for _, id in sortedKeys(self.gates) do
		gateStep(self, id, self.gates[id], dt)
	end
	local changed = sortedKeys(self._dirty)
	table.clear(self._dirty)
	return changed
end

-- Replication ----------------------------------------------------------------------------------------

export type ZoneSnapshot = {
	kind: string,
	phase: string?,
	since: number?,
	fill0: number?,
	electrified: boolean?,
	progress0: number?,
	open: boolean?,
	on: boolean?,
}

-- Compact, Instance-free view of a single zone for the replicated state channel. `since` is in model time;
-- the server converts it to server time before replicating.
function EffectModel.snapshotZone(self: Model, id: string): ZoneSnapshot?
	local b = self.basins[id]
	if b then
		return {
			kind = "basin",
			phase = b.phase :: string,
			since = b.since,
			fill0 = math.floor(b.fill0 * 1000 + 0.5) / 1000,
			electrified = b.electrified,
		}
	end
	local f = self.fires[id]
	if f then
		return { kind = "fire", phase = f.phase :: string, since = f.since }
	end
	local v = self.vines[id]
	if v then
		return {
			kind = "vine",
			phase = v.phase :: string,
			since = v.since,
			progress0 = math.floor(v.progress0 * 1000 + 0.5) / 1000,
		}
	end
	local g = self.gates[id]
	if g then
		return { kind = "gate", open = g.open, since = g.since }
	end
	local p = self.powers[id]
	if p ~= nil then
		return { kind = "power", on = p }
	end
	return nil
end

function EffectModel.allZoneIds(self: Model): { string }
	local ids = {}
	for id in self.basins do
		table.insert(ids, id)
	end
	for id in self.fires do
		table.insert(ids, id)
	end
	for id in self.vines do
		table.insert(ids, id)
	end
	for id in self.gates do
		table.insert(ids, id)
	end
	for id in self.powers do
		table.insert(ids, id)
	end
	table.sort(ids)
	return ids
end

-- Expected phase sequence helpers for client visuals (fill level at a given time).
function EffectModel.fillAt(phase: string, fill0: number, elapsed: number, timings: Timings): number
	if phase == "Filling" then
		return math.min(1, fill0 + elapsed / timings.FillSeconds)
	elseif phase == "Draining" then
		return math.max(0, fill0 - elapsed / timings.DrainSeconds)
	elseif phase == "Dry" then
		return 0
	end
	return 1
end

function EffectModel.vineProgressAt(phase: string, progress0: number, elapsed: number, timings: Timings): number
	if phase == "Growing" then
		return math.min(1, progress0 + elapsed / timings.VineGrowSeconds)
	elseif phase == "Retracting" then
		return math.max(0, progress0 - elapsed / timings.VineRetractSeconds)
	elseif phase == "Grown" or phase == "Holding" then
		return 1
	elseif phase == "Retracted" then
		return 0
	end
	return progress0
end

return EffectModel
