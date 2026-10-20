--!strict
--[[
	L5 "Greenhouse Atrium" (M5, greenhouse wing, difficulty 3).

	Route: elevator -> the lily pond B1 -> the planter gap G1 -> right past the compost fire F1 -> the crate gap
	G2 -> the great chasm G3 (two tiles) -> left to the Greenhouse Room.

	Vines are the wing's theme, but the Greenhouse is this mission's prize, so every vine is an alternative:
	starter rooms always have another way across.

	Obstacles and their solutions:
	  B1 lily pond (2 tiles)  Freezer at S1 | ledge on the left
	  G1 planter gap          Greenhouse at S2 grows vine V1 (watered by the pond) | beam on the right
	  F1 compost fire         Laundry at S3 douses it | SAFE WAY walkway on the right
	  G2 crate gap            Fan at S4 blows C1 into the slot | beam on the left
	  G3 great chasm          Greenhouse at S5 + Laundry at S6 grow vine V2 | long beam on the left
	Keys: K1 after G1, K2 on the G2 beam, K3 after the chasm.
]]
local LayoutTypes = require(script.Parent.Parent.Parent.World.LayoutTypes)

local layout: LayoutTypes.LayoutDef = {
	id = "L5",
	nameKey = "mission.M5.name",
	theme = "greenhouse",
	seed = 1501,
	roomNumberBase = 510,
	modules = {
		{ kind = "Elevator" },
		{ kind = "Hall", len = 2, sockets = { [2] = { R = "S1" } } },
		{ kind = "Basin", id = "B1", len = 2, wet = true, ledge = "L" },
		{ kind = "Hall", len = 1, sockets = { [1] = { L = "S2" } } },
		{ kind = "Gap", id = "G1", len = 1, vine = "V1", waterFrom = "B1", beam = "R" },
		{ kind = "Hall", len = 1, keys = { { id = "K1", at = 1, lateral = -4.5, along = 2 } } },
		{ kind = "Turn", dir = "R" },
		{ kind = "Hall", len = 1, sockets = { [1] = { L = "S3" } } },
		{ kind = "Fire", id = "F1", ledge = "R" },
		{
			kind = "Hall",
			len = 2,
			sockets = { [1] = { R = "S4" } },
			crates = { { id = "C1", at = 2, lateral = 0 } },
		},
		{
			kind = "Gap",
			id = "G2",
			len = 1,
			slot = "C1",
			beam = "L",
			keys = { { id = "K2", at = 1, lateral = -6.1, along = 0 } },
		},
		{ kind = "Hall", len = 1, sockets = { [1] = { L = "S5", R = "S6" } } },
		{ kind = "Gap", id = "G3", len = 2, vine = "V2", beam = "L" },
		{ kind = "Hall", len = 1, keys = { { id = "K3", at = 1, lateral = 4.5, along = 0 } } },
		{ kind = "Turn", dir = "L" },
		{ kind = "Hall", len = 1 },
		{ kind = "Target", room = "Greenhouse" },
	},
	sockets = {
		S1 = { cold = { "B1" } },
		S2 = { vine = "V1" },
		S3 = { water = "F1" },
		S4 = { wind = { "Forward", "Backward" } },
		S5 = { vine = "V2" },
		S6 = { water = "V2" },
	},
	caretaker = { patrolFrom = 8, patrolTo = 20, spawn = 14 },
	solutions = {
		{
			name = "starter: freeze the pond, beams, SAFE WAY and a crate bridge",
			loadout = { "Freezer", "Fan" },
			steps = {
				{ deploy = "S1", room = "Freezer" },
				{ cross = "B1", by = "ice" },
				{ cross = "G1", by = "beam" },
				{ cross = "F1", by = "walkway" },
				{ deploy = "S4", room = "Fan", dir = "Forward" },
				{ cross = "G2", by = "crate" },
				{ cross = "G3", by = "beam" },
				{ capture = true },
				{ cross = "G3", by = "beam" },
				{ cross = "G2", by = "beam" },
				{ cross = "F1", by = "walkway" },
				{ cross = "G1", by = "beam" },
				{ cross = "B1", by = "ice" },
				{ escape = true },
			},
			combos = { "ice_bridge", "crate_bridge" },
			keys = { "K1", "K2", "K3" },
		},
		{
			name = "gardener: vine bridges and a doused fire",
			loadout = { "Greenhouse", "Laundry" },
			steps = {
				{ cross = "B1", by = "ledge" },
				{ deploy = "S2", room = "Greenhouse" },
				{ cross = "G1", by = "vine" },
				{ deploy = "S3", room = "Laundry" },
				{ cross = "F1", by = "douse" },
				{ cross = "G2", by = "beam" },
				{ recall = "Greenhouse" },
				{ deploy = "S5", room = "Greenhouse" },
				{ recall = "Laundry" },
				{ deploy = "S6", room = "Laundry" },
				{ cross = "G3", by = "vine" },
				{ capture = true },
				{ cross = "G3", by = "vine" },
				{ cross = "G2", by = "beam" },
				{ cross = "F1", by = "walkway" },
				{ cross = "G1", by = "beam" },
				{ cross = "B1", by = "ledge" },
				{ escape = true },
			},
			combos = { "vine_bridge", "extinguish" },
			keys = { "K1", "K2", "K3" },
		},
		{
			name = "firefighter: freeze, douse, beams",
			loadout = { "Freezer", "Laundry" },
			steps = {
				{ deploy = "S1", room = "Freezer" },
				{ cross = "B1", by = "ice" },
				{ cross = "G1", by = "beam" },
				{ deploy = "S3", room = "Laundry" },
				{ cross = "F1", by = "douse" },
				{ cross = "G2", by = "beam" },
				{ cross = "G3", by = "beam" },
				{ capture = true },
				{ cross = "G3", by = "beam" },
				{ cross = "G2", by = "beam" },
				{ cross = "F1", by = "douse" },
				{ cross = "G1", by = "beam" },
				{ cross = "B1", by = "ice" },
				{ escape = true },
			},
			combos = { "extinguish", "ice_bridge" },
			keys = { "K1", "K2", "K3" },
		},
	},
}

return layout
