--!strict
--[[
	Settings: audio, comfort and controls help (U19, S29).

	Every change applies instantly and is saved to the profile shortly after (SettingsController). The
	controls list always describes the device the player is using right now. During an expedition the
	screen also offers "I'm stuck" (safe respawn at the last checkpoint) and "Leave expedition" (with a
	confirmation, because unbanked loot is lost).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.Config.GameConfig)
local Strings = require(Shared.Config.Strings)
local Net = require(Shared.Net.Net)
local Device = require(script.Parent.Parent.Parent.Core.Device)
local RunInfo = require(script.Parent.Parent.Parent.Core.RunInfo)
local SettingsController = require(script.Parent.Parent.Parent.Controllers.SettingsController)
local Theme = require(script.Parent.Parent.Theme)
local Create = require(script.Parent.Parent.Create)
local Components = require(script.Parent.Parent.Components)
local Responsive = require(script.Parent.Parent.Responsive)
local UIRoot = require(script.Parent.Parent.UIRoot)
local Common = require(script.Parent.Common)

type ButtonHandle = Components.ButtonHandle

local Settings = {}
Settings.priority = 100

local C = Theme.Colors

local window: Common.Window
local scroll: ScrollingFrame
local sliders: { [string]: Components.SliderHandle } = {}
local toggles: { [string]: Components.ToggleHandle } = {}
local controlsHeading: Frame
local controlsList: Frame
local runSection: Frame
local leaveConfirm: Frame
local firstSelectable: GuiObject? = nil

-- Controls help ------------------------------------------------------------------------------------------------

type ControlRow = { label: string, keyboard: string, gamepad: { Enum.KeyCode }?, gamepadText: string, touch: string }

local CONTROL_ROWS: { ControlRow } = {
	{ label = "controls.move", keyboard = "W A S D", gamepadText = "controls.pad.move", touch = "controls.touch.move" },
	{
		label = "controls.camera",
		keyboard = "controls.kb.camera",
		gamepadText = "controls.pad.camera",
		touch = "controls.touch.camera",
	},
	{
		label = "controls.jump",
		keyboard = "controls.kb.jump",
		gamepad = { Enum.KeyCode.ButtonA },
		gamepadText = "A",
		touch = "controls.touch.jump",
	},
	{
		label = "controls.slots",
		keyboard = "1  /  2",
		gamepad = { Enum.KeyCode.DPadLeft, Enum.KeyCode.DPadRight },
		gamepadText = "◀ ▶",
		touch = "controls.touch.slots",
	},
	{
		label = "controls.interact",
		keyboard = "E",
		gamepad = { Enum.KeyCode.ButtonX },
		gamepadText = "X",
		touch = "controls.touch.interact",
	},
	{
		label = "controls.rotate",
		keyboard = "R",
		gamepad = { Enum.KeyCode.ButtonY },
		gamepadText = "Y",
		touch = "controls.touch.rotate",
	},
	{
		label = "controls.cancel",
		keyboard = "Q",
		gamepad = { Enum.KeyCode.ButtonB },
		gamepadText = "B",
		touch = "controls.touch.cancel",
	},
	{
		label = "controls.ping",
		keyboard = "G",
		gamepad = { Enum.KeyCode.DPadUp },
		gamepadText = "▲",
		touch = "controls.touch.ping",
	},
	{
		label = "controls.drop",
		keyboard = "F",
		gamepad = { Enum.KeyCode.DPadDown },
		gamepadText = "▼",
		touch = "controls.touch.drop",
	},
	{
		label = "controls.menu",
		keyboard = "M",
		gamepad = { Enum.KeyCode.ButtonSelect },
		gamepadText = "☰",
		touch = "controls.touch.menu",
	},
}

local function keyCap(parent: Instance, text: string, order: number)
	local cap = Create.new("Frame", {
		Name = "Key",
		BackgroundColor3 = C.cream,
		Size = UDim2.fromOffset(0, 36),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = order,
		Parent = parent,
	}, { Create.corner(Theme.Radius.small), Create.stroke(C.goldDark, 2, 0), Create.padding(2, 12) })
	Components.label({
		text = text,
		font = Theme.Fonts.mono,
		textSize = Theme.Text.body,
		color = C.textDark,
		size = UDim2.fromOffset(0, 32),
		autoSize = Enum.AutomaticSize.X,
		align = Enum.TextXAlignment.Center,
		parent = cap,
	})
end

local function glyph(parent: Instance, keyCode: Enum.KeyCode, fallback: string, order: number)
	local ok, image = pcall(function()
		return UserInputService:GetImageForKeyCode(keyCode)
	end)
	if ok and type(image) == "string" and image ~= "" then
		Create.new("ImageLabel", {
			Name = "Glyph",
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(38, 38),
			Image = image,
			ScaleType = Enum.ScaleType.Fit,
			LayoutOrder = order,
			Parent = parent,
		})
	else
		keyCap(parent, fallback, order)
	end
end

local function rebuildControls()
	for _, child in controlsList:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	local kind = Device.kind()
	for index, row in CONTROL_ROWS do
		local frame = Create.new("Frame", {
			Name = "Control",
			BackgroundColor3 = C.panelDark,
			BackgroundTransparency = if index % 2 == 0 then 0.6 else 0.35,
			Size = UDim2.new(1, 0, 0, 48),
			LayoutOrder = index,
			Parent = controlsList,
		}, { Create.corner(Theme.Radius.small) })
		Components.label({
			text = Strings.t(row.label),
			font = Theme.Fonts.bodyBold,
			textSize = Theme.Text.body,
			size = UDim2.new(0.45, -16, 1, 0),
			position = UDim2.fromOffset(16, 0),
			parent = frame,
		})
		local keys = Create.new("Frame", {
			Name = "Keys",
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -12, 0.5, 0),
			Size = UDim2.new(0.55, -12, 1, -6),
			Parent = frame,
		}, {
			Create.list(
				Enum.FillDirection.Horizontal,
				6,
				Enum.HorizontalAlignment.Right,
				Enum.VerticalAlignment.Center
			),
		})
		if kind == "gamepad" then
			if row.gamepad then
				for i, keyCode in row.gamepad do
					glyph(keys, keyCode, row.gamepadText, i)
				end
			else
				keyCap(keys, Strings.t(row.gamepadText), 1)
			end
		elseif kind == "touch" then
			Components.label({
				text = Strings.t(row.touch),
				font = Theme.Fonts.bodyBold,
				textSize = Theme.Text.small,
				color = C.goldLight,
				align = Enum.TextXAlignment.Right,
				size = UDim2.new(1, 0, 1, 0),
				parent = keys,
			})
		else
			keyCap(keys, if Strings.has(row.keyboard) then Strings.t(row.keyboard) else row.keyboard, 1)
		end
	end
