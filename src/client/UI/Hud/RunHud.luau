--!strict
--[[
	RunHud: assembles the in-run HUD (U02-U12) on the responsive HUD root and shows each part only when it
	applies: the objective column is always visible (it also guides the lobby), while hearts, team, quickbar,
	touch actions and overlays appear only for players taking part in an expedition.
]]

local RunInfo = require(script.Parent.Parent.Parent.Core.RunInfo)
local UIRoot = require(script.Parent.Parent.UIRoot)
local Objective = require(script.Parent.Parent.Run.Objective)
local Vitals = require(script.Parent.Parent.Run.Vitals)
local Quickbar = require(script.Parent.Parent.Run.Quickbar)
local Overlays = require(script.Parent.Parent.Run.Overlays)

local RunHud = {}
RunHud.priority = 90

function RunHud.start()
	local root = UIRoot.Hud
	local objective = Objective.create(root)
	local vitals = Vitals.create(root)
	local quickbar = Quickbar.create(root)
	local overlays = Overlays.create(root)

	local function refresh()
		local participant = RunInfo.isParticipant()
		local active = participant and RunInfo.isActivePhase()
		objective.setVisible(true)
		vitals.setVisible(participant)
		quickbar.setVisible(active)
		overlays.setVisible(participant or RunInfo.phase() == "Results")
	end
	RunInfo.PhaseChanged:Connect(refresh)
	RunInfo.RosterChanged:Connect(refresh)
	RunInfo.StatusChanged:Connect(refresh)
	refresh()
end

return RunHud
