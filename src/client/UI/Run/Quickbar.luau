--!strict
--[[
	Quickbar: your two room suitcases and the touch action buttons (U04, U06, U11, S29).

	Bottom centre: one big slot per equipped room - icon, name, key glyph and a state badge (Ready /
	Unfolded / Resting). Selecting a slot lifts it and outlines it in gold; an unfolded room's slot offers
	the recall. Tapping a slot selects it on touch screens.

	Touch screens: nothing goes near the thumbstick. Everything gathers around Roblox's jump button like an
	ability cluster - the context action button (icon + words + hold ring) left of Jump, the two room slots
	above them, Ping beside the slots and Turn / Cancel / Drop beside the action button only when they apply
	(TouchZones keeps the thumbstick zone, the jump button and the top HUD band clear).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.Config.GameConfig)
local RoomDefs = require(Shared.Config.RoomDefs)
local Strings = require(Shared.Config.Strings)
local RunInfo = require(script.Parent.Parent.Parent.Core.RunInfo)
local Device = require(script.Parent.Parent.Parent.Core.Device)
local InputController = require(script.Parent.Parent.Parent.Controllers.InputController)
local PlacementController = require(script.Parent.Parent.Parent.Controllers.PlacementController)
local InteractionController = require(script.Parent.Parent.Parent.Controllers.InteractionController)
local PingController = require(script.Parent.Parent.Parent.Controllers.PingController)
local Theme = require(script.Parent.Parent.Theme)
local Create = require(script.Parent.Parent.Create)
local Icons = require(script.Parent.Parent.Icons)
local Motion = require(script.Parent.Parent.Motion)
local Components = require(script.Parent.Parent.Components)
local TouchZones = require(script.Parent.Parent.TouchZones)

local Quickbar = {}

local C = Theme.Colors
local localPlayer = Players.LocalPlayer

local ACTION_SIZE = 128
local SMALL_SIZE = 76
local TOUCH_GAP = 12
-- Room slots are 112 x 122 on the bottom bar; around the jump button they shrink a little.
local TOUCH_SLOT_SCALE = 0.86
local SLOT_W, SLOT_H = 112, 122
-- Canvas rows kept for the top HUD on touch screens (hearts, objective, menu and suitcase status).
Quickbar.TOP_RESERVE = 146
local PING_HOLD_SECONDS = 0.35
local DROP_HOLD_SECONDS = 0.4 -- Drop sits beside Jump: a stray tap must never throw the suitcase down

export type Handle = {
	frame: Frame,
	touch: Frame,
	setVisible: (boolean) -> (),
	setSpectating: (boolean) -> (),
}

type Slot = {
	button: TextButton,
	scale: UIScale,
	face: Frame,
	stroke: UIStroke,
	iconHolder: Frame,
	icon: Frame?,
	name: TextLabel,
	badge: Frame,
	badgeText: TextLabel,
	key: TextLabel,
	roomId: string,
}

local function makeSlot(parent: Instance, index: number): Slot
	local button = Create.new("TextButton", {
		Name = "Slot" .. index,
		Size = UDim2.fromOffset(SLOT_W, SLOT_H),
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		LayoutOrder = index,
		Parent = parent,
	})
	local scale = Create.new("UIScale", { Name = "TouchScale", Scale = 1, Parent = button })
	local face = Create.new("Frame", {
		Name = "Face",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromScale(0.5, 1),
		Size = UDim2.fromOffset(108, 108),
		BackgroundColor3 = C.panelDark,
		BackgroundTransparency = 0.08,
		Parent = button,
	}, { Create.corner(Theme.Radius.large) })
	local stroke = Create.stroke(C.shadow, 3, 0.2)
	stroke.Parent = face
	Create.new("Frame", {
		Name = "Accent",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 6),
		Size = UDim2.new(1, -24, 0, 5),
		BackgroundColor3 = C.gold,
		Parent = face,
	}, { Create.corner(Theme.Radius.pill) })
	local iconHolder = Create.new("Frame", {
		Name = "Icon",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 16),
		Size = UDim2.fromOffset(54, 54),
		BackgroundTransparency = 1,
		Parent = face,
	})
	local name = Components.label({
		text = "",
		font = Theme.Fonts.heading,
		textSize = 17,
		align = Enum.TextXAlignment.Center,
		size = UDim2.new(1, -8, 0, 22),
		position = UDim2.new(0, 4, 1, -30),
		stroke = true,
		parent = face,
	})
	local badge = Create.new("Frame", {
		Name = "Badge",
		AnchorPoint = Vector2.new(0, 0),
		Position = UDim2.fromOffset(-4, -4),
		Size = UDim2.fromOffset(0, 26),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = C.green,
		Visible = false,
		ZIndex = 3,
		Parent = face,
	}, { Create.corner(Theme.Radius.pill), Create.padding(2, 7), Create.stroke(C.ink, 2, 0) })
	local badgeText = Components.label({
		text = "",
		font = Theme.Fonts.bodyHeavy,
		textSize = 14,
		color = C.textDark,
		size = UDim2.fromOffset(0, 22),
		autoSize = Enum.AutomaticSize.X,
		parent = badge,
	})
	badgeText.ZIndex = 3
	local keyBadge = Create.new("TextLabel", {
		Name = "Key",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 4, 0, -4),
		Size = UDim2.fromOffset(28, 28),
		BackgroundColor3 = C.ink,
		Text = "",
		TextColor3 = C.goldLight,
		FontFace = Theme.Fonts.mono,
		TextSize = 16,
		ZIndex = 4,
		Parent = face,
	}, { Create.corner(Theme.Radius.small), Create.stroke(C.gold, 1.5, 0) })
	return {
		button = button,
		scale = scale,
		face = face,
		stroke = stroke,
		iconHolder = iconHolder,
		icon = nil,
		name = name,
		badge = badge,
		badgeText = badgeText,
		key = keyBadge,
		roomId = "",
	}
