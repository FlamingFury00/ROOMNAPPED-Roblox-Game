--!strict
--[[
	ExpeditionService: the run state machine and system orchestrator (S02, S14, S17, S19).

	Prep -> Launching -> Explore -> Capture -> Escape -> Results -> Prep

	* One active expedition per server. Players who were ready when the countdown ended form the roster;
	  everyone else (and anyone who joins mid-run) waits safely in the lobby (S17).
	* Run-scoped systems are started/stopped here and stepped in a fixed order every frame, so effects are
	  resolved before movement and damage (S09).
	* Success, failure and retry all pass through Results and return to a clean Prep: the level is destroyed,
	  replicated state is cleared and every run connection lives in the run trove (S27: no instance growth).
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.Config.GameConfig)
local MissionDefs = require(Shared.Config.MissionDefs)
local SkinDefs = require(Shared.Config.SkinDefs)
local Layouts = require(Shared.Content.Layouts)
local EffectModel = require(Shared.Logic.EffectModel)
local HealthModel = require(Shared.Logic.HealthModel)
local RunMachine = require(Shared.Logic.RunMachine)
local LevelBuilder = require(Shared.World.LevelBuilder)
local Trove = require(Shared.Util.Trove)
local Tables = require(Shared.Util.Tables)
local Log = require(Shared.Util.Log)
local Net = require(Shared.Net.Net)
local Registry = require(script.Parent.Parent.Core.Registry)
local StateServer = require(script.Parent.Parent.Core.StateServer)
local RunTypes = require(script.Parent.Parent.Core.RunTypes)

type Run = RunTypes.Run
type RosterEntry = RunTypes.RosterEntry

local log = Log.new("Expedition")

local ExpeditionService = {}

-- Run-scoped systems in tick order (water/cold resolve before wind/crates/damage).
local SYSTEMS = { "Effects", "Rooms", "Hazards", "Health", "Cargo", "Capture", "Caretaker", "Interaction" }
local ACTIVE_PHASES: { [string]: boolean } = { Explore = true, Capture = true, Escape = true }

local machine = RunMachine.new(os.clock())
local current: Run? = nil
local global = StateServer.global("global")
local healthConfig = HealthModel.configFrom(GameConfig)
local resultsAcks: { [number]: string } = {}
local resultsStartedAt = 0
local stepErrors: { [string]: number } = {}

local function serverNow(): number
	return workspace:GetServerTimeNow()
end
ExpeditionService.serverNow = serverNow

function ExpeditionService.current(): Run?
	return current
end

function ExpeditionService.phase(): string
	return machine.phase
end

function ExpeditionService.isActivePhase(): boolean
	return ACTIVE_PHASES[machine.phase] == true
end

function ExpeditionService.entry(player: Player): RosterEntry?
	local run = current
	if not run then
		return nil
	end
	local entry = run.roster[player.UserId]
	if entry and entry.player == player and entry.connected and not entry.left then
		return entry
	end
	return nil
end

-- Roster entries still taking part (connected and not left).
function ExpeditionService.participants(run: Run): { RosterEntry }
	local out = {}
	for _, userId in run.order do
		local entry = run.roster[userId]
		if entry and entry.connected and not entry.left then
			table.insert(out, entry)
		end
	end
	return out
end

local function publishPhase(outcome: string?)
	global:Set({ "run", "phase" }, machine.phase)
	global:Set({ "run", "phaseStartedAt" }, serverNow())
	if outcome then
		global:Set({ "run", "outcome" }, outcome)
	end
	StateServer.flushAll()
end

function ExpeditionService.publishRosterEntry(run: Run, entry: RosterEntry)
	local h = entry.health
	local status: string = h.status
	if entry.left then
		status = "Left"
	elseif not entry.connected then
		status = "Disconnected"
	end
	local deployed = {}
	for slot, socketId in entry.deployed do
		deployed[tostring(slot)] = socketId
	end
	global:Set({ "roster", entry.key }, {
		name = entry.name,
		display = entry.display,
		status = status,
		hearts = h.hearts,
		max = h.max,
		downedEndsAt = if h.status == "Downed" then serverNow() + math.max(0, h.downedUntil - os.clock()) else nil,
		recoverEndsAt = if h.status == "Recovering" then serverNow() + math.max(0, h.recoverAt - os.clock()) else nil,
		selfRecoveries = h.selfRecoveriesLeft,
		loadout = table.clone(entry.loadout),
		deployed = deployed,
		carrying = Registry.get("Cargo").carrierOf(run) == entry.userId,
		order = table.find(run.order, entry.userId) or 0,
	})
end

local function setLevelElevatorDoors(run: Run, open: boolean)
	for _, d in run.model:GetDescendants() do
		if d:IsA("BasePart") and d:GetAttribute("Elevator") then
			d:SetAttribute("Open", open)
			d.CanCollide = not open
		end
	end
end
ExpeditionService.setLevelElevatorDoors = setLevelElevatorDoors

local function systemCall(name: string, method: string, ...: any)
	local system = Registry.get(name)
	local fn = system[method]
	if type(fn) ~= "function" then
		return
	end
	local ok, problem = pcall(fn, ...)
	if not ok then
		local key = name .. "." .. method
		stepErrors[key] = (stepErrors[key] or 0) + 1
		if stepErrors[key] <= 3 then
			warn(string.format("[Expedition] %s failed: %s", key, tostring(problem)))
		end
	end
end

-- Launch ------------------------------------------------------------------------------------------------

local function newEntry(player: Player, profile: any, solo: boolean): RosterEntry
	local skins = Tables.deepCopy(profile.skins.equipped)
	return {
		userId = player.UserId,
		key = tostring(player.UserId),
		player = player,
		name = player.Name,
		display = player.DisplayName,
		connected = true,
		left = false,
		loadout = table.clone(profile.loadout),
		skins = skins,
		suitcase = skins.suitcase or SkinDefs.defaultSuitcase,
		deployed = {},
		cooldownUntil = 0,
		health = HealthModel.new(healthConfig, solo, os.clock()),
		lastSafe = nil,
		device = Registry.get("Session").deviceOf(player),
		rewardChoice = nil,
		selectedSlot = 0,
		damageTaken = 0,
	}
end

function ExpeditionService.launch(players: { Player }, missionId: string): boolean
	if machine.phase ~= "Prep" then
		return false
	end
	local mission = MissionDefs.get(missionId)
	if not mission then
		return false
	end
	local layout = Layouts[mission.layoutId]
	if not layout then
		log:Warn("mission", missionId, "has no layout", mission.layoutId)
		return false
	end
	local Profiles = Registry.get("Profiles")
	local valid = {}
	for _, player in players do
		if player.Parent == Players and Profiles.isReady(player) and #(Profiles.get(player) :: any).loadout == 2 then
			table.insert(valid, player)
		end
	end
	if #valid == 0 then
		return false
	end
	table.sort(valid, function(a, b)
		return Registry.get("Session").joinOrder(a) < Registry.get("Session").joinOrder(b)
	end)
	if not machine:transition("Launching", os.clock()) then
		return false
	end

	local built = LevelBuilder.build(layout)
	if #built.runtime.errors > 0 then
		log:Warn("layout", layout.id, "has validation errors:", table.concat(built.runtime.errors, "; "))
	end
	local folder = workspace:FindFirstChild("Expedition")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Expedition"
		folder.Parent = workspace
	end
	built.model.Parent = folder

	local solo = #valid == 1
	local run: Run = {
		id = HttpService:GenerateGUID(false),
		mission = mission,
		layout = layout,
		tutorial = mission.tutorial,
		solo = solo,
		roster = {},
		order = {},
		model = built.model,
		runtime = built.runtime,
		effect = EffectModel.new(built.runtime.effectDefs, GameConfig.Effects, os.clock()),
		trove = Trove.new(),
		startedAt = os.clock(),
		exploreStartedAt = os.clock(),
		captured = false,
		captureAt = nil,
		escapeEndsAt = nil,
		stats = {
			deploys = 0,
			recalls = 0,
			combos = {},
			comboOrder = {},
			keys = {},
			anyDowns = false,
			firstDeployAt = nil,
			roomsUsed = {},
		},
		ended = false,
		outcome = nil,
		scratch = {},
	}
	run.trove:Add(built.model)
	for _, player in valid do
		local profile = Profiles.get(player)
		local entry = newEntry(player, profile, solo)
		entry.rewardChoice = (profile :: any).rewardChoice[mission.id]
		run.roster[player.UserId] = entry
		table.insert(run.order, player.UserId)
	end
	current = run
	table.clear(resultsAcks)

	global:Set({ "run" }, {
		phase = machine.phase,
		phaseStartedAt = serverNow(),
		id = run.id,
		mission = mission.id,
		layout = layout.id,
		solo = solo,
		tutorial = mission.tutorial,
		rosterSize = #run.order,
		escapeEndsAt = nil,
		outcome = nil,
	})
	global:Set({ "roster" }, {})
	global:Set({ "level" }, LevelBuilder.clientInfo(built.runtime))
	for _, entry in run.roster do
		ExpeditionService.publishRosterEntry(run, entry)
	end

	for _, name in SYSTEMS do
		systemCall(name, "startRun", run)
	end
	Registry.get("Lobby").setElevatorDoors(false)
	Registry.get("Session").onLaunch(run)
	Registry.get("Telemetry").runStarted(run)
	StateServer.flushAll()
	log:Info("launch", run.id, mission.id, "players:", #valid)

	task.delay(GameConfig.Squad.ElevatorRideSeconds, function()
		if current == run and ExpeditionService.phase() == "Launching" then
			ExpeditionService.beginExplore(run)
		end
	end)
	return true
end

function ExpeditionService.beginExplore(run: Run)
	local Characters = Registry.get("Characters")
	for i, userId in run.order do
		local entry = run.roster[userId]
		if entry.connected then
			local spawn = run.runtime.spawns[((i - 1) % #run.runtime.spawns) + 1]
			entry.lastSafe = spawn
			Characters.teleport(entry.player, spawn)
		end
	end
	if not machine:transition("Explore", os.clock()) then
		return
	end
	run.exploreStartedAt = os.clock()
	publishPhase()
	Registry.get("Lobby").setElevatorDoors(true)
	task.delay(1.1, function()
		if current == run and not run.ended then
			setLevelElevatorDoors(run, true)
		end
	end)
	systemCall("Caretaker", "onExplore", run)
	Registry.get("Telemetry").exploreStarted(run)
	if #ExpeditionService.participants(run) == 0 then
		ExpeditionService.finish(run, "Abandoned")
	end
end

-- Capture & escape -------------------------------------------------------------------------------------

function ExpeditionService.onCaptured(run: Run, entry: RosterEntry)
	if current ~= run or machine.phase ~= "Explore" then
		return
	end
	machine:transition("Capture", os.clock())
	run.captured = true
	run.captureAt = os.clock()
	publishPhase()
	Registry.get("Telemetry").captured(run, entry)
	systemCall("Caretaker", "wake", run)
	task.delay(GameConfig.Capture.FoldCinematicSeconds, function()
		if current == run and ExpeditionService.phase() == "Capture" and not run.ended then
			machine:transition("Escape", os.clock())
			run.escapeEndsAt = serverNow() + GameConfig.Escape.WindowSeconds
			global:Set({ "run", "escapeEndsAt" }, run.escapeEndsAt)
			publishPhase()
			systemCall("Caretaker", "hunt", run)
		end
	end)
end

-- Results ------------------------------------------------------------------------------------------------

local function buildSummary(run: Run, outcome: string): any
	local keysCollected = 0
	for _ in run.stats.keys do
		keysCollected += 1
	end
	local keysTotal = 0
	for _ in run.runtime.keys do
		keysTotal += 1
	end
	return {
		runId = run.id,
		missionId = run.mission.id,
		success = outcome == "Success",
		outcome = outcome,
		timeLeft = if run.escapeEndsAt then math.max(0, run.escapeEndsAt - serverNow()) else 0,
		keysCollected = keysCollected,
		keysTotal = keysTotal,
		anyDowns = run.stats.anyDowns,
		combos = table.clone(run.stats.combos),
		durationSeconds = os.clock() - run.exploreStartedAt,
	}
end

local function teardown(run: Run)
	for i = #SYSTEMS, 1, -1 do
		systemCall(SYSTEMS[i], "endRun", run)
	end
	run.trove:Clean()
	if current == run then
		current = nil
	end
	for _, key in { "sockets", "zones", "levers", "plates", "keys", "carts", "crates", "rooms" } do
		global:Set({ key }, {})
	end
	global:Set({ "cargo" }, { state = "None" })
	global:Set({ "caretaker" }, { mode = "Gone" })
	global:Delete({ "level" })
	StateServer.flushAll()
end

local function returnToLobby(run: Run)
	local Lobby = Registry.get("Lobby")
	local Characters = Registry.get("Characters")
	for i, userId in run.order do
		local entry = run.roster[userId]
		if entry.connected and not entry.left and entry.player.Parent == Players then
			Characters.teleport(entry.player, Lobby.arrivalFor(i))
		end
	end
end

function ExpeditionService.finish(run: Run, outcome: string)
	if run.ended or current ~= run then
		return
	end
	run.ended = true
	run.outcome = outcome
	if not machine:transition("Results", os.clock(), outcome :: any) then
		-- Launching aborted before Explore: Launching -> Results is allowed; anything else is a bug.
		log:Warn("could not enter Results from", machine.phase)
	end
	if outcome == "Success" then
		setLevelElevatorDoors(run, false)
	end
	publishPhase(outcome)
	resultsStartedAt = os.clock()
	table.clear(resultsAcks)
	local summary = buildSummary(run, outcome)
	Registry.get("Telemetry").runEnded(run, summary)
	task.spawn(function()
		Registry.get("Rewards").grant(run, summary)
	end)
	task.delay(if outcome == "Success" then 2.6 else 2.2, function()
		returnToLobby(run)
		teardown(run)
	end)
	log:Info("finish", run.id, outcome)
end

local function toPrep()
	if machine.phase ~= "Results" then
		return
	end
	machine:transition("Prep", os.clock())
	global:Set({ "run" }, { phase = "Prep", phaseStartedAt = serverNow() })
	global:Set({ "roster" }, {})
	Registry.get("Lobby").setElevatorDoors(true)
	Registry.get("Session").onPrep(resultsAcks)
	table.clear(resultsAcks)
	StateServer.flushAll()
end

function ExpeditionService.resultsAction(player: Player, action: string)
	if machine.phase ~= "Results" then
		if machine.phase == "Prep" and action == "replay" then
			Registry.get("Session").setReady(player, true)
		end
		return
	end
	if action ~= "replay" and action ~= "lobby" then
		return
	end
	resultsAcks[player.UserId] = action
	if action == "replay" then
		Registry.get("Session").markReplay(player)
	end
end

-- True once every roster member still in the server has chosen Replay or Lobby on the results panel.
local function allAcked(): boolean
	local roster = global:Get({ "roster" }) or {}
	for key, info in roster do
		local userId = tonumber(key)
		local plr = if userId then Players:GetPlayerByUserId(userId) else nil
		if plr and info.status ~= "Left" and resultsAcks[userId :: number] == nil then
			return false
		end
	end
	return true
end

-- Leaving & disconnects --------------------------------------------------------------------------------

local function detach(run: Run, entry: RosterEntry, reason: string)
	systemCall("Interaction", "onPlayerLeft", run, entry)
	systemCall("Cargo", "onPlayerLeft", run, entry)
	systemCall("Rooms", "onPlayerLeft", run, entry)
	systemCall("Health", "onPlayerLeft", run, entry)
	ExpeditionService.publishRosterEntry(run, entry)
	Registry.get("Telemetry").playerLeftRun(run, entry, reason)
end

function ExpeditionService.leave(player: Player)
	local run = current
	if not run or run.ended then
		return
	end
	local entry = run.roster[player.UserId]
	if not entry or entry.left or not entry.connected then
		return
	end
	entry.left = true
	detach(run, entry, "left")
	Registry.get("Characters").teleport(player, Registry.get("Lobby").spawnFor(1))
	Registry.get("Profiles").update(player, function(profile: any)
		profile.stats.runs += 1
		profile.stats.failures += 1
	end)
	Net.fire(player, "Toast", "warn", "toast.leftRun", {})
end

local function onPlayerRemoving(player: Player)
	local run = current
	if not run or run.ended then
		return
	end
	local entry = run.roster[player.UserId]
	if not entry or not entry.connected then
		return
	end
	entry.connected = false
	if not entry.left then
		Registry.get("Profiles").update(player, function(profile: any)
			profile.flags.interruptedRunId = run.id
			profile.stats.runs += 1
			profile.stats.failures += 1
		end)
	end
	detach(run, entry, "disconnect")
end

-- Characters ----------------------------------------------------------------------------------------------

function ExpeditionService.onCharacterSpawned(player: Player, _character: Model)
	local run = current
	if not run or run.ended then
		return
	end
	local entry = run.roster[player.UserId]
	if not entry or not entry.connected or entry.left then
		return
	end
	if machine.phase == "Launching" then
		return
	end
	local target = entry.lastSafe or run.runtime.spawns[1]
	Registry.get("Characters").teleport(player, target)
	systemCall("Health", "onCharacterSpawned", run, entry)
	systemCall("Cargo", "onCharacterSpawned", run, entry)
end

local unstuckAt: { [Player]: number } = {}
function ExpeditionService.unstuck(player: Player)
	local now = os.clock()
	if (unstuckAt[player] or 0) > now then
		return
	end
	unstuckAt[player] = now + 8
	local run = current
	local entry = ExpeditionService.entry(player)
	if run and entry and ACTIVE_PHASES[machine.phase] then
		if entry.health.status ~= "Active" then
			return
		end
		Registry.get("Health").damage(run, entry, 1, "unstuck", nil)
		Registry.get("Characters").teleport(player, entry.lastSafe or run.runtime.spawns[1])
	else
		Registry.get("Characters").teleport(player, Registry.get("Lobby").spawnFor(1))
	end
end

-- Debug hooks (S28) -----------------------------------------------------------------------------------

function ExpeditionService.debugForce(target: string): string
	local run = current
	if target == "results" or target == "fail" then
		if run then
			ExpeditionService.finish(run, "Wiped")
			return "forced failure"
		end
	elseif target == "win" then
		if run then
			ExpeditionService.finish(run, "Success")
			return "forced success"
		end
	elseif target == "capture" or target == "escape" then
		if run and machine.phase == "Explore" then
			local first = ExpeditionService.participants(run)[1]
			if first then
				Registry.get("Capture").complete(run, first)
				return "forced capture"
			end
		end
	elseif target == "prep" then
		if run then
			ExpeditionService.finish(run, "Abandoned")
		end
		task.delay(3, toPrep)
		return "returning to prep"
	end
	return "cannot force " .. target .. " from " .. machine.phase
end

function ExpeditionService.debugSetEscapeTime(seconds: number)
	local run = current
	if run and run.escapeEndsAt then
		run.escapeEndsAt = serverNow() + seconds
		global:Set({ "run", "escapeEndsAt" }, run.escapeEndsAt)
	end
end

-- Lifecycle -------------------------------------------------------------------------------------------------

local function step(dt: number)
	local run = current
	if not run or run.ended then
		if machine.phase == "Results" and current == nil then
			if allAcked() or os.clock() - resultsStartedAt > GameConfig.Squad.ResultsTimeoutSeconds then
				toPrep()
			end
		end
		return
	end
	if not ACTIVE_PHASES[machine.phase] then
		return
	end
	for _, name in SYSTEMS do
		systemCall(name, "step", run, dt)
		if run.ended then
			return
		end
	end
	-- End conditions.
	if #ExpeditionService.participants(run) == 0 then
		ExpeditionService.finish(run, "Abandoned")
		return
	end
	if Registry.get("Health").isWiped(run) then
		ExpeditionService.finish(run, "Wiped")
		return
	end
	if machine.phase == "Escape" then
		if Registry.get("Cargo").isBanked(run) then
			ExpeditionService.finish(run, "Success")
		elseif run.escapeEndsAt and serverNow() >= run.escapeEndsAt then
			ExpeditionService.finish(run, "TimeUp")
		end
	end
end

function ExpeditionService.Init()
	Registry.add("Expedition", ExpeditionService)
	global:Set({ "run" }, { phase = "Prep", phaseStartedAt = 0 })
	global:Set({ "roster" }, {})
	global:Set({ "cargo" }, { state = "None" })
	global:Set({ "caretaker" }, { mode = "Gone" })
	for _, key in { "sockets", "zones", "levers", "plates", "keys", "carts", "crates", "rooms" } do
		global:Set({ key }, {})
	end
end

function ExpeditionService.Start()
	RunService.Heartbeat:Connect(step)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	Players.PlayerRemoving:Connect(function(player)
		unstuckAt[player] = nil
		if machine.phase == "Results" then
			resultsAcks[player.UserId] = "left"
		end
	end)
	Net.on("LeaveRun", ExpeditionService.leave)
	Net.on("ResultsAction", ExpeditionService.resultsAction)
end

return ExpeditionService
