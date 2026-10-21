--!strict
--[[
	Results: the end-of-expedition panel (U18, S14, S22).

	Opens by itself when the run ends and this player's results arrive. It shows the outcome, the run stats
	(time, time to spare, keys, best combo), the headline reward (new room blueprint, targeted skin or
	duplicate credits) and the full credit breakdown, and it tracks the save honestly: "Saving..." until the
	server confirms, "Saved" only after a confirmed write, and a clear error otherwise. A failed run says
	plainly that nothing owned was lost. PLAY AGAIN queues the player for the next run; LOBBY returns.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local MissionDefs = require(Shared.Config.MissionDefs)
local RoomDefs = require(Shared.Config.RoomDefs)
local Strings = require(Shared.Config.Strings)
local Net = require(Shared.Net.Net)
local ClientState = require(script.Parent.Parent.Parent.Core.ClientState)
local RunInfo = require(script.Parent.Parent.Parent.Core.RunInfo)
local Theme = require(script.Parent.Parent.Theme)
local Create = require(script.Parent.Parent.Create)
local Components = require(script.Parent.Parent.Components)
local Icons = require(script.Parent.Parent.Icons)
local Motion = require(script.Parent.Parent.Motion)
local UIRoot = require(script.Parent.Parent.UIRoot)
local Common = require(script.Parent.Common)

type ButtonHandle = Components.ButtonHandle

local Results = {}
Results.priority = 100

local C = Theme.Colors

local window: Common.Window
local headline: TextLabel
local headlineGradient: UIGradient
local subtitle: TextLabel
local rewardCard: Frame
local statsRow: Frame
local linesList: ScrollingFrame
local totalLabel: TextLabel
local savingRow: Frame
local savingIcon: Frame
local savingLabel: TextLabel
local breakdown: Frame
local buttonRow: Frame
local lobbyButton: ButtonHandle
local replayButton: ButtonHandle
-- Short windows (phones) use a compact layout: smaller headline, reward art and buttons.
local compact = false
local breakdownHeight = 254

local shownRunId: string? = nil
local actedRunId: string? = nil
local planShownFor: string? = nil -- run whose reward plan is on screen (rendered once, then only the save state)
local renderedKey = ""
local spinnerConnection: RBXScriptConnection? = nil
local raysConnection: RBXScriptConnection? = nil
local countToken = 0

-- Called after the player leaves the results panel with "lobby" or "replay" (Feedback uses this to decide
-- whether to ask).
local closedCallbacks: { (any, string) -> () } = {}

function Results.onClosed(fn: (payload: any, action: string) -> ())
	table.insert(closedCallbacks, fn)
end

-- Helpers -------------------------------------------------------------------------------------------------------

local function payload(): any
	local value = ClientState.get("me", "results")
	return if type(value) == "table" then value else nil
end

local function runId(): string?
	local run = RunInfo.run()
	return if type(run.id) == "string" then run.id else nil
end

local function clear(frame: Instance)
	for _, child in frame:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

local function comboName(id: string?): string
	if not id then
		return ""
	end
	return Strings.t("combo." .. id)
end

local function lineText(line: any): string
	local key = line.key
	if key == "reward.blueprint" or key == "reward.duplicate" then
		return Strings.t(key, { item = Common.roomName(line.item) })
	elseif key == "reward.skin" then
		return Strings.t(key, { item = Common.skinName(line.item) })
	elseif key == "reward.challenge" then
		local challenge = if type(line.item) == "string" then Common.findChallenge(line.item) else nil
		local name = if challenge then Common.challengeText(challenge) else ""
		return Strings.t("reward.challenge") .. (if name ~= "" then ": " .. name else "")
	end
	return Strings.t(key)
end

-- Rendering ---------------------------------------------------------------------------------------------------------

local function stopRays()
	if raysConnection then
		raysConnection:Disconnect()
		raysConnection = nil
	end
end

-- Slowly turning beams of light behind a reward (still with reduced motion).
local function rays(parent: Instance, color: Color3, size: number, center: UDim2)
	stopRays()
	local holder = Create.new("Frame", {
		Name = "Rays",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = center,
		Size = UDim2.fromOffset(size, size),
		Parent = parent,
	})
	for i = 0, 5 do
		local beam = Create.new("Frame", {
			BackgroundColor3 = color,
			BackgroundTransparency = 0.5,
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.new(0, math.floor(size * 0.13), 1, 0),
			Rotation = i * 30,
			Parent = holder,
		})
		Create.new("UIGradient", {
			Rotation = 90,
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1),
				NumberSequenceKeypoint.new(0.5, 0),
				NumberSequenceKeypoint.new(1, 1),
			}),
			Parent = beam,
		})
	end
	if not Motion.isReduced() then
		raysConnection = RunService.RenderStepped:Connect(function(dt: number)
			holder.Rotation = (holder.Rotation + dt * 18) % 360
		end)
	end