end

local function roundButton(
	parent: Instance,
	name: string,
	size: number,
	icon: string,
	color: Color3
): (TextButton, TextLabel)
	local button = Create.new("TextButton", {
		Name = name,
		Size = UDim2.fromOffset(size, size),
		BackgroundColor3 = C.panelDark,
		BackgroundTransparency = 0.12,
		Text = "",
		AutoButtonColor = false,
		Parent = parent,
	}, { Create.corner(Theme.Radius.pill), Create.stroke(color, 3, 0) })
	local holder = Create.new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.42),
		Size = UDim2.fromScale(0.46, 0.46),
		BackgroundTransparency = 1,
		Parent = button,
	})
	Icons.make(icon, color, C.ink).Parent = holder
	local label = Components.label({
		text = "",
		font = Theme.Fonts.heading,
		textSize = math.floor(size * 0.18),
		align = Enum.TextXAlignment.Center,
		size = UDim2.new(1, 0, 0, math.floor(size * 0.24)),
		position = UDim2.fromScale(0, 0.7),
		stroke = true,
		parent = button,
	})
	return button, label
end

function Quickbar.create(parent: Instance): Handle
	-- Slots ----------------------------------------------------------------------------------------------
	local bar = Create.new("Frame", {
		Name = "Quickbar",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -14),
		Size = UDim2.fromOffset(250, 126),
		BackgroundTransparency = 1,
		Parent = parent,
	}, {
		Create.list(Enum.FillDirection.Horizontal, 14, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Bottom),
	})
	local slots: { Slot } = {}
	for i = 1, GameConfig.Loadout.Slots do
		local slot = makeSlot(bar, i)
		slots[i] = slot
		slot.button.Activated:Connect(function()
			PlacementController.select(i)
		end)
	end

	local function refreshSlots()
		local entry = RunInfo.myEntry()
		local loadout = if entry and type(entry.loadout) == "table" then entry.loadout else {}
		local deployed = if entry and type(entry.deployed) == "table" then entry.deployed else {}
		local active = RunInfo.myStatus() == "Active"
		local selected = PlacementController.selectedSlot()
		for i, slot in slots do
			local roomId = loadout[i] or ""
			local def = RoomDefs.get(roomId)
			if roomId ~= slot.roomId then
				slot.roomId = roomId
				if slot.icon then
					(slot.icon :: Frame):Destroy()
				end
				local iconName = Icons.roomIcon[roomId] or "suitcase"
				local made = Icons.make(iconName, if def then def.color else C.text, C.ink)
				made.Parent = slot.iconHolder
				slot.icon = made
				slot.name.Text = if def then Strings.t(def.nameKey) else ""
				local accent = slot.face:FindFirstChild("Accent")
				if accent and accent:IsA("Frame") then
					accent.BackgroundColor3 = if def then def.color else C.gold
				end
			end
			local isDeployed = deployed[tostring(i)] ~= nil
			local isSelected = selected == i
			slot.badge.Visible = isDeployed or not active
			slot.badge.BackgroundColor3 = if not active then C.textMuted elseif isDeployed then C.green else C.gold
			slot.badgeText.Text = if not active then Strings.t("hud.team.downed") else Strings.t("hud.deployed")
			slot.stroke.Color = if isSelected then C.gold else C.shadow
			slot.stroke.Thickness = if isSelected then 4 else 3
			slot.stroke.Transparency = if isSelected then 0 else 0.2
			slot.face.Position = UDim2.new(0.5, 0, 1, if isSelected then -12 else 0)
			slot.face.BackgroundTransparency = if active then 0.08 else 0.45
			if slot.icon then
				Icons.tint(slot.icon :: Frame, if active then (if def then def.color else C.text) else C.textMuted)
			end
			local keyText = InputController.keyLabel(if i == 1 then "Slot1" else "Slot2")
			slot.key.Text = keyText
			slot.key.Visible = keyText ~= ""
		end
	end

	PlacementController.SelectionChanged:Connect(function(slot: number)
		refreshSlots()
		local s = slots[slot]
		if s then
			Motion.pop(s.face, 0.85)
		end
	end)
	RunInfo.RosterChanged:Connect(refreshSlots)
	RunInfo.StatusChanged:Connect(refreshSlots)
	Device.Changed:Connect(refreshSlots)
	refreshSlots()

	-- Touch action cluster --------------------------------------------------------------------------------------
	-- Laid out around the Roblox jump button (see layoutTouch): the action button left of it, the room slots
	-- above both, Ping beside the slots and the contextual small buttons beside the action button.
	local touch = Create.new("Frame", {
		Name = "TouchActions",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Visible = false,
		Parent = parent,
	})
	local actionButton = Create.new("TextButton", {
		Name = "Action",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(1, -220, 1, -180),
		Size = UDim2.fromOffset(ACTION_SIZE, ACTION_SIZE),
		BackgroundColor3 = C.panelDark,
		BackgroundTransparency = 0.1,
		Text = "",
		AutoButtonColor = false,
		Parent = touch,
	}, { Create.corner(Theme.Radius.pill) })
	local actionStroke = Create.stroke(C.gold, 4, 0)
	actionStroke.Parent = actionButton
	local actionRing = Components.holdCircle(actionButton, C.gold)
	actionRing.frame.BackgroundTransparency = 1
	local ringFill = actionRing.frame:FindFirstChild("Fill")
	if ringFill and ringFill:IsA("Frame") then
		ringFill.BackgroundTransparency = 0.55
	end
	local actionIconHolder = Create.new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.4),
		Size = UDim2.fromOffset(52, 52),
		BackgroundTransparency = 1,
		ZIndex = 3,
		Parent = actionButton,
	})
	local actionIcon: Frame? = nil
	local actionLabel = Components.label({
		text = "",
		font = Theme.Fonts.heading,
		textSize = 17,
		align = Enum.TextXAlignment.Center,
		size = UDim2.new(1, -16, 0, 40),
		position = UDim2.new(0, 8, 0.62, 0),
		wrap = true,
		stroke = true,
		parent = actionButton,
	})
	actionLabel.ZIndex = 3
	local actionPressed = false
	local function releaseAction()
		if actionPressed then
			actionPressed = false
			InputController.trigger("Use", "End")
			Motion.press(actionButton, false)
		end
	end
	actionButton.InputBegan:Connect(function(input: InputObject)
		if
			input.UserInputType == Enum.UserInputType.Touch
			or input.UserInputType == Enum.UserInputType.MouseButton1
		then
			actionPressed = true
			InputController.trigger("Use", "Begin")
			Motion.press(actionButton, true)
		end
	end)
	actionButton.InputEnded:Connect(function(input: InputObject)
		if
			input.UserInputType == Enum.UserInputType.Touch
			or input.UserInputType == Enum.UserInputType.MouseButton1
		then
			releaseAction()
		end
	end)

	local rotate, rotateLabel = roundButton(touch, "Rotate", SMALL_SIZE, "refresh", C.cyan)
	rotateLabel.Text = Strings.t("hud.rotate")
	local cancel, cancelLabel = roundButton(touch, "Cancel", SMALL_SIZE, "cross", C.red)
	cancelLabel.Text = Strings.t("hud.cancel")
	local drop, dropLabel = roundButton(touch, "Drop", SMALL_SIZE, "suitcase", C.orange)
	dropLabel.Text = Strings.t("hud.drop")
	local ping, pingLabel = roundButton(touch, "Ping", SMALL_SIZE, "pin", C.blue)
	pingLabel.Text = Strings.t("hud.ping")
	for _, button in { rotate, cancel, drop, ping } do
		button.AnchorPoint = Vector2.new(0.5, 0.5)
		button.Visible = false
	end

	-- Room slots live on the bottom bar for keyboards and controllers and join the cluster on touch screens.
	local slotsOnTouch = false
	local function placeSlots(onTouch: boolean)
		if onTouch == slotsOnTouch then
			return
		end
		slotsOnTouch = onTouch
		for _, slot in slots do
			slot.button.Parent = if onTouch then touch else bar
			slot.button.AnchorPoint = if onTouch then Vector2.new(0.5, 0.5) else Vector2.zero
			slot.button.Position = UDim2.new()
			slot.scale.Scale = if onTouch then TOUCH_SLOT_SCALE else 1
		end
	end

	-- Cluster layout (canvas units, centres). Each piece takes its designed spot next to the jump button; a
	-- spot that would leave the screen or touch the thumbstick zone, the top band or another button falls back
	-- to the nearest free place on rings around the jump button.
	local visible = false
	local spectating = false -- out of the run: only Ping stays, so spectators can still point things out
	-- What the last layout was made for (it runs every frame, so it returns early unless something moved).
	local laidOutFor: TouchZones.Zones? = nil
	local laidOutFlags = -1
	local function layoutTouch()
		local gui = parent:FindFirstAncestorOfClass("ScreenGui")
		if not gui or not touch.Visible then
			return
		end
		local zones = TouchZones.current(gui)
		local flags = (if rotate.Visible then 1 else 0)
			+ (if cancel.Visible then 2 else 0)
			+ (if drop.Visible then 4 else 0)
			+ (if spectating then 8 else 0)
		if zones == laidOutFor and flags == laidOutFlags then
			return
		end
		laidOutFor, laidOutFlags = zones, flags
		local canvas = zones.canvas
		local jump = zones.jump
		local centre = zones.jumpCenter

		local taken: { TouchZones.Rect } = { zones.stick, jump, TouchZones.rect(0, 0, canvas.X, Quickbar.TOP_RESERVE) }
		local edge = 8
		local function fits(r: TouchZones.Rect): boolean
			if r.x0 < edge or r.y0 < edge or r.x1 > canvas.X - edge or r.y1 > canvas.Y - edge then
				return false
			end
			for _, other in taken do
				if TouchZones.intersects(r, other) then
					return false
				end
			end
			return true
		end
		local function put(button: GuiObject, w: number, h: number, x: number, y: number): TouchZones.Rect
			local r = TouchZones.centred(x, y, w, h)
			if not fits(r) then
				-- Rings around the jump button, preferring left and up (away from the screen edges).
				local found = false
				local radius = zones.jumpSize / 2 + TOUCH_GAP + math.max(w, h) / 2
				while not found and radius < canvas.X do
					for _, degrees in { 180, 150, 120, 90, 165, 135, 105, 195, 210 } do
						local a = math.rad(degrees)
						local c = centre + Vector2.new(math.cos(a), -math.sin(a)) * radius
						local candidate = TouchZones.centred(c.X, c.Y, w, h)
						if fits(candidate) then
							r = candidate
							found = true
							break
						end
					end
					radius += 16
				end
			end
			table.insert(taken, r)
			button.Position = UDim2.fromOffset(math.round((r.x0 + r.x1) / 2), math.round((r.y0 + r.y1) / 2))
			return r
		end

		-- Row 1, level with Jump: [small buttons] [action] [JUMP].
		local action = put(actionButton, ACTION_SIZE, ACTION_SIZE, jump.x0 - TOUCH_GAP - ACTION_SIZE / 2, centre.Y)
		-- Row 2, above: [Ping] [slot 1] [slot 2], slot 2 over Jump and slot 1 over the action button.
		local slotW, slotH = SLOT_W * TOUCH_SLOT_SCALE, SLOT_H * TOUCH_SLOT_SCALE
		local rowY = jump.y0 - TOUCH_GAP - slotH / 2
		local leftOfRow = (action.x0 + action.x1) / 2 - slotW / 2
		if not spectating then
			local second = put(slots[2].button, slotW, slotH, centre.X, rowY)
			local first = put(slots[1].button, slotW, slotH, (action.x0 + action.x1) / 2, (second.y0 + second.y1) / 2)
			leftOfRow = first.x0
		end
		put(ping, SMALL_SIZE, SMALL_SIZE, leftOfRow - TOUCH_GAP - SMALL_SIZE / 2, rowY)
		-- Contextual buttons, right to left beside the action button.
		local x = action.x0 - TOUCH_GAP - SMALL_SIZE / 2
		for _, button in { cancel, rotate, drop } do
			if button.Visible then
				local r = put(button, SMALL_SIZE, SMALL_SIZE, x, centre.Y)
				x = r.x0 - TOUCH_GAP - SMALL_SIZE / 2
			end
		end
	end
	local hudGui = parent:FindFirstAncestorOfClass("ScreenGui")
	if hudGui then
		TouchZones.track(hudGui)
	end
	TouchZones.Changed:Connect(function()
		laidOutFor = nil
		layoutTouch()
	end)

	rotate.Activated:Connect(function()
		PlacementController.rotate()
	end)
	cancel.Activated:Connect(function()
		local slot = PlacementController.selectedSlot()
		if slot ~= 0 then
			PlacementController.select(slot)
		end
	end)
	-- Drop is a short hold with a filling ring (the hold completes while the finger is still down).
	local dropRing = Components.holdCircle(drop, C.orange)
	dropRing.frame.Visible = false
	local dropDown: number? = nil
	drop.InputBegan:Connect(function(input: InputObject)
		if
			input.UserInputType == Enum.UserInputType.Touch
			or input.UserInputType == Enum.UserInputType.MouseButton1
		then
			dropDown = os.clock()
			dropRing.set(0)
			dropRing.frame.Visible = true
		end
	end)
	drop.InputEnded:Connect(function(input: InputObject)
		if
			input.UserInputType == Enum.UserInputType.Touch
			or input.UserInputType == Enum.UserInputType.MouseButton1
		then
			dropDown = nil
			dropRing.frame.Visible = false
		end
	end)
	-- Tap = contextual ping, long press = the four-way wheel (its options are tapped); tapping Ping again
	-- while the wheel is open puts it away.
	local pingDown: number? = nil
	ping.InputBegan:Connect(function(input: InputObject)
		if
			input.UserInputType == Enum.UserInputType.Touch
			or input.UserInputType == Enum.UserInputType.MouseButton1
		then
			if PingController.isWheelOpen() then
				PingController.closeWheel(false)
				pingDown = nil
				return
			end
			pingDown = os.clock()
		end
	end)
	ping.InputEnded:Connect(function(input: InputObject)
		if
			input.UserInputType == Enum.UserInputType.Touch
			or input.UserInputType == Enum.UserInputType.MouseButton1
		then
			if pingDown and os.clock() - (pingDown :: number) < PING_HOLD_SECONDS then
				PingController.quickPing()
			end
			pingDown = nil
		end
	end)

	local function refreshAction(action: InteractionController.Action?)
		if actionIcon then
			(actionIcon :: Frame):Destroy()
			actionIcon = nil
		end
		if action then
			local made = Icons.make(action.icon, if action.valid then action.color else C.textMuted, C.ink)
			made.Parent = actionIconHolder
			actionIcon = made
			actionLabel.Text = action.text
			actionStroke.Color = if action.valid then action.color else C.red
			actionRing.setColor(action.color)
			actionButton.BackgroundTransparency = 0.1
			actionLabel.TextTransparency = 0
			Motion.pop(actionButton, 0.9)
		else
			actionLabel.Text = ""
			actionStroke.Color = C.shadow
			actionButton.BackgroundTransparency = 0.55
		end
		-- Nothing to do: no empty ring on screen (it would only cover the world above the jump button). A
		-- hidden button gets no InputEnded, so let go of a press that is still down.
		if action == nil then
			releaseAction()
		end
		actionButton.Visible = action ~= nil
	end
	InteractionController.ActionChanged:Connect(refreshAction)
	InteractionController.HoldProgress:Connect(function(progress: number)
		actionRing.set(math.max(0, progress))
	end)
	refreshAction(InteractionController.current())

	RunService.Heartbeat:Connect(function()
		if not touch.Visible then
			return
		end
		if pingDown and os.clock() - (pingDown :: number) >= PING_HOLD_SECONDS then
			pingDown = nil
			PingController.openWheel()
		end
		if dropDown then
			local progress = (os.clock() - (dropDown :: number)) / DROP_HOLD_SECONDS
			dropRing.set(progress)
			if progress >= 1 then
				dropDown = nil
				dropRing.frame.Visible = false
				InputController.trigger("Drop", "Begin")
				InputController.trigger("Drop", "End")
			end
		end
		local candidate = PlacementController.candidate()
		rotate.Visible = not spectating and candidate ~= nil and candidate.dir ~= nil
		cancel.Visible = not spectating and PlacementController.selectedSlot() ~= 0
		drop.Visible = not spectating and localPlayer:GetAttribute("Carrying") == true
		ping.Visible = true
		pingLabel.Text = if localPlayer:GetAttribute("Downed") == true
			then Strings.t("ping.help")
			else Strings.t("hud.ping")
		-- Contextual buttons coming and going move their neighbours (cheap: unchanged layouts return early).
		layoutTouch()
	end)

	local function applyVisibility()
		local onTouch = TouchZones.active()
		placeSlots(onTouch)
		bar.Visible = visible and not onTouch
		for _, slot in slots do
			slot.button.Visible = not spectating
		end
		touch.Visible = (visible or spectating) and onTouch
		laidOutFor = nil
		layoutTouch()
	end
	Device.Changed:Connect(applyVisibility)

	return {
		frame = bar,
		touch = touch,
		setVisible = function(value: boolean)
			visible = value
			applyVisibility()
		end,
		setSpectating = function(value: boolean)
			spectating = value
			applyVisibility()
		end,
	}
end

return Quickbar
