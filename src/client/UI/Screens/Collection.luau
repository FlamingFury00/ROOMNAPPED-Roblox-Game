--!strict
--[[
	Collection: the room collection, loadout and cosmetics (U16, S05, A04).

	Rooms tab     - every room (owned / locked with where to steal it) and the two loadout slots. Pick a room,
	                then "Equip to slot 1/2"; choosing the room that sits in the other slot swaps them.
	Skins tab     - cosmetic themes per room: equip owned ones, buy shop skins with credits (never Robux),
	                see which mission rewards the rest.
	Suitcases tab - suitcase skins (what you carry rooms in).

	Every item shows a live 3D preview of the real room or suitcase. Purchases ask for confirmation and are
	resolved by the server exactly once; loadout changes are locked during expeditions.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local RoomDefs = require(Shared.Config.RoomDefs)
local SkinDefs = require(Shared.Config.SkinDefs)
local Strings = require(Shared.Config.Strings)
local Net = require(Shared.Net.Net)
local RoomPrefabs = require(Shared.World.RoomPrefabs)
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
type SkinDef = SkinDefs.SkinDef

local Collection = {}
Collection.priority = 100

local C = Theme.Colors

local TABS_HEIGHT = 84 -- tab bar above the pages and the detail panel
local DETAIL_ACTIONS = 94 -- pinned action row at the bottom of the detail panel
local PREVIEW_HEIGHT = 196

local window: Common.Window
local tabs: Common.Tabs
local pages: { [string]: GuiObject } = {}
local creditsLabel: TextLabel
-- Rooms page.
local slotCards: { Frame } = {}
local roomGrid: Frame
-- Skins pages.
local skinRoomRow: Frame
local skinGrid: ScrollingFrame
local suitcaseGrid: ScrollingFrame
-- Detail panel.
local detail: Frame
local preview: Common.Preview
local detailName: TextLabel
local detailSub: TextLabel
local detailDesc: TextLabel
local detailStatus: TextLabel
local actionRow: Frame
local firstSelectable: GuiObject? = nil

local currentTab = "rooms"
local focusedRoom = "Freezer"
local skinRoom = "Freezer"
local focusedSkin: string? = nil
local previewKey = ""
local pendingBuy: SkinDef? = nil
local buyConfirmFrame: Frame
local buyConfirmBody: TextLabel? = nil

-- Data --------------------------------------------------------------------------------------------------------

local function profileOrEmpty(): { [string]: any }
	return Common.profile() or { rooms = {}, loadout = {}, skins = { owned = {}, equipped = {} }, credits = 0 }
end

local function owns(roomId: string): boolean
	local rooms = profileOrEmpty().rooms
	return type(rooms) == "table" and rooms[roomId] == true
end

local function ownsSkin(skinId: string): boolean
	local skins = profileOrEmpty().skins
	return type(skins) == "table" and type(skins.owned) == "table" and skins.owned[skinId] == true
end

local function equippedSkin(target: string): string?
	local skins = profileOrEmpty().skins
	if type(skins) == "table" and type(skins.equipped) == "table" then
		return skins.equipped[target]
	end
	return nil
end

local function loadout(): { string }
	local value = profileOrEmpty().loadout
	return if type(value) == "table" then value else {}
end

local function credits(): number
	local value = profileOrEmpty().credits
	return if type(value) == "number" then value else 0
end

local function locked(): boolean
	return RunInfo.isParticipant()
end

local function skinTarget(skin: SkinDef): string
	return if skin.kind == "suitcase" then "suitcase" else skin.room :: string
end

local function sourceText(skin: SkinDef): string
	if skin.source == "shop" then
		return Strings.t("skin.source.shop", { price = skin.price or 0 })
	elseif skin.source == "mission" then
		return Strings.t("skin.source.mission", { mission = Common.missionName(skin.missionId) })
	end
	return Strings.t("skin.source.default")
end

local function clear(frame: Instance)
	for _, child in frame:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

-- Preview -------------------------------------------------------------------------------------------------------

local function showRoomPreview(roomId: string, skinId: string?)
	local key = "room:" .. roomId .. ":" .. (skinId or "")
	if key == previewKey then
		return
	end
	previewKey = key
	preview.show(function(): Model?
		return RoomPrefabs.build(roomId, skinId, CFrame.new(), "preview")
	end, "room")
end

local function showSuitcasePreview(skinId: string)
	local key = "case:" .. skinId
	if key == previewKey then
		return
	end
	previewKey = key
	preview.show(function(): Model?
		return RoomPrefabs.suitcase(skinId, 1, nil)
	end, "suitcase")
end

-- Detail panel ----------------------------------------------------------------------------------------------------

local function actionButton(
	text: string,
	icon: string?,
	variant: Components.ButtonVariant,
	enabled: boolean,
	order: number,
	onClick: () -> ()
): ButtonHandle
	local handle = Components.button({
		text = text,
		icon = icon,
		variant = variant,
		size = UDim2.fromOffset(196, 72),
		textSize = Theme.Text.body,
		layoutOrder = order,
		onClick = onClick,
		parent = actionRow,
	})
	handle.setEnabled(enabled)
	return handle
end

local function equipSlot(roomId: string, slot: number)
	local current = loadout()
	local a, b = current[1], current[2]
	if a == nil or b == nil then
		return
	end
	local other = if slot == 1 then 2 else 1
	if current[slot] == roomId then
		return
	end
	if slot == 1 then
		a = roomId
	else
		b = roomId
	end
	if current[other] == roomId then
		-- Swap the two slots.
		if slot == 1 then
			b = current[1]
		else
			a = current[2]
		end
	end
	if a ~= b then
		Net.send("SetLoadout", a, b)
	end
end

local function showRoomDetail(roomId: string)
	local def = RoomDefs.byId[roomId]
	if not def then
		return
	end
	showRoomPreview(roomId, equippedSkin(roomId))
	detailName.Text = Common.roomName(roomId)
	detailSub.Text = Strings.t(def.effectKey)
	detailSub.TextColor3 = def.color:Lerp(C.white, 0.35)
	detailDesc.Text = Strings.t(def.descKey)
	clear(actionRow)
	if not owns(roomId) then
		local missionId = def.unlockMissionId
		detailStatus.Text = if missionId
			then Strings.t("room.unlock.mission", { mission = Common.missionName(missionId) })
			else Strings.t("room.locked")
		detailStatus.TextColor3 = C.orange
		return
	end
	detailStatus.Text = if def.starter then Strings.t("room.unlock.starter") else Strings.t("room.owned")
	detailStatus.TextColor3 = C.green
	-- Switched off live: still owned, just not equippable until it is back.
	local resting = Common.roomDisabled(roomId)
	if resting then
		detailStatus.Text = Strings.t("toast.roomDisabled")
		detailStatus.TextColor3 = C.orange
	elseif locked() then
		detailStatus.Text = Strings.t("collection.lockedInRun")
		detailStatus.TextColor3 = C.orange
	end
	local current = loadout()
	for slot = 1, 2 do
		local inSlot = current[slot] == roomId
		actionButton(
			if inSlot
				then Strings.t("collection.inSlot", { index = slot })
				else Strings.t("collection.equipSlot", { index = slot }),
			if inSlot then "check" else "arrowUp",
			if inSlot then "success" else "primary",
			not inSlot and not locked() and not resting,
			slot,
			function()
				equipSlot(roomId, slot)
			end
		)
	end
end

local function showSkinDetail(skin: SkinDef)
	local target = skinTarget(skin)
	if skin.kind == "suitcase" then
		showSuitcasePreview(skin.id)
		detailSub.Text = Strings.t("collection.suitcase")
	else
		showRoomPreview(skin.room :: string, skin.id)
		detailSub.Text = Common.roomName(skin.room)
	end
	detailSub.TextColor3 = C.textDim
	detailName.Text = Common.skinName(skin.id)
	detailDesc.Text = sourceText(skin)
	clear(actionRow)
	local owned = ownsSkin(skin.id)
	local equipped = equippedSkin(target) == skin.id
	if owned then
		detailStatus.Text = if equipped then Strings.t("collection.equipped") else Strings.t("room.owned")
		detailStatus.TextColor3 = C.green
		actionButton(
			if equipped then Strings.t("collection.equipped") else Strings.t("collection.equip"),
			if equipped then "check" else "palette",
			if equipped then "success" else "primary",
			not equipped and not locked(),
			1,
			function()
				Net.send("EquipSkin", target, skin.id)
			end
		)
		return
	end
	if skin.source == "shop" then
		local roomOwned = skin.kind == "suitcase" or owns(skin.room :: string)
		local price = skin.price or 0
		local affordable = credits() >= price
		local shopOpen = Common.featureOn("shop")
		if not shopOpen then
			detailStatus.Text = Strings.t("collection.shopClosed")
			detailStatus.TextColor3 = C.orange
		elseif not roomOwned then
			detailStatus.Text = Strings.t("toast.roomLocked")
			detailStatus.TextColor3 = C.orange
		elseif not affordable then
			detailStatus.Text = Strings.t("collection.needCredits", { amount = price - credits() })
			detailStatus.TextColor3 = C.orange
		else
			detailStatus.Text = ""
		end
		actionButton(
			Strings.t("collection.buy", { price = price }),
			"coin",
			"success",
			shopOpen and roomOwned and affordable and not locked(),
			1,
			function()
				pendingBuy = skin
				if buyConfirmBody then
					(buyConfirmBody :: TextLabel).Text = Strings.t("collection.buyConfirm", {
						item = Common.skinName(skin.id),
						price = price,
					})
				end
				UIRoot.open("BuyConfirm")
			end
		)
	else
		detailStatus.Text = Strings.t("collection.missionHint")
		detailStatus.TextColor3 = C.blue
	end
end

local detailShown = ""

local function refreshDetail()
	-- A different item starts at the top of the (scrollable) detail panel.
	local shown = currentTab .. ":" .. tostring(if currentTab == "rooms" then focusedRoom else focusedSkin)
	if shown ~= detailShown then
		detailShown = shown
		local body = detail:FindFirstChild("Body")
		if body and body:IsA("ScrollingFrame") then
			body.CanvasPosition = Vector2.zero
		end
	end
	if currentTab == "rooms" then
		showRoomDetail(focusedRoom)
	else
		local skin = if focusedSkin then SkinDefs.byId[focusedSkin] else nil
		if skin then
			showSkinDetail(skin)
		end
	end
	creditsLabel.Text = Common.formatNumber(credits())
end

-- Rooms page ----------------------------------------------------------------------------------------------------------

local function roomCard(def: RoomDefs.RoomDef, order: number, parent: Instance): TextButton
	local isOwned = owns(def.id)
	local card, stroke = Common.card(UDim2.fromOffset(128, 160), if isOwned then C.panelDark else C.ink, order)
	card.Name = "Room_" .. def.id
	card.Parent = parent
	Common.setCardSelected(stroke, def.id == focusedRoom)
	local circle = Create.new("Frame", {
		Name = "Icon",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 12),
		Size = UDim2.fromOffset(70, 70),
		BackgroundColor3 = if isOwned then def.color else C.panel,
		Parent = card,
	}, { Create.corner(Theme.Radius.pill), Create.stroke(C.shadow, 2, 0.3) })
	local inner = Create.new("Frame", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.64, 0.64),
		Parent = circle,
	})
	Icons.make(
		if isOwned then (Icons.roomIcon[def.id] or "star") else "lock",
		if isOwned then C.white else C.textMuted,
		def.color:Lerp(C.black, 0.4)
	).Parent =
		inner
	Components.label({
		text = Common.roomName(def.id),
		font = Theme.Fonts.heading,
		textSize = Theme.Text.body,
		color = if isOwned then C.text else C.textMuted,
		align = Enum.TextXAlignment.Center,
		size = UDim2.new(1, -8, 0, 26),
		position = UDim2.fromOffset(4, 88),
		stroke = true,
		parent = card,
	})
	local slot = table.find(loadout(), def.id)
	local resting = isOwned and Common.roomDisabled(def.id)
	local tagText = if slot
		then Strings.t("collection.slot", { index = slot })
		elseif resting then Strings.t("room.resting")
		elseif isOwned then Strings.t("room.owned")
		else Strings.t("room.locked")
	local tagColor = if slot then C.gold elseif resting then C.orange elseif isOwned then C.greenDark else C.panel
	local chip = Components.chip(nil, tagText, tagColor, 0, if slot then C.textDark else C.white)
	chip.AnchorPoint = Vector2.new(0.5, 0)
	chip.Position = UDim2.new(0.5, 0, 0, 118)
	chip.Parent = card
	card.Activated:Connect(function()
		Components.sound("ui_click")
		focusedRoom = def.id
		Collection.refresh()
	end)
	card.SelectionGained:Connect(function()
		if focusedRoom ~= def.id then
			focusedRoom = def.id
			Collection.refresh()
		end
	end)
	return card
