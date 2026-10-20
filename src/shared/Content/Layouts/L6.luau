--!strict
--[[
	L6 "Magnet Vault" (M6, vault wing, difficulty 3).

	Route: elevator -> crate gap G1 -> charged floor P1 -> left over the vault cart track CT1 -> the weighing hall
	(metal crates C2 and C3, plate PL1, vault alcove A1) -> crate gap G2 -> right over charged floor P2 -> the
	express cart CT2 -> the Magnet Room.

	Every crate is metal: Fans push them (the starter answer) and a Magnet pulls them toward its door from the
	far side of a gap. The Magnet is this mission's prize, so it is never required.

	Vault twist: alcove A1 only opens while plate PL1 is weighed down AND circuit PW1 is live, so a player who
	wants key K2 freezes the charged floor P1 instead of switching it off.

	Obstacles and their solutions:
	  G1 crate gap        Fan at S1 blows C1 in | Magnet at S2 pulls it in from the far side | beam on the left
	  P1 charged floor    Freezer at S3 | switch LV1 (both on P1's own tile, usable from either side)
	  CT1 vault carts     Fan at S4 Across pins it | Freezer at S4 chills it | timing
	  G2 crate gap        Fan at S5 blows C3 in (and C2 onto PL1) | Magnet at S6 pulls C3 in | beam on the right
	  P2 charged floor    switch LV2 | Freezer at S7 (both on P2's tile)
	  CT2 express cart    Fan at S8 Across | Freezer at S8 | timing
	Keys: K1 on the G1 beam, K2 in the vault alcove A1, K3 on the G2 beam.
]]
local LayoutTypes = require(script.Parent.Parent.Parent.World.LayoutTypes)

local layout: LayoutTypes.LayoutDef = {
	id = "L6",
	nameKey = "mission.M6.name",
	theme = "vault",
	seed = 1601,
	roomNumberBase = 610,
	modules = {
		{ kind = "Elevator" },
		{
			kind = "Hall",
			len = 2,
			sockets = { [1] = { R = "S1" } },
			crates = { { id = "C1", at = 2, lateral = 0, metal = true } },
		},
		{
			kind = "Gap",
			id = "G1",
			len = 1,
			slot = "C1",
			beam = "L",
			keys = { { id = "K1", at = 1, lateral = -6.1, along = 0 } },
		},
		{ kind = "Hall", len = 1, sockets = { [1] = { R = "S2" } } },
		{
			kind = "Puddle",
			id = "P1",
			power = "PW1",
			sockets = { [1] = { L = "S3" } },
			levers = { { id = "LV1", at = 1, side = "R" } },
		},
		{ kind = "Hall", len = 1 },
		{ kind = "Turn", dir = "L" },
		{ kind = "Carts", id = "CT1", sockets = { [1] = { R = "S4" } } },
		{
			kind = "Hall",
			len = 2,
			sockets = { [1] = { R = "S5" } },
			crates = {
				{ id = "C2", at = 1, lateral = -4.2, along = 0, metal = true },
				{ id = "C3", at = 2, lateral = 1.6, along = 0, metal = true },
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
		{ kind = "Hall", len = 2, sockets = { [1] = { L = "S6" } } },
		{ kind = "Turn", dir = "R" },
		{
			kind = "Puddle",
			id = "P2",
			power = "PW2",
			sockets = { [1] = { L = "S7" } },
			levers = { { id = "LV2", at = 1, side = "R" } },
		},
		{ kind = "Hall", len = 1 },
		{ kind = "Carts", id = "CT2", cartSpeed = 12, sockets = { [1] = { R = "S8" } } },
		{ kind = "Hall", len = 1 },
		{ kind = "Target", room = "Magnet" },
	},
	sockets = {
		S1 = { wind = { "Forward", "Backward" } },
		S2 = { magnet = { "C1" }, wind = { "Forward", "Backward" } },
		S3 = { cold = { "P1" } },
		S4 = { wind = { "Across" }, cold = { "CT1" } },
		S5 = { wind = { "Forward", "Backward" } },
		S6 = { magnet = { "C3" }, wind = { "Forward", "Backward" } },
		S7 = { cold = { "P2" } },
		S8 = { wind = { "Across" }, cold = { "CT2" } },
	},
	powers = {
		PW1 = { default = true, levers = { "LV1" } },
		PW2 = { default = true, levers = { "LV2" } },
	},
	gates = {
		GT1 = { signals = { "plate:PL1", "power:PW1" }, mode = "all" },
	},
	caretaker = { patrolFrom = 8, patrolTo = 19, spawn = 13 },
	solutions = {
		{
			name = "starter: wind-blown crates, a frozen floor and the vault key",
			loadout = { "Freezer", "Fan" },
			steps = {
				{ deploy = "S1", room = "Fan", dir = "Forward" },
				{ cross = "G1", by = "crate" },
				{ deploy = "S3", room = "Freezer" },
				{ cross = "P1", by = "power" },
				{ recall = "Fan" },
				{ deploy = "S4", room = "Fan", dir = "Across" },
				{ cross = "CT1", by = "pin" },
				{ recall = "Fan" },
				{ deploy = "S5", room = "Fan", dir = "Forward" },
				{ cross = "G2", by = "beam" },
				{ pull = "LV2" },
				{ cross = "P2", by = "power" },
				{ recall = "Fan" },
				{ deploy = "S8", room = "Fan", dir = "Across" },
				{ cross = "CT2", by = "pin" },
				{ capture = true },
				{ cross = "CT2", by = "pin" },
				{ cross = "P2", by = "power" },
				{ cross = "G2", by = "crate" },
				{ cross = "CT1", by = "timing" },
				{ cross = "P1", by = "power" },
				{ cross = "G1", by = "beam" },
				{ escape = true },
			},
			combos = { "crate_bridge", "crate_plate", "frozen_safe", "power_off", "cart_pin" },
			keys = { "K1", "K2", "K3" },
		},
		{
			name = "lights out: switches, chilled tracks, beams",
			loadout = { "Freezer", "Fan" },
			steps = {
				{ cross = "G1", by = "beam" },
				{ pull = "LV1" },
				{ cross = "P1", by = "power" },
				{ deploy = "S4", room = "Freezer" },
				{ cross = "CT1", by = "slow" },
				{ cross = "G2", by = "beam" },
				{ pull = "LV2" },
				{ cross = "P2", by = "power" },
				{ deploy = "S8", room = "Fan", dir = "Across" },
				{ cross = "CT2", by = "pin" },
				{ capture = true },
				{ cross = "CT2", by = "pin" },
				{ cross = "P2", by = "power" },
				{ cross = "G2", by = "beam" },
				{ cross = "CT1", by = "slow" },
				{ cross = "P1", by = "power" },
				{ cross = "G1", by = "beam" },
				{ escape = true },
			},
			combos = { "power_off", "cart_freeze", "cart_pin" },
			keys = { "K1", "K3" },
		},
		{
			name = "collector: magnets pull every crate into place",
			loadout = { "Magnet", "Freezer" },
			steps = {
				{ cross = "G1", by = "beam" },
				{ deploy = "S2", room = "Magnet" },
				{ deploy = "S3", room = "Freezer" },
				{ cross = "P1", by = "power" },
				{ cross = "CT1", by = "timing" },
				{ cross = "G2", by = "beam" },
				{ recall = "Magnet" },
				{ deploy = "S6", room = "Magnet" },
				{ recall = "Freezer" },
				{ deploy = "S7", room = "Freezer" },
				{ cross = "P2", by = "power" },
				{ cross = "CT2", by = "timing" },
				{ capture = true },
				{ cross = "CT2", by = "timing" },
				{ cross = "P2", by = "power" },
				{ cross = "G2", by = "crate" },
				{ cross = "CT1", by = "timing" },
				{ pull = "LV1" },
				{ cross = "P1", by = "power" },
				{ cross = "G1", by = "crate" },
				{ escape = true },
			},
			combos = { "crate_bridge", "frozen_safe", "power_off" },
			keys = { "K1", "K3" },
		},
	},
}

return layout
