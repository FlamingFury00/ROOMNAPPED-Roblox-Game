--!strict
--[[
	RewardRules: what an extraction is worth and how it is granted exactly once (S14, S22, S23, R12).

	Priority for the main reward of a successful extraction (shown to the player before starting):
	  1. the captured room's blueprint, if the player does not own it yet
	  2. otherwise the reward skin the player targeted for this mission, if not owned
	  3. otherwise a fixed cosmetic credit amount (duplicate blueprint)
	Every success also pays extraction credits, key credits, a first-clear bonus and challenge bonuses.

	Idempotency: apply() records the run id in the profile's bounded grant ledger in the same write as the
	reward itself, so retried saves, duplicate calls and reconnects can never award twice.
]]

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
}

export type RewardLine = { key: string, amount: number?, item: string? }

export type RewardPlan = {
	blueprint: string?,
	skin: string?,
	credits: number,
	duplicate: boolean,
	firstClear: boolean,
	challenges: { [string]: boolean },
	lines: { RewardLine },
}

export type Preview = { kind: "blueprint" | "skin" | "credits", item: string?, credits: number }

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
	challenges: { { id: string, kind: string, value: number?, combo: string?, credits: number } },
}

type RewardConfig = {
	ExtractionCredits: number,
	DuplicateBlueprintCredits: number,
	DuplicateSkinCredits: number,
	KeyCredits: number,
	FirstClearBonusCredits: number,
}

local RewardRules = {}

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
		credits = config.ExtractionCredits + config.DuplicateBlueprintCredits,
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
		firstClear = false,
		challenges = {},
		lines = {},
	}
	local preview = RewardRules.preview(profile, mission, config)
	if preview.kind == "blueprint" then
		plan.blueprint = preview.item
		table.insert(plan.lines, { key = "reward.blueprint", item = preview.item })
	elseif preview.kind == "skin" then
		plan.skin = preview.item
		table.insert(plan.lines, { key = "reward.skin", item = preview.item })
	else
		plan.duplicate = true
		plan.credits += config.DuplicateBlueprintCredits
		table.insert(
			plan.lines,
			{ key = "reward.duplicate", amount = config.DuplicateBlueprintCredits, item = mission.targetRoom }
		)
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

-- Apply a plan to a profile exactly once. Returns false (and changes nothing) for a repeated run id.
function RewardRules.apply(
	profile: ProfileLike,
	plan: RewardPlan,
	summary: RunSummary,
	now: number,
	maxHistory: number
): boolean
	if RewardRules.hasGrant(profile, summary.runId) then
		return false
	end
	if plan.blueprint then
		profile.rooms[plan.blueprint :: string] = true
	end
	if plan.skin then
		profile.skins.owned[plan.skin :: string] = true
	end
	profile.credits += plan.credits
	profile.stats.extractions += 1
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
	local list = profile.grants.list
	table.insert(list, { id = summary.runId, at = now })
	while #list > maxHistory do
		table.remove(list, 1)
	end
	return true
end

return RewardRules