end

local function slotCard(index: number): Frame
	local frame = slotCards[index]
	clear(frame)
	local roomId = loadout()[index]
	local def = if roomId then RoomDefs.byId[roomId] else nil
	Components.label({
		text = Strings.t("collection.slot", { index = index }),
		font = Theme.Fonts.bodyHeavy,
		textSize = Theme.Text.small,
		color = C.textDim,
		size = UDim2.new(1, -20, 0, 22),
		position = UDim2.fromOffset(14, 8),
		parent = frame,
	})
	if def then
		local circle = Create.new("Frame", {
			Name = "Icon",
			Position = UDim2.fromOffset(14, 34),
			Size = UDim2.fromOffset(66, 66),
			BackgroundColor3 = def.color,
			Parent = frame,
		}, { Create.corner(Theme.Radius.pill), Create.stroke(C.shadow, 2, 0.3) })
		local inner = Create.new("Frame", {
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(0.64, 0.64),
			Parent = circle,
		})
		Icons.make(Icons.roomIcon[def.id] or "star", C.white, def.color:Lerp(C.black, 0.4)).Parent = inner
		Components.label({
			text = Common.roomName(def.id),
			font = Theme.Fonts.heading,
			textSize = Theme.Text.large,
			size = UDim2.new(1, -110, 0, 32),
			position = UDim2.fromOffset(92, 36),
			stroke = true,
			parent = frame,
		})
		local effect = Components.label({
			text = Strings.t(def.effectKey),
			font = Theme.Fonts.bodyBold,
			textSize = Theme.Text.small,
			color = def.color:Lerp(C.white, 0.4),
			size = UDim2.new(1, -110, 0, 22),
			position = UDim2.fromOffset(92, 70),
			parent = frame,
		})
		effect.TextTruncate = Enum.TextTruncate.AtEnd
		local stroke = frame:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Color = def.color
		end
	end
	return frame
