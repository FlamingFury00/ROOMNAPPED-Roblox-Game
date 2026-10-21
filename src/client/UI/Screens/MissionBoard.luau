--!strict
--[[
	MissionBoard: pick the next expedition (U15, U17, S23).

	Left: every mission with its difficulty, length and progress (locked / new / cleared). Right: the
	focused mission's story, hazards, bonus challenges and - for this player - exactly what a successful
	extraction will give (new room blueprint, targeted skin or credits), with a picker for the bonus skin.
	Only the squad leader can change the mission; everyone can browse and pick their own reward target.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage.Shared
local MissionDefs = require(Shared.Config.MissionDefs)
local RoomDefs = require(Shared.Config.RoomDefs)
local Layouts = require(Shared.Content.Layouts)
local SkinDefs = require(Shared.Config.SkinDefs)
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
type MissionDef = MissionDefs.MissionDef

local MissionBoard = {}
MissionBoard.priority = 100

local C = Theme.Colors
local myKey = tostring(Players.LocalPlayer.UserId)

type Card = { button: TextButton, stroke: UIStroke, selectedTag: Frame, mission: MissionDef }

local window: Common.Window
local cards: { [string]: Card } = {}
local list: ScrollingFrame
local details: Frame
local titleLabel: TextLabel
local chipRow: Frame
local blurbLabel: TextLabel
local hazardRow: Frame
local challengeList: Frame
local rewardBox: Frame
local targetPicker: Frame
local chooseButton: ButtonHandle
local footerLabel: TextLabel
local focusedId: string? = nil

-- Helpers ---------------------------------------------------------------------------------------------------

local function previews(): { [string]: any }
	local value = ClientState.get("me", "missions")
	return if type(value) == "table" then value else {}
end

local function selectedMission(): string?
	local lobby = ClientState.get("global", "lobby")
	return if type(lobby) == "table" then lobby.mission else nil
end

local function isLeader(): boolean
	local lobby = ClientState.get("global", "lobby")
	return type(lobby) == "table" and lobby.leader == myKey
end

local function isUnlocked(mission: MissionDef): boolean
	if Common.missionDisabled(mission.id) then
		return false
	end
	local preview = previews()[mission.id]
	if type(preview) == "table" and preview.unlocked ~= nil then
		return preview.unlocked == true
	end
	local profile = Common.profile()
	if not profile then
		return mission.tutorial
	end
	return MissionDefs.isUnlocked(mission, profile.tutorialDone == true, profile.stats.extractions or 0)
end

local function lockReason(mission: MissionDef): string
	if Common.missionDisabled(mission.id) then
		return Strings.t("mission.disabled")
	end
	local profile = Common.profile()
	if mission.unlock.tutorial and not (profile and profile.tutorialDone) then
		return Strings.t("mission.lockedTutorial")
	end
	local need = mission.unlock.extractions or 0
	local have = if profile then profile.stats.extractions or 0 else 0
	local count = math.max(1, need - have)
	return Strings.t(
		if count == 1 then "mission.lockedExtractionsOne" else "mission.lockedExtractions",
		{ count = count }
	)
end

local function clearedCount(missionId: string): number
	local profile = Common.profile()
	if not profile or type(profile.stats) ~= "table" or type(profile.stats.cleared) ~= "table" then
		return 0
	end
	return profile.stats.cleared[missionId] or 0
end

local function bestTime(missionId: string): number?
	local profile = Common.profile()
	if not profile or type(profile.stats) ~= "table" or type(profile.stats.bestTimes) ~= "table" then
		return nil
	end
	return profile.stats.bestTimes[missionId]
end

local function profileStats(): { [string]: any }
	local profile = Common.profile()
	return if profile and type(profile.stats) == "table" then profile.stats else {}
end

local function challengeDone(challengeId: string): boolean
	local done = profileStats().challengesDone
	return type(done) == "table" and done[challengeId] == true
end

-- Golden keys placed in a mission's layout: module keys and keys waiting in Lost & Found alcoves (the same two
-- sources LevelBuilder places), counted once per id.
local function keyCount(mission: MissionDef): number
	local layout = Layouts[mission.layoutId]
	local ids: { [string]: boolean } = {}
	if layout then
		for _, mod in layout.modules do
			local m = mod :: any
			if type(m.alcoves) == "table" then
				for _, alcove in m.alcoves do
					if type(alcove) == "table" and type(alcove.key) == "string" then
						ids[alcove.key] = true
					end
				end
			end
			if type(m.keys) == "table" then
				for _, key in m.keys do
					if type(key) == "table" and type(key.id) == "string" then
						ids[key.id] = true
					end
				end
			end
		end
	end
	local count = 0
	for _ in ids do
		count += 1
	end
	return count
end

-- Mission mastery stars: cleared, every golden key in one extraction, every bonus challenge done.
local function masteryStars(mission: MissionDef): { boolean }
	local stats = profileStats()
	local cleared = type(stats.cleared) == "table" and (stats.cleared[mission.id] or 0) > 0
	local keys = if keyCount(mission) == 0
		then cleared
		else type(stats.allKeys) == "table" and stats.allKeys[mission.id] == true
	local challenges = #mission.challenges > 0
	for _, challenge in mission.challenges do
		if not challengeDone(challenge.id) then
			challenges = false
		end
	end
	return { cleared, keys, challenges }
end

local function clear(frame: Instance)
	for _, child in frame:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

-- Mission list ------------------------------------------------------------------------------------------------

local function paintCards()
	local selected = selectedMission()
	for id, card in cards do
		Common.setCardSelected(card.stroke, id == focusedId)
		card.selectedTag.Visible = id == selected
	end
end

local function buildCard(mission: MissionDef, order: number): Card
	local unlocked = isUnlocked(mission)
	local room = RoomDefs.byId[mission.targetRoom]
	local button, stroke = Common.card(UDim2.new(1, -12, 0, 98), C.panelDark, order)
	button.Name = "Mission_" .. mission.id
	button.Parent = list
	Create.new("Frame", {
		Name = "Stripe",
		BackgroundColor3 = if room then room.color else C.gold,
		BorderSizePixel = 0,
		Size = UDim2.new(0, 10, 1, 0),
		Parent = button,
	})
	local iconBack = Create.new("Frame", {
		Name = "RoomIcon",
		BackgroundColor3 = if room then room.color else C.gold,
		Size = UDim2.fromOffset(58, 58),
		Position = UDim2.fromOffset(22, 20),
		Parent = button,
	}, { Create.corner(Theme.Radius.pill), Create.stroke(C.shadow, 2, 0.3) })
	local iconInner = Create.new("Frame", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.66, 0.66),
		Parent = iconBack,
	})
	Icons.make(
		if room then (Icons.roomIcon[room.id] or "star") else "star",
		C.white,
		if room then room.color:Lerp(C.black, 0.4) else C.goldDark
	).Parent =
		iconInner
	local name = Components.label({
		name = "Name",
		text = Strings.t(mission.nameKey),
		font = Theme.Fonts.heading,
		textSize = Theme.Text.medium,
		size = UDim2.new(1, -190, 0, 30),
		position = UDim2.fromOffset(94, 16),
		stroke = true,
		parent = button,
	})
	name.TextTruncate = Enum.TextTruncate.AtEnd
	Components.label({
		name = "Meta",
		text = string.format(
			"%s  ·  %s",
			Common.difficultyText(mission.difficulty),
			Strings.t("mission.estimate", { minutes = mission.estMinutes })
		),
		font = Theme.Fonts.bodyBold,
		textSize = Theme.Text.small,
		color = Common.difficultyColor(mission.difficulty):Lerp(C.white, 0.35),
		size = UDim2.new(1, -190, 0, 22),
		position = UDim2.fromOffset(94, 50),
		parent = button,
	})
	-- Right side status: lock / new / cleared.
	local status = Create.new("Frame", {
		Name = "Status",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -12, 0.5, 0),
		Size = UDim2.fromOffset(90, 40),
		Parent = button,
	}, {
		Create.list(Enum.FillDirection.Horizontal, 4, Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Center),
	})
	if not unlocked then
		local lock =
			Create.new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(34, 34), Parent = status })
		Icons.make("lock", C.textMuted, C.panelDark).Parent = lock
		button.BackgroundColor3 = C.ink
		name.TextColor3 = C.textMuted
	else
		local cleared = clearedCount(mission.id)
		if cleared > 0 then
			for index, earned in masteryStars(mission) do
				local holder = Create.new("Frame", {
					Name = if earned then "StarEarned" else "Star",
					BackgroundTransparency = 1,
					Size = UDim2.fromOffset(26, 26),
					LayoutOrder = index,
					Parent = status,
				})
				-- Unearned stars stay readable (muted, not dark) so the goal is visible.
				Icons.make("star", if earned then C.gold else C.textMuted, if earned then C.goldDark else C.panelDark).Parent =
					holder
			end
		else
			Components.chip("sparkle", Strings.t("mission.new"), C.purple, 1).Parent = status
		end
	end
	local selectedTag = Create.new("Frame", {
		Name = "SelectedTag",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -6, 0, 4),
		Size = UDim2.fromOffset(0, 24),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = C.gold,
		Visible = false,
		Parent = button,
	}, { Create.corner(Theme.Radius.pill), Create.padding(2, 10) })
	Components.label({
		text = Strings.t("mission.selected"),
		font = Theme.Fonts.heading,
		textSize = Theme.Text.tiny,
		color = C.textDark,
		size = UDim2.fromOffset(0, 20),
		autoSize = Enum.AutomaticSize.X,
		parent = selectedTag,
	})
	local card: Card = { button = button, stroke = stroke, selectedTag = selectedTag, mission = mission }
	button.Activated:Connect(function()
		Components.sound("ui_click")
		MissionBoard.focus(mission.id)
	end)
	button.SelectionGained:Connect(function()
		MissionBoard.focus(mission.id)
	end)
	return card
