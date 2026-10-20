--!strict
--[[
	Toasts: short notifications at the top of the screen (U14).

	Each toast pairs an icon and a colour with its text (never colour alone), stacks up to three deep, merges
	exact repeats (shows "x2" instead of spamming) and fades out on its own. Server toasts arrive through
	the Toast remote as (kind, stringKey, params); params that are themselves string keys are translated.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Net = require(Shared.Net.Net)
local Strings = require(Shared.Config.Strings)
local Theme = require(script.Parent.Theme)
local Create = require(script.Parent.Create)
local Motion = require(script.Parent.Motion)
local Icons = require(script.Parent.Icons)
local Components = require(script.Parent.Components)
local UIRoot = require(script.Parent.UIRoot)

export type Kind = "info" | "success" | "warn" | "error" | "combo" | "key"

local Toasts = {}

local C = Theme.Colors
local MAX_VISIBLE = 3
local LIFETIME = 3.6

local STYLE: { [string]: { color: Color3, icon: string, sound: string } } = {
	info = { color = C.blue, icon = "info", sound = "ui_notify" },
	success = { color = C.green, icon = "check", sound = "ui_success" },
	warn = { color = C.orange, icon = "alert", sound = "ui_notify" },
	error = { color = C.red, icon = "cross", sound = "ui_error" },
	combo = { color = C.purple, icon = "star", sound = "ui_success" },
	key = { color = C.gold, icon = "key", sound = "ui_coin" },
}

type Entry = { frame: Frame, text: string, count: number, expires: number, label: TextLabel }

local container = Create.new("Frame", {
	Name = "Toasts",
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.new(0.5, 0, 0, 86),
	Size = UDim2.fromOffset(560, 0),
	AutomaticSize = Enum.AutomaticSize.Y,
	BackgroundTransparency = 1,
	Parent = UIRoot.Overlay,
}, {
	Create.list(Enum.FillDirection.Vertical, 8, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Top),
})

local entries: { Entry } = {}
local order = 0

local function remove(entry: Entry)
	local index = table.find(entries, entry)
	if not index then
		return
	end
	table.remove(entries, index)
	local frame = entry.frame
	Motion.fade(frame, Theme.Tween.fast, { BackgroundTransparency = 1 })
	for _, d in frame:GetDescendants() do
		if d:IsA("TextLabel") then
			Motion.fade(d, Theme.Tween.fast, { TextTransparency = 1 })
		elseif d:IsA("UIStroke") then
			Motion.fade(d, Theme.Tween.fast, { Transparency = 1 })
		elseif d:IsA("Frame") and d.BackgroundTransparency < 1 then
			Motion.fade(d, Theme.Tween.fast, { BackgroundTransparency = 1 })
		end
	end
	task.delay(0.2, function()
		frame:Destroy()
	end)
end

-- Translate params whose values are catalogue keys (item names etc.).
local function translateParams(params: { [string]: any }?): { [string]: any }?
	if not params then
		return nil
	end
	local out = {}
	for key, value in params do
		if type(value) == "string" and Strings.has(value) then
			out[key] = Strings.t(value)
		else
			out[key] = value
		end
	end
	return out
end

function Toasts.show(kind: Kind, text: string, silent: boolean?)
	local style = STYLE[kind] or STYLE.info
	-- Merge repeats of the same message.
	for _, entry in entries do
		if entry.text == text then
			entry.count += 1
			entry.expires = os.clock() + LIFETIME
			entry.label.Text = string.format("%s  x%d", text, entry.count)
			Motion.pop(entry.frame, 0.92)
			return
		end
	end
	while #entries >= MAX_VISIBLE do
		remove(entries[1])
	end
	order += 1
	local frame = Create.new("Frame", {
		Name = "Toast",
		Size = UDim2.fromOffset(0, 52),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = C.panelDark,
		BackgroundTransparency = 0.08,
		LayoutOrder = order,
		Parent = container,
	}, {
		Create.corner(Theme.Radius.pill),
		Create.stroke(style.color, 2.5, 0),
		Create.padding(6, 18),
		Create.list(Enum.FillDirection.Horizontal, 10, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center),
	})
	local badge = Create.new("Frame", {
		Name = "Badge",
		Size = UDim2.fromOffset(34, 34),
		BackgroundColor3 = style.color,
		LayoutOrder = 1,
		Parent = frame,
	}, { Create.corner(Theme.Radius.pill) })
	local iconHolder = Create.new("Frame", {
		Name = "Icon",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.68, 0.68),
		BackgroundTransparency = 1,
		Parent = badge,
	})
	Icons.make(style.icon, C.textDark, style.color).Parent = iconHolder
	local label = Components.label({
		name = "Text",
		text = text,
		font = Theme.Fonts.bodyHeavy,
		textSize = Theme.Text.medium,
		size = UDim2.fromOffset(0, 40),
		autoSize = Enum.AutomaticSize.X,
		layoutOrder = 2,
		stroke = true,
		parent = frame,
	})
	local textLimit = Create.new("UISizeConstraint", { MaxSize = Vector2.new(480, 40) })
	textLimit.Parent = label
	label.TextTruncate = Enum.TextTruncate.AtEnd
	local entry: Entry = { frame = frame, text = text, count = 1, expires = os.clock() + LIFETIME, label = label }
	table.insert(entries, entry)
	Motion.pop(frame, 0.7)
	if not silent then
		Components.sound(style.sound)
	end
end

-- Show a catalogue string (key + params).
function Toasts.key(kind: Kind, key: string, params: { [string]: any }?, silent: boolean?)
	Toasts.show(kind, Strings.t(key, translateParams(params)), silent)
end

function Toasts.start()
	Net.listen("Toast", function(kind: any, key: any, params: any)
		if type(kind) ~= "string" or type(key) ~= "string" then
			return
		end
		Toasts.key(kind :: Kind, key, if type(params) == "table" then params else nil)
	end)
	task.spawn(function()
		while true do
			task.wait(0.25)
			local now = os.clock()
			for i = #entries, 1, -1 do
				local entry = entries[i]
				if entry and entry.expires <= now then
					remove(entry)
				end
			end
		end
	end)
end

return Toasts
