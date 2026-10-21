--!strict
--[[
	LobbyHud: everything the lobby needs on screen (U15, S17, S25).

	* PLAY / READY toggle (also Enter on keyboards and Y on gamepads) with the launch countdown, the squad's
	  ready count and clear reasons when playing is not possible yet (profile loading, run in progress).
	* Squad list: headshots, leader crown, ready ticks, profile loading and "next run" tags, plus an "Invite
	  friends" row (Roblox's invite prompt) while the squad has room.
	* The selected mission with this player's own reward preview; tapping it opens the mission board.
	* Notices for test servers (progress not saved) and failed profile loads (with Retry).

	Hidden while the local player is inside an expedition.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SocialService = game:GetService("SocialService")

local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.Config.GameConfig)
local MissionDefs = require(Shared.Config.MissionDefs)
local RoomDefs = require(Shared.Config.RoomDefs)
local Strings = require(Shared.Config.Strings)
local Net = require(Shared.Net.Net)
local ClientState = require(script.Parent.Parent.Parent.Core.ClientState)
local Device = require(script.Parent.Parent.Parent.Core.Device)
local RunInfo = require(script.Parent.Parent.Parent.Core.RunInfo)
local AudioController = require(script.Parent.Parent.Parent.Controllers.AudioController)
local Theme = require(script.Parent.Parent.Theme)
local Create = require(script.Parent.Parent.Create)
local Components = require(script.Parent.Parent.Components)
local Icons = require(script.Parent.Parent.Icons)
local Motion = require(script.Parent.Parent.Motion)
local UIRoot = require(script.Parent.Parent.UIRoot)
local Responsive = require(script.Parent.Parent.Responsive)
local Common = require(script.Parent.Parent.Screens.Common)

type ButtonHandle = Components.ButtonHandle

local LobbyHud = {}
LobbyHud.priority = 110

local C = Theme.Colors
local player = Players.LocalPlayer
local myKey = tostring(player.UserId)

local container: Frame
local playButton: ButtonHandle
local readyButton: ButtonHandle
local statusLabel: TextLabel
local countdownLabel: TextLabel
local readyChipHolder: Frame
local squadRows: ScrollingFrame
local squadCount: TextLabel
local noticeHolder: Frame
local missionCard: TextButton
local missionStripe: Frame
local missionName: TextLabel
local missionChips: Frame
local rewardIconHolder: Frame
local rewardLabel: TextLabel
local leaderCaption: TextLabel
local changeButton: ButtonHandle

local lastSecond = -1
local pendingReady = false

-- Squad rows: full height on tall canvases, compact on short ones (phones in landscape).
local ROW_HEIGHT = 58
local ROW_HEIGHT_COMPACT = 42
local ROW_GAP = 6
local COMPACT_CANVAS_HEIGHT = 600
-- Notices are short and wrap to at most two lines in the panel; the Retry button is a fixed 72px.
local NOTICE_HEIGHT = 54
local RETRY_HEIGHT = 72
local squadRowHeight = ROW_HEIGHT
local squadContent = 0 -- height of the rows (and the invite row) with their gaps
-- The invite row is a touch target: 72 everywhere (about 44 pt on a phone at the smallest UI scale).
local INVITE_HEIGHT = 72
local noticeHeight = 0
-- Whether Roblox lets this player send game invites (checked once; false in Studio or when unsupported).
local canInvite = false

-- State helpers ------------------------------------------------------------------------------------------

local function lobbyState(): { [string]: any }
	local value = ClientState.get("global", "lobby")
	return if type(value) == "table" then value else {}
end

local function presence(): { [string]: any }
	local value = ClientState.get("global", "players")
	return if type(value) == "table" then value else {}
end

local function me(): any
	return presence()[myKey]
end

local function isReady(): boolean
	local p = me()
	return p ~= nil and p.ready == true
end

local function isLeader(): boolean
	return lobbyState().leader == myKey
end

local function isWaiting(): boolean
	local p = me()
	if p and p.waiting then
		return true
	end
	local phase = RunInfo.phase()
	return phase ~= "Prep" and phase ~= "Results" and not RunInfo.isParticipant()
end

-- PLAY / READY -----------------------------------------------------------------------------------------------

local function toggleReady()
	if not playButton.enabled and not readyButton.instance.Visible then
		return
	end
	pendingReady = true
	Net.send("SetReady", not isReady())
	task.delay(0.6, function()
		pendingReady = false
	end)
end

local function refreshPlay()
	local phase = RunInfo.phase()
	local status = Common.profileStatus()
	local ready = isReady()
	local canPlay = status == "Ready" and phase == "Prep" and not isWaiting()
	readyButton.instance.Visible = canPlay and ready
	playButton.instance.Visible = not (canPlay and ready)
	playButton.setEnabled(canPlay)
	if status == "Loading" or status == "Missing" then
		-- The button keeps its short label; the longer explanation goes underneath.
		playButton.setText(Strings.t("lobby.play"))
		statusLabel.Text = Strings.t("lobby.profileLoading")
	elseif status == "Failed" then
		playButton.setText(Strings.t("lobby.play"))
		statusLabel.Text = Strings.t("lobby.profileFailed")
	elseif status == "Newer" then
		playButton.setText(Strings.t("lobby.play"))
		statusLabel.Text = Strings.t("lobby.profileNewer")
	elseif phase == "Results" then
		playButton.setText(Strings.t("lobby.play"))
		statusLabel.Text = Strings.t("lobby.waitingSquad")
	elseif isWaiting() then
		playButton.setText(Strings.t("lobby.play"))
		statusLabel.Text = Strings.t("objective.lobbyWaiting")
	elseif ready then
		statusLabel.Text = Strings.t("lobby.tapToCancel")
	else
		playButton.setText(Strings.t("lobby.play"))
		statusLabel.Text = Strings.t("lobby.walkIn")
	end
	local label = if Device.isGamepad() then "Y" else nil
	playButton.setKeyHint(if canPlay then label else nil)
	readyButton.setKeyHint(label)
end

local function refreshReadyChip()
	readyChipHolder:ClearAllChildren()
	local lobby = lobbyState()
	local total = if type(lobby.total) == "number" then lobby.total else 0
	local ready = if type(lobby.ready) == "number" then lobby.ready else 0
	if RunInfo.phase() ~= "Prep" or total == 0 or (total == 1 and ready == 0) then
		return
	end
	local chip = Components.chip(
		"check",
		Strings.t("lobby.waitingPlayers", { ready = ready, total = total }),
		if ready >= total then C.greenDark else C.panelLight
	)
	chip.AnchorPoint = Vector2.new(0.5, 0.5)
	chip.Position = UDim2.fromScale(0.5, 0.5)
	chip.Parent = readyChipHolder
end

local function updateCountdown()
	local endsAt = lobbyState().countdownEndsAt
	if type(endsAt) ~= "number" or RunInfo.phase() ~= "Prep" or not container.Visible then
		if countdownLabel.Visible then
			countdownLabel.Visible = false
		end
		lastSecond = -1
		return
	end
	local remaining = endsAt - RunInfo.serverNow()
	local seconds = math.max(0, math.ceil(remaining))
	countdownLabel.Visible = true
	if seconds ~= lastSecond then
		lastSecond = seconds
		countdownLabel.Text = Strings.t("lobby.launchIn", { seconds = seconds })
		if isReady() then
			if seconds <= 5 and seconds > 0 then
				AudioController.ui("ui_countdown_tick")
				Motion.pop(countdownLabel, 0.8)
			elseif seconds == 0 then
				AudioController.ui("ui_countdown_go")
			end
		end
	end
	countdownLabel.TextColor3 = if seconds <= 3 then C.goldLight else C.cream
end

-- Squad ---------------------------------------------------------------------------------------------------------

local function tag(parent: Instance, icon: string, color: Color3, order: number)
	local holder = Create.new("Frame", {
		Name = "Tag_" .. icon,
		BackgroundColor3 = color,
		Size = UDim2.fromOffset(30, 30),
		LayoutOrder = order,
		Parent = parent,
	}, { Create.corner(Theme.Radius.pill), Create.stroke(C.shadow, 1.5, 0.3) })
	local inner = Create.new("Frame", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.7, 0.7),
		Parent = holder,
	})
	Icons.make(icon, C.textDark, color).Parent = inner