end

local function rebuildList()
	for _, card in cards do
		card.button:Destroy()
	end
	table.clear(cards)
	for index, mission in MissionDefs.list do
		cards[mission.id] = buildCard(mission, index)
	end
	paintCards()
end

-- Details ---------------------------------------------------------------------------------------------------------

local function rewardRow(icon: string, color: Color3, text: string, sub: string?)
	clear(rewardBox)
	local iconBack = Create.new("Frame", {
		BackgroundColor3 = color,
		Size = UDim2.fromOffset(64, 64),
		Position = UDim2.fromOffset(12, 12),
		Parent = rewardBox,
	}, { Create.corner(Theme.Radius.pill), Create.stroke(C.shadow, 2, 0.3) })
	local inner = Create.new("Frame", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.66, 0.66),
		Parent = iconBack,
	})
	Icons.make(icon, C.white, color:Lerp(C.black, 0.4)).Parent = inner
	Components.label({
		text = Strings.t("mission.reward"),
		font = Theme.Fonts.bodyHeavy,
		textSize = Theme.Text.small,
		color = C.textDim,
		size = UDim2.new(1, -100, 0, 20),
		position = UDim2.fromOffset(90, 10),
		parent = rewardBox,
	})
	local main = Components.label({
		text = text,
		font = Theme.Fonts.heading,
		textSize = Theme.Text.large,
		color = C.goldLight,
		size = UDim2.new(1, -100, 0, 32),
		position = UDim2.fromOffset(90, 30),
		stroke = true,
		parent = rewardBox,
	})
	main.TextTruncate = Enum.TextTruncate.AtEnd
	if sub then
		Components.label({
			text = sub,
			font = Theme.Fonts.bodyBold,
			textSize = Theme.Text.small,
			color = C.cream,
			size = UDim2.new(1, -100, 0, 20),
			position = UDim2.fromOffset(90, 62),
			parent = rewardBox,
		})
	end