end

local function refreshRooms()
	slotCard(1)
	slotCard(2)
	clear(roomGrid)
	firstSelectable = nil
	for index, def in RoomDefs.ordered do
		local card = roomCard(def, index, roomGrid)
		if index == 1 then
			firstSelectable = card
		end
	end
end

-- Skins pages -----------------------------------------------------------------------------------------------------------

local function skinCard(skin: SkinDef, order: number, parent: Instance): TextButton
	local owned = ownsSkin(skin.id)
	local equipped = equippedSkin(skinTarget(skin)) == skin.id
	local card, stroke = Common.card(UDim2.fromOffset(196, 170), C.panelDark, order)
	card.Name = "Skin_" .. skin.id
	card.Parent = parent
	Common.setCardSelected(stroke, skin.id == focusedSkin)
	-- Palette swatches: a tiny room (wall / floor / trim / accent).
	local swatch = Create.new("Frame", {
		Name = "Swatch",
		Position = UDim2.fromOffset(10, 10),
		Size = UDim2.new(1, -20, 0, 84),
		BackgroundColor3 = skin.palette.wall,
		ClipsDescendants = true,
		Parent = card,
	}, { Create.corner(Theme.Radius.small), Create.stroke(C.shadow, 1.5, 0.3) })
	Create.new("Frame", {
		Name = "Floor",
		BackgroundColor3 = skin.palette.floor,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.fromScale(1, 0.32),
		Parent = swatch,
	})
	Create.new("Frame", {
		Name = "Trim",
		BackgroundColor3 = skin.palette.trim,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 0.68),
		Size = UDim2.new(1, 0, 0, 6),
		Parent = swatch,
	})
	Create.new("Frame", {
		Name = "Accent",
		BackgroundColor3 = skin.palette.accent,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.72, 0.36),
		Size = UDim2.fromOffset(30, 30),
		Parent = swatch,
	}, { Create.corner(Theme.Radius.pill) })
	Create.new("Frame", {
		Name = "Prop",
		BackgroundColor3 = skin.palette.prop,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromScale(0.3, 0.74),
		Size = UDim2.fromOffset(34, 40),
		Parent = swatch,
	}, { Create.corner(Theme.Radius.small) })
	local name = Components.label({
		text = Common.skinName(skin.id),
		font = Theme.Fonts.heading,
		textSize = Theme.Text.body,
		size = UDim2.new(1, -16, 0, 26),
		position = UDim2.fromOffset(10, 100),
		stroke = true,
		parent = card,
	})
	name.TextTruncate = Enum.TextTruncate.AtEnd
	local chipText: string
	local chipColor: Color3
	local chipIcon: string?
	if equipped then
		chipText, chipColor, chipIcon = Strings.t("collection.equipped"), C.gold, "check"
	elseif owned then
		chipText, chipColor, chipIcon = Strings.t("room.owned"), C.greenDark, nil
	elseif skin.source == "shop" then
		chipText, chipColor, chipIcon = Common.formatNumber(skin.price or 0), C.goldDark, "coin"
	else
		chipText, chipColor, chipIcon = Common.missionName(skin.missionId), C.blue, "board"
	end
	local chip = Components.chip(chipIcon, chipText, chipColor, 0, if equipped then C.textDark else C.white)
	chip.Position = UDim2.fromOffset(10, 130)
	chip.Parent = card
	card.Activated:Connect(function()
		Components.sound("ui_click")
		focusedSkin = skin.id
		Collection.refresh()
	end)
	card.SelectionGained:Connect(function()
		if focusedSkin ~= skin.id then
			focusedSkin = skin.id
			Collection.refresh()
		end
	end)
	return card
