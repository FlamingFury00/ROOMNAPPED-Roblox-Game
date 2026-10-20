--!strict
--[[
	MissionDefs: expeditions offered on the mission board (S23, S31, U17).

	Each mission names the layout it builds, the room that waits at the end (its blueprint is the main
	reward), optional reward skins the player can target, and optional challenges with visible credit
	bonuses. `unlock` gates the mission on progress so the board always shows a clear next goal.
]]

local Tables = require(script.Parent.Parent.Util.Tables)

export type Challenge = {
	id: string,
	kind: "timeLeft" | "noDowns" | "allKeys" | "combo",
	value: number?,
	combo: string?,
	credits: number,
	nameKey: string,
}

export type MissionDef = {
	id: string,
	order: number,
	layoutId: string,
	nameKey: string,
	blurbKey: string,
	targetRoom: string,
	rewardSkins: { string },
	challenges: { Challenge },
	hazards: { string },
	estMinutes: number,
	difficulty: number,
	tutorial: boolean,
	unlock: { extractions: number?, tutorial: boolean? },
}

local list: { MissionDef } = {
	{
		id = "M0",
		order = 0,
		layoutId = "L0",
		nameKey = "mission.M0.name",
		blurbKey = "mission.M0.blurb",
		targetRoom = "Laundry",
		rewardSkins = {},
		challenges = {
			{ id = "M0_fast", kind = "timeLeft", value = 45, credits = 20, nameKey = "challenge.timeLeft" },
		},
		hazards = { "flood" },
		estMinutes = 3,
		difficulty = 1,
		tutorial = true,
		unlock = {},
	},
	{
		id = "M1",
		order = 1,
		layoutId = "L1",
		nameKey = "mission.M1.name",
		blurbKey = "mission.M1.blurb",
		targetRoom = "Laundry",
		rewardSkins = { "laundry_royal" },
		challenges = {
			{ id = "M1_keys", kind = "allKeys", credits = 25, nameKey = "challenge.allKeys" },
			{
				id = "M1_douse",
				kind = "combo",
				combo = "extinguish",
				credits = 25,
				nameKey = "challenge.combo.extinguish",
			},
		},
		hazards = { "flood", "fire", "gap" },
		estMinutes = 6,
		difficulty = 1,
		tutorial = false,
		unlock = { tutorial = true },
	},
	{
		id = "M2",
		order = 2,
		layoutId = "L2",
		nameKey = "mission.M2.name",
		blurbKey = "mission.M2.blurb",
		targetRoom = "Freezer",
		rewardSkins = { "freezer_lodge" },
		challenges = {
			{
				id = "M2_launch",
				kind = "combo",
				combo = "ice_launch",
				credits = 30,
				nameKey = "challenge.combo.ice_launch",
			},
			{ id = "M2_flawless", kind = "noDowns", credits = 25, nameKey = "challenge.noDowns" },
		},
		hazards = { "flood", "gap", "carts" },
		estMinutes = 7,
		difficulty = 2,
		tutorial = false,
		unlock = { tutorial = true, extractions = 1 },
	},
	{
		id = "M3",
		order = 3,
		layoutId = "L3",
		nameKey = "mission.M3.name",
		blurbKey = "mission.M3.blurb",
		targetRoom = "Fan",
		rewardSkins = { "fan_retro" },
		challenges = {
			{
				id = "M3_power",
				kind = "combo",
				combo = "power_off",
				credits = 20,
				nameKey = "challenge.combo.power_off",
			},
			{ id = "M3_fast", kind = "timeLeft", value = 35, credits = 30, nameKey = "challenge.timeLeft" },
		},
		hazards = { "fire", "electric", "flood" },
		estMinutes = 7,
		difficulty = 2,
		tutorial = false,
		unlock = { tutorial = true, extractions = 2 },
	},
	{
		id = "M4",
		order = 4,
		layoutId = "L4",
		nameKey = "mission.M4.name",
		blurbKey = "mission.M4.blurb",
		targetRoom = "Fan",
		rewardSkins = { "case_gold" },
		challenges = {
			{
				id = "M4_crates",
				kind = "combo",
				combo = "crate_bridge",
				credits = 25,
				nameKey = "challenge.combo.crate_bridge",
			},
			{ id = "M4_keys", kind = "allKeys", credits = 30, nameKey = "challenge.allKeys" },
		},
		hazards = { "carts", "gap", "crates" },
		estMinutes = 8,
		difficulty = 2,
		tutorial = false,
		unlock = { tutorial = true, extractions = 3 },
	},
	{
		id = "M5",
		order = 5,
		layoutId = "L5",
		nameKey = "mission.M5.name",
		blurbKey = "mission.M5.blurb",
		targetRoom = "Greenhouse",
		rewardSkins = { "greenhouse_zen" },
		challenges = {
			{ id = "M5_flawless", kind = "noDowns", credits = 30, nameKey = "challenge.noDowns" },
			{ id = "M5_fast", kind = "timeLeft", value = 30, credits = 30, nameKey = "challenge.timeLeft" },
		},
		hazards = { "gap", "flood", "fire" },
		estMinutes = 8,
		difficulty = 3,
		tutorial = false,
		unlock = { tutorial = true, extractions = 3 },
	},
	{
		id = "M6",
		order = 6,
		layoutId = "L6",
		nameKey = "mission.M6.name",
		blurbKey = "mission.M6.blurb",
		targetRoom = "Magnet",
		rewardSkins = { "magnet_arcade" },
		challenges = {
			{ id = "M6_keys", kind = "allKeys", credits = 35, nameKey = "challenge.allKeys" },
			{ id = "M6_flawless", kind = "noDowns", credits = 35, nameKey = "challenge.noDowns" },
		},
		hazards = { "electric", "carts", "crates", "gap" },
		estMinutes = 9,
		difficulty = 3,
		tutorial = false,
		unlock = { tutorial = true, extractions = 4 },
	},
}

local byId: { [string]: MissionDef } = {}
for _, mission in list do
	assert(byId[mission.id] == nil, "duplicate mission " .. mission.id)
	byId[mission.id] = mission
end
table.sort(list, function(a, b)
	return a.order < b.order
end)

local Missions = {
	list = list,
	byId = byId,
	tutorialId = "M0",
}

function Missions.get(id: string): MissionDef?
	return byId[id]
end

-- Whether a profile has unlocked a mission.
function Missions.isUnlocked(mission: MissionDef, tutorialDone: boolean, extractions: number): boolean
	if mission.unlock.tutorial and not tutorialDone then
		return false
	end
	if mission.unlock.extractions and extractions < mission.unlock.extractions then
		return false
	end
	return true
end

return Tables.deepFreeze(Missions)
