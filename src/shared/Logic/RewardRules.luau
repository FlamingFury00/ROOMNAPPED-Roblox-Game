--!strict
--[[
	RewardRules: what an extraction is worth and how it is granted exactly once (S14, S22, S23, R12).

	Priority for the main reward of a successful extraction (shown to the player before starting):
	  1. the captured room's blueprint, if the player does not own it yet
	  2. otherwise the reward skin the player targeted for this mission, if not owned
	  3. otherwise a cosmetic credit amount (duplicate blueprint) that grows with the mission's difficulty
	Every success also pays extraction credits, key credits, a first-clear bonus and challenge bonuses.

	Replaying Check-In is practice: it pays the extraction credits only (so it never out-earns a real
	mission) and does not count toward mission unlocks. Its challenges and keys still count for mastery.

	Idempotency: apply() records the run id in the profile's bounded grant ledger in the same write as the
	reward itself, so retried saves, duplicate calls and reconnects can never award twice. The same write grants
	any medal suitcase the run's new stars have earned (Logic/Mastery).
]]

local Mastery = require(script.Parent.Mastery)

export type RunSummary = {
	runId: string,
	missionId: string,
	success: boolean,
	timeLeft: number,
	keysCollected: number,
	keysTotal: number,
	anyDowns: boolean,
	combos: { [string]: boolean },
	durationSeconds: number,
	-- False for a success faster than anyone can play the route (a teleporting client): it pays the practice
	-- credits and counts toward nothing else. Missing means plausible.
	plausible: boolean?,
}

export type RewardLine = { key: string, amount: number?, item: string? }

export type RewardPlan = {
	blueprint: string?,
	skin: string?,
	credits: number,
	duplicate: boolean,
	practice: boolean,
	firstClear: boolean,
	challenges: { [string]: boolean },
	lines: { RewardLine },
	unranked: boolean?, -- an implausible run: no stats, records, unlock progress or mastery
}

export type Preview = { kind: "blueprint" | "skin" | "credits" | "practice", item: string?, credits: number }

type ProfileLike = {
	rooms: { [string]: boolean },
	skins: { owned: { [string]: boolean }, equipped: { [string]: string } },
	credits: number,
	stats: {
		cleared: { [string]: number },
		extractions: number,
		captures: number,
		keys: number,
		bestTimes: { [string]: number },
		challengesDone: { [string]: boolean },
		allKeys: { [string]: boolean },
	},
	grants: { list: { { id: string, at: number } } },
	rewardChoice: { [string]: string },
	tutorialDone: boolean,
}

type MissionLike = {
	id: string,
	targetRoom: string,
	rewardSkins: { string },
	tutorial: boolean,
	difficulty: number?,
	challenges: { { id: string, kind: string, value: number?, combo: string?, credits: number } },
}

type RewardConfig = {
	ExtractionCredits: number,
	DuplicateBlueprintCredits: number,
	DuplicateDifficultyCredits: number?,
	DuplicateSkinCredits: number,
	KeyCredits: number,
	FirstClearBonusCredits: number,
}

local RewardRules = {}

-- What a duplicate blueprint pays on this mission: harder missions pay more.
function RewardRules.duplicateCredits(mission: MissionLike, config: RewardConfig): number
	local steps = math.max(0, (mission.difficulty or 1) - 1)
	return config.DuplicateBlueprintCredits + steps * (config.DuplicateDifficultyCredits or 0)
end

-- A cleared Check-In replayed: practice.
function RewardRules.isPractice(profile: ProfileLike, mission: MissionLike): boolean
	return mission.tutorial and (profile.stats.cleared[mission.id] or 0) > 0
end