end

local function refreshSkinRoomRow()
	clear(skinRoomRow)
	for index, def in RoomDefs.ordered do
		local handle = Components.button({
			name = "Filter_" .. def.id,
			text = Common.roomName(def.id),
			icon = Icons.roomIcon[def.id],
			variant = if def.id == skinRoom then "primary" else "secondary",
			size = UDim2.fromOffset(150, 72),
			textSize = Theme.Text.small,
			layoutOrder = index,
			sound = "ui_toggle",
			onClick = function()
				if skinRoom ~= def.id then
					skinRoom = def.id
					focusedSkin = nil
					Collection.refresh()
				end
			end,
			parent = skinRoomRow,
		})
		handle.setSelected(def.id == skinRoom)
	end
end

local function fillSkinGrid(grid: ScrollingFrame, skins: { SkinDef })
	clear(grid)
	firstSelectable = nil
	if focusedSkin == nil or not table.find(skins, SkinDefs.byId[focusedSkin :: string]) then
		focusedSkin = nil
		-- Focus the equipped skin by default.
		for _, skin in skins do
			if equippedSkin(skinTarget(skin)) == skin.id then
				focusedSkin = skin.id
			end
		end
		if focusedSkin == nil and skins[1] then
			focusedSkin = skins[1].id
		end
	end
	for index, skin in skins do
		local card = skinCard(skin, index, grid)
		if index == 1 then
			firstSelectable = card
		end
	end