end

-- Build ------------------------------------------------------------------------------------------------------------------

local function build()
	window = Common.window("Settings", Strings.t("settings.title"), "gear", Vector2.new(940, 630))
	scroll = Common.scroll(window.content, UDim2.fromScale(1, 1), nil, 8)
	local pad = scroll:FindFirstChildOfClass("UIPadding")
	if pad then
		pad.PaddingRight = UDim.new(0, 18)
	end
	local order = 0
	local function nextOrder(): number
		order += 1
		return order
	end

	local current = SettingsController.get()
	Common.heading(scroll, Strings.t("settings.audio"), "speaker", nextOrder())
	for _, key in { "music", "sfx", "ambience", "ui" } do
		local handle = Components.slider(Strings.t("settings." .. key), (current :: any)[key], function(value: number)
			SettingsController.set(key, value)
		end, nextOrder())
		handle.frame.Name = "Slider_" .. key
		handle.frame.Parent = scroll
		sliders[key] = handle
		if firstSelectable == nil then
			firstSelectable = handle.frame:FindFirstChild("Hit") :: GuiObject?
		end
	end

	Common.heading(scroll, Strings.t("settings.display"), "eye", nextOrder())
	for _, key in { "reducedMotion", "lowEffects", "hints", "cameraShake" } do
		local handle = Components.toggle(
			Strings.t("settings." .. key),
			(current :: any)[key] == true,
			function(value: boolean)
				SettingsController.set(key, value)
			end,
			nextOrder()
		)
		handle.frame.Name = "Toggle_" .. key
		handle.frame.Parent = scroll
		toggles[key] = handle
	end
	local textScale = Components.slider(Strings.t("settings.textScale"), current.textScale, function(value: number)
		SettingsController.set("textScale", value)
	end, nextOrder(), 0.85, 1.3)
	textScale.frame.Name = "Slider_textScale"
	textScale.frame.Parent = scroll
	sliders.textScale = textScale

	controlsHeading = Common.heading(scroll, Strings.t("settings.controls"), "controller", nextOrder())
	controlsList = Create.new("Frame", {
		Name = "Controls",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = nextOrder(),
		Parent = scroll,
	}, { Create.list(Enum.FillDirection.Vertical, 4) })

	-- In-run actions.
	runSection = Create.new("Frame", {
		Name = "RunActions",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = nextOrder(),
		Parent = scroll,
	}, { Create.list(Enum.FillDirection.Vertical, 8) })
	Common.heading(runSection, Strings.t("settings.expedition"), "door", 1)
	local runButtons = Create.new("Frame", {
		Name = "Buttons",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 84),
		LayoutOrder = 2,
		Parent = runSection,
	}, {
		Create.list(Enum.FillDirection.Horizontal, 14, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center),
	})
	Components.button({
		text = Strings.t("settings.unstuck"),
		icon = "refresh",
		variant = "blue",
		size = UDim2.fromOffset(300, 76),
		textSize = Theme.Text.medium,
		layoutOrder = 1,
		onClick = function()
			Net.send("RequestUnstuck")
			UIRoot.close("Settings")
		end,
		parent = runButtons,
	})
	Components.button({
		text = Strings.t("settings.leaveRun"),
		icon = "door",
		variant = "danger",
		size = UDim2.fromOffset(330, 76),
		textSize = Theme.Text.medium,
		layoutOrder = 2,
		onClick = function()
			UIRoot.open("LeaveConfirm")
		end,
		parent = runButtons,
	})

	Components.label({
		text = Strings.t("settings.version", { version = GameConfig.Version }),
		font = Theme.Fonts.bodyBold,
		textSize = Theme.Text.tiny,
		color = C.textMuted,
		align = Enum.TextXAlignment.Center,
		size = UDim2.new(1, 0, 0, 30),
		layoutOrder = nextOrder(),
		parent = scroll,
	})

	local confirm = Common.confirmFrame(
		"LeaveConfirm",
		Strings.t("settings.leaveRun"),
		Strings.t("settings.leaveConfirm"),
		Strings.t("settings.leaveYes"),
		Strings.t("settings.leaveNo"),
		function()
			Net.send("LeaveRun")
			UIRoot.closeAll()
		end,
		function()
			UIRoot.close("LeaveConfirm")
		end,
		"danger",
		"door"
	)
	leaveConfirm = confirm