end

local function buildTargetPicker(mission: MissionDef)
	clear(targetPicker)
	if #mission.rewardSkins == 0 then
		targetPicker.Visible = false
		return
	end
	targetPicker.Visible = true
	local preview = previews()[mission.id]
	local choice = if type(preview) == "table" then preview.choice else nil
	local profile = Common.profile()
	local owned = if profile and type(profile.skins) == "table" then profile.skins.owned or {} else {}
	Components.label({
		text = Strings.t("mission.chooseTarget"),
		font = Theme.Fonts.bodyHeavy,
		textSize = Theme.Text.small,
		color = C.textDim,
		size = UDim2.new(1, 0, 0, 22),
		layoutOrder = 0,
		parent = targetPicker,
	})
	local row = Create.new("Frame", {
		Name = "Skins",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 76),
		LayoutOrder = 1,
		Parent = targetPicker,
	}, { Create.list(Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center) })
	for index, skinId in mission.rewardSkins do
		local skin = SkinDefs.byId[skinId]
		local isOwned = owned[skinId] == true
		local text = Common.skinName(skinId) .. (if isOwned then "  ✓" else "")
		local handle = Components.button({
			name = "Target_" .. skinId,
			text = text,
			icon = if skin and skin.kind == "suitcase" then "suitcase" else "palette",
			variant = if skinId == choice then "primary" else "secondary",
			size = UDim2.fromOffset(300, 72),
			textSize = Theme.Text.body,
			layoutOrder = index,
			sound = "ui_toggle",
			onClick = function()
				Net.send("SelectReward", mission.id, skinId)
			end,
			parent = row,
		})
		handle.setSelected(skinId == choice)
	end
