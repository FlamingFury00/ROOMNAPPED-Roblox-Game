--!strict
--[[
	InteractionService: server authority for the single context action (S04, S12, S20, U06).

	Hold actions (capture, revive) are verified on the server: a HoldBegin must be valid (phase, roster,
	state, range and line of sight), the player must stay valid and in range for the whole hold (checked
	every frame - walking away cancels), and HoldEnd(completed) is only honoured once the nominal duration has
	actually elapsed on the server (minus a small latency tolerance). When the client's timer fills first (its
	HoldBegin reached the server late), the hold finishes on the server's clock instead, as long as the player
	stays valid until then. Instant actions (cargo pickup, levers)
	are range and line-of-sight checked. Spoofed or stale requests are rejected without breaking the run.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.Config.GameConfig)
local Net = require(Shared.Net.Net)
local Registry = require(script.Parent.Parent.Core.Registry)
local RunTypes = require(script.Parent.Parent.Core.RunTypes)

type Run = RunTypes.Run
type RosterEntry = RunTypes.RosterEntry

type Hold = {
	kind: string,
	target: string,
	startedAt: number,
	duration: number,
	finishing: boolean, -- the client's timer filled; complete once the server's does
}

local InteractionService = {}

local I = GameConfig.Interaction
local holds: { [Player]: Hold } = {}

local losParams = RaycastParams.new()
losParams.FilterType = Enum.RaycastFilterType.Exclude

local function hasLineOfSight(from: Vector3, to: Vector3, ignore: { Instance }): boolean
	local filter = table.clone(ignore)
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(filter, player.Character)
		end
	end
	losParams.FilterDescendantsInstances = filter
	local direction = to - from
	local length = direction.Magnitude
	if length < 0.2 then
		return true
	end
	local hit = workspace:Raycast(from, direction.Unit * math.max(0, length - I.LineOfSightSlack), losParams)
	return hit == nil
end

local function targetPoint(run: Run, kind: string, targetId: string): (Vector3?, number?)
	if kind == "capture" then
		return run.runtime.target.capturePoint, GameConfig.Capture.Range
	elseif kind == "revive" then
		local userId = tonumber(targetId)
		local target = if userId then run.roster[userId] else nil
		if target and target.connected and not target.left then
			return Registry.get("Characters").position(target.player), GameConfig.Revive.Range
		end
	elseif kind == "cargo" then
		return Registry.get("Cargo").droppedPosition(run), I.CargoPickupRange
	elseif kind == "lever" then
		return Registry.get("Effects").leverPosition(run, targetId), I.LeverRange
	end
	return nil, nil
end

-- Validates that `entry` may act on the target right now. Returns ok + reason.
local function validate(run: Run, entry: RosterEntry, kind: string, targetId: string): (boolean, string?)
	if run.ended then
		return false, "ended"
	end
	if entry.health.status ~= "Active" then
		return false, "notActive"
	end
	local Expedition = Registry.get("Expedition")
	if not Expedition.isActivePhase() then
		return false, "phase"
	end
	if kind == "capture" then
		if not Registry.get("Capture").canCapture(run, entry) then
			return false, "capture"
		end
	elseif kind == "revive" then
		local userId = tonumber(targetId)
		local target = if userId then run.roster[userId] else nil
		if not target or target == entry or not Registry.get("Health").canRevive(run, target) then
			return false, "revive"
		end
	elseif kind == "cargo" then
		if Registry.get("Cargo").state(run) ~= "Dropped" then
			return false, "cargo"
		end
	elseif kind == "lever" then
		if run.runtime.levers[targetId] == nil then
			return false, "lever"
		end
	else
		return false, "kind"
	end
	local point, range = targetPoint(run, kind, targetId)
	local Characters = Registry.get("Characters")
	local position = Characters.position(entry.player)
	if not point or not range or not position then
		return false, "missing"
	end
	if (position - point).Magnitude > range + I.RangeTolerance then
		return false, "range"
	end
	local eye = Characters.eye(entry.player) or position
	local ignore: { Instance } = {}
	local cargoModel = run.model:FindFirstChild("CargoSuitcase")
	if cargoModel then
		table.insert(ignore, cargoModel)
	end
	local interact = run.model:FindFirstChild("Interact")
	if interact then
		table.insert(ignore, interact)
	end
	if not hasLineOfSight(eye, point, ignore) then
		return false, "sight"
	end
	return true, nil
end

local function durationFor(kind: string): number
	if kind == "capture" then
		return GameConfig.Capture.HoldSeconds
	elseif kind == "revive" then
		return GameConfig.Revive.HoldSeconds
	end
	return 0
end

local function execute(run: Run, entry: RosterEntry, kind: string, targetId: string)
	if kind == "capture" then
		Registry.get("Capture").complete(run, entry)
	elseif kind == "revive" then
		local userId = tonumber(targetId)
		local target = if userId then run.roster[userId] else nil
		if target then
			Registry.get("Health").revive(run, target, entry)
		end
	elseif kind == "cargo" then
		Registry.get("Cargo").pickup(run, entry)
	elseif kind == "lever" then
		Registry.get("Effects").toggleLever(run, entry, targetId)
	end
