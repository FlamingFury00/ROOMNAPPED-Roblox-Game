--!strict
--[[
	L1 "Soggy Suites" (M1, laundry wing, difficulty 1).

	Route: elevator -> flooded hall B1 -> left into the burning corridor F1 -> the planter gap G2 -> right past
	the broken floor G1 -> left to the Laundry Room.

	Obstacles and their solutions (S10/S31 - every one has a starter answer and a slower safe bypass):
	  B1 flood (2 tiles, deep)   Freezer at S1 freezes it | ledge along the left wall
	  F1 fire                    Laundry at S2 douses it (bonus challenge) | heat-shielded SAFE WAY on the left
	  G2 planter gap             Greenhouse at S5 grows vine V1 while the doused fire's pool holds water | beam
	                             on the left
	  G1 broken floor            Fan at S3 blows crate C1 into the slot -> two short hops | Magnet at S6 pulls the
	                             metal crate in from the far side | beam on the left
	The Greenhouse and the Magnet (later prizes) are never required here; they give a replay new routes.
	Keys (all with starter rooms):
	  K1 hangs over the B1 ledge (also reachable from the ice), K2 waits in the Lost & Found alcove A1
	  (its gate opens while the F1 pool is wet or once lever LV1 past the broken floor is pulled),
	  K3 floats above the G1 beam.
]]
local LayoutTypes = require(script.Parent.Parent.Parent.World.LayoutTypes)

