--!strict
--[[
	HazardService: everything that moves or hurts (S11, R02, R08, R09, R10, R05).

	Order inside step(): crates (wind + magnet) -> plates -> carts -> damage volumes -> falls -> safe points
	-> keys. Effects were already resolved this frame by EffectService (S09).

	* Crates slide on rails. Wind pushes them along a lane only when the lane runs parallel to the rail;
	  a Magnet room pulls linked metal crates toward its door; wind competes with a bounded force (R05).
	  A crate reaching its slot drops into the gap as a stepping block.
	* Carts move on a deterministic timeline that clients reproduce exactly from replicated parameters.
	  Cold slows them; a Fan blowing across the track pins the cart at the far end while it runs.
	* Fire only hurts while Burning (after its visible warning), electrified water only while powered and
	  liquid, falls cost a heart and return the player to their last safe point.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.Config.GameConfig)
local CartTimeline = require(Shared.Logic.CartTimeline)
local MathUtil = require(Shared.Util.MathUtil)
local Engine = require(Shared.Util.Engine)
local Registry = require(script.Parent.Parent.Core.Registry)
local StateServer = require(script.Parent.Parent.Core.StateServer)
local RunTypes = require(script.Parent.Parent.Core.RunTypes)

type Run = RunTypes.Run
type RosterEntry = RunTypes.RosterEntry

type CrateState = {
	id: string,
	part: BasePart,
	offset: number,
	velocity: number,
	half: number,
	slotted: boolean,
	moving: boolean,
	runtime: any,
}

type CartState = {
	id: string,
	runtime: any,
	phase0: number,
	t0: number,
	rate: number,
	pinned: number, -- 0 = running, +1/-1 = pinned toward that end
	x0: number,
	coldMul: number,
	pinKey: string,
}

-- Movement guard state for one run member (see guardEntry).
type Guard = {
	root: BasePart,
	anchor: Vector3, -- last accepted position
	budget: number, -- studs the character may still cover right now
	seen: number, -- server teleports already accounted for
	settleTo: Vector3?, -- destination of a server teleport the client may not have applied yet
	settleAt: number,
}

type Scratch = {
	crates: { [string]: CrateState },
	carts: { [string]: CartState },
	falling: { [number]: number },
	sampleTimer: number,
	keyTaken: { [string]: boolean },
	tickTimer: number,
	guards: { [number]: Guard },
}

local HazardService = {}

local global = StateServer.global("global")
local H = GameConfig.Hazards
local I = GameConfig.Integrity

local function serverNow(): number
	return workspace:GetServerTimeNow()
end

local function scratch(run: Run): Scratch
	return run.scratch.hazards
end

-- Cart timeline ----------------------------------------------------------------------------------------

-- Current lateral offset of a cart (shared maths with the client renderer: Logic/CartTimeline).
function HazardService.cartOffset(state: CartState, now: number): number
	return CartTimeline.offset(state :: any, state.runtime.range, state.runtime.speed, now)
end

local function publishCart(state: CartState)
	global:Set({ "carts", state.id }, {
		phase0 = state.phase0,
		t0 = state.t0,
		rate = state.rate,
		pinned = state.pinned,
		x0 = state.x0,
		coldMul = state.coldMul,
	})
end

local function updateCartModifiers(run: Run, state: CartState)
	local Rooms = Registry.get("Rooms")
	local cart = state.runtime
	local coldMul = if Rooms.isCold(run, state.id) then GameConfig.Cold.CartSlowMultiplier else 1
	local pinned = 0
	local pinKey = ""
	for _, lane in Rooms.activeLanes(run) do
		if
			lane.dir == "Across"
			and MathUtil.pointInBox(lane.cf, lane.size, cart.tileCF.Position + Vector3.new(0, 3, 0), 0.5)
		then
			local along = lane.vector:Dot(cart.tileCF.RightVector)
			pinned = if along >= 0 then 1 else -1
			pinKey = lane.id
			break
		end
	end
	if coldMul == state.coldMul and pinned == state.pinned and pinKey == state.pinKey then
		return
	end
	local now = serverNow()
	local x = HazardService.cartOffset(state, now)
	local wasMovingPositive: boolean
	if state.pinned ~= 0 then
		wasMovingPositive = state.pinned < 0 -- leaving a pinned end, head back the other way
	else
		local f = (state.phase0 + state.rate * (now - state.t0)) % 1
		wasMovingPositive = f < 0.5
	end
	state.coldMul = coldMul
	state.pinned = pinned
	state.pinKey = pinKey
	state.t0 = now
	state.x0 = x
	state.rate = cart.speed * coldMul / (4 * cart.range)
	state.phase0 = CartTimeline.phaseFor(x, cart.range, wasMovingPositive)
	publishCart(state)
	if pinned ~= 0 then
		Registry.get("Effects").combo(run, "cart_pin")
	elseif coldMul < 1 then
		Registry.get("Effects").combo(run, "cart_freeze")
	end
end

-- Crates ------------------------------------------------------------------------------------------------

local function crateCFrame(state: CrateState): CFrame
	-- Rail X axis is the movement axis; undo the rail rotation so the crate keeps its run orientation.
	return state.runtime.railCF * CFrame.new(state.offset, 0, 0) * CFrame.Angles(0, -math.pi / 2, 0)
end

local function crateTargetVelocity(run: Run, state: CrateState): number
	local position = state.part.CFrame.Position
	local axis = state.runtime.railCF.XVector
	local Rooms = Registry.get("Rooms")
	local wind = 0
	for _, lane in Rooms.activeLanes(run) do
		if lane.dir ~= "Across" and MathUtil.pointInBox(lane.cf, lane.size, position, 0.5) then
			local along = lane.vector:Dot(axis)
			if math.abs(along) > 0.9 then
				wind = GameConfig.Wind.CratePushSpeed * math.sign(along)
				break
			end
		end
	end
	local magnet = 0
	if state.runtime.metal then
		for _, m in Rooms.activeMagnets(run) do
			if table.find(m.crates, state.id) then
				local toAnchor = (m.anchor - position):Dot(axis)
				if math.abs(toAnchor) > 3.2 then
					magnet = GameConfig.Magnet.PullSpeed * math.sign(toAnchor)
				end
				break
			end
		end
	end
	if magnet ~= 0 and wind ~= 0 then
		return math.clamp(wind + magnet, -GameConfig.Magnet.MaxCombinedSpeed, GameConfig.Magnet.MaxCombinedSpeed) * 0.5
	end
	return wind + magnet
end

local function stepCrates(run: Run, dt: number)
	local s = scratch(run)
	for _, state in s.crates do
		if not state.slotted then
			local target = crateTargetVelocity(run, state)
			state.velocity = MathUtil.approach(state.velocity, target, 40 * dt)
			if math.abs(state.velocity) > 1e-3 then
				local before = state.offset
				local nextOffset = math.clamp(before + state.velocity * dt, -state.half, state.half)
				local slot = state.runtime.slotOffset
				if
					slot
					and (
						(before < slot and nextOffset >= slot)
						or (before > slot and nextOffset <= slot)
						or math.abs(nextOffset - slot) < 0.05
					)
				then
					-- Drop into the gap slot: becomes a stepping block flush with the floor.
					state.slotted = true
					state.velocity = 0
					state.part.CFrame = state.runtime.slotCF
					state.part:SetAttribute("Slotted", true)
					Registry.get("Expedition").fireRun("crateSlot", { crate = state.id })
					Registry.get("Effects").combo(run, "crate_bridge")
					Registry.get("Caretaker").noise(run, state.part.CFrame.Position, GameConfig.Noise.CrateImpact)
					global:Set({ "crates", state.id }, { slotted = true })
				else
					local hitEnd = nextOffset == state.half or nextOffset == -state.half
					state.offset = nextOffset
					state.part.CFrame = crateCFrame(state)
					if hitEnd and math.abs(state.velocity) > 4 then
						Registry.get("Expedition").fireRun("crateImpact", { crate = state.id })
						Registry.get("Caretaker").noise(run, state.part.CFrame.Position, GameConfig.Noise.CrateImpact)
					end
					if hitEnd then
						state.velocity = 0
					end
					local moving = math.abs(state.velocity) > 0.05
					if moving ~= state.moving then
						state.moving = moving
						state.part:SetAttribute("Moving", moving)
					end
				end
			elseif state.moving then
				state.moving = false
				state.part:SetAttribute("Moving", false)
			end
		end
	end
	-- Pressure plates: any crate resting on a plate.
	local Effects = Registry.get("Effects")
	for plateId, plate in run.runtime.plates do
		local active = false
		for _, state in s.crates do
			local p = state.part.CFrame.Position
			local d = Vector3.new(p.X - plate.cf.Position.X, 0, p.Z - plate.cf.Position.Z).Magnitude
			if d <= plate.radius then
				active = true
				break
			end
		end
		Effects.setPlate(run, plateId, active)
	end
end

-- Damage & falls -----------------------------------------------------------------------------------------

local function knockFrom(origin: Vector3, position: Vector3, strength: number): Vector3
	local away = Vector3.new(position.X - origin.X, 0, position.Z - origin.Z)
	if away.Magnitude < 0.1 then
		away = Vector3.new(0, 0, 1)
	end
	return (away.Unit + Vector3.new(0, 0.55, 0)).Unit * strength
end

-- Region from the launch trigger to the landing point (cached per launch record).
local launchRegions: { [any]: { cf: CFrame, size: Vector3 } } = setmetatable({}, { __mode = "k" }) :: any
local function launchRegion(launch: any): { cf: CFrame, size: Vector3 }
	local cached = launchRegions[launch]
	if cached then
		return cached
	end
	local from = launch.trigger.cf.Position
	local to = launch.landing
	local flat = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
	local length = math.max(flat.Magnitude, 1)
	local middle = (from + to) / 2
	local region = {
		cf = CFrame.lookAt(middle, middle + flat.Unit),
		size = Vector3.new(launch.trigger.size.X, 40, length + launch.trigger.size.Z),
	}
	launchRegions[launch] = region
	return region
end

local function inPitXZ(run: Run, position: Vector3): any?
	for _, pit in run.runtime.pits do
		if MathUtil.pointInBoxXZ(pit.box.cf, pit.box.size, position, 0) then
			return pit
		end
	end
	return nil
end

-- Whether a character stands on something solid. The client simulates its own character, so the server cannot
-- rely on Humanoid.FloorMaterial (computed where the character is simulated): a short ray down from the root
-- answers it here. An R6 body stands on its 2-stud legs; R15 builds the legs into HipHeight.
local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Exclude
groundParams.RespectCanCollide = true

local function standing(root: BasePart, humanoid: Humanoid): boolean
	local legs = if humanoid.RigType == Enum.HumanoidRigType.R6 then 2 else 0
	local depth = humanoid.HipHeight + legs + root.Size.Y / 2 + 1.5
	groundParams.FilterDescendantsInstances = { humanoid.Parent :: Instance }
	return workspace:Raycast(root.CFrame.Position, Vector3.new(0, -depth, 0), groundParams) ~= nil
end

local function onLedge(run: Run, position: Vector3): boolean
	for _, ledge in run.runtime.ledges do
		if MathUtil.pointInBox(ledge.cf, ledge.size, position, 0.3) then
			return true
		end
	end
	return false
end

-- Movement guard. The client owns its character, so a modified client can put it anywhere: next to the
-- target room, or into the exit with the suitcase. Every frame, before the suitcase, capture and Caretaker
-- checks run, each run member may only have covered what legitimate movement allows: MaxMoveSpeed plus a
-- burst allowance that covers launches, boosted slides, knockback and a lagging client whose position arrives
-- all at once. Anything further is a teleport and the character goes back to where it was last accepted.
--
-- Server teleports (falls, checkpoints, unstuck) take a moment to reach the client, which keeps reporting where
-- it was until then. For TeleportSettleSeconds after one, a report counts only if the character could have
-- walked there from the destination since the teleport; anything else goes straight back to the destination,
-- and the allowance is left untouched. Then the guard carries on from wherever the character legitimately is.
local SETTLE_SLACK = 4 -- studs around the destination that always count as arrived

local function flatDistance(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

local function guardEntry(s: Scratch, entry: RosterEntry, dt: number, now: number)
	local Characters = Registry.get("Characters")
	local root = Characters.root(entry.player)
	if not root or entry.health.status == "Eliminated" then
		s.guards[entry.userId] = nil
		return
	end
	local position = root.CFrame.Position
	local existing = s.guards[entry.userId]
	local g: Guard
	if existing and existing.root == root then
		g = existing
	else
		g = { root = root, anchor = position, budget = I.MoveBurstStuds, seen = 0, settleTo = nil, settleAt = 0 }
		s.guards[entry.userId] = g
	end
	local teleport = Characters.lastTeleport(entry.player)
	if teleport and teleport.count ~= g.seen then
		g.seen = teleport.count
		if now - teleport.at < I.TeleportSettleSeconds then
			g.settleTo = teleport.to
			g.settleAt = teleport.at
		end
	end
	local settleTo = g.settleTo
	if settleTo then
		local arrived = flatDistance(position, settleTo) <= SETTLE_SLACK + I.MaxMoveSpeed * (now - g.settleAt)
		if now - g.settleAt < I.TeleportSettleSeconds then
			if not arrived then
				Characters.snapBack(entry.player, settleTo)
			end
			return
		end
		-- Settled: carry on from where the character now is (or from the destination, if it still is not there).
		g.settleTo = nil
		g.anchor = if arrived then position else settleTo
		g.budget = I.MoveBurstStuds
		if not arrived then
			Characters.snapBack(entry.player, settleTo)
		end
		return
	end
	g.budget = math.min(I.MoveBurstStuds, g.budget + I.MaxMoveSpeed * dt)
	local moved = flatDistance(position, g.anchor)
	if moved <= g.budget then
		g.budget -= moved
		g.anchor = position
		return
	end
	Characters.snapBack(entry.player, g.anchor)
end

local function stepEntry(run: Run, entry: RosterEntry, now: number, sample: boolean)
	local Characters = Registry.get("Characters")
	local Health = Registry.get("Health")
	local root = Characters.root(entry.player)
	if not root then
		return
	end
	local position = root.CFrame.Position
	local s = scratch(run)
	local status = entry.health.status
	if status == "Eliminated" then
		return
	end

	-- Falls into pits / water (deep basins that are not frozen solid).
	local pit = inPitXZ(run, position)
	local fallingUntil = s.falling[entry.userId]
	if fallingUntil and now < fallingUntil then
		return
	end
	local pitTop = if pit then pit.box.cf.Position.Y + pit.box.size.Y / 2 else 0
	if pit and position.Y < pitTop - H.FallDepth and not onLedge(run, position) then
		s.falling[entry.userId] = now + GameConfig.Health.FallRespawnDelaySeconds + 0.4
		local water = pit.zone ~= nil and run.effect:basinWet(pit.zone)
		Registry.get("Expedition")
			.fireRun(if water then "splash" else "fall", { userId = entry.key, position = position })
		Registry.get("Caretaker").noise(run, position, GameConfig.Noise.Splash)
		-- Check-In forgives falls: a new player learns the flood with a splash, not by losing the run.
		if status == "Active" and not run.tutorial then
			Health.damage(run, entry, H.FallDamage, if water then "water" else "fall", nil)
		end
		local back = entry.lastSafe or run.runtime.spawns[1]
		task.delay(GameConfig.Health.FallRespawnDelaySeconds, function()
			if not run.ended and entry.connected and not entry.left then
				Characters.teleport(entry.player, back)
				-- A fall that downed them: the Help marker moves from the pit to where they now lie.
				if entry.health.status == "Downed" then
					local left = entry.health.downedUntil - os.clock()
					if left > 0 then
						Registry.get("Pings").helpFor(run, entry, left, back.Position)
					end
				end
			end
		end)
		return
	end

	-- Out of bounds safety net.
	local b = run.runtime.bounds
	if
		position.Y < b.min.Y
		or position.X < b.min.X
		or position.X > b.max.X
		or position.Z < b.min.Z
		or position.Z > b.max.Z
	then
		Characters.teleport(entry.player, entry.lastSafe or run.runtime.spawns[1])
		return
	end

	if status == "Active" then
		-- Fire.
		for id, fire in run.runtime.fires do
			if run.effect:fireLit(id) and MathUtil.pointInBox(fire.volume.cf, fire.volume.size, position, 0.6) then
				Health.damage(
					run,
					entry,
					H.FireDamage,
					"fire",
					knockFrom(fire.volume.cf.Position, position, H.FireKnockback)
				)
				break
			end
		end
		-- Electrified water.
		for id, basin in run.runtime.basins do
			if
				basin.damage
				and run.effect:basinElectrified(id)
				and MathUtil.pointInBox(basin.damage.cf, basin.damage.size, position, 0.3)
			then
				Health.damage(
					run,
					entry,
					H.ShockDamage,
					"shock",
					knockFrom(basin.damage.cf.Position, position, H.ShockKnockback)
				)
				break
			end
		end
		-- Carts.
		for _, state in s.carts do
			local cart = state.runtime
			local localPos = cart.tileCF:PointToObjectSpace(position)
			local x = HazardService.cartOffset(state, serverNow())
			if
				math.abs(localPos.X - x) < cart.size.X / 2 + 1.1
				and math.abs(localPos.Z) < cart.size.Z / 2 + 0.9
				and localPos.Y < cart.size.Y + 1.5
			then
				local origin = cart.tileCF * Vector3.new(x, 0, 0)
				local push = knockFrom(origin, position, H.CartKnockback)
				Health.damage(run, entry, H.CartDamage, "cart", push)
				break
			end
		end
	end

	-- Ice + wind launch (R08): detected from the replicated character velocity anywhere between the launch
	-- ramp and the landing point. Hazards tick at 10 Hz and a sliding player crosses the ramp in well under
	-- a tick, so the detection region covers the whole flight arc instead of only the ramp.
	if status == "Active" then
		for _, launch in run.runtime.launches do
			local region = launchRegion(launch)
			if MathUtil.pointInBox(region.cf, region.size, position, 0.5) then
				local velocity = Engine.velocity(root)
				local along = Vector3.new(velocity.X, 0, velocity.Z):Dot(launch.direction)
				if along >= GameConfig.Wind.LaunchMinSpeed * 0.8 then
					Registry.get("Effects").combo(run, "ice_launch", entry)
				end
			end
		end
	end

	-- Last safe point sampling (S16 checkpoint).
	if sample and status == "Active" then
		local humanoid = Characters.humanoid(entry.player)
		if humanoid and standing(root, humanoid) and (pit == nil or onLedge(run, position)) then
			for _, floor in run.runtime.safeFloors do
				if MathUtil.pointInBox(floor.cf, floor.size, position, 0.2) then
					local look = root.CFrame.LookVector * Vector3.new(1, 0, 1)
					if look.Magnitude < 0.1 then
						look = Vector3.new(0, 0, -1)
					end
					local p = position + Vector3.new(0, 0.4, 0)
					entry.lastSafe = CFrame.lookAt(p, p + look.Unit)
					break
				end
			end
		end
	end

	-- Keys.
	if status == "Active" and Registry.get("Flags").feature("keys") then
		for keyId, key in run.runtime.keys do
			if not s.keyTaken[keyId] and (key.position - position).Magnitude < 4.2 then
				s.keyTaken[keyId] = true
				run.stats.keys[keyId] = entry.userId
				global:Set({ "keys", keyId }, entry.key)
				Registry.get("Expedition").fireRun("key", { key = keyId, userId = entry.key })
				Registry.get("Telemetry").keyCollected(run, entry, keyId)
			end
		end
	end
end

-- Lifecycle ---------------------------------------------------------------------------------------------

function HazardService.startRun(run: Run)
	local s: Scratch = {
		crates = {},
		carts = {},
		falling = {},
		sampleTimer = 0,
		keyTaken = {},
		tickTimer = 0,
		guards = {},
	}
	run.scratch.hazards = s
	for _, d in run.model:GetDescendants() do
		if d:IsA("BasePart") and d:HasTag("RN_Crate") then
			local id = d:GetAttribute("CrateId") :: string
			local rt = run.runtime.crates[id]
			if rt then
				local state: CrateState = {
					id = id,
					part = d,
					offset = rt.startOffset,
					velocity = 0,
					half = rt.railLength / 2,
					slotted = false,
					moving = false,
					runtime = rt,
				}
				d.CFrame = crateCFrame(state)
				s.crates[id] = state
			end
		end
	end
	local now = serverNow()
	local carts = {}
	for id, cart in run.runtime.carts do
		local state: CartState = {
			id = id,
			runtime = cart,
			phase0 = 0,
			t0 = now,
			rate = cart.speed / (4 * cart.range),
			pinned = 0,
			x0 = -cart.range,
			coldMul = 1,
			pinKey = "",
		}
		s.carts[id] = state
		carts[id] = {
			phase0 = state.phase0,
			t0 = state.t0,
			rate = state.rate,
			pinned = 0,
			x0 = state.x0,
			coldMul = 1,
		}
	end
	global:Set({ "carts" }, carts)
	global:Set({ "keys" }, {})
	global:Set({ "crates" }, {})
end

function HazardService.step(run: Run, dt: number)
	local s = scratch(run)
	if not s then
		return
	end
	local clock = os.clock()
	for _, entry in Registry.get("Expedition").participants(run) do
		if entry.player.Parent == Players then
			guardEntry(s, entry, dt, clock)
		end
	end
	stepCrates(run, dt)
	for _, state in s.carts do
		updateCartModifiers(run, state)
	end
	s.tickTimer += dt
	if s.tickTimer < H.TickSeconds then
		return
	end
	s.tickTimer = 0
	s.sampleTimer += H.TickSeconds
	local sample = s.sampleTimer >= 0.2
	if sample then
		s.sampleTimer = 0
	end
	local now = os.clock()
	for _, entry in Registry.get("Expedition").participants(run) do
		if entry.player.Parent == Players then
			stepEntry(run, entry, now, sample)
		end
	end
end

function HazardService.endRun(run: Run)
	run.scratch.hazards = nil
end

-- Exposed for the caretaker / tests.
function HazardService.crateParts(run: Run): { BasePart }
	local out = {}
	local s = run.scratch.hazards
	if s then
		for _, state in s.crates do
			table.insert(out, state.part)
		end
	end
	return out
end

function HazardService.Init()
	Registry.add("Hazards", HazardService)
end

function HazardService.Start() end

return HazardService