end

-- Counts the credit total up from zero once the reward lines have landed (instant with reduced motion).
local function countUp(amount: number, delaySeconds: number)
	countToken += 1
	local token = countToken
	local function show(value: number)
		totalLabel.Text = Strings.t("results.totalCredits", { amount = value })
	end
	if Motion.isReduced() or amount <= 0 then
		show(amount)
		return
	end
	show(0)
	task.delay(delaySeconds, function()
		if token ~= countToken then
			return
		end
		Components.sound("ui_coin")
		local duration = math.clamp(0.35 + amount / 220, 0.5, 1.3)
		local elapsed = 0
		while token == countToken and elapsed < duration do
			elapsed += task.wait()
			local t = math.min(1, elapsed / duration)
			show(math.floor(amount * (1 - (1 - t) ^ 3) + 0.5))
		end
		if token == countToken then
			show(amount)
			Motion.pop(totalLabel, 0.85)
		end
	end)
end

local function bigIcon(parent: Instance, icon: string, color: Color3, size: number, position: UDim2)
	local back = Create.new("Frame", {
		Name = "BigIcon",
		BackgroundColor3 = color,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = position,
		Size = UDim2.fromOffset(size, size),
		Parent = parent,
	}, { Create.corner(Theme.Radius.pill), Create.stroke(C.white, 4, 0.2) })
	local inner = Create.new("Frame", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.64, 0.64),
		Parent = back,
	})
	Icons.make(icon, C.white, color:Lerp(C.black, 0.4)).Parent = inner
	Motion.pop(back, 0.4)
end

