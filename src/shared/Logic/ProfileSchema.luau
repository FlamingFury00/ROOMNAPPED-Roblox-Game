--!strict
--[[
	ProfileSchema: versioned save format, migrations and sanitisation (S21, R12).

	Room ids are stable strings. A room that is disabled by a feature flag or removed from config stays in
	the profile untouched (it is simply not offered), so disabling content never wipes progress (S32).
]]

local Tables = require(script.Parent.Parent.Util.Tables)

export type Settings = {
	music: number,
	sfx: number,
	ambience: number,
	ui: number,
	reducedMotion: boolean,
	lowEffects: boolean,
	hints: boolean,
	cameraShake: boolean,
	textScale: number,
}

export type Profile = {
	schema: number,
	createdAt: number,
	lastSeenAt: number,
	rooms: { [string]: boolean },
	loadout: { string },
	skins: { owned: { [string]: boolean }, equipped: { [string]: string } },
	credits: number,
	settings: Settings,
	stats: {
		runs: number,
		extractions: number,
		failures: number,
		captures: number,
		deploys: number,
		combos: number,
		keys: number,
		cleared: { [string]: number },
		bestTimes: { [string]: number },
		-- Mission mastery: bonus challenges ever completed, missions extracted with every golden key.
		challengesDone: { [string]: boolean },
		allKeys: { [string]: boolean },
	},
	grants: { list: { { id: string, at: number } } },
	rewardChoice: { [string]: string },
	tutorialDone: boolean,
	-- onboardingSteps: bit (step - 1) is set once onboarding funnel step `step` has been logged.
	flags: { interruptedRunId: string, lastVersion: string, onboardingSteps: number },
	feedbackCount: number,
}

local CURRENT = 5

local ProfileSchema = {}
ProfileSchema.CURRENT = CURRENT

function ProfileSchema.defaultSettings(): Settings
	return {
		music = 0.55,
		sfx = 0.85,
		ambience = 0.7,
		ui = 0.8,
		reducedMotion = false,
		lowEffects = false,
		hints = true,
		cameraShake = true,
		textScale = 1,
	}
end

function ProfileSchema.default(
	now: number,
	starterRooms: { string },
	defaultSkins: { [string]: string },
	defaultSuitcase: string
): Profile
	local rooms = {}
	for _, id in starterRooms do
		rooms[id] = true
	end
	local owned = {}
	for _, skinId in defaultSkins do
		owned[skinId] = true
	end
	owned[defaultSuitcase] = true
	local equipped = table.clone(defaultSkins)
	equipped.suitcase = defaultSuitcase
	return {
		schema = CURRENT,
		createdAt = now,
		lastSeenAt = now,
		rooms = rooms,
		loadout = { starterRooms[1], starterRooms[2] },
		skins = { owned = owned, equipped = equipped },
		credits = 0,
		settings = ProfileSchema.defaultSettings(),
		stats = {
			runs = 0,
			extractions = 0,
			failures = 0,
			captures = 0,
			deploys = 0,
			combos = 0,
			keys = 0,
			cleared = {},
			bestTimes = {},
			challengesDone = {},
			allKeys = {},
		},
		grants = { list = {} },
		rewardChoice = {},
		tutorialDone = false,
		flags = { interruptedRunId = "", lastVersion = "", onboardingSteps = 0 },
		feedbackCount = 0,
	}
end

-- Migrations: each step takes data at version N and returns data at N + 1.
local MIGRATIONS: { [number]: (any) -> any } = {
	-- v1 stored owned rooms as an array and had no skins.
	[1] = function(data: any): any
		local rooms = {}
		if type(data.ownedRooms) == "table" then
			for _, id in data.ownedRooms do
				if type(id) == "string" then
					rooms[id] = true
				end
			end
		end
		data.rooms = rooms
		data.ownedRooms = nil
		data.schema = 2
		return data
	end,
	-- v2 added cosmetic skins, reward choices and the grant ledger as a list.
	[2] = function(data: any): any
		if type(data.grants) == "table" and data.grants.list == nil then
			local list = {}
			for id, at in data.grants do
				if type(id) == "string" then
					table.insert(list, { id = id, at = if type(at) == "number" then at else 0 })
				end
			end
			table.sort(list, function(a, b)
				return a.at < b.at
			end)
			data.grants = { list = list }
		end
		data.schema = 3
		return data
	end,
	-- v3 stored only the highest onboarding funnel step; v4 keeps one bit per logged step so a step that was
	-- skipped (a failed first run jumping to "Replayed") can still be logged later.
	[3] = function(data: any): any
		if type(data.flags) == "table" then
			local highest = data.flags.onboardingFunnel
			local mask = 0
			if type(highest) == "number" and highest == highest then
				for step = 1, math.clamp(math.floor(highest), 0, 16) do
					mask = bit32.bor(mask, bit32.lshift(1, step - 1))
				end
			end
			data.flags.onboardingSteps = mask
			data.flags.onboardingFunnel = nil
		end
		data.schema = 4
		return data
	end,
	-- v5 records mission mastery (completed bonus challenges, all-keys extractions) from now on.
	[4] = function(data: any): any
		if type(data.stats) == "table" then
			data.stats.challengesDone = if type(data.stats.challengesDone) == "table"
				then data.stats.challengesDone
				else {}
			data.stats.allKeys = if type(data.stats.allKeys) == "table" then data.stats.allKeys else {}
		end
		data.schema = 5
		return data
	end,
}

