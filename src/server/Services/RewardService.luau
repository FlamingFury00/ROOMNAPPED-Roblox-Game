--!strict
--[[
	RewardService: durable, exactly-once rewards (S14, S22, S23, R12, U18).

	On a successful extraction every connected member of the starting roster receives their own reward plan
	(blueprint > targeted skin > duplicate credits, plus extraction/key/first-clear/challenge credits). The
	grant and the run id are written to the profile in one save, so retries, duplicate calls and reconnects
	can never pay twice. The results panel shows "Saving..." until the DataStore confirms the write and never
	shows "Saved" for a write that failed. Failed runs only record statistics - they never imply a reward.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.Config.GameConfig)
local RewardRules = require(Shared.Logic.RewardRules)
local Tables = require(Shared.Util.Tables)
local Net = require(Shared.Net.Net)
local Registry = require(script.Parent.Parent.Core.Registry)
local StateServer = require(script.Parent.Parent.Core.StateServer)
local RunTypes = require(script.Parent.Parent.Core.RunTypes)

type Run = RunTypes.Run
type RosterEntry = RunTypes.RosterEntry

local RewardService = {}

-- Background retries after a failed reward save: one every RETRY_SECONDS (plus the store's own backoff), for
-- about fifteen minutes.
local RETRY_SECONDS = 30
local RETRY_ATTEMPTS = 20

-- The run whose results each player is looking at (a newer run's results replace the panel).
local shownRun: { [Player]: string } = {}

local function bestCombo(run: Run): string?
	-- Prefer the most "inventive" combo used this run for the results panel (U18).
	local priority = {
		"ice_launch",
		"vine_bridge",
		"crate_bridge",
		"extinguish",
		"frozen_safe",
		"cart_pin",
		"caretaker_blown",
		"cart_freeze",
		"power_off",
		"crate_plate",
		"ice_bridge",
	}
	for _, id in priority do
		if run.stats.combos[id] then
			return id
		end
	end
	return nil
end

local function publishResults(player: Player, payload: any)
	if player.Parent == Players then
		shownRun[player] = payload.runId
		StateServer.private(player):Set({ "results" }, payload)
	end
end

local function grantFor(run: Run, entry: RosterEntry, summary: any)
	local player = entry.player
	local Profiles = Registry.get("Profiles")
	local profile = Profiles.get(player)
	local payload: any = {
		runId = run.id,
		mission = run.mission.id,
		outcome = summary.outcome,
		success = summary.success,
		duration = math.floor(summary.durationSeconds + 0.5),
		timeLeft = math.floor(summary.timeLeft + 0.5),
		keys = summary.keysCollected,
		keysTotal = summary.keysTotal,
		combo = bestCombo(run),
		combos = Tables.deepCopy(run.stats.comboOrder),
		deploys = run.stats.deploys,
		plan = nil,
		saving = "Idle",
		tutorial = run.tutorial,
		-- After someone's first Check-In the lobby moves on (the results button says NEXT MISSION).
		next = Registry.get("Expedition").lobbyMovesOn(),
		-- What knocked the squad out, so a wipe names its cause.
		cause = if summary.success then nil else run.stats.lastKnockout,
	}
	if not profile then
		payload.saving = "Error"
		publishResults(player, payload)
		return
	end
	if not summary.success then
		Profiles.update(player, function(p: any)
			p.stats.runs += 1
			p.stats.failures += 1
		end)
		publishResults(player, payload)
		return
	end
	local plan = RewardRules.compute(profile :: any, run.mission :: any, summary, GameConfig.Rewards)
	if not plan then
		publishResults(player, payload)
		return
	end
	payload.plan = Tables.deepCopy(plan)
	payload.saving = "Saving"
	-- Beat this player's own record on the mission (first clears are celebrated by their reward line).
	-- Best times are stored in whole seconds: compare like with like, so "New best" never repeats the record.
	local previousBest = (profile :: any).stats.bestTimes[run.mission.id]
	if
		not plan.unranked
		and type(previousBest) == "number"
		and math.floor(summary.durationSeconds + 0.5) < previousBest
	then
		payload.newBest = true
	end
	publishResults(player, payload)
	local applied = false
	local mastery: { string } = {}
	Profiles.update(player, function(p: any)
		applied, mastery = RewardRules.apply(p :: any, plan, summary, os.time(), GameConfig.Data.MaxGrantHistory)
		if applied then
			p.stats.runs += 1
			if run.tutorial and not plan.unranked then
				p.tutorialDone = true
			end
		end
	end)
	if not applied then
		-- Already granted earlier (duplicate call): show the plan as already saved.
		payload.saving = "Saved"
		payload.duplicate = true
		publishResults(player, payload)
		return
	end
	if plan.credits > 0 then
		Registry.get("Telemetry").creditsEarned(player, plan.credits, (Profiles.get(player) :: any).credits)
	end
	Net.fire(
		player,
		"Effect",
		"reward",
		{ blueprint = plan.blueprint, skin = plan.skin, credits = plan.credits, mastery = mastery }
	)
	-- Save with retries; the client keeps showing "Saving..." until this resolves.
	local saved = false
	for attempt = 1, 3 do
		if player.Parent ~= Players then
			break
		end
		if Profiles.saveNow(player) then
			saved = true
			break
		end
		task.wait(2 * attempt)
	end
	payload.saving = if saved then "Saved" else "Error"
	publishResults(player, payload)
	if saved or player.Parent ~= Players then
		return
	end
	Net.fire(player, "Toast", "error", "toast.saveFailed", {})
	-- Keep the panel's promise ("retrying automatically"): retry in the background until a write lands, then
	-- confirm. Saves write the whole profile, so any later successful save (autosave, a newer run) carries
	-- this reward too and ends the retries.
	for _ = 1, RETRY_ATTEMPTS do
		task.wait(RETRY_SECONDS)
		if player.Parent ~= Players then
			return
		end
		if not Profiles.hasUnsavedChanges(player) or Profiles.saveNow(player) then
			if shownRun[player] == payload.runId then
				payload.saving = "Saved"
				publishResults(player, payload)
			end
			Net.fire(player, "Toast", "success", "toast.saveRecovered", {})
			return
		end
	end
end

function RewardService.grant(run: Run, summary: any)
	for _, userId in run.order do
		local entry = run.roster[userId]
		if entry and entry.connected and not entry.left and entry.player.Parent == Players then
			task.spawn(grantFor, run, entry, summary)
		end
	end
end

function RewardService.Init()
	Registry.add("Rewards", RewardService)
end

function RewardService.Start()
	Players.PlayerRemoving:Connect(function(player: Player)
		shownRun[player] = nil
	end)
end

return RewardService
