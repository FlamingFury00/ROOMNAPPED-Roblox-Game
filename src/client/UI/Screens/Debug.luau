--!strict
--[[
	Debug: test tools for admins and Studio (S28).

	One-tap buttons for the DebugService commands (force outcomes, unlock content, health, caretaker,
	teleports, escape timer, diagnostics) plus a free-form command line for anything with arguments
	(e.g. "room S1 Freezer"). Replies from the server are listed underneath. The server re-checks admin
	rights on every command, so this panel only appears for players it already trusts.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Strings = require(Shared.Config.Strings)
local Net = require(Shared.Net.Net)
local ClientState = require(script.Parent.Parent.Parent.Core.ClientState)
local Theme = require(script.Parent.Parent.Theme)
local Create = require(script.Parent.Parent.Create)
local Components = require(script.Parent.Parent.Components)
local UIRoot = require(script.Parent.Parent.UIRoot)
local Common = require(script.Parent.Common)

local Debug = {}
Debug.priority = 100

local C = Theme.Colors
local MAX_LINES = 40

type Command = { label: string, command: string, a: string?, b: string?, variant: Components.ButtonVariant? }

local GROUPS: { { title: string, commands: { Command } } } = {
	{
		title = "Run",
		commands = {
			{ label = "Win", command = "phase", a = "win", variant = "success" },
			{ label = "Fail", command = "phase", a = "fail", variant = "danger" },
			{ label = "Capture", command = "phase", a = "escape" },
			{ label = "To lobby", command = "phase", a = "prep" },
			{ label = "Escape 10s", command = "time", a = "10" },
			{ label = "Escape 90s", command = "time", a = "90" },
		},
	},
	{
		title = "Player",
		commands = {
			{ label = "Down me", command = "down", variant = "danger" },
			{ label = "Heal me", command = "heal", variant = "success" },
			{ label = "TP target", command = "tp", a = "target" },
			{ label = "TP exit", command = "tp", a = "exit" },
			{ label = "TP checkpoint", command = "tp", a = "safe" },
			{ label = "Leave run", command = "disconnect" },
		},
	},
	{
		title = "World",
		commands = {
			{ label = "Caretaker on", command = "caretaker", a = "on" },
			{ label = "Caretaker off", command = "caretaker", a = "off" },
			{ label = "Run id", command = "runid" },
			{ label = "Stats", command = "stats" },
		},
	},
	{
		title = "Profile",
		commands = {
			{ label = "Unlock all", command = "give", a = "all", variant = "blue" },
			{ label = "+1000 credits", command = "give", a = "credits", b = "1000" },
			{ label = "-1000 credits", command = "give", a = "credits", b = "-1000" },
			{ label = "Tutorial done", command = "tutorial", a = "done" },
			{ label = "Tutorial reset", command = "tutorial", a = "reset" },
			{ label = "Reset profile", command = "resetprofile", variant = "danger" },
		},
	},
}

local window: Common.Window
local log: ScrollingFrame
local input: TextBox
local lineCount = 0
local firstButton: GuiObject? = nil

local function addLine(text: string, color: Color3?)
	lineCount += 1
	local label = Components.label({
		text = text,
		font = Theme.Fonts.mono,
		textSize = Theme.Text.small,
		color = color or C.cream,
		wrap = true,
		size = UDim2.new(1, -8, 0, 0),
		autoSize = Enum.AutomaticSize.Y,
		layoutOrder = lineCount,
		parent = log,
	})
	label.TextYAlignment = Enum.TextYAlignment.Top
	local labels = {}
	for _, child in log:GetChildren() do
		if child:IsA("TextLabel") then
			table.insert(labels, child)
		end
	end
	if #labels > MAX_LINES then
		table.sort(labels, function(a, b)
			return a.LayoutOrder < b.LayoutOrder
		end)
		for i = 1, #labels - MAX_LINES do
			labels[i]:Destroy()
		end
	end
	-- Keep the newest reply in view once the list has been laid out.
	task.defer(function()
		pcall(function()
			log.CanvasPosition = Vector2.new(0, math.max(0, log.AbsoluteCanvasSize.Y - log.AbsoluteWindowSize.Y))
		end)
	end)
end

local function run(command: string, a: string?, b: string?)
	addLine("> " .. command .. (if a then " " .. a else "") .. (if b then " " .. b else ""), C.goldLight)
	Net.send("Debug", command, a, b)
end

local function runInput()
	local text = input.Text
	local parts = string.split(text, " ")
	local words = {}
	for _, part in parts do
		if part ~= "" then
			table.insert(words, string.sub(part, 1, 60))
		end
	end
	if #words == 0 then
		return
	end
	run(words[1], words[2], words[3])
	input.Text = ""
end

local function build()
	window = Common.window("Debug", Strings.t("debug.title"), "bolt", Vector2.new(1120, 630))
	local content = window.content
	local left = Common.scroll(content, UDim2.new(0, 620, 1, 0), nil, 8)
	left.Name = "Commands"
	for groupIndex, group in GROUPS do
		Common.heading(left, group.title, "bolt", groupIndex * 2 - 1)
		local grid = Create.new("Frame", {
			Name = "Group_" .. group.title,
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = groupIndex * 2,
			Parent = left,
		})
		local layout = Instance.new("UIGridLayout")
		layout.CellSize = UDim2.fromOffset(190, 56)
		layout.CellPadding = UDim2.fromOffset(8, 8)
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Parent = grid
		for index, item in group.commands do
			local handle = Components.button({
				text = item.label,
				variant = item.variant or "secondary",
				size = UDim2.fromOffset(190, 56),
				textSize = Theme.Text.small,
				layoutOrder = index,
				onClick = function()
					run(item.command, item.a, item.b)
				end,
				parent = grid,
			})
			if firstButton == nil then
				firstButton = handle.instance
			end
		end
	end

	local right = Create.new("Frame", {
		Name = "Console",
		BackgroundColor3 = C.ink,
		BackgroundTransparency = 0.25,
		Position = UDim2.fromOffset(636, 0),
		Size = UDim2.new(1, -636, 1, 0),
		Parent = content,
	}, { Create.corner(Theme.Radius.medium) })
	input = Create.new("TextBox", {
		Name = "Input",
		Position = UDim2.fromOffset(10, 10),
		Size = UDim2.new(1, -150, 0, 56),
		BackgroundColor3 = C.panelDark,
		PlaceholderText = "room S1 Freezer",
		PlaceholderColor3 = C.textMuted,
		Text = "",
		TextColor3 = C.text,
		FontFace = Theme.Fonts.mono,
		TextSize = Theme.Text.body,
		ClearTextOnFocus = false,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = right,
	}, { Create.corner(Theme.Radius.small), Create.stroke(C.gold, 2, 0.3), Create.padding(4, 12) })
	input.FocusLost:Connect(function(enterPressed: boolean)
		if enterPressed then
			runInput()
		end
	end)
	Components.button({
		text = "Run",
		icon = "play",
		variant = "primary",
		size = UDim2.fromOffset(124, 56),
		position = UDim2.new(1, -10, 0, 10),
		anchor = Vector2.new(1, 0),
		textSize = Theme.Text.body,
		onClick = runInput,
		parent = right,
	})
	log = Common.scroll(right, UDim2.new(1, -20, 1, -86), UDim2.fromOffset(10, 76), 4)
	log.Name = "Log"
end

function Debug.start()
	build()
	UIRoot.register({
		name = "Debug",
		frame = window.frame,
		defaultSelection = function(): GuiObject?
			return firstButton
		end,
	})
	Net.listen("DebugReply", function(text: any)
		if type(text) == "string" then
			addLine(text)
		end
	end)
	ClientState.observe("me", "admin", function(value: any)
		if value ~= true and UIRoot.isOpen("Debug") then
			UIRoot.close("Debug")
		end
	end)
end

return Debug
