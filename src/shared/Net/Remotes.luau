--!strict
--[[
	Remote definitions (S20). Every client->server remote declares an argument schema and a rate-limit
	bucket; the server wrapper rejects anything that does not match before game code sees it.

	Schema tokens:
	  "string" | "number" | "integer" | "boolean" | "table" | "Vector3" | "any"
	  suffix "?" makes an argument optional (nil allowed)
	Strings are limited to 64 characters unless the token is "longstring" (512).
]]

local Tables = require(script.Parent.Parent.Util.Tables)

export type ClientEventDef = {
	schema: { string },
	rate: string,
}

local Remotes = {
	-- Client -> server --------------------------------------------------------------------------------
	ClientEvents = {
		ClientReady = { schema = { "string", "string?" }, rate = "Lobby" }, -- deviceKind, localeId
		RequestDeploy = { schema = { "string", "integer", "string?" }, rate = "Deploy" }, -- socketId, slot, direction
		RequestRecall = { schema = { "integer" }, rate = "Deploy" }, -- slot
		SelectSlot = { schema = { "integer" }, rate = "Interaction" }, -- 0 = none, 1/2 = room slot (held suitcase)
		HoldBegin = { schema = { "string", "string" }, rate = "Interaction" }, -- kind, targetId
		HoldEnd = { schema = { "string", "string", "boolean" }, rate = "Interaction" }, -- kind, targetId, completed
		Interact = { schema = { "string", "string" }, rate = "Interaction" }, -- kind, targetId
		DropCargo = { schema = {}, rate = "Interaction" },
		Ping = { schema = { "string", "Vector3", "string?" }, rate = "Ping" }, -- kind, position, targetId
		SetLoadout = { schema = { "string", "string" }, rate = "Lobby" },
		SelectMission = { schema = { "string" }, rate = "Lobby" },
		SelectReward = { schema = { "string", "string" }, rate = "Lobby" }, -- missionId, rewardId
		SetReady = { schema = { "boolean" }, rate = "Lobby" },
		ResultsAction = { schema = { "string" }, rate = "Lobby" }, -- "replay" | "lobby"
		BuySkin = { schema = { "string" }, rate = "Purchase" },
		EquipSkin = { schema = { "string", "string" }, rate = "Lobby" }, -- targetId (room id or "suitcase"), skinId
		SaveSettings = { schema = { "table" }, rate = "Settings" },
		Feedback = { schema = { "integer", "string?" }, rate = "Lobby" }, -- rating, tag
		LeaveRun = { schema = {}, rate = "Lobby" },
		RequestUnstuck = { schema = {}, rate = "Lobby" },
		TutorialStep = { schema = { "string" }, rate = "Default" },
		RetryProfile = { schema = {}, rate = "Lobby" },
		Debug = { schema = { "string", "string?", "string?" }, rate = "Debug" }, -- command, arg1, arg2
	} :: { [string]: ClientEventDef },

	-- Server -> client --------------------------------------------------------------------------------
	ServerEvents = {
		"StatePatch", -- (channel, seq, patches)
		"Toast", -- (kind, key, params)
		"Effect", -- (name, params) one-shot visual/audio event
		"Knockback", -- (direction, strength)
		"Teleported", -- (cframe) camera snap hint after a server teleport
		"Results", -- (payload) per-player results
		"PingMarker", -- (ping)
		"Hint", -- (key, params)
		"DebugReply", -- (text)
	},

	-- Unreliable server -> client streams ---------------------------------------------------------
	UnreliableEvents = {
		"CaretakerSnapshot", -- (serverTime, position, yaw, mode)
	},

	-- Client -> server request/response -------------------------------------------------------------
	Functions = {
		"GetSnapshot",
	},
}

return Tables.deepFreeze(Remotes)