end

function InteractionService.cancelFor(player: Player)
	local hold = holds[player]
	if hold then
		holds[player] = nil
		if player.Parent == Players then
			Net.fire(player, "Effect", "holdCancelled", { kind = hold.kind })
		end
		Registry.get("Expedition").fireRun("holdStop", { userId = tostring(player.UserId), kind = hold.kind })
	end
end

local function onHoldBegin(player: Player, kind: string, targetId: string)
	local Expedition = Registry.get("Expedition")
	local run = Expedition.current()
	local entry = Expedition.entry(player)
	if not run or not entry then
		return
	end
	if durationFor(kind) <= 0 then
		return
	end
	local ok, reason = validate(run, entry, kind, targetId)
	if not ok then
		Net.fire(player, "Effect", "holdRejected", { kind = kind, reason = reason })
		return
	end
	holds[player] = {
		kind = kind,
		target = targetId,
		startedAt = os.clock(),
		duration = durationFor(kind),
		finishing = false,
	}
	Registry.get("Expedition").fireRun("holdStart", { userId = entry.key, kind = kind, target = targetId })
	if kind == "capture" then
		Registry.get("Caretaker").noise(run, run.runtime.target.capturePoint, 30)
	end
end

-- End a hold whose time is up: validate once more and act.
local function finish(player: Player, hold: Hold)
	holds[player] = nil
	Registry.get("Expedition").fireRun("holdStop", { userId = tostring(player.UserId), kind = hold.kind })
	local Expedition = Registry.get("Expedition")
	local run = Expedition.current()
	local entry = Expedition.entry(player)
	if not run or not entry then
		return
	end
	local ok, reason = validate(run, entry, hold.kind, hold.target)
	if not ok then
		Net.fire(player, "Effect", "holdRejected", { kind = hold.kind, reason = reason })
		return
	end
	execute(run, entry, hold.kind, hold.target)
end

local function onHoldEnd(player: Player, kind: string, targetId: string, completed: boolean)
	local hold = holds[player]
	if not hold or hold.kind ~= kind or hold.target ~= targetId then
		return
	end
	if not completed then
		holds[player] = nil
		Registry.get("Expedition").fireRun("holdStop", { userId = tostring(player.UserId), kind = kind })
		return
	end
	local elapsed = os.clock() - hold.startedAt
	if elapsed > hold.duration + I.MaxHoldDriftSeconds then
		holds[player] = nil
		Registry.get("Expedition").fireRun("holdStop", { userId = tostring(player.UserId), kind = kind })
		Net.fire(player, "Effect", "holdRejected", { kind = kind, reason = "timing" })
		return
	end
	if elapsed < hold.duration - I.HoldToleranceSeconds then
		-- The client's timer filled first (network jitter delayed its HoldBegin): finish on the server's clock,
		-- still checking every frame that the player stays in range (see step).
		hold.finishing = true
		return
	end
	finish(player, hold)
end

local function onInteract(player: Player, kind: string, targetId: string)
	if kind ~= "cargo" and kind ~= "lever" then
		return
	end
	local Expedition = Registry.get("Expedition")
	local run = Expedition.current()
	local entry = Expedition.entry(player)
	if not run or not entry then
		return
	end
	local ok, reason = validate(run, entry, kind, targetId)
	if not ok then
		Net.fire(player, "Effect", "interactRejected", { kind = kind, reason = reason })
		return
	end
	execute(run, entry, kind, targetId)
end

function InteractionService.startRun(_run: Run)
	table.clear(holds)
end

function InteractionService.step(run: Run, _dt: number)
	local now = os.clock()
	local due: { [Player]: Hold } = {}
	for player, hold in holds do
		local entry = Registry.get("Expedition").entry(player)
		if not entry then
			InteractionService.cancelFor(player)
		else
			local ok = validate(run, entry, hold.kind, hold.target)
			if not ok or now - hold.startedAt > hold.duration + I.MaxHoldDriftSeconds then
				InteractionService.cancelFor(player)
			elseif hold.finishing and now - hold.startedAt >= hold.duration - I.HoldToleranceSeconds then
				due[player] = hold
			end
		end
	end
	-- Acting can end the run or change phase, so it happens after the sweep.
	for player, hold in due do
		if holds[player] == hold then
			finish(player, hold)
		end
	end
end

function InteractionService.onPlayerLeft(_run: Run, entry: RosterEntry)
	holds[entry.player] = nil
end

function InteractionService.endRun(_run: Run)
	for player in holds do
		InteractionService.cancelFor(player)
	end
	table.clear(holds)
end

function InteractionService.Init()
	Registry.add("Interaction", InteractionService)
end

function InteractionService.Start()
	Net.on("HoldBegin", onHoldBegin)
	Net.on("HoldEnd", onHoldEnd)
	Net.on("Interact", onInteract)
	Players.PlayerRemoving:Connect(function(player)
		holds[player] = nil
	end)
end

return InteractionService