end

local function refreshDetails()
	local mission = if focusedId then MissionDefs.byId[focusedId] else nil
	if not mission then
		details.Visible = false
		return
	end
	details.Visible = true
	local m = mission :: MissionDef
	local unlocked = isUnlocked(m)
	local room = RoomDefs.byId[m.targetRoom]
	titleLabel.Text = Strings.t(m.nameKey)
	blurbLabel.Text = Strings.t(m.blurbKey)

	clear(chipRow)
	Components.chip(nil, Common.difficultyText(m.difficulty), Common.difficultyColor(m.difficulty), 1, C.textDark).Parent =
		chipRow
	Components.chip("clock", Strings.t("mission.estimate", { minutes = m.estMinutes }), C.panelLight, 2).Parent =
		chipRow
	if room then
		Components.chip(
			Icons.roomIcon[room.id],
			Strings.t("mission.targetRoom", { room = Common.roomName(room.id) }),
			room.color:Lerp(C.black, 0.3),
			3
		).Parent =
			chipRow
	end
	local cleared = clearedCount(m.id)
	if cleared > 0 then
		Components.chip("trophy", Strings.t("mission.cleared", { count = cleared }), C.greenDark, 4).Parent = chipRow
	end
	local best = bestTime(m.id)
	if best then
		Components.chip("clock", Strings.t("mission.best", { time = Common.formatTime(best) }), C.blue, 5).Parent =
			chipRow
	end
	if cleared > 0 then
		local earned = 0
		for _, star in masteryStars(m) do
			if star then
				earned += 1
			end
		end
		Components.chip("star", Strings.t("mission.mastery", { count = earned }), C.goldDark, 6).Parent = chipRow
	end

	clear(hazardRow)
	for index, hazard in m.hazards do
		Components.chip(Icons.hazardIcon[hazard] or "alert", Strings.t("hazard." .. hazard), C.redDark, index).Parent =
			hazardRow
	end

	clear(challengeList)
	local preview = previews()[m.id]
	local practice = type(preview) == "table" and preview.kind == "practice"
	for index, challenge in m.challenges do
		local row = Create.new("Frame", {
			Name = "Challenge",
			BackgroundColor3 = C.panel,
			BackgroundTransparency = 0.3,
			Size = UDim2.new(1, 0, 0, 40),
			LayoutOrder = index,
			Parent = challengeList,
		}, { Create.corner(Theme.Radius.small) })
		local star = Create.new("Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(26, 26),
			Position = UDim2.fromOffset(8, 7),
			Parent = row,
		})
		local done = challengeDone(challenge.id)
		Icons.make(if done then "check" else "star", if done then C.green else C.gold, C.panelDark).Parent = star
		local text = Components.label({
			text = Common.challengeText(challenge),
			font = Theme.Fonts.bodyBold,
			textSize = Theme.Text.small,
			size = UDim2.new(1, -130, 1, 0),
			position = UDim2.fromOffset(42, 0),
			parent = row,
		})
		text.TextTruncate = Enum.TextTruncate.AtEnd
		-- Challenges pay every time (a done one keeps its tick); in Check-In practice they only earn stars.
		if not practice then
			local credits =
				Components.chip("coin", "+" .. tostring(challenge.credits), if done then C.greenDark else C.goldDark, 1)
			credits.AnchorPoint = Vector2.new(1, 0.5)
			credits.Position = UDim2.new(1, -6, 0.5, 0)
			credits.Parent = row
		end
	end

	-- Personal reward preview.
	if type(preview) == "table" then
		local extra = Strings.t("reward.credits", { amount = preview.credits or 0 })
		if preview.kind == "practice" then
			rewardRow("refresh", C.blue, Strings.t("reward.preview.practice", { amount = preview.credits or 0 }), nil)
		elseif preview.kind == "blueprint" then
			local def = RoomDefs.byId[preview.item]
			rewardRow(
				Icons.roomIcon[preview.item] or "star",
				if def then def.color else C.gold,
				Strings.t("reward.preview.blueprint", { item = Common.roomName(preview.item) }),
				extra
			)
		elseif preview.kind == "skin" then
			rewardRow(
				"palette",
				C.purple,
				Strings.t("reward.preview.skin", { item = Common.skinName(preview.item) }),
				extra
			)
		else
			rewardRow("coin", C.gold, Strings.t("reward.preview.credits", { amount = preview.credits or 0 }), nil)
		end
	else
		rewardRow("coin", C.gold, Strings.t("lobby.profileLoading"), nil)
	end
	buildTargetPicker(m)

	-- Footer: choose / locked / leader-only.
	local selected = selectedMission()
	local leader = isLeader()
	local prep = RunInfo.phase() == "Prep"
	if not unlocked then
		chooseButton.setText(Strings.t("mission.locked"))
		chooseButton.setEnabled(false)
		footerLabel.Text = lockReason(m)
	elseif selected == m.id then
		chooseButton.setText(Strings.t("mission.selected"))
		chooseButton.setEnabled(false)
		footerLabel.Text = if leader then "" else Strings.t("mission.leaderOnly")
	elseif not leader then
		chooseButton.setText(Strings.t("mission.select"))
		chooseButton.setEnabled(false)
		footerLabel.Text = Strings.t("mission.leaderOnly")
	elseif not prep then
		chooseButton.setText(Strings.t("mission.select"))
		chooseButton.setEnabled(false)
		footerLabel.Text = Strings.t("objective.lobbyWaiting")
	else
		chooseButton.setText(Strings.t("mission.select"))
		chooseButton.setEnabled(true)
		footerLabel.Text = ""
	end