end

-- Refresh --------------------------------------------------------------------------------------------------------------------

function Collection.refresh()
	-- Cards are rebuilt on every change; a gamepad selection follows the card it was on.
	Common.keepSelection(window.frame, function()
		for id, page in pages do
			page.Visible = id == currentTab
		end
		if currentTab == "rooms" then
			refreshRooms()
		elseif currentTab == "skins" then
			refreshSkinRoomRow()
			fillSkinGrid(skinGrid, SkinDefs.byRoom[skinRoom] or {})
		else
			fillSkinGrid(suitcaseGrid, SkinDefs.suitcases)
		end
		refreshDetail()
	end)
end

-- Build ------------------------------------------------------------------------------------------------------------------------

-- Swap a scroll list's vertical list layout for a card grid.
local function useGrid(scroll: ScrollingFrame)
	local list = scroll:FindFirstChildOfClass("UIListLayout")
	if list then
		list:Destroy()
	end
	local layout = Instance.new("UIGridLayout")
	layout.CellSize = UDim2.fromOffset(196, 170)
	layout.CellPadding = UDim2.fromOffset(12, 12)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = scroll
end

local function build()
	window = Common.window("Collection", Strings.t("collection.title"), "suitcase", Vector2.new(1160, 630))
	local content = window.content

	tabs = Common.tabs(content, {
		{ id = "rooms", text = Strings.t("collection.rooms"), icon = "door" },
		{ id = "skins", text = Strings.t("collection.skins"), icon = "palette" },
		{ id = "suitcases", text = Strings.t("collection.suitcases"), icon = "suitcase" },
	}, function(id: string)
		currentTab = id
		previewKey = ""
		if id == "rooms" then
			focusedSkin = nil
		end
		Collection.refresh()
	end, 210)

	local pill = Create.new("Frame", {
		Name = "Credits",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -70, 0, 8),
		Size = UDim2.fromOffset(0, 52),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = C.ink,
		BackgroundTransparency = 0.2,
		Parent = content,
	}, {
		Create.corner(Theme.Radius.pill),
		Create.stroke(C.gold, 2, 0),
		Create.padding(6, 16),
		Create.list(Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center),
	})
	local coin = Create.new(
		"Frame",
		{ BackgroundTransparency = 1, Size = UDim2.fromOffset(32, 32), LayoutOrder = 1, Parent = pill }
	)
	Icons.make("coin", C.gold, C.goldDark).Parent = coin
	creditsLabel = Components.label({
		text = "0",
		font = Theme.Fonts.heading,
		textSize = Theme.Text.large,
		color = C.goldLight,
		size = UDim2.fromOffset(0, 36),
		autoSize = Enum.AutomaticSize.X,
		layoutOrder = 2,
		stroke = true,
		parent = pill,
	})

	local body = Create.new("Frame", {
		Name = "Body",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, TABS_HEIGHT),
		Size = UDim2.new(1, 0, 1, -TABS_HEIGHT),
		Parent = content,
	})
	local left = Create.new("Frame", {
		Name = "Pages",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -432, 1, 0),
		Parent = body,
	})

	-- Rooms page (scrolls when the window is shorter than the page, on phones).
	local rooms = Create.new("ScrollingFrame", {
		Name = "Rooms",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 8,
		ScrollBarImageColor3 = C.gold,
		ScrollBarImageTransparency = 0.2,
		VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar,
		Selectable = false,
		Parent = left,
	})
	pages.rooms = rooms
	Common.heading(rooms, Strings.t("lobby.loadout"), "suitcase").Position = UDim2.fromOffset(0, 0)
	local slots = Create.new("Frame", {
		Name = "Slots",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 42),
		Size = UDim2.new(1, 0, 0, 112),
		Parent = rooms,
	}, { Create.list(Enum.FillDirection.Horizontal, 12) })
	for index = 1, 2 do
		slotCards[index] = Create.new("Frame", {
			Name = "Slot" .. index,
			BackgroundColor3 = C.panel,
			BackgroundTransparency = 0.1,
			Size = UDim2.new(0.5, -6, 1, 0),
			LayoutOrder = index,
			Parent = slots,
		}, { Create.corner(Theme.Radius.medium), Create.stroke(C.gold, 3, 0) })
	end
	Components.label({
		text = Strings.t("collection.swapHint"),
		font = Theme.Fonts.bodyBold,
		textSize = Theme.Text.small,
		color = C.textDim,
		size = UDim2.new(1, 0, 0, 22),
		position = UDim2.fromOffset(0, 160),
		parent = rooms,
	})
	local allRooms = Common.heading(rooms, Strings.t("collection.allRooms"), "door")
	allRooms.Position = UDim2.fromOffset(0, 190)
	-- Room cards wrap onto more rows when the window is narrow (phones, large text), so every room stays
	-- reachable; the page scrolls when the rows get taller than the window.
	roomGrid = Create.new("Frame", {
		Name = "Grid",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 234),
		Size = UDim2.new(1, -10, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = rooms,
	}, {
		(function(): UIListLayout
			local layout = Create.list(
				Enum.FillDirection.Horizontal,
				10,
				Enum.HorizontalAlignment.Left,
				Enum.VerticalAlignment.Top
			)
			layout.Wraps = true
			return layout
		end)(),
	})

	-- Skins page.
	local skins =
		Create.new("Frame", { Name = "Skins", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = left })
	pages.skins = skins
	skinRoomRow = Create.new("Frame", {
		Name = "RoomFilter",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 134),
		Parent = skins,
	}, {
		(function(): UIListLayout
			local layout = Create.list(Enum.FillDirection.Horizontal, 8)
			layout.Wraps = true
			return layout
		end)(),
	})
	skinGrid = Common.scroll(skins, UDim2.new(1, 0, 1, -140), UDim2.fromOffset(0, 140))
	useGrid(skinGrid)

	-- Suitcases page.
	local suitcases = Create.new(
		"Frame",
		{ Name = "Suitcases", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = left }
	)
	pages.suitcases = suitcases
	suitcaseGrid = Common.scroll(suitcases, UDim2.fromScale(1, 1))
	useGrid(suitcaseGrid)

	-- Shared detail panel: the preview and texts scroll (short phone windows), the actions stay pinned below.
	detail = Create.new("Frame", {
		Name = "Detail",
		BackgroundColor3 = C.ink,
		BackgroundTransparency = 0.4,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.new(0, 416, 1, 0),
		Parent = body,
	}, { Create.corner(Theme.Radius.medium), Create.stroke(C.goldDark, 2, 0.3) })
	local detailBody = Common.scroll(detail, UDim2.new(1, 0, 1, -DETAIL_ACTIONS), UDim2.fromOffset(0, 0), 4)
	detailBody.Name = "Body"
	local detailPad = detailBody:FindFirstChildOfClass("UIPadding")
	if detailPad then
		detailPad.PaddingTop = UDim.new(0, 10)
		detailPad.PaddingLeft = UDim.new(0, 10)
		detailPad.PaddingRight = UDim.new(0, 10)
	end
	preview = Common.preview(detailBody, UDim2.new(1, 0, 0, PREVIEW_HEIGHT))
	preview.frame.LayoutOrder = 1
	detailName = Components.label({
		text = "",
		font = Theme.Fonts.heading,
		textSize = Theme.Text.large,
		color = C.goldLight,
		size = UDim2.new(1, -8, 0, 34),
		layoutOrder = 2,
		stroke = true,
		parent = detailBody,
	})
	detailName.TextTruncate = Enum.TextTruncate.AtEnd
	detailSub = Components.label({
		text = "",
		font = Theme.Fonts.bodyHeavy,
		textSize = Theme.Text.body,
		size = UDim2.new(1, -8, 0, 24),
		layoutOrder = 3,
		parent = detailBody,
	})
	detailDesc = Components.label({
		text = "",
		font = Theme.Fonts.body,
		textSize = Theme.Text.small,
		color = C.cream,
		wrap = true,
		yAlign = Enum.TextYAlignment.Top,
		size = UDim2.new(1, -8, 0, 0),
		autoSize = Enum.AutomaticSize.Y,
		layoutOrder = 4,
		parent = detailBody,
	})
	detailStatus = Components.label({
		text = "",
		font = Theme.Fonts.bodyHeavy,
		textSize = Theme.Text.small,
		wrap = true,
		size = UDim2.new(1, -8, 0, 0),
		autoSize = Enum.AutomaticSize.Y,
		layoutOrder = 5,
		parent = detailBody,
	})
	-- Short windows (phones) trade preview height for the name and the start of the description.
	window.onResize(function(contentSize: Vector2)
		local visible = contentSize.Y - TABS_HEIGHT - DETAIL_ACTIONS - 10
		preview.frame.Size = UDim2.new(1, 0, 0, math.clamp(visible - 124, 104, PREVIEW_HEIGHT))
	end)
	actionRow = Create.new("Frame", {
		Name = "Actions",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 10, 1, -8),
		Size = UDim2.new(1, -20, 0, 78),
		Parent = detail,
	}, {
		Create.list(Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center),
	})

	-- Purchase confirmation (stacks on top of the collection).
	local confirmFrame, _, _ = Common.confirmFrame(
		"BuyConfirm",
		Strings.t("collection.buyTitle"),
		"",
		Strings.t("collection.buyYes"),
		Strings.t("settings.leaveNo"),
		function()
			local skin = pendingBuy
			pendingBuy = nil
			UIRoot.close("BuyConfirm")
			if skin then
				Net.send("BuySkin", skin.id)
			end
		end,
		function()
			pendingBuy = nil
			UIRoot.close("BuyConfirm")
		end,
		"success",
		"coin"
	)
	buyConfirmFrame = confirmFrame
	for _, d in confirmFrame:GetDescendants() do
		if d:IsA("TextLabel") and d.TextWrapped then
			buyConfirmBody = d
			break
		end
	end