local function renderRewardCard(data: any)
	stopRays()
	clear(rewardCard)
	local plan = data.plan
	local title: string
	local name: string
	local icon: string
	local color: Color3
	if not data.success then
		title = Strings.t("results.noRewardTitle")
		name = Strings.t("reward.nothing")
		icon = "heart"
		color = C.panelLight
	elseif type(plan) == "table" and plan.blueprint then
		local def = RoomDefs.byId[plan.blueprint]
		title = Strings.t("results.newRoom")
		name = Common.roomName(plan.blueprint)
		icon = Icons.roomIcon[plan.blueprint] or "star"
		color = if def then def.color else C.gold
	elseif type(plan) == "table" and plan.skin then
		title = Strings.t("results.newSkin")
		name = Common.skinName(plan.skin)
		icon = "palette"
		color = C.purple
	elseif type(plan) == "table" then
		title = Strings.t("results.creditsTitle")
		name = Strings.t("reward.credits", { amount = plan.credits or 0 })
		icon = "coin"
		color = C.gold
	else
		title = Strings.t("results.newRoom")
		name = Strings.t("results.saving")
		icon = "clock"
		color = C.panelLight
	end
	-- Rays first so the title and the icon draw over them.
	local iconSize = if compact then 78 else 116
	local iconTop = if compact then 48 else 52
	if data.success and type(plan) == "table" then
		rays(rewardCard, color:Lerp(C.white, 0.35), iconSize * 2, UDim2.new(0.5, 0, 0, iconTop + iconSize // 2))
	end
	Components.label({
		text = title,
		font = Theme.Fonts.display,
		textSize = 30,
		color = C.goldLight,
		align = Enum.TextXAlignment.Center,
		size = UDim2.new(1, -20, 0, 36),
		position = UDim2.fromOffset(10, 10),
		stroke = true,
		parent = rewardCard,
	})
	bigIcon(rewardCard, icon, color, iconSize, UDim2.new(0.5, 0, 0, iconTop))
	local nameLabel = Components.label({
		text = name,
		font = Theme.Fonts.heading,
		textSize = Theme.Text.large,
		align = Enum.TextXAlignment.Center,
		wrap = true,
		size = UDim2.new(1, -24, 0, if compact then 36 else 64),
		position = UDim2.fromOffset(12, if compact then 134 else 176),
		stroke = true,
		parent = rewardCard,
	})
	nameLabel.TextYAlignment = Enum.TextYAlignment.Top
end

local function renderStats(data: any)
	clear(statsRow)
	local order = 0
	local function add(icon: string, text: string, color: Color3)
		order += 1
		Components.chip(icon, text, color, order).Parent = statsRow
	end
	if data.success and data.newBest == true then
		add("trophy", Strings.t("results.newBest", { time = Common.formatTime(data.duration) }), C.goldDark)
		local chip = statsRow:FindFirstChild("Chip")
		if chip and chip:IsA("GuiObject") then
			Motion.pop(chip, 0.6)
		end
	else
		add("clock", Strings.t("results.time", { time = Common.formatTime(data.duration) }), C.panelLight)
	end
	if data.success and (data.timeLeft or 0) > 0 then
		add("bolt", Strings.t("results.timeLeft", { seconds = data.timeLeft }), C.blue)
	end
	if (data.keysTotal or 0) > 0 then
		add("key", Strings.t("results.keys", { count = data.keys or 0, total = data.keysTotal }), C.goldDark)
	end
	if type(data.combo) == "string" then
		add("star", Strings.t("results.combo", { combo = comboName(data.combo) }), C.purple)
	end
end

-- Height the total takes under the list.
local function totalReserve(): number
	return if compact then 44 else 56
end

-- Reward lines shrink so every line fits without scrolling: the longest plan (six lines) on a desktop, and on a
-- phone (which leaves the room or skin to the reward card) five credit lines.
local function lineHeight(count: number): number
	local available = breakdownHeight - totalReserve() - 12 - 4 * math.max(0, count - 1)
	return math.clamp(math.floor(available / math.max(count, 1)), if compact then 22 else 26, 40)
end

local function sizeLine(row: Frame, height: number)
	row.Size = UDim2.new(1, 0, 0, height)
	local chip = row:FindFirstChild("Chip")
	if not (chip and chip:IsA("Frame")) then
		return
	end
	-- A short row gets a matching chip: thinner padding, a smaller icon and text.
	local chipHeight = math.min(34, height - 2)
	local inner = math.min(26, chipHeight - 4)
	chip.Size = UDim2.fromOffset(0, chipHeight)
	for _, child in chip:GetChildren() do
		if child:IsA("TextLabel") then
			child.Size = UDim2.fromOffset(0, inner)
			child.TextSize = math.min(Theme.Text.small, inner - 2)
		elseif child:IsA("Frame") then
			child.Size = UDim2.fromOffset(math.min(22, inner), math.min(22, inner))
		elseif child:IsA("UIPadding") then
			local pad = UDim.new(0, if chipHeight < 30 then 2 else 4)
			child.PaddingTop = pad
			child.PaddingBottom = pad
		end
	end
end

local function fitLines()
	local rows = {}
	for _, child in linesList:GetChildren() do
		if child.Name == "Line" and child:IsA("Frame") then
			table.insert(rows, child)
		end
	end
	local height = lineHeight(#rows)
	for _, row in rows do
		sizeLine(row, height)
	end
end

local function renderLines(data: any)
	clear(linesList)
	local plan = data.plan
	if not data.success or type(plan) ~= "table" then
		countToken += 1
		totalLabel.Text = ""
		local _, _, tip = Common.failureText(data.outcome, data.cause)
		Components.label({
			text = if data.success or tip == "" then Strings.t("results.failBody") else tip,
			font = Theme.Fonts.bodyBold,
			textSize = Theme.Text.body,
			color = C.cream,
			wrap = true,
			size = UDim2.new(1, 0, 0, 90),
			parent = linesList,
		})
		return
	end
	local shown = {}
	for _, line in plan.lines or {} do
		-- On a phone the reward card beside the list already shows the room or skin won: list the credits only.
		if not (compact and (line.key == "reward.blueprint" or line.key == "reward.skin")) then
			table.insert(shown, line)
		end
	end
	local height = lineHeight(#shown)
	for index, line in shown do
		local row = Create.new("Frame", {
			Name = "Line",
			BackgroundColor3 = C.panel,
			BackgroundTransparency = if index % 2 == 0 then 0.55 else 0.3,
			LayoutOrder = index,
			Parent = linesList,
		}, { Create.corner(Theme.Radius.small) })
		local text = Components.label({
			text = lineText(line),
			font = Theme.Fonts.bodyBold,
			textSize = Theme.Text.small,
			size = UDim2.new(1, -120, 1, 0),
			position = UDim2.fromOffset(12, 0),
			parent = row,
		})
		text.TextTruncate = Enum.TextTruncate.AtEnd
		if type(line.amount) == "number" and line.amount > 0 then
			local chip = Components.chip("coin", "+" .. tostring(line.amount), C.goldDark, 1)
			chip.AnchorPoint = Vector2.new(1, 0.5)
			chip.Position = UDim2.new(1, -6, 0.5, 0)
			chip.Parent = row
		else
			local chip = Components.chip("sparkle", Strings.t("results.unlocked"), C.purple, 1)
			chip.AnchorPoint = Vector2.new(1, 0.5)
			chip.Position = UDim2.new(1, -6, 0.5, 0)
			chip.Parent = row
		end
		sizeLine(row, height)
		if not Motion.isReduced() then
			row.BackgroundTransparency = 1
			text.TextTransparency = 1
			task.delay(0.12 * index, function()
				if row.Parent then
					Motion.fade(
						row,
						Theme.Tween.medium,
						{ BackgroundTransparency = if index % 2 == 0 then 0.55 else 0.3 }
					)
					Motion.fade(text, Theme.Tween.medium, { TextTransparency = 0 })
				end
			end)
		end
	end
	countUp(plan.credits or 0, 0.12 * #shown + 0.25)
end

local function stopSpinner()
	if spinnerConnection then
		spinnerConnection:Disconnect()
		spinnerConnection = nil
	end
end

local function renderSaving(data: any)
	clear(savingIcon)
	stopSpinner()
	savingIcon.Rotation = 0
	local state = data.saving
	if not data.success or state == "Idle" then
		savingRow.Visible = false
		return
	end
	savingRow.Visible = true
	if state == "Saved" then
		Icons.make("check", C.green, C.panelDark).Parent = savingIcon
		savingLabel.Text = Strings.t("results.saved")
		savingLabel.TextColor3 = C.green
	elseif state == "Error" then
		Icons.make("alert", C.orange, C.panelDark).Parent = savingIcon
		savingLabel.Text = Strings.t("results.saveError")
		savingLabel.TextColor3 = C.orange
	else
		Icons.make("refresh", C.goldLight, C.panelDark).Parent = savingIcon
		savingLabel.Text = Strings.t("results.saving")
		savingLabel.TextColor3 = C.goldLight
		if not Motion.isReduced() then
			spinnerConnection = RunService.RenderStepped:Connect(function(dt: number)
				savingIcon.Rotation = (savingIcon.Rotation + dt * 240) % 360
			end)
		end
	end
end

local function render(data: any)
	local outcome = if type(data.outcome) == "string" then data.outcome else "Wiped"
	local mission = if type(data.mission) == "string" then MissionDefs.byId[data.mission] else nil
	local room = if mission then mission.targetRoom else nil
	if data.success then
		headline.Text = Strings.t("results.success")
		headlineGradient.Color = ColorSequence.new(C.goldLight, C.gold)
		local targetRoom = if type(data.plan) == "table" and data.plan.blueprint then data.plan.blueprint else room
		subtitle.Text = if data.tutorial
			then Strings.t("results.tutorial")
			else Strings.t("results.successBody", { room = Common.roomName(targetRoom or "?") })
	else
		local title, reason = Common.failureText(outcome, data.cause)
		headline.Text = title
		headlineGradient.Color = ColorSequence.new(Color3.fromRGB(255, 160, 160), C.red)
		subtitle.Text = reason
	end
	-- After Check-In the lobby moves on to the first real mission, so the button says where it goes.
	replayButton.setText(Strings.t(if data.success and data.next == true then "results.next" else "results.replay"))
	renderRewardCard(data)
	renderStats(data)
	renderLines(data)
	renderSaving(data)
end

-- Opening logic --------------------------------------------------------------------------------------------------------

local function maybeOpen()
	local data = payload()
	if not data or type(data.runId) ~= "string" then
		return
	end
	local phase = RunInfo.phase()
	local id = data.runId
	if UIRoot.isOpen("Results") then
		-- Live updates (saving state, plan arriving).
		local key = id .. ":" .. tostring(data.saving) .. ":" .. tostring(data.plan ~= nil)
		if key ~= renderedKey then
			renderedKey = key
			if shownRunId == id then
				renderSaving(data)
				-- The plan arrives once; later updates only move the save state (no second count-up).
				if data.plan ~= nil and planShownFor ~= id then
					planShownFor = id
					renderRewardCard(data)
					renderLines(data)
				end
			end
		end
		return
	end
	if actedRunId == id or shownRunId == id then
		return
	end
	if phase ~= "Results" or runId() ~= id then
		return
	end
	shownRunId = id
	planShownFor = if data.plan ~= nil then id else nil
	renderedKey = id .. ":" .. tostring(data.saving) .. ":" .. tostring(data.plan ~= nil)
	render(data)
	UIRoot.open("Results")
	Motion.pop(headline, 0.5)
	if data.success then
		Components.sound("ui_reward")
	end
end

local function act(action: string)
	local data = payload()
	if data then
		actedRunId = data.runId
	end
	if RunInfo.phase() == "Results" then
		Net.send("ResultsAction", action)
	elseif action == "replay" then
		Net.send("SetReady", true)
	end
	UIRoot.close("Results")
	for _, fn in closedCallbacks do
		task.spawn(fn, data, action)
	end
end

-- Build ------------------------------------------------------------------------------------------------------------------

local function build()
	window = Common.window("Results", "", nil, Vector2.new(1020, 630), false)
	local content = window.content
	-- Remove the empty title ribbon; the headline is the title.
	local ribbon = window.frame:FindFirstChild("TitleRibbon")
	if ribbon then
		ribbon:Destroy()
	end
	content.Position = UDim2.fromOffset(22, 18)
	content.Size = UDim2.new(1, -44, 1, -36)

	headline = Components.label({
		name = "Headline",
		text = "",
		font = Theme.Fonts.display,
		textSize = 66,
		color = C.white,
		align = Enum.TextXAlignment.Center,
		size = UDim2.new(1, 0, 0, 74),
		stroke = true,
		parent = content,
	})
	headlineGradient = Create.gradient(C.goldLight, C.gold, 90)
	headlineGradient.Parent = headline
	subtitle = Components.label({
		name = "Subtitle",
		text = "",
		font = Theme.Fonts.heading,
		textSize = Theme.Text.medium,
		color = C.cream,
		align = Enum.TextXAlignment.Center,
		size = UDim2.new(1, 0, 0, 30),
		position = UDim2.fromOffset(0, 74),
		stroke = true,
		parent = content,
	})
	statsRow = Create.new("Frame", {
		Name = "Stats",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 40),
		Position = UDim2.fromOffset(0, 112),
		Parent = content,
	}, {
		Create.list(Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center),
	})

	rewardCard = Create.new("Frame", {
		Name = "RewardCard",
		BackgroundColor3 = C.ink,
		BackgroundTransparency = 0.35,
		Position = UDim2.fromOffset(0, 162),
		Size = UDim2.fromOffset(330, 254),
		ClipsDescendants = true,
		Parent = content,
	}, { Create.corner(Theme.Radius.large), Create.stroke(C.gold, 3, 0.1) })

	local right = Create.new("Frame", {
		Name = "Breakdown",
		BackgroundColor3 = C.ink,
		BackgroundTransparency = 0.45,
		Position = UDim2.fromOffset(346, 162),
		Size = UDim2.new(1, -346, 0, 254),
		Parent = content,
	}, { Create.corner(Theme.Radius.large) })
	breakdown = right
	linesList = Common.scroll(right, UDim2.new(1, -12, 1, -56), UDim2.fromOffset(6, 6), 4)
	linesList.Name = "Lines"
	totalLabel = Components.label({
		name = "Total",
		text = "",
		font = Theme.Fonts.heading,
		textSize = Theme.Text.large,
		color = C.goldLight,
		align = Enum.TextXAlignment.Right,
		size = UDim2.new(1, -24, 0, 40),
		-- Anchored at its right edge (where the right-aligned text sits) so the end-of-count pop stays put.
		anchor = Vector2.new(1, 1),
		position = UDim2.new(1, -12, 1, -6),
		stroke = true,
		parent = right,
	})

	savingRow = Create.new("Frame", {
		Name = "Saving",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 424),
		Size = UDim2.new(1, 0, 0, 36),
		Parent = content,
	}, {
		Create.list(Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center),
	})
	savingIcon = Create.new("Frame", {
		Name = "Icon",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(28, 28),
		LayoutOrder = 1,
		Parent = savingRow,
	})
	savingLabel = Components.label({
		text = "",
		font = Theme.Fonts.bodyHeavy,
		textSize = Theme.Text.body,
		size = UDim2.fromOffset(0, 30),
		autoSize = Enum.AutomaticSize.X,
		layoutOrder = 2,
		stroke = true,
		parent = savingRow,
	})

	local buttons = Create.new("Frame", {
		Name = "Buttons",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromScale(0.5, 1),
		Size = UDim2.new(1, 0, 0, 96),
		Parent = content,
	}, {
		Create.list(Enum.FillDirection.Horizontal, 20, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center),
	})
	buttonRow = buttons
	lobbyButton = Components.button({
		name = "Lobby",
		text = Strings.t("results.lobby"),
		icon = "door",
		variant = "secondary",
		size = UDim2.fromOffset(300, 88),
		textSize = Theme.Text.large,
		layoutOrder = 1,
		onClick = function()
			act("lobby")
		end,
		parent = buttons,
	})
	replayButton = Components.button({
		name = "Replay",
		text = Strings.t("results.replay"),
		icon = "refresh",
		iconColor = C.textDark,
		variant = "primary",
		size = UDim2.fromOffset(340, 88),
		textSize = Theme.Text.large,
		layoutOrder = 2,
		sound = "ui_ready",
		onClick = function()
			act("replay")
		end,
		parent = buttons,
	})

	-- Phone-height windows: everything keeps its place, just tighter, so nothing overlaps.
	window.onResize(function(contentSize: Vector2)
		-- The content was stretched over the removed title ribbon (frame - 36 instead of frame - 74).
		local height = contentSize.Y + 38
		local wasCompact = compact
		compact = height < 560
		local top = if compact then 128 else 162
		local buttonsHeight = if compact then 80 else 96
		local middle = if compact then math.max(150, height - top - 44 - buttonsHeight) else 254
		headline.TextSize = if compact then 50 else 66
		headline.Size = UDim2.new(1, 0, 0, if compact then 56 else 74)
		subtitle.TextSize = if compact then Theme.Text.body else Theme.Text.medium
		subtitle.Position = UDim2.fromOffset(0, if compact then 56 else 74)
		statsRow.Position = UDim2.fromOffset(0, if compact then 84 else 112)
		rewardCard.Position = UDim2.fromOffset(0, top)
		rewardCard.Size = UDim2.fromOffset(330, middle)
		breakdown.Position = UDim2.fromOffset(346, top)
		breakdown.Size = UDim2.new(1, -346, 0, middle)
		breakdownHeight = middle
		linesList.Size = UDim2.new(1, -12, 1, -totalReserve())
		totalLabel.Size = UDim2.new(1, -24, 0, if compact then 34 else 40)
		totalLabel.Position = UDim2.new(1, -12, 1, if compact then -4 else -6)
		fitLines()
		savingRow.Position = UDim2.fromOffset(0, top + middle + 8)
		buttonRow.Size = UDim2.new(1, 0, 0, buttonsHeight)
		lobbyButton.instance.Size = UDim2.fromOffset(300, buttonsHeight - 8)
		replayButton.instance.Size = UDim2.fromOffset(340, buttonsHeight - 8)
		local data = payload()
		if compact ~= wasCompact and data and shownRunId == data.runId and UIRoot.isOpen("Results") then
			renderRewardCard(data)
			renderLines(data) -- the phone list leaves out what the card shows
		end
	end)
end

function Results.start()
	build()
	UIRoot.register({
		name = "Results",
		frame = window.frame,
		closable = false,
		onClose = function()
			stopSpinner()
			stopRays()
			countToken += 1
		end,
		defaultSelection = function(): GuiObject?
			return replayButton.instance
		end,
	})
	ClientState.observe("me", "results", maybeOpen)
	RunInfo.PhaseChanged:Connect(function()
		maybeOpen()
	end)
	ClientState.observe("global", "run.id", maybeOpen)
end

return Results
