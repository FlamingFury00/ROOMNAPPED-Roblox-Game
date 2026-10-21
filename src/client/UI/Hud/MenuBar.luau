--!strict
--[[
	MenuBar: the persistent top-right bar (U15, U16, U19).

	Lobby:  [Missions] [Rooms] [Settings]   with the credits pill underneath.
	In run: [Help] [Settings]               (no shopping or loadout changes during an expedition).
	Admins also get a Test tools button. The Menu action (M / gamepad Select) toggles Settings.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage.Shared
local Strings = require(Shared.Config.Strings)
local ClientState = require(script.Parent.Parent.Parent.Core.ClientState)
local Device = require(script.Parent.Parent.Parent.Core.Device)
local RunInfo = require(script.Parent.Parent.Parent.Core.RunInfo)
local InputController = require(script.Parent.Parent.Parent.Controllers.InputController)
local Theme = require(script.Parent.Parent.Theme)
local Create = require(script.Parent.Parent.Create)
local Components = require(script.Parent.Parent.Components)
local Icons = require(script.Parent.Parent.Icons)
local Motion = require(script.Parent.Parent.Motion)
local UIRoot = require(script.Parent.Parent.UIRoot)
local Common = require(script.Parent.Parent.Screens.Common)

type ButtonHandle = Components.ButtonHandle

local MenuBar = {}
MenuBar.priority = 120

local C = Theme.Colors
local BUTTON = 80

type Item = { frame: Frame, button: ButtonHandle, lobbyOnly: boolean, adminOnly: boolean }

local items: { Item } = {}
local root: Frame
local creditsPill: Frame
local creditsLabel: TextLabel
local shownCredits = 0
local creditsValue: NumberValue? = nil

local function makeItem(
	order: number,
	icon: string,
	caption: string,
	variant: Components.ButtonVariant,
	onClick: () -> ()
): Item
	local frame = Create.new("Frame", {
		Name = "Item_" .. icon,
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(BUTTON + 8, BUTTON + 24),
		LayoutOrder = order,
	})
	local button = Components.button({
		icon = icon,
		variant = variant,
		size = UDim2.fromOffset(BUTTON, BUTTON),
		position = UDim2.fromOffset(4, 0),
		name = "Button",
		onClick = onClick,
		parent = frame,
	})
	local holder = button.instance:FindFirstChild("IconHolder", true)
	if holder and holder:IsA("Frame") then
		holder.Size = UDim2.fromScale(0, 0.66)
	end
	Components.label({
		name = "Caption",
		text = caption,
		font = Theme.Fonts.bodyHeavy,
		textSize = Theme.Text.small,
		align = Enum.TextXAlignment.Center,
		size = UDim2.new(1, 0, 0, 22),
		position = UDim2.fromOffset(0, BUTTON + 1),
		stroke = true,
		parent = frame,
	})
	return { frame = frame, button = button, lobbyOnly = false, adminOnly = false }
end

local function refreshKeyHints()
	for _, item in items do
		if item.frame.Name == "Item_gear" then
			local label = InputController.keyLabel("Menu")
			item.button.setKeyHint(if label ~= "" then label else nil)
		end
	end
end

local function refreshVisibility()
	local inRun = RunInfo.isParticipant()
	local admin = Common.isAdmin()
	for _, item in items do
		local visible = true
		if item.lobbyOnly and inRun then
			visible = false
		end
		if item.adminOnly and not admin then
			visible = false
		end
		if item.frame.Name == "Item_question" then
			visible = inRun
		end
		item.frame.Visible = visible
	end
	creditsPill.Visible = not inRun and Common.profile() ~= nil
end

local function setCredits(amount: number, animate: boolean)
	if creditsValue then
		creditsValue:Destroy()
		creditsValue = nil
	end
	if not animate or amount <= shownCredits or Motion.isReduced() then
		shownCredits = amount
		creditsLabel.Text = Common.formatNumber(amount)
		return
	end
	local value = Instance.new("NumberValue")
	value.Value = shownCredits
	creditsValue = value
	value.Changed:Connect(function(v: number)
		creditsLabel.Text = Common.formatNumber(v)
	end)
	local tween = TweenService:Create(value, TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Value = amount,
	})
	tween:Play()
	tween.Completed:Once(function()
		if creditsValue == value then
			creditsLabel.Text = Common.formatNumber(amount)
			creditsValue = nil
		end
		value:Destroy()
	end)
	shownCredits = amount
	Motion.pop(creditsPill, 0.8)
	Components.sound("ui_coin")
end

function MenuBar.start()
	root = Create.new("Frame", {
		Name = "MenuBar",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 10),
		Size = UDim2.fromOffset(0, BUTTON + 24),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundTransparency = 1,
		Parent = UIRoot.Hud,
	}, {
		Create.list(Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Right, Enum.VerticalAlignment.Top),
	})

	local dev = makeItem(1, "bolt", Strings.t("menu.dev"), "blue", function()
		UIRoot.toggle("Debug")
	end)
	dev.adminOnly = true
	local help = makeItem(2, "question", Strings.t("menu.help"), "secondary", function()
		UIRoot.open("Settings", "controls")
	end)
	local missions = makeItem(3, "board", Strings.t("lobby.missions"), "secondary", function()
		UIRoot.toggle("MissionBoard")
	end)
	missions.lobbyOnly = true
	local collection = makeItem(4, "suitcase", Strings.t("menu.rooms"), "secondary", function()
		UIRoot.toggle("Collection")
	end)
	collection.lobbyOnly = true
	local settings = makeItem(5, "gear", Strings.t("lobby.settings"), "secondary", function()
		UIRoot.toggle("Settings")
	end)
	for _, item in { dev, help, missions, collection, settings } do
		item.frame.Parent = root
		table.insert(items, item)
	end

	-- Credits pill (second row, right aligned under the buttons).
	creditsPill = Create.new("Frame", {
		Name = "Credits",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -14, 0, BUTTON + 34),
		Size = UDim2.fromOffset(0, 52),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = C.panelDark,
		BackgroundTransparency = 0.08,
		Visible = false,
		Parent = UIRoot.Hud,
	}, {
		Create.corner(Theme.Radius.pill),
		Create.stroke(C.gold, 2.5, 0),
		Create.padding(6, 16),
		Create.list(Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center),
	})
	local coinHolder = Create.new("Frame", {
		Name = "Coin",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(34, 34),
		LayoutOrder = 1,
		Parent = creditsPill,
	})
	Icons.make("coin", C.gold, C.goldDark).Parent = coinHolder
	creditsLabel = Components.label({
		name = "Amount",
		text = "0",
		font = Theme.Fonts.heading,
		textSize = Theme.Text.large,
		color = C.goldLight,
		size = UDim2.fromOffset(0, 36),
		autoSize = Enum.AutomaticSize.X,
		layoutOrder = 2,
		stroke = true,
		parent = creditsPill,
	})

	local creditsKnown = false
	ClientState.observe("me", "profile", function(profile: any)
		if type(profile) == "table" and type(profile.credits) == "number" then
			setCredits(profile.credits, creditsKnown)
			creditsKnown = true
		end
		refreshVisibility()
	end)
	ClientState.observe("me", "admin", function()
		refreshVisibility()
	end)
	RunInfo.PhaseChanged:Connect(refreshVisibility)
	RunInfo.RosterChanged:Connect(refreshVisibility)
	Device.Changed:Connect(refreshKeyHints)
	InputController.on("Menu", function(state)
		if state ~= "Begin" then
			return
		end
		if UIRoot.top() == "Settings" then
			UIRoot.close("Settings")
		else
			UIRoot.open("Settings")
		end
	end)
	refreshKeyHints()
	refreshVisibility()
end

return MenuBar
