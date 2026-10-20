--!strict
--[[
	L2 "Frostbite Floor" (M2, frost wing, difficulty 2).

	Route: elevator -> ice slide B1 into the launch gap G1 -> right through two luggage-cart tracks -> left
	across the pond B2 -> right to the Freezer Room.

	Obstacles and their solutions:
	  B1 pool (1 tile, deep)  Freezer at S1 freezes it | ledge on the left
	  G1 broken floor         Freezer (S1) + Fan blowing Forward (S2) = ice launch (challenge) | beam on the right
	                          (the launch is one-way: the beam is the way back)
	  CT1 carts               Fan at S3 blowing Across pins the cart | Freezer at S3 slows it | timing
	  CT2 carts (faster)      Freezer at S3 slows it too | timing
	  B2 pond (2 tiles)       Freezer at S4 | ledge on the left
	Keys: K1 on the landing, K2 past the pond, K3 in the Lost & Found alcove (lever LV1 around the corner).
]]
local LayoutTypes = require(script.Parent.Parent.Parent.World.LayoutTypes)

local layout: LayoutTypes.LayoutDef = {
	id = "L2",
	nameKey = "mission.M2.name",
	theme = "frost",
	seed = 1201,
	roomNumberBase = 210,
	modules = {
		{ kind = "Elevator" },
		{ kind = "Hall", len = 1, sockets = { [1] = { R = "S1" } } },
		{ kind = "Hall", len = 1, sockets = { [1] = { L = "S2" } } },
		{ kind = "Basin", id = "B1", len = 1, wet = true, ledge = "L" },
		{ kind = "Gap", id = "G1", len = 1, launch = true, beam = "R" },
		{ kind = "Hall", len = 1, keys = { { id = "K1", at = 1, lateral = -4.5, along = 2 } } },
		{ kind = "Turn", dir = "R" },
		{ kind = "Hall", len = 1 },
		{ kind = "Carts", id = "CT1", sockets = { [1] = { L = "S3" } } },
		{ kind = "Hall", len = 1 },
		{ kind = "Carts", id = "CT2", cartSpeed = 11 },
		{ kind = "Hall", len = 1 },
		{ kind = "Turn", dir = "L" },
		{ kind = "Hall", len = 1, sockets = { [1] = { R = "S4" } } },
		{ kind = "Basin", id = "B2", len = 2, wet = true, ledge = "L" },
		{
			kind = "Hall",
			len = 1,
			alcoves = { { id = "A1", at = 1, side = "R", gate = "GT1", key = "K3" } },
			keys = { { id = "K2", at = 1, lateral = -4.5, along = -3 } },
		},
		{ kind = "Turn", dir = "R" },
		{ kind = "Hall", len = 2, levers = { { id = "LV1", at = 1, side = "L" } } },
		{ kind = "Target", room = "Freezer" },
	},
	sockets = {
		S1 = { cold = { "B1" } },
		S2 = { wind = { "Forward", "Backward" } },
		S3 = { wind = { "Across" }, cold = { "CT1", "CT2" } },
		S4 = { cold = { "B2" } },
	},
	gates = {
		GT1 = { signals = { "lever:LV1" } },
	},
	caretaker = { patrolFrom = 8, patrolTo = 20, spawn = 14 },
	solutions = {
		{
			name = "starter: ice launch, pin the cart, freeze the pond",
			loadout = { "Freezer", "Fan" },
			steps = {
				{ deploy = "S1", room = "Freezer" },
				{ deploy = "S2", room = "Fan", dir = "Forward" },
				{ cross = "B1", by = "ice" },
				{ cross = "G1", by = "launch" },
				{ recall = "Fan" },
				{ deploy = "S3", room = "Fan", dir = "Across" },
				{ cross = "CT1", by = "pin" },
				{ cross = "CT2", by = "timing" },
				{ recall = "Freezer" },
				{ deploy = "S4", room = "Freezer" },
				{ cross = "B2", by = "ice" },
				{ pull = "LV1" },
				{ capture = true },
				{ cross = "B2", by = "ice" },
				{ cross = "CT2", by = "timing" },
				{ cross = "CT1", by = "pin" },
				{ cross = "G1", by = "beam" },
				{ cross = "B1", by = "ledge" },
				{ escape = true },
			},
			combos = { "ice_launch", "cart_pin", "ice_bridge" },
			keys = { "K1", "K2", "K3" },
		},
		{
			name = "careful: ledges, beam and a chilled cart track",
			loadout = { "Freezer", "Fan" },
			steps = {
				{ cross = "B1", by = "ledge" },
				{ cross = "G1", by = "beam" },
				{ deploy = "S3", room = "Freezer" },
				{ cross = "CT1", by = "slow" },
				{ cross = "CT2", by = "slow" },
				{ cross = "B2", by = "ledge" },
				{ pull = "LV1" },
				{ capture = true },
				{ cross = "B2", by = "ledge" },
				{ cross = "CT2", by = "slow" },
				{ cross = "CT1", by = "slow" },
				{ cross = "G1", by = "beam" },
				{ cross = "B1", by = "ledge" },
				{ escape = true },
			},
			combos = { "cart_freeze" },
			keys = { "K1", "K2", "K3" },
		},
	},
}

return layout