end

function MissionBoard.focus(missionId: string)
	if focusedId == missionId then
		return
	end
	focusedId = missionId
	paintCards()
	refreshDetails()
	Motion.pop(details, 0.97)
end

-- Build ----------------------------------------------------------------------------------------------------------------

local function build()
	window = Common.window("MissionBoard", Strings.t("lobby.missions"), "board", Vector2.new(1160, 630))
	local content = window.content
	list = Common.scroll(content, UDim2.new(0, 420, 1, 0), UDim2.fromOffset(0, 0), 10)
	list.Name = "Missions"

	details = Create.new("Frame", {
		Name = "Details",
		BackgroundColor3 = C.ink,
		BackgroundTransparency = 0.45,
		Position = UDim2.fromOffset(436, 0),
		Size = UDim2.new(1, -436, 1, 0),
		Parent = content,
	}, { Create.corner(Theme.Radius.medium) })
	local body = Common.scroll(details, UDim2.new(1, 0, 1, -104), UDim2.fromOffset(0, 0), 8)
	body.Name = "Body"
	local pad = body:FindFirstChildOfClass("UIPadding")
	if pad then
		pad.PaddingLeft = UDim.new(0, 16)
		pad.PaddingRight = UDim.new(0, 16)
		pad.PaddingTop = UDim.new(0, 12)
	end
	titleLabel = Components.label({
		name = "Title",
		text = "",
		font = Theme.Fonts.display,
		textSize = 40,
		color = C.goldLight,
		size = UDim2.new(1, 0, 0, 46),
		layoutOrder = 1,
		stroke = true,
		parent = body,
	})
	chipRow = Create.new("Frame", {
		Name = "Chips",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 2,
		Parent = body,
	}, {
		(function(): UIListLayout
			local layout = Create.list(Enum.FillDirection.Horizontal, 6)
			layout.Wraps = true
			return layout
		end)(),
	})
	blurbLabel = Components.label({
		name = "Blurb",
		text = "",
		font = Theme.Fonts.body,
		textSize = Theme.Text.body,
		color = C.cream,
		wrap = true,
		size = UDim2.fromScale(1, 0),
		autoSize = Enum.AutomaticSize.Y,
		layoutOrder = 3,
		parent = body,
	})
	Common.heading(body, Strings.t("mission.hazards"), "alert", 4)
	hazardRow = Create.new("Frame", {
		Name = "Hazards",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 5,
		Parent = body,
	}, {
		(function(): UIListLayout
			local layout = Create.list(Enum.FillDirection.Horizontal, 6)
			layout.Wraps = true
			return layout
		end)(),
	})
	Common.heading(body, Strings.t("mission.challenges"), "star", 6)
	challengeList = Create.new("Frame", {
		Name = "Challenges",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 7,
		Parent = body,
	}, { Create.list(Enum.FillDirection.Vertical, 6) })
	rewardBox = Create.new("Frame", {
		Name = "Reward",
		BackgroundColor3 = C.panel,
		BackgroundTransparency = 0.15,
		Size = UDim2.new(1, 0, 0, 90),
		LayoutOrder = 8,
		Parent = body,
	}, { Create.corner(Theme.Radius.medium), Create.stroke(C.gold, 2, 0.1) })
	targetPicker = Create.new("Frame", {
		Name = "TargetPicker",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 9,
		Parent = body,
	}, { Create.list(Enum.FillDirection.Vertical, 4) })

	-- Footer.
	local footer = Create.new("Frame", {
		Name = "Footer",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, 100),
		Parent = details,
	})
	footerLabel = Components.label({
		name = "FooterText",
		text = "",
		font = Theme.Fonts.bodyBold,
		textSize = Theme.Text.body,
		color = C.textDim,
		wrap = true,
		size = UDim2.new(1, -350, 1, 0),
		position = UDim2.fromOffset(18, 0),
		parent = footer,
	})
	chooseButton = Components.button({
		name = "Choose",
		text = Strings.t("mission.select"),
		icon = "check",
		iconColor = C.textDark,
		variant = "primary",
		size = UDim2.fromOffset(310, 82),
		position = UDim2.new(1, -14, 0.5, 0),
		anchor = Vector2.new(1, 0.5),
		textSize = Theme.Text.large,
		sound = "ui_success",
		onClick = function()
			if focusedId then
				Net.send("SelectMission", focusedId)
				task.delay(0.35, function()
					UIRoot.close("MissionBoard")
				end)
			end
		end,
		parent = footer,
	})
