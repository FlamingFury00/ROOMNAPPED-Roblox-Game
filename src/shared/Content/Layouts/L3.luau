--!strict
--[[
	L3 "The Boiler Wing" (M3, boiler wing, difficulty 2).

	Route: elevator -> live puddle P1 -> left past the furnace fire F1 -> the charged flood B1 -> right through
	the second live puddle P2 and the boiler fire F2 -> left to the Fan Room.

	Two power circuits (R10): PW1 feeds P1; PW2 feeds the flooded basin B1 and P2. Switch LV1 and Freezer
	socket S1 sit on P1's own tile, so they can be used from either side of the puddle; LV2 sits between B1 and
	P2. Frozen water is never live and nothing ever requires an electrified crossing.

	Obstacles and their solutions:
	  P1 live puddle         pull LV1 | Freezer at S1 freezes it safe
	  F1 furnace fire        Laundry at S2 douses it | SAFE WAY walkway on the right
	  B1 charged flood       Freezer at S3 (ice is never live) | ledge on the left, outside the live water
	  P2 live puddle         pull LV2 (also cuts B1: the power_off combo) | Freezer at S4
	  F2 boiler fire         Laundry at S5 douses it | SAFE WAY walkway on the left
	Keys: K1 after P1, K2 in the maintenance alcove A1 (opens once LV2 cuts the power), K3 past F2.
]]
local LayoutTypes = require(script.Parent.Parent.Parent.World.LayoutTypes)

local layout: LayoutTypes.LayoutDef = {
	id = "L3",
	nameKey = "mission.M3.name",
	theme = "boiler",
	seed = 1301,
	roomNumberBase = 310,
	modules = {
		{ kind = "Elevator" },
		{ kind = "Hall", len = 2 },
		{
			kind = "Puddle",
			id = "P1",
			power = "PW1",
			sockets = { [1] = { R = "S1" } },
			levers = { { id = "LV1", at = 1, side = "L" } },
		},
		{ kind = "Hall", len = 1, keys = { { id = "K1", at = 1, lateral = 4.5, along = 2 } } },
		{ kind = "Turn", dir = "L" },
		{ kind = "Hall", len = 1, sockets = { [1] = { L = "S2" } } },
		{ kind = "Fire", id = "F1", ledge = "R" },
		{ kind = "Hall", len = 1, sockets = { [1] = { R = "S3" } } },
		{ kind = "Basin", id = "B1", len = 2, wet = true, power = "PW2", ledge = "L" },
		{
			kind = "Hall",
			len = 1,
			levers = { { id = "LV2", at = 1, side = "R" } },
			alcoves = { { id = "A1", at = 1, side = "L", gate = "GT1", key = "K2" } },
		},
		{ kind = "Turn", dir = "R" },
		{ kind = "Puddle", id = "P2", power = "PW2", sockets = { [1] = { L = "S4" } } },
		{ kind = "Hall", len = 1, sockets = { [1] = { R = "S5" } } },
		{ kind = "Fire", id = "F2", ledge = "L" },
		{ kind = "Hall", len = 1, keys = { { id = "K3", at = 1, lateral = -4.5, along = 0 } } },
		{ kind = "Turn", dir = "L" },
		{ kind = "Hall", len = 1 },
		{ kind = "Target", room = "Fan" },
	},
	sockets = {
		S1 = { cold = { "P1" } },
		S2 = { water = "F1" },
		S3 = { cold = { "B1" } },
		S4 = { cold = { "P2" } },
		S5 = { water = "F2" },
	},
	powers = {
		PW1 = { default = true, levers = { "LV1" } },
		PW2 = { default = true, levers = { "LV2" } },
	},
	gates = {
		GT1 = { signals = { "lever:LV2" } },
	},
	caretaker = { patrolFrom = 8, patrolTo = 19, spawn = 12 },
	solutions = {
		{
			name = "starter: cut the power, freeze the charged flood, SAFE WAY past the fires",
			loadout = { "Freezer", "Fan" },
			steps = {
				{ pull = "LV1" },
				{ cross = "P1", by = "power" },
				{ cross = "F1", by = "walkway" },
				{ deploy = "S3", room = "Freezer" },
				{ cross = "B1", by = "ice" },
				{ pull = "LV2" },
				{ cross = "P2", by = "power" },
				{ cross = "F2", by = "walkway" },
				{ capture = true },
				{ cross = "F2", by = "walkway" },
				{ cross = "P2", by = "power" },
				{ cross = "B1", by = "ice" },
				{ cross = "F1", by = "walkway" },
				{ cross = "P1", by = "power" },
				{ escape = true },
			},
			combos = { "power_off", "frozen_safe", "ice_bridge" },
			keys = { "K1", "K2", "K3" },
		},
		{
			name = "firefighter: freeze, douse, and cut the power on the way home",
			loadout = { "Freezer", "Laundry" },
			steps = {
				{ deploy = "S1", room = "Freezer" },
				{ cross = "P1", by = "power" },
				{ deploy = "S2", room = "Laundry" },
				{ cross = "F1", by = "douse" },
				{ recall = "Freezer" },
				{ deploy = "S3", room = "Freezer" },
				{ cross = "B1", by = "ice" },
				{ pull = "LV2" },
				{ cross = "P2", by = "power" },
				{ recall = "Laundry" },
				{ deploy = "S5", room = "Laundry" },
				{ cross = "F2", by = "douse" },
				{ capture = true },
				{ cross = "F2", by = "douse" },
				{ cross = "P2", by = "power" },
				{ cross = "B1", by = "ice" },
				{ cross = "F1", by = "walkway" },
				{ pull = "LV1" },
				{ cross = "P1", by = "power" },
				{ escape = true },
			},
			combos = { "extinguish", "frozen_safe", "power_off" },
			keys = { "K1", "K2", "K3" },
		},
		{
			name = "no freezer: switches, douse, ledge",
			loadout = { "Laundry", "Fan" },
			steps = {
				{ pull = "LV1" },
				{ cross = "P1", by = "power" },
				{ deploy = "S2", room = "Laundry" },
				{ cross = "F1", by = "douse" },
				{ cross = "B1", by = "ledge" },
				{ pull = "LV2" },
				{ cross = "P2", by = "power" },
				{ cross = "F2", by = "walkway" },
				{ capture = true },
				{ cross = "F2", by = "walkway" },
				{ cross = "P2", by = "power" },
				{ cross = "B1", by = "ledge" },
				{ cross = "F1", by = "douse" },
				{ cross = "P1", by = "power" },
				{ escape = true },
			},
			combos = { "power_off", "extinguish" },
			keys = { "K1", "K2", "K3" },
		},
	},
}

return layout