-- The reward skin a player is targeting for a mission (validated against the mission's list).
function RewardRules.choiceFor(profile: ProfileLike, mission: MissionLike): string?
	local choice = profile.rewardChoice[mission.id]
	if choice and table.find(mission.rewardSkins, choice) then
		return choice
	end
	-- Default to the first reward skin the player does not own yet.
	for _, skinId in mission.rewardSkins do
		if not profile.skins.owned[skinId] then
			return skinId
		end
	end
	return mission.rewardSkins[1]
end

function RewardRules.preview(profile: ProfileLike, mission: MissionLike, config: RewardConfig): Preview
	if RewardRules.isPractice(profile, mission) then
		return { kind = "practice", item = nil, credits = config.ExtractionCredits }
	end
	if not profile.rooms[mission.targetRoom] then
		return { kind = "blueprint", item = mission.targetRoom, credits = config.ExtractionCredits }
	end
	local choice = RewardRules.choiceFor(profile, mission)
	if choice and not profile.skins.owned[choice] then
		return { kind = "skin", item = choice, credits = config.ExtractionCredits }
	end
	return {
		kind = "credits",
		item = nil,
		credits = config.ExtractionCredits + RewardRules.duplicateCredits(mission, config),
	}
end

function RewardRules.challengeMet(
	challenge: { kind: string, value: number?, combo: string? },
	summary: RunSummary
): boolean
	if not summary.success then
		return false
	end
	if challenge.kind == "timeLeft" then
		return summary.timeLeft >= (challenge.value or 0)
	elseif challenge.kind == "noDowns" then
		return not summary.anyDowns
	elseif challenge.kind == "allKeys" then
		return summary.keysTotal > 0 and summary.keysCollected >= summary.keysTotal
	elseif challenge.kind == "combo" then
		return challenge.combo ~= nil and summary.combos[challenge.combo :: string] == true
	end
	return false
end

-- Compute the plan for one player. Returns nil for failed runs (failures never imply a reward).
function RewardRules.compute(
	profile: ProfileLike,
	mission: MissionLike,
	summary: RunSummary,
	config: RewardConfig
): RewardPlan?
	if not summary.success then
		return nil
	end
	local plan: RewardPlan = {
		blueprint = nil,
		skin = nil,
		credits = 0,
		duplicate = false,
		practice = false,
		firstClear = false,
		challenges = {},
		lines = {},
	}
	local preview = RewardRules.preview(profile, mission, config)
	if preview.kind == "practice" or summary.plausible == false then
		plan.practice = true
		plan.credits = config.ExtractionCredits
		table.insert(plan.lines, { key = "reward.practice", amount = config.ExtractionCredits })
		if summary.plausible == false then
			plan.unranked = true
			return plan
		end
		-- Challenges still count toward the mission's stars; they just do not pay again.
		for _, challenge in mission.challenges do
			if RewardRules.challengeMet(challenge, summary) then
				plan.challenges[challenge.id] = true
			end
		end
		return plan
	end
	if preview.kind == "blueprint" then
		plan.blueprint = preview.item
		table.insert(plan.lines, { key = "reward.blueprint", item = preview.item })
	elseif preview.kind == "skin" then
		plan.skin = preview.item
		table.insert(plan.lines, { key = "reward.skin", item = preview.item })
	else
		local duplicate = RewardRules.duplicateCredits(mission, config)
		plan.duplicate = true
		plan.credits += duplicate
		table.insert(plan.lines, { key = "reward.duplicate", amount = duplicate, item = mission.targetRoom })
	end

	plan.credits += config.ExtractionCredits
	table.insert(plan.lines, { key = "reward.extraction", amount = config.ExtractionCredits })

	if summary.keysCollected > 0 then
		local keyCredits = summary.keysCollected * config.KeyCredits
		plan.credits += keyCredits
		table.insert(plan.lines, { key = "reward.keys", amount = keyCredits })
	end

	if (profile.stats.cleared[mission.id] or 0) == 0 then
		plan.firstClear = true
		plan.credits += config.FirstClearBonusCredits
		table.insert(plan.lines, { key = "reward.firstClear", amount = config.FirstClearBonusCredits })
	end

	for _, challenge in mission.challenges do
		if RewardRules.challengeMet(challenge, summary) then
			plan.challenges[challenge.id] = true
			plan.credits += challenge.credits
			table.insert(plan.lines, { key = "reward.challenge", amount = challenge.credits, item = challenge.id })
		end
	end
	return plan
end

function RewardRules.hasGrant(profile: ProfileLike, runId: string): boolean
	for _, entry in profile.grants.list do
		if entry.id == runId then
			return true
		end
	end
	return false
end

-- Apply a plan to a profile exactly once. Returns false (and changes nothing) for a repeated run id; on
-- success also returns the medal suitcases the run's stars just earned.
function RewardRules.apply(
	profile: ProfileLike,
	plan: RewardPlan,
	summary: RunSummary,
	now: number,
	maxHistory: number
): (boolean, { string })
	if RewardRules.hasGrant(profile, summary.runId) then
		return false, {}
	end
	local list = profile.grants.list
	table.insert(list, { id = summary.runId, at = now })
	while #list > maxHistory do
		table.remove(list, 1)
	end
	if plan.unranked then
		profile.credits += plan.credits
		return true, {}
	end
	if plan.blueprint then
		profile.rooms[plan.blueprint :: string] = true
	end
	if plan.skin then
		profile.skins.owned[plan.skin :: string] = true
	end
	profile.credits += plan.credits
	if not plan.practice then
		profile.stats.extractions += 1 -- unlocks count real missions, not Check-In practice
	end
	profile.stats.captures += 1
	profile.stats.keys += summary.keysCollected
	profile.stats.cleared[summary.missionId] = (profile.stats.cleared[summary.missionId] or 0) + 1
	local best = profile.stats.bestTimes[summary.missionId]
	local seconds = math.floor(summary.durationSeconds + 0.5)
	if best == nil or seconds < best then
		profile.stats.bestTimes[summary.missionId] = seconds
	end
	-- Mastery: challenges stay done once done; every key in one extraction earns the keys star.
	for id in plan.challenges do
		profile.stats.challengesDone[id] = true
	end
	if summary.keysTotal > 0 and summary.keysCollected >= summary.keysTotal then
		profile.stats.allKeys[summary.missionId] = true
	end
	return true, Mastery.grant(profile :: any)
end

return RewardRules