end

-- Caps the squad rows to the space above the mission card; a squad that still does not fit scrolls.
local function fitSquad()
	local content = squadContent
	squadRows.CanvasSize = UDim2.fromOffset(0, content)
	local height = content
	local gui = UIRoot.Guis.Hud
	local canvas = Responsive.canvasSize(gui)
	if canvas.Y > 0 then
		local cardTop = if missionCard.Visible then canvas.Y - 14 - missionCard.Size.Y.Offset else canvas.Y
		-- Panel top (12), padding (2 x 10), header (34), list gaps (2 x 6) and a 12px gap above the card.
		local room = math.floor(cardTop - 12 - 20 - 34 - 12 - noticeHeight - 12)
		height = math.max(math.min(content, room), math.min(content, squadRowHeight))
	end
	squadRows.Size = UDim2.new(1, 0, 0, height)
	-- Only a list that actually scrolls needs a gamepad selection stop.
	squadRows.Selectable = height < content
end

-- The lobby HUD is hidden during an expedition; its lists rebuild once it shows again instead of on every
-- update meanwhile (a deploy republishes the profile and the mission previews).
local staleWhileHidden = false

local function rebuildSquad()
	if container and not container.Visible then
		staleWhileHidden = true
		return
	end
	for _, child in squadRows:GetChildren() do
		if child:IsA("TextButton") then
			child:Destroy()
		end
	end
	local canvas = Responsive.canvasSize(UIRoot.Guis.Hud)
	local compact = canvas.Y > 0 and canvas.Y < COMPACT_CANVAS_HEIGHT
	squadRowHeight = if compact then ROW_HEIGHT_COMPACT else ROW_HEIGHT
	local avatarSize = squadRowHeight - 12
	local textLeft = avatarSize + 14
	for _, child in squadRows:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
	local list: { { key: string, info: any } } = {}
	for key, info in presence() do
		if type(info) == "table" then
			table.insert(list, { key = key, info = info })
		end
	end
	table.sort(list, function(a, b)
		return (a.info.order or 0) < (b.info.order or 0)
	end)
	squadCount.Text = if #list <= 1 then Strings.t("lobby.solo") else Strings.t("lobby.group", { count = #list })
	for index, item in list do
		local info = item.info
		local isMe = item.key == myKey
		local row = Create.new("Frame", {
			Name = "Player_" .. item.key,
			BackgroundColor3 = if isMe then C.panelLight else C.panel,
			BackgroundTransparency = 0.25,
			Size = UDim2.new(1, 0, 0, squadRowHeight),
			LayoutOrder = index,
			Parent = squadRows,
		}, { Create.corner(Theme.Radius.medium) })
		local avatar = Create.new("ImageLabel", {
			Name = "Avatar",
			BackgroundColor3 = C.ink,
			Size = UDim2.fromOffset(avatarSize, avatarSize),
			Position = UDim2.fromOffset(6, 6),
			Image = "",
			Parent = row,
		}, { Create.corner(Theme.Radius.pill), Create.stroke(if info.ready then C.green else C.gold, 2, 0) })
		local userId = tonumber(item.key)
		if userId then
			Common.headshot(avatar, userId)
		end
		-- Right-aligned tags: the leader's crown, then ready / loading / next-run.
		local tagList: { { icon: string, color: Color3 } } = {}
		if info.leader then
			table.insert(tagList, { icon = "crown", color = C.gold })
		end
		if info.ready then
			table.insert(tagList, { icon = "check", color = C.green })
		elseif info.profile ~= "Ready" then
			table.insert(tagList, { icon = "clock", color = C.textMuted })
		elseif info.waiting then
			table.insert(tagList, { icon = "zzz", color = C.orange })
		end
		-- Text runs up to the tags this row actually shows.
		local textInset = textLeft + 12 + #tagList * 34
		local name = if type(info.display) == "string" then info.display else (info.name or item.key)
		Components.label({
			name = "Name",
			text = name,
			font = Theme.Fonts.heading,
			textSize = if compact then Theme.Text.small else Theme.Text.body,
			size = UDim2.new(1, -textInset, 0, if compact then 20 else 26),
			position = UDim2.fromOffset(textLeft, if compact then 2 else 6),
			stroke = true,
			parent = row,
		}).TextTruncate =
			Enum.TextTruncate.AtEnd
		local subtitle: string
		local subColor = C.textDim
		if info.profile ~= "Ready" then
			subtitle = Strings.t("lobby.loadingTag")
		elseif info.waiting then
			subtitle = Strings.t("lobby.nextRun")
			subColor = C.orange
		elseif info.ready then
			subtitle = Strings.t("lobby.readyTag")
			subColor = C.green
		else
			subtitle = if isMe then Strings.t("hud.team.you") else Strings.t("lobby.notReady")
		end
		Components.label({
			name = "Status",
			text = subtitle,
			font = Theme.Fonts.bodyBold,
			textSize = if compact then Theme.Text.tiny else Theme.Text.small,
			color = subColor,
			size = UDim2.new(1, -textInset, 0, if compact then 17 else 20),
			position = UDim2.fromOffset(textLeft, if compact then 22 else 31),
			parent = row,
		}).TextTruncate =
			Enum.TextTruncate.AtEnd
		local tags = Create.new("Frame", {
			Name = "Tags",
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -8, 0.5, 0),
			Size = UDim2.fromOffset(84, 32),
			Parent = row,
		}, {
			Create.list(
				Enum.FillDirection.Horizontal,
				4,
				Enum.HorizontalAlignment.Right,
				Enum.VerticalAlignment.Center
			),
		})
		for order, entry in tagList do
			tag(tags, entry.icon, entry.color, order)
		end
	end
	squadContent = #list * squadRowHeight + math.max(0, #list - 1) * ROW_GAP
	-- An open seat: invite friends straight from the squad list.
	if canInvite and #list < GameConfig.Squad.MaxPlayers then
		local inviteHeight = INVITE_HEIGHT
		local invite = Create.new("TextButton", {
			Name = "Invite",
			BackgroundColor3 = C.panel,
			BackgroundTransparency = 0.55,
			Size = UDim2.new(1, 0, 0, inviteHeight),
			LayoutOrder = #list + 1,
			Text = "",
			AutoButtonColor = false,
			Selectable = true,
			Parent = squadRows,
		}, { Create.corner(Theme.Radius.medium), Create.stroke(C.goldDark, 2, 0.35) })
		local iconSize = if compact then 46 else avatarSize
		local plus = Create.new("Frame", {
			BackgroundColor3 = C.panelLight,
			AnchorPoint = Vector2.new(0, 0.5),
			Size = UDim2.fromOffset(iconSize, iconSize),
			Position = UDim2.new(0, 6, 0.5, 0),
			Parent = invite,
		}, { Create.corner(Theme.Radius.pill) })
		local inner = Create.new("Frame", {
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(0.6, 0.6),
			Parent = plus,
		})
		Icons.make("users", C.goldLight, C.panelLight).Parent = inner
		Components.label({
			text = Strings.t("lobby.invite"),
			font = Theme.Fonts.heading,
			textSize = Theme.Text.body,
			color = C.goldLight,
			size = UDim2.new(1, -(iconSize + 26), 1, 0),
			position = UDim2.fromOffset(iconSize + 14, 0),
			stroke = true,
			parent = invite,
		})
		invite.Activated:Connect(function()
			Components.sound("ui_click")
			pcall(function()
				SocialService:PromptGameInvite(player)
			end)
		end)
		squadContent += (if #list > 0 then ROW_GAP else 0) + inviteHeight
	end
	fitSquad()
end

-- Mission card --------------------------------------------------------------------------------------------------

local function refreshMission()
	if container and not container.Visible then
		staleWhileHidden = true
		return
	end
	local missionId = lobbyState().mission
	local mission = if type(missionId) == "string" then MissionDefs.byId[missionId] else nil
	if missionCard.Visible ~= (mission ~= nil) then
		missionCard.Visible = mission ~= nil
		fitSquad()
	end
	if not mission then
		return
	end
	local room = RoomDefs.byId[mission.targetRoom]
	missionStripe.BackgroundColor3 = if room then room.color else C.gold
	missionName.Text = Strings.t(mission.nameKey)
	for _, child in missionChips:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	Components.chip(
		nil,
		Common.difficultyText(mission.difficulty),
		Common.difficultyColor(mission.difficulty),
		1,
		C.textDark
	).Parent =
		missionChips
	Components.chip("clock", Strings.t("mission.estimate", { minutes = mission.estMinutes }), C.panelLight, 2).Parent =
		missionChips
	if room then
		Components.chip(Icons.roomIcon[room.id], Common.roomName(room.id), room.color:Lerp(C.black, 0.35), 3).Parent =
			missionChips
	end
	-- This player's own reward preview.
	for _, child in rewardIconHolder:GetChildren() do
		child:Destroy()
	end
	local previews = ClientState.get("me", "missions")
	local preview = if type(previews) == "table" then previews[mission.id] else nil
	if type(preview) == "table" then
		if preview.kind == "practice" then
			rewardLabel.Text = Strings.t("reward.preview.practice", { amount = preview.credits or 0 })
			Icons.make("refresh", C.blue, C.panelDark).Parent = rewardIconHolder
		elseif preview.kind == "blueprint" then
			rewardLabel.Text = Strings.t("reward.preview.blueprint", { item = Common.roomName(preview.item) })
			local def = RoomDefs.byId[preview.item]
			Icons.make(Icons.roomIcon[preview.item] or "star", if def then def.color else C.gold, C.panelDark).Parent =
				rewardIconHolder
		elseif preview.kind == "skin" then
			rewardLabel.Text = Strings.t("reward.preview.skin", { item = Common.skinName(preview.item) })
			Icons.make("palette", C.purple, C.panelDark).Parent = rewardIconHolder
		else
			rewardLabel.Text = Strings.t("reward.preview.credits", { amount = preview.credits or 0 })
			Icons.make("coin", C.gold, C.goldDark).Parent = rewardIconHolder
		end
	else
		rewardLabel.Text = ""
	end
	-- Who picks.
	local leader = lobbyState().leader
	if isLeader() then
		leaderCaption.Text = ""
		changeButton.instance.Visible = true
	else
		local leaderInfo = if type(leader) == "string" then presence()[leader] else nil
		local leaderName = if leaderInfo then (leaderInfo.display or leaderInfo.name or "") else ""
		leaderCaption.Text = if leaderName ~= "" then Strings.t("lobby.leaderPicks", { name = leaderName }) else ""
		changeButton.instance.Visible = false
	end
end

-- Notices --------------------------------------------------------------------------------------------------------

local function refreshNotices()
	for _, child in noticeHolder:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	local profile = ClientState.get("me", "profile")
	local height = 0
	local function reserve(amount: number)
		height += (if height > 0 then ROW_GAP else 0) + amount
	end
	if type(profile) == "table" and profile.memory == true then
		Components.notice("alert", Strings.t("lobby.testServer"), C.orange, 1, C.textDark).Parent = noticeHolder
		reserve(NOTICE_HEIGHT)
	end
	local status = if type(profile) == "table" then profile.status else nil
	if status == "Failed" then
		Components.notice("cross", Strings.t("lobby.profileFailed"), C.red, 2).Parent = noticeHolder
		reserve(NOTICE_HEIGHT)
		reserve(RETRY_HEIGHT)
		Components.button({
			text = Strings.t("lobby.retryProfile"),
			icon = "refresh",
			variant = "blue",
			size = UDim2.fromOffset(220, RETRY_HEIGHT),
			textSize = Theme.Text.body,
			layoutOrder = 3,
			onClick = function()
				Net.send("RetryProfile")
			end,
			parent = noticeHolder,
		})
	elseif status == "Newer" then
		Components.notice("alert", Strings.t("lobby.profileNewer"), C.red, 2).Parent = noticeHolder
		reserve(NOTICE_HEIGHT)
	end
	if height ~= noticeHeight then
		noticeHeight = height
		fitSquad()
	end
end

-- Visibility -------------------------------------------------------------------------------------------------------

local function refreshVisibility()
	local visible = not RunInfo.isParticipant()
	if container.Visible ~= visible then
		container.Visible = visible
		if visible then
			if staleWhileHidden then
				staleWhileHidden = false
				rebuildSquad()
				refreshMission()
			end
			Motion.pop(container, 0.96)
		end
	end
end

local function refreshAll()
	refreshVisibility()
	refreshPlay()
	refreshReadyChip()
	rebuildSquad()
	refreshMission()
	refreshNotices()
end

-- Build ---------------------------------------------------------------------------------------------------------------

local function build()
	container = Create.new("Frame", {
		Name = "LobbyHud",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = UIRoot.Hud,
	})

	-- PLAY cluster (bottom centre).
	local cluster = Create.new("Frame", {
		Name = "Play",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -14),
		Size = UDim2.fromOffset(440, 214),
		Parent = container,
	})
	countdownLabel = Components.label({
		name = "Countdown",
		text = "",
		font = Theme.Fonts.display,
		textSize = 46,
		color = C.cream,
		align = Enum.TextXAlignment.Center,
		size = UDim2.new(1, 0, 0, 52),
		position = UDim2.fromOffset(0, 0),
		stroke = true,
		parent = cluster,
	})
	countdownLabel.Visible = false
	readyChipHolder = Create.new("Frame", {
		Name = "ReadyChip",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 38),
		Position = UDim2.fromOffset(0, 52),
		Parent = cluster,
	})
	playButton = Components.button({
		name = "PlayButton",
		text = Strings.t("lobby.play"),
		icon = "play",
		iconColor = C.textDark,
		variant = "primary",
		size = UDim2.fromOffset(360, 96),
		position = UDim2.new(0.5, 0, 0, 92),
		anchor = Vector2.new(0.5, 0),
		textSize = Theme.Text.title,
		sound = "ui_ready",
		onClick = toggleReady,
		parent = cluster,
	})
	readyButton = Components.button({
		name = "ReadyButton",
		text = Strings.t("lobby.ready"),
		icon = "check",
		iconColor = C.textDark,
		variant = "success",
		size = UDim2.fromOffset(360, 96),
		position = UDim2.new(0.5, 0, 0, 92),
		anchor = Vector2.new(0.5, 0),
		textSize = Theme.Text.title,
		sound = "ui_toggle",
		onClick = toggleReady,
		parent = cluster,
	})
	readyButton.instance.Visible = false
	statusLabel = Components.label({
		name = "Status",
		text = "",
		font = Theme.Fonts.bodyHeavy,
		textSize = Theme.Text.body,
		color = C.cream,
		align = Enum.TextXAlignment.Center,
		size = UDim2.new(1, 40, 0, 26),
		position = UDim2.new(0, -20, 1, -24),
		stroke = true,
		parent = cluster,
	})

	-- Squad (top left).
	local squad = Create.new("Frame", {
		Name = "Squad",
		Position = UDim2.fromOffset(14, 12),
		Size = UDim2.fromOffset(310, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = C.panelDark,
		BackgroundTransparency = 0.18,
		Parent = container,
	}, {
		Create.corner(Theme.Radius.large),
		Create.stroke(C.goldDark, 2, 0.2),
		Create.padding(10, 10),
		Create.list(Enum.FillDirection.Vertical, 6, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Top),
	})
	local header = Create.new("Frame", {
		Name = "Header",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 34),
		LayoutOrder = 0,
		Parent = squad,
	})
	local usersIcon = Create.new("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(30, 30),
		Position = UDim2.fromOffset(2, 2),
		Parent = header,
	})
	Icons.make("users", C.gold, C.panelDark).Parent = usersIcon
	Components.label({
		text = Strings.t("lobby.squad"),
		font = Theme.Fonts.heading,
		textSize = Theme.Text.large,
		color = C.goldLight,
		size = UDim2.fromScale(0.5, 1),
		position = UDim2.fromOffset(40, 0),
		stroke = true,
		parent = header,
	})
	squadCount = Components.label({
		text = "",
		font = Theme.Fonts.bodyBold,
		textSize = Theme.Text.small,
		color = C.textDim,
		align = Enum.TextXAlignment.Right,
		size = UDim2.new(0.5, -6, 1, 0),
		position = UDim2.fromScale(0.5, 0),
		parent = header,
	})
	squadRows = Create.new("ScrollingFrame", {
		Name = "Rows",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 0),
		CanvasSize = UDim2.new(),
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = C.gold,
		VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar,
		Selectable = false,
		LayoutOrder = 1,
		Parent = squad,
	}, { Create.list(Enum.FillDirection.Vertical, ROW_GAP) })
	noticeHolder = Create.new("Frame", {
		Name = "Notices",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 2,
		Parent = squad,
	}, { Create.list(Enum.FillDirection.Vertical, 6) })

	-- Mission card (bottom left).
	local stroke: UIStroke
	missionCard, stroke = Common.card(UDim2.fromOffset(452, 178), C.panelDark)
	missionCard.Name = "MissionCard"
	missionCard.AnchorPoint = Vector2.new(0, 1)
	missionCard.Position = UDim2.new(0, 14, 1, -14)
	missionCard.BackgroundTransparency = 0.12
	missionCard.Parent = container
	stroke.Color = C.goldDark
	missionStripe = Create.new("Frame", {
		Name = "Stripe",
		BackgroundColor3 = C.gold,
		BorderSizePixel = 0,
		Size = UDim2.new(0, 10, 1, 0),
		Parent = missionCard,
	})
	Components.label({
		text = Strings.t("lobby.missionCaption"),
		font = Theme.Fonts.bodyHeavy,
		textSize = Theme.Text.small,
		color = C.textDim,
		size = UDim2.new(1, -40, 0, 20),
		position = UDim2.fromOffset(24, 10),
		parent = missionCard,
	})
	missionName = Components.label({
		text = "",
		font = Theme.Fonts.display,
		textSize = 32,
		color = C.goldLight,
		size = UDim2.new(1, -40, 0, 38),
		position = UDim2.fromOffset(24, 30),
		stroke = true,
		parent = missionCard,
	})
	missionName.TextTruncate = Enum.TextTruncate.AtEnd
	missionChips = Create.new("Frame", {
		Name = "Chips",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -34, 0, 36),
		Position = UDim2.fromOffset(24, 72),
		Parent = missionCard,
	}, {
		Create.list(Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center),
	})
	rewardIconHolder = Create.new("Frame", {
		Name = "RewardIcon",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(30, 30),
		Position = UDim2.fromOffset(24, 116),
		Parent = missionCard,
	})
	rewardLabel = Components.label({
		text = "",
		font = Theme.Fonts.bodyHeavy,
		textSize = Theme.Text.body,
		color = C.cream,
		size = UDim2.new(1, -226, 0, 30),
		position = UDim2.fromOffset(60, 116),
		stroke = true,
		parent = missionCard,
	})
	rewardLabel.TextTruncate = Enum.TextTruncate.AtEnd
	leaderCaption = Components.label({
		text = "",
		font = Theme.Fonts.bodyBold,
		textSize = Theme.Text.tiny,
		color = C.textDim,
		size = UDim2.new(1, -40, 0, 18),
		position = UDim2.fromOffset(24, 150),
		parent = missionCard,
	})
	-- The whole card is the touch target (it opens the board too); this button only marks it for the leader, so
	-- it stays short enough to sit under the chips.
	changeButton = Components.button({
		name = "Change",
		text = Strings.t("lobby.change"),
		icon = "board",
		variant = "secondary",
		size = UDim2.fromOffset(150, 58),
		position = UDim2.new(1, -12, 1, -12),
		anchor = Vector2.new(1, 1),
		textSize = Theme.Text.body,
		onClick = function()
			UIRoot.open("MissionBoard")
		end,
		parent = missionCard,
	})
	missionCard.Activated:Connect(function()
		Components.sound("ui_click")
		UIRoot.open("MissionBoard")
	end)

	-- PLAY stays centred, except on narrow canvases (phones) where it slides right to clear the mission card.
	local function placeCluster()
		local canvas = Responsive.canvasSize(UIRoot.Guis.Hud)
		if canvas.X <= 0 then
			return
		end
		local cardRight = missionCard.Position.X.Offset + missionCard.Size.X.Offset
		local center = math.max(canvas.X / 2, cardRight + 24 + cluster.Size.X.Offset / 2)
		cluster.Position = UDim2.new(0, math.round(center), 1, -14)
	end
	placeCluster()
	Responsive.Changed:Connect(placeCluster)
	-- Canvas changes can switch the squad between full and compact rows.
	Responsive.Changed:Connect(rebuildSquad)
