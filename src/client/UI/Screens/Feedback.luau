--!strict
--[[
	Feedback: a two-tap "how was that?" prompt after some expeditions (S26).

	Asked after the 1st and 3rd expedition and then every 5th, at most once per session, and never twice
	in a row - so it gives the team a steady signal without nagging. A star rating is required to send; the
	tag is optional. Skipping is always one tap away.
]]

local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Strings = require(Shared.Config.Strings)
local Net = require(Shared.Net.Net)
local Theme = require(script.Parent.Parent.Theme)
local Create = require(script.Parent.Parent.Create)
local Components = require(script.Parent.Parent.Components)
local Icons = require(script.Parent.Parent.Icons)
local Motion = require(script.Parent.Parent.Motion)
local Toasts = require(script.Parent.Parent.Toasts)
local UIRoot = require(script.Parent.Parent.UIRoot)
local Common = require(script.Parent.Common)
local Results = require(script.Parent.Results)

type ButtonHandle = Components.ButtonHandle

local Feedback = {}
Feedback.priority = 100

local C = Theme.Colors
local TAGS = { "fun", "confusing", "hard", "easy" }
-- The engine's own rounded five-point "favorite" star (white, tinted per state). If it ever fails to load,
-- the rating falls back to the vector star icon.
local STAR_IMAGE = "rbxasset://textures/ui/InspectMenu/ico_favorite@3x.png"
local starImageReady = false

local window: Common.Window
local stars: { TextButton } = {}
local starIcons: { Frame } = {}
local tagButtons: { [string]: ButtonHandle } = {}
local sendButton: ButtonHandle
local rating = 0
local selectedTag: string? = nil
local askedThisSession = false

local function paint()
	for index, holder in starIcons do
		holder:ClearAllChildren()
		local filled = index <= rating
		local color = if filled then C.gold else C.panelLight
		if starImageReady then
			Create.new("ImageLabel", {
				Name = "Star",
				BackgroundTransparency = 1,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromScale(0.84, 0.84), -- 48px source: keep the upscale modest
				Image = STAR_IMAGE,
				ImageColor3 = color,
				ScaleType = Enum.ScaleType.Fit,
				Parent = holder,
			})
		else
			Icons.make("star", color, C.panelDark).Parent = holder
		end
	end
	for tag, handle in tagButtons do
		handle.setVariant(if tag == selectedTag then "primary" else "secondary")
		handle.setSelected(tag == selectedTag)
	end
	sendButton.setEnabled(rating > 0)
end

local function reset()
	rating = 0
	selectedTag = nil
	paint()
end

local function shouldAsk(runs: number): boolean
	if askedThisSession then
		return false
	end
	return runs == 1 or runs == 3 or (runs > 0 and runs % 5 == 0)
end

local function preloadStar()
	task.spawn(function()
		local loaded = false
		pcall(function()
			ContentProvider:PreloadAsync({ STAR_IMAGE }, function(_contentId: string, status: Enum.AssetFetchStatus)
				loaded = status == Enum.AssetFetchStatus.Success
			end)
		end)
		if loaded and not starImageReady then
			starImageReady = true
			paint()
		end
	end)
end

local function build()
	window = Common.window("Feedback", Strings.t("feedback.title"), "star", Vector2.new(700, 470))
	local content = window.content
	local starRow = Create.new("Frame", {
		Name = "Stars",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 100),
		Position = UDim2.fromOffset(0, 10),
		Parent = content,
	}, {
		Create.list(Enum.FillDirection.Horizontal, 14, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center),
	})
	for index = 1, 5 do
		local button = Create.new("TextButton", {
			Name = "Star" .. index,
			BackgroundColor3 = C.panelDark,
			BackgroundTransparency = 0.3,
			Size = UDim2.fromOffset(88, 88),
			Text = "",
			AutoButtonColor = false,
			LayoutOrder = index,
			Selectable = true,
			Parent = starRow,
		}, { Create.corner(Theme.Radius.medium) })
		local holder = Create.new("Frame", {
			Name = "Icon",
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(0.78, 0.78),
			Parent = button,
		})
		button.Activated:Connect(function()
			rating = index
			Components.sound("ui_toggle")
			paint()
			Motion.pop(button, 0.8)
		end)
		table.insert(stars, button)
		table.insert(starIcons, holder)
	end
	local tagRow = Create.new("Frame", {
		Name = "Tags",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 70),
		Position = UDim2.fromOffset(0, 124),
		Parent = content,
	}, {
		Create.list(Enum.FillDirection.Horizontal, 10, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center),
	})
	for index, tag in TAGS do
		tagButtons[tag] = Components.button({
			text = Strings.t("feedback.tag." .. tag),
			variant = "secondary",
			size = UDim2.fromOffset(150, 58),
			textSize = Theme.Text.body,
			layoutOrder = index,
			sound = "ui_toggle",
			onClick = function()
				selectedTag = if selectedTag == tag then nil else tag
				paint()
			end,
			parent = tagRow,
		})
	end
	local buttons = Create.new("Frame", {
		Name = "Buttons",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromScale(0.5, 1),
		Size = UDim2.new(1, 0, 0, 90),
		Parent = content,
	}, {
		Create.list(Enum.FillDirection.Horizontal, 18, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center),
	})
	Components.button({
		name = "Skip",
		text = Strings.t("feedback.skip"),
		variant = "secondary",
		size = UDim2.fromOffset(220, 78),
		layoutOrder = 1,
		onClick = function()
			UIRoot.close("Feedback")
		end,
		parent = buttons,
	})
	sendButton = Components.button({
		name = "Send",
		text = Strings.t("feedback.send"),
		icon = "check",
		iconColor = C.textDark,
		variant = "success",
		size = UDim2.fromOffset(260, 78),
		layoutOrder = 2,
		sound = "ui_success",
		onClick = function()
			if rating <= 0 then
				return
			end
			Net.send("Feedback", rating, selectedTag)
			UIRoot.close("Feedback")
			Toasts.key("success", "feedback.thanks")
		end,
		parent = buttons,
	})
	paint()
end

function Feedback.start()
	build()
	preloadStar()
	UIRoot.register({
		name = "Feedback",
		frame = window.frame,
		onOpen = reset,
		defaultSelection = function(): GuiObject?
			return stars[4]
		end,
	})
	Results.onClosed(function(_payload: any)
		local profile = Common.profile()
		local runs = if profile and type(profile.stats) == "table" then profile.stats.runs or 0 else 0
		if shouldAsk(runs) then
			askedThisSession = true
			task.wait(0.6)
			if not UIRoot.anyOpen() then
				UIRoot.open("Feedback")
			end
		end
	end)
end

return Feedback
