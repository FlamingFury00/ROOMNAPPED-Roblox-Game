--!strict
--[[
	RoomDefs: the functional room catalogue (S01: add a room through config without touching other systems).

	`effect` names the single channel a room emits into the zones its socket links to:
	  cold   - freezes linked water into walkable ice, slows the caretaker and moving obstacles, pauses vines
	  wind   - directional lane that moves crates, pushes players (capped) and pushes the caretaker (bounded)
	  water  - fills one linked basin; water extinguishes linked fire and lifts water switches
	  vine   - grows a linked vine bridge while its planter is watered
	  magnet - pulls linked metal crates toward the socket's anchor
]]

local Tables = require(script.Parent.Parent.Util.Tables)

export type EffectChannel = "cold" | "wind" | "water" | "vine" | "magnet"

export type RoomDef = {
	id: string,
	order: number,
	effect: EffectChannel,
	nameKey: string,
	effectKey: string,
	descKey: string,
	icon: string,
	color: Color3,
	accent: Color3,
	glow: Color3,
	directional: boolean,
	starter: boolean,
	unlockMissionId: string?,
}

local RoomDefs: { [string]: RoomDef } = {
	Freezer = {
		id = "Freezer",
		order = 1,
		effect = "cold",
		nameKey = "room.Freezer.name",
		effectKey = "room.Freezer.effect",
		descKey = "room.Freezer.desc",
		icon = "snowflake",
		color = Color3.fromRGB(96, 196, 255),
		accent = Color3.fromRGB(214, 244, 255),
		glow = Color3.fromRGB(140, 220, 255),
		directional = false,
		starter = true,
	},
	Fan = {
		id = "Fan",
		order = 2,
		effect = "wind",
		nameKey = "room.Fan.name",
		effectKey = "room.Fan.effect",
		descKey = "room.Fan.desc",
		icon = "fan",
		color = Color3.fromRGB(150, 232, 170),
		accent = Color3.fromRGB(230, 255, 236),
		glow = Color3.fromRGB(170, 255, 200),
		directional = true,
		starter = true,
	},
	Laundry = {
		id = "Laundry",
		order = 3,
		effect = "water",
		nameKey = "room.Laundry.name",
		effectKey = "room.Laundry.effect",
		descKey = "room.Laundry.desc",
		icon = "drop",
		color = Color3.fromRGB(70, 140, 255),
		accent = Color3.fromRGB(200, 226, 255),
		glow = Color3.fromRGB(110, 170, 255),
		directional = false,
		starter = false,
		unlockMissionId = "M0",
	},
	Greenhouse = {
		id = "Greenhouse",
		order = 4,
		effect = "vine",
		nameKey = "room.Greenhouse.name",
		effectKey = "room.Greenhouse.effect",
		descKey = "room.Greenhouse.desc",
		icon = "leaf",
		color = Color3.fromRGB(118, 204, 84),
		accent = Color3.fromRGB(226, 255, 200),
		glow = Color3.fromRGB(160, 255, 120),
		directional = false,
		starter = false,
		unlockMissionId = "M5",
	},
	Magnet = {
		id = "Magnet",
		order = 5,
		effect = "magnet",
		nameKey = "room.Magnet.name",
		effectKey = "room.Magnet.effect",
		descKey = "room.Magnet.desc",
		icon = "magnet",
		color = Color3.fromRGB(255, 92, 92),
		accent = Color3.fromRGB(255, 220, 220),
		glow = Color3.fromRGB(255, 130, 130),
		directional = false,
		starter = false,
		unlockMissionId = "M6",
	},
}

local ordered: { RoomDef } = {}
for _, def in RoomDefs do
	table.insert(ordered, def)
end
table.sort(ordered, function(a, b)
	return a.order < b.order
end)

local Rooms = {
	byId = RoomDefs,
	ordered = ordered,
}

function Rooms.get(id: string): RoomDef?
	return RoomDefs[id]
end

function Rooms.isValid(id: any): boolean
	return type(id) == "string" and RoomDefs[id] ~= nil
end

return Tables.deepFreeze(Rooms)