-- Upgrade any stored version to CURRENT. Returns nil if the data is newer than this build understands
-- (a newer server wrote it) - callers must then refuse to write so progress is never downgraded.
function ProfileSchema.migrate(data: any): any?
	if type(data) ~= "table" then
		return nil
	end
	local version = if type(data.schema) == "number" then data.schema else 1
	if version > CURRENT then
		return nil
	end
	while version < CURRENT do
		local step = MIGRATIONS[version]
		if not step then
			return nil
		end
		data = step(data)
		version = data.schema
	end
	return data
end

local function clampNumber(value: any, lo: number, hi: number, fallback: number): number
	if type(value) ~= "number" or value ~= value then
		return fallback
	end
	return math.clamp(value, lo, hi)
end

export type ContentInfo = {
	isRoomKnown: (string) -> boolean,
	isRoomEnabled: (string) -> boolean,
	starterRooms: { string },
	defaultSkins: { [string]: string }, -- room id -> default skin id
	defaultSuitcase: string,
	skinTarget: (string) -> string?, -- skin id -> room id or "suitcase" (nil if unknown)
}

-- Sanitise a migrated profile in place against the current content definitions.
function ProfileSchema.sanitize(data: Profile, template: Profile, content: ContentInfo): Profile
	local isRoomKnown, isRoomEnabled, starterRooms = content.isRoomKnown, content.isRoomEnabled, content.starterRooms
	Tables.reconcile(data :: any, template :: any)
	-- Starter rooms are always owned.
	for _, id in starterRooms do
		data.rooms[id] = true
	end
	-- Default skins are always owned; equipped skins must be owned and match their target.
	for room, skinId in content.defaultSkins do
		data.skins.owned[skinId] = true
		local equipped = data.skins.equipped[room]
		if type(equipped) ~= "string" or not data.skins.owned[equipped] or content.skinTarget(equipped) ~= room then
			data.skins.equipped[room] = skinId
		end
	end
	data.skins.owned[content.defaultSuitcase] = true
	local case = data.skins.equipped.suitcase
	if type(case) ~= "string" or not data.skins.owned[case] or content.skinTarget(case) ~= "suitcase" then
		data.skins.equipped.suitcase = content.defaultSuitcase
	end
	data.credits = math.max(0, math.floor(clampNumber(data.credits, 0, 1e9, 0)))
	-- Mastery maps hold only `id = true` entries.
	for _, field in { "challengesDone", "allKeys" } do
		local clean = {}
		for id, value in (data.stats :: any)[field] do
			if type(id) == "string" and value == true then
				clean[id] = true
			end
		end
		(data.stats :: any)[field] = clean
	end
	data.flags.onboardingSteps = math.floor(clampNumber(data.flags.onboardingSteps, 0, 0xFFFF, 0))
	local s = data.settings
	s.music = clampNumber(s.music, 0, 1, 0.55)
	s.sfx = clampNumber(s.sfx, 0, 1, 0.85)
	s.ambience = clampNumber(s.ambience, 0, 1, 0.7)
	s.ui = clampNumber(s.ui, 0, 1, 0.8)
	s.textScale = clampNumber(s.textScale, 0.85, 1.3, 1)
	ProfileSchema.fixLoadout(data, isRoomKnown, isRoomEnabled, starterRooms)
	-- Trim the grant ledger to its bound.
	local list = data.grants.list
	while #list > 64 do
		table.remove(list, 1)
	end
	data.schema = CURRENT
	return data
end

-- Ensure the loadout holds two distinct, owned, known and enabled rooms (S05).
function ProfileSchema.fixLoadout(
	data: Profile,
	isRoomKnown: (string) -> boolean,
	isRoomEnabled: (string) -> boolean,
	starterRooms: { string }
)
	local fixed: { string } = {}
	local seen: { [string]: boolean } = {}
	if type(data.loadout) == "table" then
		for _, id in data.loadout do
			if
				#fixed < 2
				and type(id) == "string"
				and not seen[id]
				and data.rooms[id]
				and isRoomKnown(id)
				and isRoomEnabled(id)
			then
				table.insert(fixed, id)
				seen[id] = true
			end
		end
	end
	local candidates = table.clone(starterRooms)
	for id in data.rooms do
		if not table.find(candidates, id) then
			table.insert(candidates, id)
		end
	end
	table.sort(candidates, function(a, b)
		local ia, ib = table.find(starterRooms, a), table.find(starterRooms, b)
		if ia and ib then
			return ia < ib
		elseif ia then
			return true
		elseif ib then
			return false
		end
		return a < b
	end)
	for _, id in candidates do
		if #fixed >= 2 then
			break
		end
		if not seen[id] and data.rooms[id] and isRoomKnown(id) and isRoomEnabled(id) then
			table.insert(fixed, id)
			seen[id] = true
		end
	end
	data.loadout = fixed
end

-- Validate a client-provided settings table and copy only known, well-typed fields.
function ProfileSchema.cleanSettings(input: any, current: Settings): Settings
	local out = table.clone(current)
	if type(input) ~= "table" then
		return out
	end
	for key, value in input do
		if type(key) == "string" then
			local existing = (current :: any)[key]
			if type(existing) == "number" and type(value) == "number" and value == value then
				if key == "textScale" then
					(out :: any)[key] = math.clamp(value, 0.85, 1.3)
				else
					(out :: any)[key] = math.clamp(value, 0, 1)
				end
			elseif type(existing) == "boolean" and type(value) == "boolean" then
				(out :: any)[key] = value
			end
		end
	end
	return out
end

return ProfileSchema
