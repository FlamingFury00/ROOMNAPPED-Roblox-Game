--!strict
--[[
	LobbyPrompts: walk up to the mission board or the luggage rack and press the context key - or tap the
	floating prompt - to open the mission board / room collection (U15, U16).

	Prompts are plain BillboardGuis (no ProximityPrompt), so they share the game's input mapping (E / X /
	tap) and look like the rest of the interface. Only the nearest prop within range shows its prompt, and
	nothing shows during an expedition or while a menu is open.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local Strings = require(Shared.Config.Strings)
local MathUtil = require(Shared.Util.MathUtil)
local Device = require(script.Parent.Parent.Parent.Core.Device)
local RunInfo = require(script.Parent.Parent.Parent.Core.RunInfo)
local InputController = require(script.Parent.Parent.Parent.Controllers.InputController)
local Theme = require(script.Parent.Parent.Theme)
local Create = require(script.Parent.Parent.Create)
local Components = require(script.Parent.Parent.Components)
local Icons = require(script.Parent.Parent.Icons)
local Motion = require(script.Parent.Parent.Motion)
local UIRoot = require(script.Parent.Parent.UIRoot)

local LobbyPrompts = {}
LobbyPrompts.priority = 115

local C = Theme.Colors
local RANGE = 13
local player = Players.LocalPlayer

type Target = {
	part: BasePart,
	screen: string,
	gui: BillboardGui,
	pill: TextButton,
	keyBadge: TextLabel,
	tapIcon: Frame,
}

local KINDS: { [string]: { screen: string, textKey: string, icon: string } } = {
	RN_MissionBoard = { screen = "MissionBoard", textKey = "action.missions", icon = "board" },
	RN_CollectionStation = { screen = "Collection", textKey = "action.collection", icon = "suitcase" },
}

local targets: { [BasePart]: Target } = {}
local active: Target? = nil
local accumulator = 0

local function playerGui(): PlayerGui
	return player:WaitForChild("PlayerGui") :: PlayerGui
end

local function refreshBadge(target: Target)
	local label = InputController.keyLabel("Use")
	target.keyBadge.Text = label
	target.keyBadge.Visible = label ~= ""
	target.tapIcon.Visible = label == ""
end

local function open(target: Target)
	if UIRoot.anyOpen() or RunInfo.isParticipant() then
		return
	end
	UIRoot.open(target.screen)
end

local function addTarget(part: Instance, tagName: string)
	if not part:IsA("BasePart") or targets[part] then
		return
	end
	local kind = KINDS[tagName]
	local gui = Create.new("BillboardGui", {
		Name = "RN_Prompt_" .. kind.screen,
		Adornee = part,
		AlwaysOnTop = true,
		LightInfluence = 0,
		Size = UDim2.fromOffset(290, 74),
		StudsOffsetWorldSpace = Vector3.new(0, part.Size.Y / 2 + 1.8, 0),
		MaxDistance = RANGE + 12,
		ResetOnSpawn = false,
		Active = true,
		Enabled = false,
		ClipsDescendants = false,
	})
	local pill = Create.new("TextButton", {
		Name = "Pill",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(0, 62),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = C.panelDark,
		BackgroundTransparency = 0.06,
		Text = "",
		AutoButtonColor = false,
		Parent = gui,
	}, {
		Create.corner(Theme.Radius.pill),
		Create.stroke(C.gold, 2.5, 0),
		Create.padding(8, 16),
		Create.list(Enum.FillDirection.Horizontal, 10, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center),
	})
	local keyBadge = Create.new("TextLabel", {
		Name = "Key",
		Size = UDim2.fromOffset(42, 42),
		BackgroundColor3 = C.gold,
		Text = "",
		TextColor3 = C.textDark,
		FontFace = Theme.Fonts.mono,
		TextSize = 24,
		LayoutOrder = 1,
		Parent = pill,
	}, { Create.corner(Theme.Radius.small), Create.stroke(C.goldDark, 2, 0) })
	local tapIcon = Create.new("Frame", {
		Name = "Tap",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(40, 40),
		LayoutOrder = 1,
		Parent = pill,
	})
	Icons.make("hand", C.gold, C.panelDark).Parent = tapIcon
	local iconHolder = Create.new("Frame", {
		Name = "Icon",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(34, 34),
		LayoutOrder = 2,
		Parent = pill,
	})
	Icons.make(kind.icon, C.cream, C.panelDark).Parent = iconHolder
	Components.label({
		name = "Text",
		text = Strings.t(kind.textKey),
		font = Theme.Fonts.heading,
		textSize = Theme.Text.medium,
		size = UDim2.fromOffset(0, 40),
		autoSize = Enum.AutomaticSize.X,
		layoutOrder = 3,
		stroke = true,
		parent = pill,
	})
	gui.Parent = playerGui()
	local target: Target = {
		part = part,
		screen = kind.screen,
		gui = gui,
		pill = pill,
		keyBadge = keyBadge,
		tapIcon = tapIcon,
	}
	pill.Activated:Connect(function()
		Components.sound("ui_click")
		open(target)
	end)
	refreshBadge(target)
	targets[part] = target
	part.Destroying:Connect(function()
		targets[part] = nil
		if active == target then
			active = nil
		end
		gui:Destroy()
	end)
end

local function setActive(target: Target?)
	if active == target then
		return
	end
	if active then
		active.gui.Enabled = false
	end
	active = target
	if target then
		target.gui.Enabled = true
		Motion.pop(target.pill, 0.7)
	end
end

local function step(dt: number)
	accumulator += dt
	if accumulator < 0.12 then
		return
	end
	accumulator = 0
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") or RunInfo.isParticipant() or UIRoot.anyOpen() then
		setActive(nil)
		return
	end
	local position = root.CFrame.Position
	local best: Target? = nil
	local bestDistance = RANGE
	for part, target in targets do
		local closest = MathUtil.closestPointInBox(part.CFrame, part.Size, position)
		local distance = (closest - position).Magnitude
		if distance <= bestDistance then
			best = target
			bestDistance = distance
		end
	end
	setActive(best)
end

function LobbyPrompts.start()
	for tagName in KINDS do
		for _, part in CollectionService:GetTagged(tagName) do
			addTarget(part, tagName)
		end
		CollectionService:GetInstanceAddedSignal(tagName):Connect(function(part: Instance)
			addTarget(part, tagName)
		end)
	end
	InputController.on("Use", function(state)
		if state == "Begin" and active then
			open(active)
		end
	end)
	Device.Changed:Connect(function()
		for _, target in targets do
			refreshBadge(target)
		end
	end)
	RunService.Heartbeat:Connect(step)
end

return LobbyPrompts