end

function Collection.start()
	build()
	UIRoot.register({
		name = "Collection",
		frame = window.frame,
		onOpen = function(arg: any?)
			if type(arg) == "string" and RoomDefs.byId[arg] then
				focusedRoom = arg
				tabs.select("rooms")
			else
				Collection.refresh()
			end
			Motion.pop(window.frame, 0.97)
		end,
		onClose = function()
			previewKey = ""
			preview.show(nil, "room")
		end,
		defaultSelection = function(): GuiObject?
			return firstSelectable
		end,
	})
	UIRoot.register({
		name = "BuyConfirm",
		frame = buyConfirmFrame,
		keepUnder = true,
		defaultSelection = function(): GuiObject?
			-- Default to "No" so a stray press never spends credits.
			local no = buyConfirmFrame:FindFirstChild("Cancel", true)
			return if no and no:IsA("GuiObject") then no else nil
		end,
	})
	local function live()
		if UIRoot.isOpen("Collection") then
			Collection.refresh()
		end
	end
	ClientState.observe("me", "profile", live)
	-- Rooms or the shop switched off (or back on) live.
	ClientState.observe("global", "flags", live)
	RunInfo.PhaseChanged:Connect(function()
		if RunInfo.isParticipant() then
			UIRoot.close("BuyConfirm")
			UIRoot.close("Collection")
		end
	end)
end

return Collection