end

local function onOpen()
	-- Rebuild cards (unlocks and clears may have changed) and focus the squad's mission.
	rebuildList()
	local selected = selectedMission()
	focusedId = nil
	MissionBoard.focus(selected or (MissionDefs.list[1] and MissionDefs.list[1].id) or "M0")
end

function MissionBoard.start()
	build()
	UIRoot.register({
		name = "MissionBoard",
		frame = window.frame,
		onOpen = function()
			onOpen()
		end,
		defaultSelection = function(): GuiObject?
			local selected = selectedMission()
			local card = if selected then cards[selected] else nil
			return if card then card.button else nil
		end,
	})
	-- Live updates rebuild cards and reward buttons; a gamepad selection follows the item it was on.
	local function live()
		if UIRoot.isOpen("MissionBoard") then
			Common.keepSelection(window.frame, function()
				paintCards()
				refreshDetails()
			end)
		end
	end
	ClientState.observe("global", "lobby", live)
	ClientState.observe("me", "missions", live)
	-- Missions switched off (or back on) live.
	ClientState.observe("global", "flags", function()
		if UIRoot.isOpen("MissionBoard") then
			Common.keepSelection(window.frame, function()
				rebuildList()
				refreshDetails()
			end)
		end
	end)
	ClientState.observe("me", "profile", function()
		if UIRoot.isOpen("MissionBoard") then
			Common.keepSelection(window.frame, function()
				rebuildList()
				refreshDetails()
			end)
		end
	end)
	RunInfo.PhaseChanged:Connect(function()
		if RunInfo.isParticipant() then
			UIRoot.close("MissionBoard")
		else
			live()
		end
	end)
end

return MissionBoard
