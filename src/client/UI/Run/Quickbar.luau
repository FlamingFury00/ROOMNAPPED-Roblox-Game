--!strict
--[[
	Quickbar: your two room suitcases and the touch action buttons (U04, U06, U11, S29).

	Bottom centre: one big slot per equipped room - icon, name, key glyph and a state badge (Ready /
	Unfolded / Resting). Selecting a slot lifts it and outlines it in gold; an unfolded room's slot offers
	the recall. Tapping a slot selects it on touch screens.

	Bottom right (touch screens): the context action button (icon + words + hold ring) sits above the
	Roblox jump button, with Turn / Cancel / Drop / Ping buttons that appear only when they apply.
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

local Quickbar = {}

local C = Theme.Colors
local localPlayer = Players.LocalPlayer

export type Handle = { frame: Frame, touch: Frame, setVisible: (boolean) -> () }

type Slot = {
	button: TextButton,
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
		Size = UDim2.fromOffset(112, 122),
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		LayoutOrder = index,
		Parent = parent,
	})
	local face = Create.new("Frame", {
		Name = "Face",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, 0),
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
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0, 2),
		Size = UDim2.fromOffset(0, 24),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = C.green,
		Visible = false,
		ZIndex = 3,
		Parent = face,
	}, { Create.corner(Theme.Radius.pill), Create.padding(2, 8), Create.stroke(C.ink, 2, 0) })
	local badgeText = Components.label({
		text = "",
		font = Theme.Fonts.bodyHeavy,
		textSize = 13,
		color = C.textDark,
		size = UDim2.fromOffset(0, 20),
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

local function roundButton(parent: Instance, name: string, size: number, icon: string, color: Color3): (TextButton, TextLabel)
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
		Position = UDim2.new(0.5, 0, 0.42, 0),
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
		position = UDim2.new(0, 0, 0.7, 0),
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
	}, { Create.list(Enum.FillDirection.Horizontal, 14, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Bottom) })
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
	local touch = Create.new("Frame", {
		Name = "TouchActions",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -24, 1, -250),
		Size = UDim2.fromOffset(330, 200),
		BackgroundTransparency = 1,
		Visible = false,
		Parent = parent,
	})
	local actionButton = Create.new("TextButton", {
		Name = "Action",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, 0, 1, 0),
		Size = UDim2.fromOffset(136, 136),
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
		Position = UDim2.new(0.5, 0, 0.4, 0),
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
	actionButton.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
			InputController.trigger("Use", "Begin")
			Motion.press(actionButton, true)
		end
	end)
	actionButton.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
			InputController.trigger("Use", "End")
			Motion.press(actionButton, false)
		end
	end)

	local small = Create.new("Frame", {
		Name = "Small",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -150, 1, 0),
		Size = UDim2.fromOffset(170, 160),
		BackgroundTransparency = 1,
		Parent = touch,
	}, {
		Create.list(Enum.FillDirection.Horizontal, 10, Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Bottom),
	})
	local rotate, rotateLabel = roundButton(small, "Rotate", 72, "refresh", C.cyan)
	rotateLabel.Text = Strings.t("hud.rotate")
	rotate.LayoutOrder = 3
	local cancel, cancelLabel = roundButton(small, "Cancel", 72, "cross", C.red)
	cancelLabel.Text = Strings.t("hud.cancel")
	cancel.LayoutOrder = 2
	local drop, dropLabel = roundButton(small, "Drop", 72, "suitcase", C.orange)
	dropLabel.Text = Strings.t("hud.drop")
	drop.LayoutOrder = 1
	local ping, pingLabel = roundButton(touch, "Ping", 64, "pin", C.blue)
	pingLabel.Text = Strings.t("hud.ping")
	ping.AnchorPoint = Vector2.new(1, 1)
	ping.Position = UDim2.new(1, -36, 1, -150)

	rotate.Activated:Connect(function()
		PlacementController.rotate()
	end)
	cancel.Activated:Connect(function()
		local slot = PlacementController.selectedSlot()
		if slot ~= 0 then
			PlacementController.select(slot)
		end
	end)
	drop.Activated:Connect(function()
		InputController.trigger("Drop", "Begin")
		InputController.trigger("Drop", "End")
	end)
	-- Tap = contextual ping, long press = wheel.
	local pingDown: number? = nil
	ping.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
			pingDown = os.clock()
		end
	end)
	ping.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
			if pingDown and os.clock() - (pingDown :: number) < 0.35 then
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
		local candidate = PlacementController.candidate()
		rotate.Visible = candidate ~= nil and candidate.dir ~= nil
		cancel.Visible = PlacementController.selectedSlot() ~= 0
		drop.Visible = localPlayer:GetAttribute("Carrying") == true
		pingLabel.Text = if localPlayer:GetAttribute("Downed") == true then Strings.t("ping.help") else Strings.t("hud.ping")
	end)

	local visible = false
	local function applyVisibility()
		bar.Visible = visible
		touch.Visible = visible and (Device.isTouch() or Device.hasTouch() and not Device.isGamepad() and not Device.isKeyboard())
	end
	Device.Changed:Connect(applyVisibility)

	return {
		frame = bar,
		touch = touch,
		setVisible = function(value: boolean)
			visible = value
			applyVisibility()
		end,
	}
end

return Quickbar
