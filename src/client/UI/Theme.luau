--!strict
--[[
	Theme: design tokens for every interface element (U01, A07).

	The palette follows the hotel: deep plum panels, brass/gold accents and cream text. Danger is never shown
	with colour alone - every state also has an icon or a label (S29).
]]

local Theme = {}

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

Theme.Colors = {
	ink = rgb(22, 14, 26),
	panel = rgb(48, 28, 54),
	panelLight = rgb(78, 48, 86),
	panelDark = rgb(30, 18, 36),
	panelGlass = rgb(36, 22, 42),
	gold = rgb(255, 202, 92),
	goldLight = rgb(255, 230, 160),
	goldDark = rgb(184, 122, 36),
	cream = rgb(255, 244, 222),
	text = rgb(255, 247, 235),
	textDim = rgb(214, 190, 204),
	textMuted = rgb(156, 132, 148),
	textDark = rgb(42, 24, 30),
	red = rgb(244, 72, 84),
	redDark = rgb(160, 30, 44),
	green = rgb(96, 218, 124),
	greenDark = rgb(40, 140, 70),
	blue = rgb(96, 176, 255),
	cyan = rgb(120, 230, 255),
	orange = rgb(255, 152, 60),
	purple = rgb(186, 120, 255),
	shadow = rgb(8, 4, 10),
	heart = rgb(255, 74, 98),
	heartEmpty = rgb(78, 50, 66),
	white = rgb(255, 255, 255),
	black = rgb(0, 0, 0),
}

Theme.Fonts = {
	display = Font.new("rbxasset://fonts/families/LuckiestGuy.json", Enum.FontWeight.Regular),
	heading = Font.new("rbxasset://fonts/families/FredokaOne.json", Enum.FontWeight.Regular),
	body = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Medium),
	bodyBold = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Bold),
	bodyHeavy = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.ExtraBold),
	mono = Font.new("rbxasset://fonts/families/RobotoMono.json", Enum.FontWeight.Bold),
	spooky = Font.new("rbxasset://fonts/families/Creepster.json", Enum.FontWeight.Regular),
}

Theme.Text = {
	tiny = 14,
	small = 17,
	body = 20,
	medium = 23,
	large = 27,
	title = 36,
	huge = 54,
	giant = 76,
}

Theme.Radius = {
	small = UDim.new(0, 8),
	medium = UDim.new(0, 14),
	large = UDim.new(0, 22),
	pill = UDim.new(1, 0),
}

Theme.Spacing = {
	tiny = 4,
	small = 8,
	medium = 14,
	large = 22,
	huge = 34,
}

-- Reference resolution the interface is laid out for; Responsive scales from it.
Theme.Reference = Vector2.new(1280, 720)

Theme.Tween = {
	fast = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
	medium = TweenInfo.new(0.25, Enum.EasingStyle.Quart, Enum.EasingDirection.Out),
	slow = TweenInfo.new(0.5, Enum.EasingStyle.Quart, Enum.EasingDirection.Out),
	pop = TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
	bounce = TweenInfo.new(0.55, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out),
}

-- Status colours with paired icons (never colour-only).
Theme.Status = {
	ok = { color = Theme.Colors.green, icon = "check" },
	bad = { color = Theme.Colors.red, icon = "cross" },
	warn = { color = Theme.Colors.orange, icon = "alert" },
	info = { color = Theme.Colors.blue, icon = "info" },
}

return Theme
