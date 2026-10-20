--!strict
--[[
	FeatureFlags: release & rollback switches (S32, S35).

	Defaults live here; a live server additionally reads overrides from the "RoomnappedConfig" DataStore
	(key "flags/<environment>") at startup, so a bad room or mission can be switched off without a
	republish and without touching player profiles (disabled content stays owned, it is just not offered).

	Environments are chosen by PlaceId: list your test place id(s) in TestPlaceIds. Studio is always "studio".
]]

local Tables = require(script.Parent.Parent.Util.Tables)

export type Flags = {
	rooms: { [string]: boolean },
	missions: { [string]: boolean },
	features: {
		pings: boolean,
		feedbackPrompt: boolean,
		analytics: boolean,
		debugTools: boolean,
		caretaker: boolean,
		keys: boolean,
		shop: boolean,
	},
	adminUserIds: { number },
	adminGroup: { id: number, minRank: number }?,
}

local FeatureFlags = {
	-- Place ids that should run with test configuration (debug tools for admins, verbose logs).
	TestPlaceIds = {} :: { number },

	Defaults = {
		rooms = { Freezer = true, Fan = true, Laundry = true, Greenhouse = true, Magnet = true },
		missions = { M0 = true, M1 = true, M2 = true, M3 = true, M4 = true, M5 = true, M6 = true },
		features = {
			pings = true,
			feedbackPrompt = true,
			analytics = true,
			debugTools = true, -- still restricted to admins (see DebugService)
			caretaker = true,
			keys = true,
			shop = true,
		},
		-- Extra admins besides the experience owner (or group owner rank).
		adminUserIds = {},
		adminGroup = nil,
	} :: Flags,

	-- Per-environment overrides merged on top of Defaults.
	Environments = {
		studio = { features = { debugTools = true } },
		test = { features = { debugTools = true } },
		live = { features = { debugTools = true } },
	} :: { [string]: any },
}

return Tables.deepFreeze(FeatureFlags)
