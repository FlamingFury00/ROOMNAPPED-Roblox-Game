--!strict
-- L0 "Check-In": first-time onboarding route (S24). Walk -> select Freezer -> unfold it at S1 -> cross the
-- frozen flood -> steal the Laundry Room -> escape. The caretaker sleeps until the capture.
local LayoutTypes = require(script.Parent.Parent.Parent.World.LayoutTypes)

local layout: LayoutTypes.LayoutDef = {
	id = "L0",
	nameKey = "mission.M0.name",
	theme = "classic",
	seed = 1001,
	roomNumberBase = 100,
	tutorial = true,
	modules = {
		{ kind = "Elevator" },
		{ kind = "Hall", len = 2 },
		{ kind = "Hall", len = 1, sockets = { [1] = { R = "S1" } } },
		{ kind = "Basin", id = "B1", len = 2, wet = true, ledge = "L" },
		{ kind = "Hall", len = 1, keys = { { id = "K1", at = 1, lateral = 4.5, along = 3 } } },
		{ kind = "Turn", dir = "L" },
		{ kind = "Hall", len = 2, sockets = { [1] = { R = "S2" } } },
		{ kind = "Target", room = "Laundry" },
	},
	sockets = {
		S1 = { cold = { "B1" }, wind = { "Forward", "Backward" } },
		S2 = { wind = { "Forward", "Backward" } },
	},
	caretaker = { dormant = true },
	solutions = {}, -- the tutorial is a scripted single path (S24)
}

return layout
