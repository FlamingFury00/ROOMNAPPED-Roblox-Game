--!strict
--[[
	L4 "Luggage Line" (M4, classic wing, difficulty 2).

	Route: elevator -> broken floor G1 (crate C1) -> left through the double cart crossing CT1/CT2 -> right
	into the sorting hall (crates C2 and C3, pressure plate PL1) -> broken floor G2 -> left over the express
	track CT3 -> the Fan Room.

	One Fan at S4 does two jobs at once: it blows C3 into G2's slot and slides C2 onto plate PL1, which opens
	the Lost & Found alcove A1.

	Obstacles and their solutions:
	  G1 broken floor     Fan at S1 blows C1 into the slot (crate_bridge) | beam on the left
	  CT1 + CT2 carts     Freezer at S2 chills both | Fans blowing Across at S2 / S3 pin them | timing
	  G2 broken floor     Fan at S4 blows C3 into the slot | beam on the right
	  CT3 express cart    Fan at S5 Across pins it | Freezer at S5 chills it | timing
	Keys (all with starter rooms): K1 on the G1 beam, K2 in alcove A1 (plate PL1), K3 on the G2 beam.
]]
local LayoutTypes = require(script.Parent.Parent.Parent.World.LayoutTypes)

local layout: LayoutTypes.LayoutDef = {
	id = "L4",
	nameKey = "mission.M4.name",
	theme = "classic",
	seed = 1401,
	roomNumberBase = 410,
	modules = {
		{ kind = "Elevator" },
		{
			kind = "Hall",
			len = 2,
			sockets = { [1] = { R = "S1" } },
			crates = { { id = "C1", at = 2, lateral = 0 } },
		},
		{
			kind = "Gap",
			id = "G1",
			len = 1,
			slot = "C1",
			beam = "L",
			keys = { { id = "K1", at = 1, lateral = -6.1, along = 0 } },
		},
		{ kind = "Hall", len = 1 },
		{ kind = "Turn", dir = "L" },
		{ kind = "Carts", id = "CT1", sockets = { [1] = { R = "S2" } } },
		{ kind = "Carts", id = "CT2", cartSpeed = 10, sockets = { [1] = { L = "S3" } } },
		{ kind = "Hall", len = 1 },
		{ kind = "Turn", dir = "R" },
		{
			kind = "Hall",
			len = 2,
			sockets = { [1] = { R = "S4" } },
			crates = {
				{ id = "C2", at = 1, lateral = -4.2, along = 0 },
				{ id = "C3", at = 2, lateral = 1.6, along = 0 },
			},
			plates = { { id = "PL1", at = 2, lateral = -4.2, along = 4.6 } },
			alcoves = { { id = "A1", at = 2, side = "R", gate = "GT1" } },
			keys = { { id = "K2", alcove = "A1" } },
		},
		{
			kind = "Gap",
			id = "G2",
			len = 1,
			slot = "C3",
			beam = "R",
			keys = { { id = "K3", at = 1, lateral = 6.1, along = 0 } },
		},
		{ kind = "Hall", len = 1 },
		{ kind = "Turn", dir = "L" },
		{ kind = "Carts", id = "CT3", cartSpeed = 12, sockets = { [1] = { L = "S5" } } },
		{ kind = "Hall", len = 2 },
		{ kind = "Target", room = "Fan" },
	},
	sockets = {
		S1 = { wind = { "Forward", "Backward" } },
		S2 = { wind = { "Across" }, cold = { "CT1", "CT2" } },
		S3 = { wind = { "Across" }, cold = { "CT2" } },
		S4 = { wind = { "Forward", "Backward" } },
		S5 = { wind = { "Across" }, cold = { "CT3" } },
	},
	gates = {
		GT1 = { signals = { "plate:PL1" } },
	},
	caretaker = { patrolFrom = 9, patrolTo = 18, spawn = 13 },
	solutions = {
		{
			name = "starter: crate bridges, chilled tracks, one Fan for two crates",
			loadout = { "Freezer", "Fan" },
			steps = {
				{ deploy = "S1", room = "Fan", dir = "Forward" },
				{ cross = "G1", by = "crate" },
				{ recall = "Fan" },
				{ deploy = "S2", room = "Freezer" },
				{ cross = "CT1", by = "slow" },
				{ cross = "CT2", by = "slow" },
				{ deploy = "S4", room = "Fan", dir = "Forward" },
				{ cross = "G2", by = "beam" },
				{ cross = "CT3", by = "timing" },
				{ capture = true },
				{ cross = "CT3", by = "timing" },
				{ cross = "G2", by = "crate" },
				{ cross = "CT2", by = "slow" },
				{ cross = "CT1", by = "slow" },
				{ cross = "G1", by = "beam" },
				{ escape = true },
			},
			combos = { "crate_bridge", "crate_plate", "cart_freeze" },
			keys = { "K1", "K2", "K3" },
		},
		{
			name = "wind tunnel: pin the carts, beams on the way in",
			loadout = { "Freezer", "Fan" },
			steps = {
				{ cross = "G1", by = "beam" },
				{ deploy = "S2", room = "Fan", dir = "Across" },
				{ cross = "CT1", by = "pin" },
				{ deploy = "S3", room = "Freezer" },
				{ cross = "CT2", by = "slow" },
				{ cross = "G2", by = "beam" },
				{ recall = "Fan" },
				{ deploy = "S5", room = "Fan", dir = "Across" },
				{ cross = "CT3", by = "pin" },
				{ capture = true },
				{ cross = "CT3", by = "pin" },
				{ cross = "G2", by = "beam" },
				{ cross = "CT2", by = "slow" },
				{ cross = "CT1", by = "timing" },
				{ cross = "G1", by = "beam" },
				{ escape = true },
			},
			combos = { "cart_pin", "cart_freeze" },
			keys = { "K1", "K3" },
		},
	},
}

return layout
