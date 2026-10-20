--!strict
--[[
	Objective: the top-centre column (U02, U08).

	  [ objective pill ............ ] [ keys 1/3 ]
	        [ threat: eye "Patrolling" ] [ clock 0:47 ]

	The objective always tells you what to do next (lobby and run). Below it the Caretaker threat shows its
	behaviour with an icon and a word (never colour alone) and, after the capture, the escape countdown takes
	the spotlight: it grows, turns orange and then pulses red in the final warning window. The countdown is
	computed from the replicated server deadline, so every client shows the same number.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.Config.GameConfig)
local RoomDefs = require(Shared.Config.RoomDefs)
local Strings = require(Shared.Config.Strings)
local ClientState = require(script.Parent.Parent.Parent.Core.ClientState)
local RunInfo = require(script.Parent.Parent.Parent.Core.RunInfo)
local Theme = require(script.Parent.Parent.Theme)
local Create = require(script.Parent.Parent.Create)
local Icons = require(script.Parent.Parent.Icons)
local Motion = require(script.Parent.Parent.Motion)
local Components = require(script.Parent.Parent.Components)

local Objective = {}

local C = Theme.Colors
local localPlayer = Players.LocalPlayer

local THREAT_ICON: { [string]: string } = {
	Dormant = "zzz",
	Patrol = "eyeClosed",
	Investigate = "eye",
	Search = "eye",
	Chase = "alert",
	Hunt = "alert",
	Lunge = "alert",
	Alert = "alert",
	React = "star",
	Phase = "wind",
	Off = "eyeClosed",
}

local THREAT_COLOR: { [string]: Color3 } = {
	Dormant = C.blue,
	Patrol = C.green,
	Investigate = C.orange,
	Search = C.orange,
	Chase = C.red,
	Hunt = C.red,
	Lunge = C.red,
	Alert = C.red,
	React = C.goldLight,
	Phase = C.purple,
	Off = C.textMuted,
}

export type Handle = { frame: Frame, setVisible: (boolean) -> () }

function Objective.create(parent: Instance): Handle
	local column = Create.new("Frame", {
		Name = "ObjectiveColumn",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 10),
		Size = UDim2.fromOffset(760, 140),
		BackgroundTransparency = 1,
		Parent = parent,
	}, {
		Create.list(Enum.FillDirection.Vertical, 8, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Top),
	})

	-- Objective row --------------------------------------------------------------------------------------
	local topRow = Create.new("Frame", {
		Name = "TopRow",
		Size = UDim2.fromOffset(0, 52),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundTransparency = 1,
		LayoutOrder = 1,
		Parent = column,
	}, {
		Create.list(Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center),
	})
	local pill = Create.new("Frame", {
		Name = "Objective",
		Size = UDim2.fromOffset(0, 50),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = C.panelDark,
		BackgroundTransparency = 0.12,
		LayoutOrder = 1,
		Parent = topRow,
	}, {
		Create.corner(Theme.Radius.pill),
		Create.stroke(C.gold, 2.5, 0.1),
		Create.padding(6, 20),
		Create.list(Enum.FillDirection.Horizontal, 10, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center),
	})
	local objectiveIconHolder = Create.new("Frame", {
		Name = "IconHolder",
		Size = UDim2.fromOffset(30, 30),
		BackgroundTransparency = 1,
		LayoutOrder = 1,
		Parent = pill,
	})
	local objectiveIcon: Frame? = nil
	local objectiveText = Components.label({
		name = "Text",
		text = "",
		font = Theme.Fonts.heading,
		textSize = Theme.Text.medium,
		size = UDim2.fromOffset(0, 38),
		autoSize = Enum.AutomaticSize.X,
		stroke = true,
		layoutOrder = 2,
		parent = pill,
	})
	Create.new("UISizeConstraint", { MaxSize = Vector2.new(560, 40), Parent = objectiveText })
	objectiveText.TextTruncate = Enum.TextTruncate.AtEnd

	local keysChip = Create.new("Frame", {
		Name = "Keys",
		Size = UDim2.fromOffset(0, 44),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = C.panelDark,
		BackgroundTransparency = 0.12,
		LayoutOrder = 2,
		Visible = false,
		Parent = topRow,
	}, {
		Create.corner(Theme.Radius.pill),
		Create.stroke(C.gold, 2, 0.3),
		Create.padding(4, 14),
		Create.list(Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center),
	})
	local keyIconHolder = Create.new(
		"Frame",
		{ Size = UDim2.fromOffset(26, 26), BackgroundTransparency = 1, LayoutOrder = 1, Parent = keysChip }
	)
	Icons.make("key", C.gold, C.ink).Parent = keyIconHolder
	local keysText = Components.label({
		text = "",
		font = Theme.Fonts.heading,
		textSize = Theme.Text.body,
		size = UDim2.fromOffset(0, 32),
		autoSize = Enum.AutomaticSize.X,
		color = C.goldLight,
		stroke = true,
		layoutOrder = 2,
		parent = keysChip,
	})

	-- Threat + escape row ------------------------------------------------------------------------------------
	local secondRow = Create.new("Frame", {
		Name = "SecondRow",
		Size = UDim2.fromOffset(0, 64),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundTransparency = 1,
		LayoutOrder = 2,
		Parent = column,
	}, {
		Create.list(Enum.FillDirection.Horizontal, 10, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center),
	})

	local threat = Create.new("Frame", {
		Name = "Threat",
		Size = UDim2.fromOffset(0, 42),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = C.panelDark,
		BackgroundTransparency = 0.15,
		LayoutOrder = 1,
		Visible = false,
		Parent = secondRow,
	}, {
		Create.corner(Theme.Radius.pill),
		Create.padding(4, 14),
		Create.list(Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center),
	})
	local threatStroke = Create.stroke(C.green, 2.5, 0)
	threatStroke.Parent = threat
	local threatIconHolder = Create.new(
		"Frame",
		{ Size = UDim2.fromOffset(28, 28), BackgroundTransparency = 1, LayoutOrder = 1, Parent = threat }
	)
	local threatIcon: Frame? = nil
	local threatText = Components.label({
		text = "",
		font = Theme.Fonts.heading,
		textSize = Theme.Text.body,
		size = UDim2.fromOffset(0, 30),
		autoSize = Enum.AutomaticSize.X,
		stroke = true,
		layoutOrder = 2,
		parent = threat,
	})
	local chilledChip = Components.chip("snowflake", Strings.t("hud.threat.chilled"), C.blue, 3)
	chilledChip.Visible = false
	chilledChip.Parent = threat
	local bracedChip = Components.chip("wind", Strings.t("hud.threat.braced"), C.panelLight, 4)
	bracedChip.Visible = false
	bracedChip.Parent = threat

	local timer = Create.new("Frame", {
		Name = "EscapeTimer",
		Size = UDim2.fromOffset(196, 64),
		BackgroundColor3 = C.panelDark,
		BackgroundTransparency = 0.1,
		LayoutOrder = 2,
		Visible = false,
		Parent = secondRow,
	}, { Create.corner(Theme.Radius.large) })
	local timerStroke = Create.stroke(C.orange, 3, 0)
	timerStroke.Parent = timer
	local clockHolder = Create.new("Frame", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 12, 0.5, -4),
		Size = UDim2.fromOffset(34, 34),
		BackgroundTransparency = 1,
		Parent = timer,
	})
	Icons.make("clock", C.text, C.panelDark).Parent = clockHolder
	local timerText = Components.label({
		text = "1:30",
		font = Theme.Fonts.display,
		textSize = 44,
		align = Enum.TextXAlignment.Center,
		size = UDim2.new(1, -56, 1, -10),
		position = UDim2.fromOffset(52, 0),
		stroke = true,
		parent = timer,
	})
	local timerBar = Components.bar(UDim2.new(1, -24, 0, 6), C.orange, timer)
	timerBar.frame.AnchorPoint = Vector2.new(0.5, 1)
	timerBar.frame.Position = UDim2.new(0.5, 0, 1, -6)

	-- State ----------------------------------------------------------------------------------------------------
	local lastObjectiveKey = ""
	local lastThreat = ""
	local lastSecond = -1

	local function objectiveFor(): (string, string, { [string]: any }?)
		local phase = RunInfo.phase()
		local status = RunInfo.myStatus()
		if not RunInfo.isParticipant() then
			local me = ClientState.get("global", "players." .. RunInfo.myKey())
			if RunInfo.inRunPhase() and type(me) == "table" and me.waiting then
				return "objective.lobbyWaiting", "clock", nil
			end
			return "objective.lobby", "door", nil
		end
		if status == "Eliminated" then
			return "objective.spectating", "eye", nil
		elseif status == "Downed" or status == "Recovering" then
			return "objective.downed", "heart", nil
		end
		local level = RunInfo.level()
		local roomId = if level and level.target then level.target.room else ""
		local def = RoomDefs.get(roomId)
		local roomName = if def then Strings.t(def.nameKey) else roomId
		if phase == "Launching" then
			return "objective.launching", "arrowUp", nil
		elseif phase == "Explore" then
			return if RunInfo.isTutorial() then "objective.exploreTutorial" else "objective.explore",
				"suitcase",
				{ room = roomName }
		elseif phase == "Capture" then
			return "objective.capture", "star", nil
		elseif phase == "Escape" then
			local cargo = ClientState.get("global", "cargo") or {}
			if cargo.state == "Dropped" then
				return "objective.escapeDropped", "alert", nil
			elseif cargo.state == "Carried" and cargo.carrier == RunInfo.myKey() then
				return "objective.escapeCarry", "suitcase", nil
			end
			return "objective.escape", "arrowUp", nil
		elseif phase == "Results" then
			return "objective.results", "trophy", nil
		end
		return "objective.lobby", "door", nil
	end

	local function refreshObjective()
		local key, icon, params = objectiveFor()
		local full = key .. icon .. (if params then tostring(params.room) else "")
		if full == lastObjectiveKey then
			return
		end
		lastObjectiveKey = full
		objectiveText.Text = Strings.t(key, params)
		if objectiveIcon then
			objectiveIcon:Destroy()
		end
		local made = Icons.make(icon, C.gold, C.ink)
		made.Parent = objectiveIconHolder
		objectiveIcon = made
		Motion.pop(pill, 0.9)
	end

	local function refreshKeys()
		local level = RunInfo.level()
		local total = 0
		if level and type(level.keys) == "table" then
			for _ in level.keys do
				total += 1
			end
		end
		local taken = 0
		local keys = ClientState.get("global", "keys")
		if type(keys) == "table" then
			for _ in keys do
				taken += 1
			end
		end
		keysChip.Visible = total > 0 and RunInfo.isParticipant()
		keysText.Text = Strings.t("hud.keys", { count = taken, total = total })
	end

	local function refreshThreat()
		local state = ClientState.get("global", "caretaker")
		local mode = if type(state) == "table" then state.mode else nil
		local visible = RunInfo.isParticipant()
			and RunInfo.isActivePhase()
			and type(mode) == "string"
			and mode ~= "Gone"
		threat.Visible = visible
		if not visible then
			lastThreat = ""
			return
		end
		chilledChip.Visible = state.chilled == true
		bracedChip.Visible = state.braced == true
		if mode == lastThreat then
			return
		end
		lastThreat = mode
		local color = THREAT_COLOR[mode] or C.textMuted
		threatText.Text = Strings.t("hud.threat." .. mode)
		threatStroke.Color = color
		if threatIcon then
			threatIcon:Destroy()
		end
		local made = Icons.make(THREAT_ICON[mode] or "eye", color, C.ink)
		made.Parent = threatIconHolder
		threatIcon = made
		Motion.pop(threat, 0.85)
		if mode == "Chase" or mode == "Hunt" or mode == "Alert" then
			Motion.shake(threat)
		end
	end

	local function refreshTimer()
		local run = RunInfo.run()
		local endsAt = run.escapeEndsAt
		local phase = RunInfo.phase()
		local visible = RunInfo.isParticipant()
			and (phase == "Escape" or phase == "Capture")
			and type(endsAt) == "number"
		timer.Visible = visible
		if not visible then
			lastSecond = -1
			return
		end
		local remaining = math.max(0, endsAt - RunInfo.serverNow())
		local seconds = math.ceil(remaining)
		timerBar.set(remaining / GameConfig.Escape.WindowSeconds)
		local warning = remaining <= GameConfig.Escape.WarningSeconds
		local color = if warning then C.red elseif remaining <= 45 then C.orange else C.gold
		timerStroke.Color = color
		timerBar.setColor(color)
		timerText.TextColor3 = if warning then C.red:Lerp(C.white, 0.35 + 0.35 * math.sin(os.clock() * 8)) else C.text
		if seconds ~= lastSecond then
			lastSecond = seconds
			timerText.Text = string.format("%d:%02d", seconds // 60, seconds % 60)
			if warning then
				Motion.pop(timer, 0.92)
			end
			if seconds == GameConfig.Escape.WarningSeconds then
				Components.sound("ui_countdown_tick")
			end
		end
	end

	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt: number)
		accumulator += dt
		refreshTimer()
		if accumulator >= 0.15 then
			accumulator = 0
			refreshObjective()
			refreshKeys()
			refreshThreat()
		end
	end)
	localPlayer:GetAttributeChangedSignal("Downed"):Connect(refreshObjective)

	return {
		frame = column,
		setVisible = function(value: boolean)
			column.Visible = value
		end,
	}
end

return Objective