end

local function syncWidgets()
	local current = SettingsController.get() :: any
	for key, handle in sliders do
		if type(current[key]) == "number" then
			handle.set(current[key])
		end
	end
	for key, handle in toggles do
		if type(current[key]) == "boolean" and handle.get() ~= current[key] then
			handle.set(current[key])
		end
	end
end

local function scrollToControls()
	task.defer(function()
		local scale = Responsive.scaleOf(UIRoot.Guis.Menus)
		local delta = (controlsHeading.AbsolutePosition.Y - scroll.AbsolutePosition.Y) / math.max(scale, 0.01)
		scroll.CanvasPosition = Vector2.new(0, math.max(0, scroll.CanvasPosition.Y + delta - 8))
	end)
end

function Settings.start()
	build()
	rebuildControls()
	UIRoot.register({
		name = "Settings",
		frame = window.frame,
		onOpen = function(arg: any?)
			syncWidgets()
			runSection.Visible = RunInfo.isParticipant()
			if arg == "controls" then
				scrollToControls()
			else
				scroll.CanvasPosition = Vector2.zero
			end
		end,
		defaultSelection = function(): GuiObject?
			return firstSelectable
		end,
	})
	UIRoot.register({
		name = "LeaveConfirm",
		frame = leaveConfirm,
		keepUnder = true,
		defaultSelection = function(): GuiObject?
			local stay = leaveConfirm:FindFirstChild("Cancel", true)
			return if stay and stay:IsA("GuiObject") then stay else nil
		end,
	})
	SettingsController.Changed:Connect(function(_, key: string?)
		if key == nil then
			syncWidgets()
		end
	end)
	Device.Changed:Connect(rebuildControls)
	RunInfo.PhaseChanged:Connect(function()
		runSection.Visible = RunInfo.isParticipant()
		if not RunInfo.isParticipant() then
			UIRoot.close("LeaveConfirm")
		end
	end)
end

return Settings