end

function LobbyHud.start()
	build()
	ClientState.observe("global", "lobby", function()
		refreshPlay()
		refreshReadyChip()
		refreshMission()
	end)
	ClientState.observe("global", "players", function()
		rebuildSquad()
		refreshPlay()
		refreshMission()
	end)
	ClientState.observe("me", "profile", function()
		refreshPlay()
		refreshNotices()
	end)
	ClientState.observe("me", "missions", refreshMission)
	RunInfo.PhaseChanged:Connect(function()
		refreshVisibility()
		refreshPlay()
		refreshReadyChip()
	end)
	RunInfo.RosterChanged:Connect(refreshVisibility)
	Device.Changed:Connect(refreshPlay)
	ContextActionService:BindActionAtPriority(
		"RN_LobbyPlay",
		function(_name: string, state: Enum.UserInputState): Enum.ContextActionResult
			if state ~= Enum.UserInputState.Begin then
				return Enum.ContextActionResult.Pass
			end
			if not container.Visible or UIRoot.anyOpen() or RunInfo.phase() ~= "Prep" then
				return Enum.ContextActionResult.Pass
			end
			if pendingReady then
				return Enum.ContextActionResult.Sink
			end
			if playButton.enabled or readyButton.instance.Visible then
				Components.sound("ui_click")
				toggleReady()
				return Enum.ContextActionResult.Sink
			end
			return Enum.ContextActionResult.Pass
		end,
		false,
		Enum.ContextActionPriority.High.Value + 5,
		Enum.KeyCode.Return,
		Enum.KeyCode.ButtonY
	)
	RunService.Heartbeat:Connect(updateCountdown)
	refreshAll()
	task.spawn(function()
		local ok, allowed = pcall(function()
			return SocialService:CanSendGameInviteAsync(player)
		end)
		if ok and allowed == true then
			canInvite = true
			rebuildSquad()
		end
	end)
end

return LobbyHud