local layout: LayoutTypes.LayoutDef = {
	id = "L1",
	nameKey = "mission.M1.name",
	theme = "laundry",
	seed = 1101,
	roomNumberBase = 110,
	modules = {
		{ kind = "Elevator" },
		{ kind = "Hall", len = 2, sockets = { [2] = { R = "S1" } } },
		{
			kind = "Basin",
			id = "B1",
			len = 2,
			wet = true,
			ledge = "L",
			keys = { { id = "K1", at = 2, lateral = -5.5, along = 0 } },
		},
		{ kind = "Hall", len = 1 },
		{ kind = "Turn", dir = "L" },
		{
			kind = "Hall",
			len = 2,
			sockets = { [1] = { L = "S2" } },
			alcoves = { { id = "A1", at = 2, side = "R", gate = "GT1", key = "K2" } },
		},
		{ kind = "Fire", id = "F1", ledge = "L" },
		{ kind = "Hall", len = 1, sockets = { [1] = { R = "S5" } } },
		{ kind = "Gap", id = "G2", len = 1, vine = "V1", waterFrom = "F1_pool", beam = "L" },
		{ kind = "Hall", len = 1 },
		{ kind = "Turn", dir = "R" },
		{
			kind = "Hall",
			len = 2,
			sockets = { [1] = { L = "S3" } },
			crates = { { id = "C1", at = 2, lateral = 0, metal = true } },
		},
		{
			kind = "Gap",
			id = "G1",
			len = 1,
			slot = "C1",
			beam = "L",
			keys = { { id = "K3", at = 1, lateral = -6.1, along = 0 } },
		},
		{
			kind = "Hall",
			len = 1,
			sockets = { [1] = { L = "S6" } },
			levers = { { id = "LV1", at = 1, side = "R" } },
		},
		{ kind = "Turn", dir = "L" },
		{ kind = "Hall", len = 2, sockets = { [1] = { R = "S4" } } },
		{ kind = "Target", room = "Laundry" },
	},
	sockets = {
		S1 = { cold = { "B1" } },
		S2 = { water = "F1" },
		S3 = { wind = { "Forward", "Backward" } },
		S4 = { wind = { "Forward", "Backward" } },
		S5 = { vine = "V1" },
		S6 = { magnet = { "C1" }, wind = { "Forward", "Backward" } },
	},
	gates = {
		GT1 = { signals = { "float:F1_pool", "lever:LV1" } },
	},
	caretaker = { patrolFrom = 15, patrolTo = 21, spawn = 18 },
	solutions = {
		{
			name = "starter: freeze the flood, SAFE WAY past the fire, crate hops over the gap",
			loadout = { "Freezer", "Fan" },
			steps = {
				{ deploy = "S1", room = "Freezer" },
				{ cross = "B1", by = "ice" },
				{ cross = "F1", by = "walkway" },
				{ cross = "G2", by = "beam" },
				{ deploy = "S3", room = "Fan", dir = "Forward" },
				{ cross = "G1", by = "crate" },
				{ pull = "LV1" },
				{ capture = true },
				{ cross = "G1", by = "beam" },
				{ cross = "G2", by = "beam" },
				{ cross = "F1", by = "walkway" },
				{ cross = "B1", by = "ice" },
				{ escape = true },
			},
			combos = { "crate_bridge", "ice_bridge" },
			keys = { "K1", "K2", "K3" },
		},
		{
			name = "laundry: douse the fire",
			loadout = { "Freezer", "Laundry" },
			steps = {
				{ deploy = "S1", room = "Freezer" },
				{ cross = "B1", by = "ice" },
				{ deploy = "S2", room = "Laundry" },
				{ cross = "F1", by = "douse" },
				{ cross = "G2", by = "beam" },
				{ cross = "G1", by = "beam" },
				{ capture = true },
				{ cross = "G1", by = "beam" },
				{ cross = "G2", by = "beam" },
				{ cross = "F1", by = "douse" },
				{ cross = "B1", by = "ice" },
				{ escape = true },
			},
			combos = { "extinguish", "ice_bridge" },
			keys = { "K1", "K2", "K3" },
		},
		{
			name = "no freezer: ledge, douse, crate hops",
			loadout = { "Fan", "Laundry" },
			steps = {
				{ cross = "B1", by = "ledge" },
				{ deploy = "S2", room = "Laundry" },
				{ cross = "F1", by = "douse" },
				{ cross = "G2", by = "beam" },
				{ deploy = "S3", room = "Fan", dir = "Forward" },
				{ cross = "G1", by = "crate" },
				{ capture = true },
				{ cross = "G1", by = "crate" },
				{ cross = "G2", by = "beam" },
				{ cross = "F1", by = "douse" },
				{ cross = "B1", by = "ledge" },
				{ escape = true },
			},
			combos = { "extinguish", "crate_bridge" },
			keys = { "K1", "K2" },
		},
		{
			name = "gardener: the doused fire waters a vine bridge",
			loadout = { "Greenhouse", "Laundry" },
			steps = {
				{ cross = "B1", by = "ledge" },
				{ deploy = "S2", room = "Laundry" },
				{ cross = "F1", by = "douse" },
				{ deploy = "S5", room = "Greenhouse" },
				{ cross = "G2", by = "vine" },
				{ cross = "G1", by = "beam" },
				{ capture = true },
				{ cross = "G1", by = "beam" },
				{ cross = "G2", by = "vine" },
				{ cross = "F1", by = "douse" },
				{ cross = "B1", by = "ledge" },
				{ escape = true },
			},
			combos = { "extinguish", "vine_bridge" },
			keys = { "K1", "K2", "K3" },
		},
		{
			name = "collector: a Magnet pulls the crate in from the far side",
			loadout = { "Freezer", "Magnet" },
			steps = {
				{ deploy = "S1", room = "Freezer" },
				{ cross = "B1", by = "ice" },
				{ cross = "F1", by = "walkway" },
				{ cross = "G2", by = "beam" },
				{ cross = "G1", by = "beam" },
				{ deploy = "S6", room = "Magnet" },
				{ pull = "LV1" },
				{ capture = true },
				{ cross = "G1", by = "crate" },
				{ cross = "G2", by = "beam" },
				{ cross = "F1", by = "walkway" },
				{ cross = "B1", by = "ice" },
				{ escape = true },
			},
			combos = { "ice_bridge", "crate_bridge" },
			keys = { "K1", "K2", "K3" },
		},
	},
}

return layout
