--!strict
--[[
	Mastery: the three stars of each mission and what the stars earn (S23, U17).

	A mission's stars: cleared once; every golden key in a single run (a mission without keys counts its clear
	again); every bonus challenge done at least once. The mission board draws them, and the total unlocks the
	medal suitcases (SkinDefs source "mastery") - granted on the server when a run is applied and when a
	profile loads, so players who earned the stars before the suitcases existed get them too.
]]

local MissionDefs = require(script.Parent.Parent.Config.MissionDefs)
local SkinDefs = require(script.Parent.Parent.Config.SkinDefs)
local Layouts = require(script.Parent.Parent.Content.Layouts)

type StatsLike = {
	cleared: { [string]: number }?,
	allKeys: { [string]: boolean }?,
	challengesDone: { [string]: boolean }?,
}

type ProfileLike = {
	stats: StatsLike,
	skins: { owned: { [string]: boolean } },
}

local Mastery = {}

-- Golden keys placed in a mission's layout: module keys and keys waiting in Lost & Found alcoves (the same two
-- sources LevelBuilder places), counted once per id.
local keyCounts: { [string]: number } = {}
function Mastery.keyCount(mission: MissionDefs.MissionDef): number
	local cached = keyCounts[mission.id]
	if cached then
		return cached
	end
	local layout = Layouts[mission.layoutId]
	local ids: { [string]: boolean } = {}
	if layout then
		for _, mod in layout.modules do
			local m = mod :: any
			if type(m.alcoves) == "table" then
				for _, alcove in m.alcoves do
					if type(alcove) == "table" and type(alcove.key) == "string" then
						ids[alcove.key] = true
					end
				end
			end
			if type(m.keys) == "table" then
				for _, key in m.keys do
					if type(key) == "table" and type(key.id) == "string" then
						ids[key.id] = true
					end
				end
			end
		end
	end
	local count = 0
	for _ in ids do
		count += 1
	end
	keyCounts[mission.id] = count
	return count
end

-- The three stars of one mission: { cleared, every key in one run, every bonus challenge }.
function Mastery.missionStars(stats: StatsLike, mission: MissionDefs.MissionDef): { boolean }
	local cleared = type(stats.cleared) == "table" and ((stats.cleared :: any)[mission.id] or 0) > 0
	local keys = if Mastery.keyCount(mission) == 0
		then cleared
		else type(stats.allKeys) == "table" and (stats.allKeys :: any)[mission.id] == true
	local done = if type(stats.challengesDone) == "table" then stats.challengesDone :: any else {}
	local challenges = #mission.challenges > 0
	for _, challenge in mission.challenges do
		if done[challenge.id] ~= true then
			challenges = false
		end
	end
	return { cleared, keys, challenges }
end

function Mastery.totalStars(stats: StatsLike): number
	local total = 0
	for _, mission in MissionDefs.list do
		for _, earned in Mastery.missionStars(stats, mission) do
			if earned then
				total += 1
			end
		end
	end
	return total
end

function Mastery.maxStars(): number
	return #MissionDefs.list * 3
end

-- Give the profile every mastery skin its stars have earned. Returns the newly granted skin ids.
function Mastery.grant(profile: ProfileLike): { string }
	local granted = {}
	local total: number? = nil
	for _, skin in SkinDefs.list do
		if skin.source == "mastery" and not profile.skins.owned[skin.id] then
			total = total or Mastery.totalStars(profile.stats)
			if (total :: number) >= (skin.stars or math.huge) then
				profile.skins.owned[skin.id] = true
				table.insert(granted, skin.id)
			end
		end
	end
	return granted
end

return Mastery
