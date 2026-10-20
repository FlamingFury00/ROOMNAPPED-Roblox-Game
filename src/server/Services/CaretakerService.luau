--!strict
--[[
	CaretakerService: the hotel's hovering bellhop (S15, S18, A03, U08).

	The caretaker is simulated on the server as data (no physics body): it hovers along the level's waypoint
	graph, sees with a vision cone + line of sight, hears noises (room deploys, splashes, levers, crates) and
	switches between Patrol, Investigate, Chase, Search and - after the capture - Hunt. Clients render it from
	15 Hz unreliable snapshots with interpolation and procedural animation.

	Fairness rules:
	  * Every attack is telegraphed by a 0.4 s wind-up (Lunge) and followed by a React pause.
	  * Cold zones slow it; wind pushes it back by at most CaretakerMaxPushback studs per exposure, after which
	    it braces for CaretakerBraceSeconds - wind can never stun-lock it.
	  * If it gets stuck or no path exists (closed gate, odd geometry) it "phases" through the walls: it fades
	    out with a cue and reappears on the graph near its target (recovers from a blocked path).
	  * Pressure scales with squad size (S18) through speed, not through extra objectives.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.Config.GameConfig)
local NavGraph = require(Shared.Logic.NavGraph)
local Geometry = require(Shared.World.Geometry)
local MathUtil = require(Shared.Util.MathUtil)
local Net = require(Shared.Net.Net)
local Registry = require(script.Parent.Parent.Core.Registry)
local StateServer = require(script.Parent.Parent.Core.StateServer)
local RunTypes = require(script.Parent.Parent.Core.RunTypes)

type Run = RunTypes.Run
type RosterEntry = RunTypes.RosterEntry

type Mode =
	"Dormant"
	| "Patrol"
	| "Investigate"
	| "Chase"
	| "Search"
	| "Alert"
	| "Hunt"
	| "Lunge"
	| "React"
	| "Phase"
	| "Off"

type State = {
	graph: NavGraph.Graph,
	position: Vector3,
	yaw: number,
	mode: Mode,
	modeSince: number,
	resumeMode: Mode,
	target: number?,
	lastSeen: Vector3?,
	lastSeenAt: number,
	path: { string },
	pathIndex: number,
	repathAt: number,
	goal: Vector3?,
	patrolIndex: number,
	patrolDir: number,
	lungeDir: Vector3,
	lungeHit: boolean,
	pushback: number,
	braceUntil: number,
	inWind: boolean,
	stuckTimer: number,
	progressAt: Vector3,
	snapshotTimer: number,
	perceptionTimer: number,
	tickAccumulator: number,
	chilled: boolean,
	enabled: boolean,
	roomNodes: { [string]: boolean },
	phaseTarget: Vector3?,
}

local C = GameConfig.Caretaker
local W = GameConfig.Wind

local MODE_CODES: { [string]: number } = {
	Off = 0,
	Dormant = 1,
	Patrol = 2,
	Investigate = 3,
	Chase = 4,
	Search = 5,
	Alert = 6,
	Hunt = 7,
	Lunge = 8,
	React = 9,
	Phase = 10,
}

local CaretakerService = {}

local global = StateServer.global("global")
local disabledByDebug = false

local function serverNow(): number
	return workspace:GetServerTimeNow()
end

local function state(run: Run): State?
	return run.scratch.caretaker
end

local function publish(run: Run, s: State)
	global:Set({ "caretaker" }, {
		mode = s.mode,
		target = if s.target then tostring(s.target) else nil,
		chilled = s.chilled,
		braced = os.clock() < s.braceUntil,
		since = serverNow(),
	})
end

local function setMode(run: Run, s: State, mode: Mode)
	if s.mode == mode then
		return
	end
	local previous = s.mode
	s.mode = mode
	s.modeSince = os.clock()
	publish(run, s)
	if mode == "Chase" and previous ~= "Lunge" and previous ~= "React" then
		Net.fireAll("Effect", "caretakerSpotted", { target = if s.target then tostring(s.target) else nil })
	end
end

-- Geometry helpers ---------------------------------------------------------------------------------------

local function nodeAt(run: Run, s: State, position: Vector3): string?
	-- Deployed rooms first, then corridor tiles (exact cell containment), then nearest node.
	local Rooms = Registry.get("Rooms")
	local roomSocket = Rooms.roomAt(run, position)
	if roomSocket and s.graph.nodes["r" .. roomSocket] then
		return "r" .. roomSocket
	end
	for i, tile in run.runtime.tiles do
		if MathUtil.pointInBoxXZ(tile.cf, Vector3.new(Geometry.Tile, 1, Geometry.Tile), position, 0.01) then
			return "t" .. i
		end
	end
	return s.graph:nearest(position)
end

local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude

local function refreshRayFilter()
	local ignore = {}
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(ignore, player.Character)
		end
	end
	raycastParams.FilterDescendantsInstances = ignore
end

local function clearLine(from: Vector3, to: Vector3): boolean
	local direction = to - from
	if direction.Magnitude < 0.1 then
		return true
	end
	local hit = workspace:Raycast(from, direction, raycastParams)
	return hit == nil
end

-- Two parallel rays so a direct dash never cuts through a wall corner.
local function clearCorridor(from: Vector3, to: Vector3): boolean
	local flat = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
	if flat.Magnitude < 0.5 then
		return true
	end
	local side = flat.Unit:Cross(Vector3.yAxis) * (Geometry.Caretaker.Radius * 0.75)
	return clearLine(from + side, to + side) and clearLine(from - side, to - side)
end

local function hoverY(): number
	return Geometry.LevelOrigin.Y + Geometry.Caretaker.HoverY
end

local function participantsActive(run: Run): { RosterEntry }
	local out = {}
	for _, entry in Registry.get("Expedition").participants(run) do
		if entry.health.status == "Active" then
			table.insert(out, entry)
		end
	end
	return out
end

local function entryPosition(entry: RosterEntry): Vector3?
	return Registry.get("Characters").position(entry.player)
end

-- Speed ---------------------------------------------------------------------------------------------------

local function baseSpeed(run: Run, s: State): number
	local mode = s.mode
	local soloMul = if run.solo then 0.92 else 1
	local tutorialMul = if run.tutorial then 0.8 else 1
	local speed = C.PatrolSpeed
	if mode == "Investigate" then
		speed = C.InvestigateSpeed
	elseif mode == "Chase" then
		speed = C.ChaseSpeed * soloMul
	elseif mode == "Search" then
		speed = C.PatrolSpeed + 1
	elseif mode == "Hunt" then
		local extra = math.max(0, #run.order - 1)
		speed = C.HuntSpeedBase + C.HuntSpeedPerExtraPlayer * extra
		if run.escapeEndsAt and run.escapeEndsAt - serverNow() < GameConfig.Escape.WarningSeconds then
			speed += C.HuntSpeedFinalStretchBonus
		end
		speed *= soloMul
	elseif mode == "Lunge" then
		speed = C.LungeDashSpeed
	end
	return speed * tutorialMul
end

local function inColdField(run: Run, position: Vector3): boolean
	for _, field in Registry.get("Effects").coldFields(run) do
		if MathUtil.pointInBox(field.cf, field.size, position, 1) then
			return true
		end
	end
	-- Standing over frozen water also chills it.
	for id, basin in run.runtime.basins do
		if run.effect:basinSolid(id) and MathUtil.pointInBox(basin.occupancy.cf, basin.occupancy.size, position, 1) then
			return true
		end
	end
	return false
end

-- Movement -------------------------------------------------------------------------------------------------

local function moveToward(run: Run, s: State, goal: Vector3, speed: number, dt: number): boolean
	local flatGoal = Vector3.new(goal.X, hoverY(), goal.Z)
	local delta = flatGoal - s.position
	local distance = delta.Magnitude
	if distance < 0.05 then
		return true
	end
	local stepLength = math.min(distance, speed * dt)
	s.position += delta.Unit * stepLength
	local desiredYaw = math.atan2(-delta.X, -delta.Z)
	s.yaw += MathUtil.angleDelta(s.yaw, desiredYaw) * MathUtil.dampAlpha(10, dt)
	return stepLength >= distance - 0.05
end

local function planPath(run: Run, s: State, goal: Vector3): boolean
	local from = nodeAt(run, s, s.position)
	local to = nodeAt(run, s, goal)
	if not from or not to then
		return false
	end
	local path = s.graph:path(from, to)
	if not path then
		return false
	end
	s.path = path
	-- path[1] is the node we are already in; heading back to its centre on every re-plan would make the
	-- caretaker oscillate, so continue straight toward the next node.
	s.pathIndex = if #path >= 2 then 2 else 1
	s.goal = goal
	s.repathAt = os.clock() + 0.5
	return true
end

-- Follow the current path; returns true when the final node has been reached.
local function followPath(run: Run, s: State, speed: number, dt: number): boolean
	if #s.path == 0 then
		return true
	end
	local nodeId = s.path[s.pathIndex]
	local position = s.graph:position(nodeId)
	if not position then
		s.path = {}
		return true
	end
	local arrived = moveToward(run, s, position, speed, dt)
	if
		arrived
		or (Vector3.new(position.X, 0, position.Z) - Vector3.new(s.position.X, 0, s.position.Z)).Magnitude < 1.2
	then
		if s.pathIndex >= #s.path then
			return true
		end
		s.pathIndex += 1
	end
	return false
end

-- Travel to a world position: direct when the corridor is clear and close, otherwise via the graph.
local function travel(run: Run, s: State, goal: Vector3, speed: number, dt: number): boolean
	local eye = s.position
	local flatGoal = Vector3.new(goal.X, hoverY(), goal.Z)
	if (flatGoal - eye).Magnitude < 40 and clearCorridor(eye, flatGoal) then
		s.path = {}
		return moveToward(run, s, flatGoal, speed, dt)
	end
	if #s.path == 0 or os.clock() >= s.repathAt or s.goal == nil or (s.goal :: Vector3 - goal).Magnitude > 6 then
		if not planPath(run, s, goal) then
			return false
		end
	end
	local reached = followPath(run, s, speed, dt)
	if reached then
		return moveToward(run, s, flatGoal, speed, dt)
	end
	return false
end

-- Wind (bounded pushback with bracing) --------------------------------------------------------------------

local function applyWind(run: Run, s: State, dt: number)
	local now = os.clock()
	local inWind = false
	if now >= s.braceUntil then
		for _, lane in Registry.get("Rooms").activeLanes(run) do
			if MathUtil.pointInBox(lane.cf, lane.size, s.position, 0) then
				inWind = true
				local push = lane.vector * W.CaretakerPushSpeed * dt
				local candidate = s.position + push
				if MathUtil.pointInBox(lane.cf, lane.size, candidate, -1) then
					s.position = candidate
					s.pushback += push.Magnitude
				end
				if s.pushback >= W.CaretakerMaxPushback then
					s.braceUntil = now + W.CaretakerBraceSeconds
					s.pushback = 0
					publish(run, s)
					Registry.get("Effects").combo(run, "caretaker_blown")
				end
				break
			end
		end
	end
	if not inWind and s.inWind then
		s.pushback = 0
	end
	s.inWind = inWind
end

-- Perception ---------------------------------------------------------------------------------------------------

local function canSee(run: Run, s: State, entry: RosterEntry): boolean
	local position = entryPosition(entry)
	if not position then
		return false
	end
	local range = C.VisionRange * (if run.solo then C.SoloDetectionMultiplier else 1)
	local offset = position - s.position
	local distance = offset.Magnitude
	if distance > range then
		return false
	end
	if distance > 9 then
		local facing = Vector3.new(-math.sin(s.yaw), 0, -math.cos(s.yaw))
		local flat = Vector3.new(offset.X, 0, offset.Z)
		if flat.Magnitude > 0.1 then
			local angle = math.deg(math.acos(math.clamp(facing:Dot(flat.Unit), -1, 1)))
			if angle > C.VisionHalfAngleDegrees then
				return false
			end
		end
	end
	local eye = s.position + Vector3.new(0, 3, 0)
	return clearLine(eye, position + Vector3.new(0, 1, 0))
end

local function closestVisible(run: Run, s: State): RosterEntry?
	local best: RosterEntry? = nil
	local bestDistance = math.huge
	for _, entry in participantsActive(run) do
		if canSee(run, s, entry) then
			local position = entryPosition(entry) :: Vector3
			local d = (position - s.position).Magnitude
			if d < bestDistance then
				best, bestDistance = entry, d
			end
		end
	end
	return best
end

-- Escape-phase target: the cargo carrier, else whoever is nearest the cargo, else the nearest player.
local function huntTarget(run: Run, s: State): RosterEntry?
	local Cargo = Registry.get("Cargo")
	local carrier = Cargo.carrierOf(run)
	if carrier then
		local entry = run.roster[carrier]
		if entry and entry.health.status == "Active" then
			return entry
		end
	end
	local anchor = Cargo.position(run) or s.position
	local best: RosterEntry? = nil
	local bestDistance = math.huge
	for _, entry in participantsActive(run) do
		local position = entryPosition(entry)
		if position then
			local d = (position - anchor).Magnitude
			if d < bestDistance then
				best, bestDistance = entry, d
			end
		end
	end
	return best
end

-- Attacks ----------------------------------------------------------------------------------------------------

local function startLunge(run: Run, s: State, target: RosterEntry)
	local position = entryPosition(target)
	if not position then
		return
	end
	local flat = Vector3.new(position.X - s.position.X, 0, position.Z - s.position.Z)
	s.lungeDir = if flat.Magnitude > 0.1 then flat.Unit else Vector3.new(0, 0, -1)
	s.lungeHit = false
	s.resumeMode = if s.mode == "Hunt" then "Hunt" else "Chase"
	s.target = target.userId
	setMode(run, s, "Lunge")
	Net.fireAll("Effect", "caretakerLunge", { target = target.key })
end

local function tryStrike(run: Run, s: State): boolean
	for _, entry in participantsActive(run) do
		local position = entryPosition(entry)
		if position then
			local flat = Vector3.new(position.X - s.position.X, 0, position.Z - s.position.Z)
			if flat.Magnitude <= C.StrikeRange and math.abs(position.Y - s.position.Y) < 6 then
				local knock = (if flat.Magnitude > 0.1 then flat.Unit else s.lungeDir) + Vector3.new(0, 0.6, 0)
				local landed = Registry.get("Health").damage(run, entry, 1, "caretaker", knock.Unit * 60)
				if landed then
					Net.fireAll("Effect", "caretakerHit", { userId = entry.key })
					Registry.get("Telemetry").caretakerHit(run, entry)
					return true
				end
			end
		end
	end
	return false
end

-- Phasing (stuck / blocked recovery) ----------------------------------------------------------------------

local function beginPhase(run: Run, s: State, near: Vector3)
	-- Reappear two nodes away from the target along the graph so the threat stays fair.
	local targetNode = nodeAt(run, s, near)
	local spot: Vector3 = near
	if targetNode then
		local neighbours = s.graph:neighbors(targetNode)
		local chosen = targetNode
		for _, n in neighbours do
			for _, nn in s.graph:neighbors(n) do
				if nn ~= targetNode then
					chosen = nn
					break
				end
			end
			if chosen ~= targetNode then
				break
			end
		end
		spot = s.graph:position(chosen) or near
	end
	s.phaseTarget = spot
	s.path = {}
	setMode(run, s, "Phase")
	Net.fireAll("Effect", "caretakerPhase", { position = s.position })
end

-- Run lifecycle ------------------------------------------------------------------------------------------------

function CaretakerService.startRun(run: Run)
	local graph = NavGraph.new()
	for _, node in run.runtime.nav.nodes do
		graph:addNode(node.id, node.position)
	end
	for _, edge in run.runtime.nav.edges do
		graph:addEdge(edge[1], edge[2])
	end
	local spawnNode = run.runtime.caretaker.spawnNode
	local start = graph:position(spawnNode) or run.runtime.tiles[#run.runtime.tiles].cf.Position
	local s: State = {
		graph = graph,
		position = Vector3.new(start.X, hoverY(), start.Z),
		yaw = 0,
		mode = "Off",
		modeSince = os.clock(),
		resumeMode = "Patrol",
		target = nil,
		lastSeen = nil,
		lastSeenAt = 0,
		path = {},
		pathIndex = 1,
		repathAt = 0,
		goal = nil,
		patrolIndex = 1,
		patrolDir = 1,
		lungeDir = Vector3.new(0, 0, -1),
		lungeHit = false,
		pushback = 0,
		braceUntil = 0,
		inWind = false,
		stuckTimer = 0,
		progressAt = start,
		snapshotTimer = 0,
		perceptionTimer = 0,
		tickAccumulator = 0,
		chilled = false,
		enabled = not disabledByDebug and Registry.get("Flags").feature("caretaker"),
		roomNodes = {},
		phaseTarget = nil,
	}
	-- Gates start closed: alcove edges are disabled until open.
	for gateId in run.runtime.gates do
		local nodeId = "g" .. gateId
		if graph.nodes[nodeId] then
			graph:setNodeEnabled(nodeId, false)
		end
	end
	run.scratch.caretaker = s
	publish(run, s)
end

function CaretakerService.onExplore(run: Run)
	local s = state(run)
	if not s or not s.enabled then
		return
	end
	if run.runtime.caretaker.dormant then
		setMode(run, s, "Dormant")
		-- Sleeping inside the target room until the theft.
		local p = s.graph:position(run.runtime.caretaker.escapeSpawnNode)
		if p then
			s.position = Vector3.new(p.X, hoverY(), p.Z)
		end
	else
		setMode(run, s, "Patrol")
	end
end

function CaretakerService.wake(run: Run)
	local s = state(run)
	if not s or not s.enabled then
		return
	end
	s.target = nil
	s.path = {}
	setMode(run, s, "Alert")
	Net.fireAll("Effect", "caretakerAlert", {})
end

function CaretakerService.hunt(run: Run)
	local s = state(run)
	if not s or not s.enabled then
		return
	end
	setMode(run, s, "Hunt")
end

function CaretakerService.noise(run: Run, position: Vector3, radius: number)
	local s = state(run)
	if not s or not s.enabled then
		return
	end
	if s.mode ~= "Patrol" and s.mode ~= "Search" and s.mode ~= "Investigate" then
		return
	end
	if (position - s.position).Magnitude <= radius * C.HearingMultiplier then
		s.goal = position
		s.path = {}
		s.repathAt = 0
		setMode(run, s, "Investigate")
		Net.fireAll("Effect", "caretakerHeard", { position = position })
	end
end

-- Keep room nodes in sync with deployed rooms (it pursues players into rooms).
function CaretakerService.onRoomsChanged(run: Run)
	local s = state(run)
	if not s then
		return
	end
	local active = Registry.get("Rooms").activeSources(run)
	for socketId in s.roomNodes do
		if active[socketId] == nil then
			s.graph:removeNode("r" .. socketId)
			s.roomNodes[socketId] = nil
		end
	end
	for socketId in active do
		if not s.roomNodes[socketId] then
			local socket = run.runtime.sockets[socketId]
			if socket then
				local p = (socket.roomCF * CFrame.new(0, Geometry.Caretaker.HoverY, -7)).Position
				s.graph:addNode("r" .. socketId, p)
				s.graph:addEdge("t" .. socket.tile, "r" .. socketId)
				s.roomNodes[socketId] = true
			end
		end
	end
	s.path = {}
end

local function patrolGoal(run: Run, s: State): Vector3?
	local patrol = run.runtime.caretaker.patrol
	if #patrol == 0 then
		return nil
	end
	s.patrolIndex = math.clamp(s.patrolIndex, 1, #patrol)
	return s.graph:position(patrol[s.patrolIndex])
end

local function advancePatrol(run: Run, s: State)
	local count = #run.runtime.caretaker.patrol
	if count <= 1 then
		return
	end
	s.patrolIndex += s.patrolDir
	if s.patrolIndex > count then
		s.patrolIndex = count - 1
		s.patrolDir = -1
	elseif s.patrolIndex < 1 then
		s.patrolIndex = 2
		s.patrolDir = 1
	end
end

local function think(run: Run, s: State, dt: number)
	local now = os.clock()
	local mode = s.mode
	if mode == "Off" or mode == "Dormant" then
		return
	end
	if mode == "Alert" then
		-- Brief roar after the capture; it faces the thief.
		return
	end
	if mode == "Phase" then
		if now - s.modeSince >= C.PhaseDelaySeconds then
			local p = s.phaseTarget or s.position
			s.position = Vector3.new(p.X, hoverY(), p.Z)
			s.progressAt = s.position
			s.stuckTimer = 0
			setMode(run, s, if run.captured then "Hunt" else "Search")
			Net.fireAll("Effect", "caretakerReappear", { position = s.position })
		end
		return
	end
	if mode == "React" then
		if now - s.modeSince >= C.ReactSeconds * (if s.lungeHit then 1 else 0.5) then
			setMode(run, s, if run.captured then "Hunt" else s.resumeMode)
		end
		return
	end

	s.chilled = inColdField(run, s.position)
	local speed = baseSpeed(run, s) * (if s.chilled then GameConfig.Cold.CaretakerSlowMultiplier else 1)

	if mode == "Lunge" then
		local elapsed = now - s.modeSince
		if elapsed >= C.LungeWindupSeconds then
			local dash = s.lungeDir
				* C.LungeDashSpeed
				* (if s.chilled then GameConfig.Cold.CaretakerSlowMultiplier else 1)
				* dt
			local candidate = s.position + dash
			if clearCorridor(s.position, candidate + dash.Unit * 1.5) then
				s.position = candidate
			end
			if tryStrike(run, s) then
				s.lungeHit = true
				setMode(run, s, "React")
				return
			end
			if elapsed >= C.LungeWindupSeconds + 0.35 then
				setMode(run, s, "React")
			end
		end
		return
	end

	-- Perception (5 Hz).
	s.perceptionTimer -= dt
	local seen: RosterEntry? = nil
	if s.perceptionTimer <= 0 then
		s.perceptionTimer = 0.2
		refreshRayFilter()
		if mode ~= "Hunt" then
			seen = closestVisible(run, s)
			if seen then
				s.target = seen.userId
				s.lastSeen = entryPosition(seen)
				s.lastSeenAt = now
				if mode ~= "Chase" then
					setMode(run, s, "Chase")
				end
			end
		end
	end

	mode = s.mode
	if mode == "Hunt" then
		local target = huntTarget(run, s)
		if target then
			s.target = target.userId
			local position = entryPosition(target)
			if position then
				local flatDistance = MathUtil.flatDistance(position, s.position)
				if
					flatDistance <= C.LungeRange
					and clearCorridor(s.position, Vector3.new(position.X, hoverY(), position.Z))
				then
					startLunge(run, s, target)
					return
				end
				if not travel(run, s, position, speed, dt) and #s.path == 0 and flatDistance > 20 then
					s.stuckTimer += dt
				end
			end
		end
	elseif mode == "Chase" then
		local target = if s.target then run.roster[s.target] else nil
		local position = if target and target.health.status == "Active" then entryPosition(target) else nil
		if not position or now - s.lastSeenAt > C.LoseSightSeconds then
			setMode(run, s, "Search")
			s.goal = s.lastSeen
			s.path = {}
		else
			if
				MathUtil.flatDistance(position, s.position) <= C.LungeRange
				and clearCorridor(s.position, Vector3.new(position.X, hoverY(), position.Z))
			then
				startLunge(run, s, target :: RosterEntry)
				return
			end
			-- While chasing it keeps tracking the target briefly even through corners.
			s.lastSeen = position
			travel(run, s, position, speed, dt)
		end
	elseif mode == "Investigate" or mode == "Search" then
		local goal = s.goal or s.lastSeen
		if goal then
			local arrived = travel(run, s, goal, speed, dt)
			if arrived or MathUtil.flatDistance(goal, s.position) < 2.5 then
				s.goal = nil
				s.modeSince = now
			end
		elseif now - s.modeSince >= (if mode == "Search" then C.SearchSeconds else C.InvestigateLookSeconds) then
			s.target = nil
			setMode(run, s, "Patrol")
		else
			-- Look around.
			s.yaw += dt * 1.6
		end
	elseif mode == "Patrol" then
		local goal = patrolGoal(run, s)
		if goal then
			local arrived = travel(run, s, goal, speed, dt)
			if arrived or MathUtil.flatDistance(goal, s.position) < 1.5 then
				advancePatrol(run, s)
			end
		end
	end

	applyWind(run, s, dt)

	-- Stuck detection: no real progress for a while while it should be moving.
	if (s.position - s.progressAt).Magnitude > 2 then
		s.progressAt = s.position
		s.stuckTimer = 0
	elseif s.mode == "Hunt" or s.mode == "Chase" then
		s.stuckTimer += dt
	end
	if s.stuckTimer >= C.StuckSeconds then
		s.stuckTimer = 0
		local target = if s.target then run.roster[s.target] else nil
		local near = if target then entryPosition(target) else nil
		if near and not s.inWind then
			beginPhase(run, s, near)
		end
	end
end

function CaretakerService.step(run: Run, dt: number)
	local s = state(run)
	if not s or not s.enabled then
		return
	end
	-- Keep alcove nodes in sync with gates.
	for gateId in run.runtime.gates do
		local nodeId = "g" .. gateId
		if s.graph.nodes[nodeId] then
			s.graph:setNodeEnabled(nodeId, run.effect:gateOpen(gateId))
		end
	end
	s.tickAccumulator += dt
	local tick = 1 / C.TickRate
	local guard = 0
	while s.tickAccumulator >= tick and guard < 4 do
		s.tickAccumulator -= tick
		guard += 1
		think(run, s, tick)
	end
	if guard >= 4 then
		s.tickAccumulator = 0
	end
	s.snapshotTimer -= dt
	if s.snapshotTimer <= 0 then
		s.snapshotTimer = 1 / C.SnapshotRate
		Net.fireUnreliableAll("CaretakerSnapshot", serverNow(), s.position, s.yaw, MODE_CODES[s.mode] or 0)
	end
end

function CaretakerService.endRun(run: Run)
	run.scratch.caretaker = nil
	global:Set({ "caretaker" }, { mode = "Gone" })
end

function CaretakerService.setDebugEnabled(run: Run?, enabled: boolean)
	disabledByDebug = not enabled
	if run then
		local s = state(run)
		if s then
			s.enabled = enabled
			if not enabled then
				setMode(run, s, "Off")
			else
				setMode(run, s, if run.captured then "Hunt" else "Patrol")
			end
		end
	end
end

function CaretakerService.position(run: Run): Vector3?
	local s = state(run)
	return if s then s.position else nil
end

function CaretakerService.Init()
	Registry.add("Caretaker", CaretakerService)
end

function CaretakerService.Start() end

return CaretakerService
