--!strict
--[[
	Icons: crisp vector icons composed from UI primitives (A07) - no uploaded images, so they scale to any
	size and inherit theme colours. Every icon fits a square box (coordinates 0..1, centre anchored).

	Icons.make(name, color?, accent?) -> Frame
]]

local Theme = require(script.Parent.Theme)

local Icons = {}

type Builder = (Frame, Color3, Color3) -> ()

local function shape(
	parent: Instance,
	x: number,
	y: number,
	w: number,
	h: number,
	color: Color3,
	rotation: number?,
	round: number?,
	name: string?
): Frame
	local frame = Instance.new("Frame")
	frame.Name = name or "Shape"
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(x, y)
	frame.Size = UDim2.fromScale(w, h)
	frame.BackgroundColor3 = color
	frame.BorderSizePixel = 0
	frame.Rotation = rotation or 0
	if round and round > 0 then
		local corner = Instance.new("UICorner")
		corner.CornerRadius = if round >= 1 then UDim.new(1, 0) else UDim.new(round, 0)
		corner.Parent = frame
	end
	frame.Parent = parent
	return frame
end

local function circle(parent: Instance, x: number, y: number, d: number, color: Color3, name: string?): Frame
	return shape(parent, x, y, d, d, color, 0, 1, name)
end

local function ring(parent: Instance, x: number, y: number, d: number, color: Color3, thickness: number): Frame
	local frame = shape(parent, x, y, d, d, color, 0, 1, "Ring")
	frame.BackgroundTransparency = 1
	local stroke = Instance.new("UIStroke")
	stroke.Color = color
	stroke.Thickness = thickness
	stroke.Parent = frame
	-- Thickness is in pixels; scale it with the icon size once the icon is laid out (an unparented frame
	-- has no size yet, so the first real value arrives through this signal).
	stroke.Thickness = 1
	frame:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		stroke.Thickness = math.max(1, frame.AbsoluteSize.X * thickness / 10)
	end)
	return frame
end

local function glyph(parent: Instance, text: string, color: Color3, font: Font?, scale: number?): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = "Glyph"
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.52)
	label.Size = UDim2.fromScale(scale or 0.9, scale or 0.9)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextColor3 = color
	label.FontFace = font or Theme.Fonts.heading
	label.TextScaled = true
	label.Parent = parent
	return label
end

local function darker(c: Color3, t: number): Color3
	return c:Lerp(Color3.new(0, 0, 0), t)
end

local function lighter(c: Color3, t: number): Color3
	return c:Lerp(Color3.new(1, 1, 1), t)
end

local builders: { [string]: Builder } = {}

builders.heart = function(f, c)
	circle(f, 0.31, 0.38, 0.46, c)
	circle(f, 0.69, 0.38, 0.46, c)
	shape(f, 0.5, 0.56, 0.47, 0.47, c, 45, 0.12)
	circle(f, 0.3, 0.33, 0.14, lighter(c, 0.55), "Shine")
end

builders.heartEmpty = function(f, c)
	builders.heart(f, c, c)
	local shine = f:FindFirstChild("Shine")
	if shine then
		shine:Destroy()
	end
end

builders.snowflake = function(f, c)
	for i = 0, 2 do
		shape(f, 0.5, 0.5, 0.12, 0.92, c, i * 60, 1)
	end
	for i = 0, 5 do
		local a = math.rad(i * 60 - 90)
		local x, y = 0.5 + math.cos(a) * 0.3, 0.5 + math.sin(a) * 0.3
		shape(f, x, y, 0.08, 0.26, c, i * 60 + 45, 1)
		shape(f, x, y, 0.08, 0.26, c, i * 60 - 45, 1)
	end
	circle(f, 0.5, 0.5, 0.22, lighter(c, 0.4))
end

builders.fan = function(f, c, a)
	for i = 0, 2 do
		local angle = math.rad(i * 120 - 90)
		local x, y = 0.5 + math.cos(angle) * 0.22, 0.5 + math.sin(angle) * 0.22
		shape(f, x, y, 0.5, 0.26, c, i * 120 - 60, 1)
	end
	circle(f, 0.5, 0.5, 0.26, a)
	circle(f, 0.5, 0.5, 0.12, c)
end

builders.drop = function(f, c)
	circle(f, 0.5, 0.6, 0.6, c)
	shape(f, 0.5, 0.41, 0.42, 0.42, c, 45, 0.08)
	circle(f, 0.38, 0.62, 0.15, lighter(c, 0.5), "Shine")
end

builders.leaf = function(f, c)
	shape(f, 0.52, 0.46, 0.5, 0.84, c, 40, 1)
	shape(f, 0.5, 0.5, 0.06, 0.66, darker(c, 0.35), 40, 1)
	shape(f, 0.28, 0.82, 0.08, 0.26, darker(c, 0.35), 40, 1)
end

builders.magnet = function(f, c, a)
	-- Horseshoe drawn as a "U": two arms joined by a rounded base, with silver pole tips.
	shape(f, 0.27, 0.46, 0.24, 0.62, c, 0, 0.3)
	shape(f, 0.73, 0.46, 0.24, 0.62, c, 0, 0.3)
	shape(f, 0.5, 0.7, 0.7, 0.28, c, 0, 1)
	shape(f, 0.5, 0.62, 0.22, 0.22, darker(c, 0.45), 0, 1)
	shape(f, 0.27, 0.2, 0.24, 0.14, a, 0, 0.2)
	shape(f, 0.73, 0.2, 0.24, 0.14, a, 0, 0.2)
end

builders.suitcase = function(f, c, a)
	local handle = shape(f, 0.5, 0.2, 0.36, 0.2, c, 0, 0.4, "Handle")
	handle.BackgroundTransparency = 1
	local stroke = Instance.new("UIStroke")
	stroke.Color = darker(c, 0.25)
	stroke.Thickness = 3
	stroke.Parent = handle
	shape(f, 0.5, 0.6, 0.86, 0.62, c, 0, 0.18, "Body")
	shape(f, 0.3, 0.6, 0.08, 0.62, darker(c, 0.3), 0, 0)
	shape(f, 0.7, 0.6, 0.08, 0.62, darker(c, 0.3), 0, 0)
	shape(f, 0.5, 0.42, 0.18, 0.08, a, 0, 0.3)
end

builders.eye = function(f, c, a)
	shape(f, 0.5, 0.5, 0.92, 0.52, c, 0, 1)
	circle(f, 0.5, 0.5, 0.42, a)
	circle(f, 0.5, 0.5, 0.18, Color3.new(0.05, 0.03, 0.06))
	circle(f, 0.58, 0.42, 0.1, Color3.new(1, 1, 1))
end

builders.eyeClosed = function(f, c)
	shape(f, 0.5, 0.52, 0.86, 0.1, c, 0, 1)
	for i = -1, 1 do
		shape(f, 0.5 + i * 0.26, 0.64, 0.07, 0.2, c, i * 20, 1)
	end
end

builders.clock = function(f, c, a)
	circle(f, 0.5, 0.5, 0.92, c)
	circle(f, 0.5, 0.5, 0.74, a)
	shape(f, 0.5, 0.36, 0.08, 0.3, c, 0, 1)
	shape(f, 0.6, 0.53, 0.08, 0.24, c, 110, 1)
	circle(f, 0.5, 0.5, 0.12, c)
end

builders.key = function(f, c)
	circle(f, 0.3, 0.5, 0.42, c)
	circle(f, 0.3, 0.5, 0.18, darker(c, 0.55))
	shape(f, 0.66, 0.5, 0.5, 0.13, c, 0, 0.3)
	shape(f, 0.78, 0.62, 0.08, 0.2, c, 0, 0.2)
	shape(f, 0.88, 0.6, 0.08, 0.16, c, 0, 0.2)
end

builders.coin = function(f, c)
	circle(f, 0.5, 0.5, 0.92, darker(c, 0.2))
	circle(f, 0.5, 0.47, 0.84, c)
	circle(f, 0.5, 0.47, 0.6, lighter(c, 0.15))
	glyph(f, "C", darker(c, 0.45), Theme.Fonts.heading, 0.5).Position = UDim2.fromScale(0.5, 0.48)
end

builders.star = function(f, c)
	shape(f, 0.5, 0.52, 0.56, 0.56, c, 0, 0.1)
	shape(f, 0.5, 0.52, 0.56, 0.56, c, 45, 0.1)
	circle(f, 0.5, 0.52, 0.4, lighter(c, 0.3))
end

builders.check = function(f, c)
	shape(f, 0.38, 0.62, 0.14, 0.4, c, -45, 1)
	shape(f, 0.62, 0.48, 0.14, 0.7, c, 40, 1)
end

builders.cross = function(f, c)
	shape(f, 0.5, 0.5, 0.15, 0.82, c, 45, 1)
	shape(f, 0.5, 0.5, 0.15, 0.82, c, -45, 1)
end

builders.lock = function(f, c, a)
	local shackle = shape(f, 0.5, 0.34, 0.5, 0.5, c, 0, 1, "Shackle")
	shackle.BackgroundTransparency = 1
	local stroke = Instance.new("UIStroke")
	stroke.Color = c
	stroke.Thickness = 4
	stroke.Parent = shackle
	shape(f, 0.5, 0.66, 0.74, 0.52, c, 0, 0.2)
	circle(f, 0.5, 0.62, 0.14, a)
	shape(f, 0.5, 0.74, 0.07, 0.16, a, 0, 1)
end

builders.gear = function(f, c, a)
	for i = 0, 7 do
		local angle = math.rad(i * 45)
		shape(f, 0.5 + math.cos(angle) * 0.36, 0.5 + math.sin(angle) * 0.36, 0.2, 0.2, c, i * 45, 0.2)
	end
	circle(f, 0.5, 0.5, 0.72, c)
	circle(f, 0.5, 0.5, 0.3, a)
end

builders.pin = function(f, c, a)
	circle(f, 0.5, 0.38, 0.62, c)
	shape(f, 0.5, 0.62, 0.42, 0.42, c, 45, 0.1)
	circle(f, 0.5, 0.38, 0.26, a)
end

builders.alert = function(f, c, a)
	shape(f, 0.5, 0.56, 0.8, 0.8, c, 45, 0.18)
	glyph(f, "!", a, Theme.Fonts.heading, 0.62)
end

builders.info = function(f, c, a)
	circle(f, 0.5, 0.5, 0.92, c)
	glyph(f, "i", a, Theme.Fonts.heading, 0.6)
end

builders.crown = function(f, c, a)
	shape(f, 0.5, 0.72, 0.8, 0.24, c, 0, 0.15)
	for i = -1, 1 do
		shape(f, 0.5 + i * 0.28, 0.5, 0.26, 0.26, c, 45, 0.1)
		circle(f, 0.5 + i * 0.28, 0.3, 0.14, a)
	end
end

builders.flame = function(f, c, a)
	circle(f, 0.5, 0.64, 0.62, c)
	shape(f, 0.5, 0.42, 0.42, 0.42, c, 45, 0.1)
	circle(f, 0.5, 0.7, 0.34, a)
	shape(f, 0.5, 0.58, 0.22, 0.22, a, 45, 0.1)
end

builders.bolt = function(f, c)
	shape(f, 0.56, 0.28, 0.16, 0.5, c, 25, 0.2)
	shape(f, 0.5, 0.5, 0.42, 0.13, c, -10, 0.2)
	shape(f, 0.44, 0.72, 0.16, 0.5, c, 25, 0.2)
end

builders.wind = function(f, c)
	shape(f, 0.44, 0.3, 0.7, 0.11, c, 0, 1)
	shape(f, 0.54, 0.5, 0.84, 0.11, c, 0, 1)
	shape(f, 0.4, 0.7, 0.6, 0.11, c, 0, 1)
end

builders.person = function(f, c)
	circle(f, 0.5, 0.3, 0.38, c)
	shape(f, 0.5, 0.78, 0.72, 0.44, c, 0, 0.5)
end

builders.door = function(f, c, a)
	shape(f, 0.5, 0.52, 0.62, 0.9, c, 0, 0.08)
	circle(f, 0.66, 0.54, 0.1, a)
end

builders.offline = function(f, c)
	local r = ring(f, 0.5, 0.5, 0.8, c, 0.9)
	local _ = r
	shape(f, 0.5, 0.5, 0.12, 0.92, c, 45, 1)
end

builders.zzz = function(f, c)
	glyph(f, "z", c, Theme.Fonts.heading, 0.42).Position = UDim2.fromScale(0.3, 0.68)
	glyph(f, "Z", c, Theme.Fonts.heading, 0.56).Position = UDim2.fromScale(0.66, 0.36)
end

builders.arrowUp = function(f, c)
	shape(f, 0.5, 0.62, 0.2, 0.56, c, 0, 0.3)
	shape(f, 0.37, 0.36, 0.16, 0.46, c, 45, 1)
	shape(f, 0.63, 0.36, 0.16, 0.46, c, -45, 1)
end

builders.refresh = function(f, c)
	ring(f, 0.5, 0.5, 0.72, c, 0.9)
	shape(f, 0.76, 0.26, 0.26, 0.26, c, 45, 0.15)
end

builders.trophy = function(f, c, a)
	shape(f, 0.5, 0.38, 0.6, 0.48, c, 0, 0.35)
	shape(f, 0.5, 0.68, 0.14, 0.2, c, 0, 0)
	shape(f, 0.5, 0.84, 0.46, 0.12, c, 0, 0.3)
	circle(f, 0.5, 0.36, 0.2, a)
end

builders.hand = function(f, c)
	shape(f, 0.5, 0.62, 0.56, 0.5, c, 0, 0.4)
	for i = 0, 3 do
		shape(f, 0.3 + i * 0.13, 0.32, 0.11, 0.36, c, 0, 1)
	end
	shape(f, 0.18, 0.56, 0.11, 0.3, c, -35, 1)
end

-- Isosceles right triangle: half of a 45-degree square, clipped by an axis-aligned frame (rotated children
-- are clipped correctly; only a rotated clipping frame would not clip). (bx, by) is the middle of the flat
-- side, `h` the distance from it to the tip (the flat side is 2h long), `dir` the way the tip points.
local function triangle(parent: Instance, bx: number, by: number, h: number, color: Color3, dir: string?): Frame
	local direction = dir or "right"
	local clip = Instance.new("Frame")
	clip.Name = "TriangleClip"
	clip.BackgroundTransparency = 1
	clip.ClipsDescendants = true
	local square = Instance.new("Frame")
	square.Name = "Shape"
	square.AnchorPoint = Vector2.new(0.5, 0.5)
	square.BackgroundColor3 = color
	square.BorderSizePixel = 0
	square.Rotation = 45
	local side = math.sqrt(2)
	if direction == "right" or direction == "left" then
		clip.Size = UDim2.fromScale(h, 2 * h)
		clip.Position = UDim2.fromScale(if direction == "right" then bx else bx - h, by - h)
		square.Size = UDim2.fromScale(side, side / 2)
		square.Position = UDim2.fromScale(if direction == "right" then 0 else 1, 0.5)
	else
		clip.Size = UDim2.fromScale(2 * h, h)
		clip.Position = UDim2.fromScale(bx - h, if direction == "up" then by - h else by)
		square.Size = UDim2.fromScale(side / 2, side)
		square.Position = UDim2.fromScale(0.5, if direction == "up" then 1 else 0)
	end
	square.Parent = clip
	clip.Parent = parent
	return clip
end

builders.play = function(f, c)
	triangle(f, 0.32, 0.5, 0.4, c, "right")
end

builders.question = function(f, c, a)
	circle(f, 0.5, 0.5, 0.92, c)
	glyph(f, "?", a, Theme.Fonts.heading, 0.66)
end

builders.speaker = function(f, c)
	shape(f, 0.24, 0.5, 0.18, 0.34, c, 0, 0.15)
	triangle(f, 0.62, 0.5, 0.32, c, "left")
	shape(f, 0.74, 0.5, 0.07, 0.3, c, 0, 1)
	shape(f, 0.87, 0.5, 0.07, 0.5, c, 0, 1)
end

builders.sparkle = function(f, c)
	shape(f, 0.5, 0.5, 0.2, 0.92, c, 0, 1)
	shape(f, 0.5, 0.5, 0.92, 0.2, c, 0, 1)
	shape(f, 0.5, 0.5, 0.34, 0.34, c, 45, 0.15)
	circle(f, 0.8, 0.2, 0.16, c)
end

builders.target = function(f, c, a)
	circle(f, 0.5, 0.5, 0.92, c)
	circle(f, 0.5, 0.5, 0.66, a)
	circle(f, 0.5, 0.5, 0.42, c)
	circle(f, 0.5, 0.5, 0.18, a)
end

builders.board = function(f, c, a)
	shape(f, 0.5, 0.5, 0.92, 0.76, c, 0, 0.12)
	shape(f, 0.32, 0.4, 0.26, 0.22, a, -6, 0.1)
	shape(f, 0.66, 0.38, 0.24, 0.2, a, 5, 0.1)
	shape(f, 0.48, 0.68, 0.34, 0.18, a, 3, 0.1)
	circle(f, 0.32, 0.31, 0.08, c)
	circle(f, 0.66, 0.3, 0.08, c)
end

builders.controller = function(f, c, a)
	shape(f, 0.5, 0.5, 0.86, 0.46, c, 0, 0.45)
	shape(f, 0.24, 0.66, 0.24, 0.3, c, 20, 1)
	shape(f, 0.76, 0.66, 0.24, 0.3, c, -20, 1)
	shape(f, 0.3, 0.48, 0.18, 0.06, a, 0, 0.2)
	shape(f, 0.3, 0.48, 0.06, 0.18, a, 0, 0.2)
	circle(f, 0.68, 0.43, 0.08, a)
	circle(f, 0.76, 0.52, 0.08, a)
end

builders.keyboard = function(f, c, a)
	shape(f, 0.5, 0.52, 0.94, 0.56, c, 0, 0.12)
	for row = 0, 1 do
		for col = 0, 4 do
			shape(f, 0.18 + col * 0.16, 0.38 + row * 0.15, 0.1, 0.09, a, 0, 0.2)
		end
	end
	shape(f, 0.5, 0.7, 0.5, 0.08, a, 0, 0.3)
end

builders.crate = function(f, c, a)
	shape(f, 0.5, 0.5, 0.84, 0.84, c, 0, 0.08)
	shape(f, 0.5, 0.5, 0.66, 0.66, a, 0, 0.04)
	shape(f, 0.5, 0.5, 0.12, 0.9, c, 45, 0)
	shape(f, 0.5, 0.5, 0.12, 0.9, c, -45, 0)
end

builders.arrowDown = function(f, c)
	shape(f, 0.5, 0.38, 0.2, 0.56, c, 0, 0.3)
	shape(f, 0.37, 0.64, 0.16, 0.46, c, -45, 1)
	shape(f, 0.63, 0.64, 0.16, 0.46, c, 45, 1)
end

builders.flag = function(f, c, a)
	shape(f, 0.26, 0.5, 0.08, 0.86, c, 0, 1)
	shape(f, 0.56, 0.32, 0.56, 0.36, c, 0, 0.1)
	shape(f, 0.56, 0.32, 0.18, 0.12, a, 0, 0.3)
end

builders.users = function(f, c)
	circle(f, 0.34, 0.32, 0.3, c)
	shape(f, 0.34, 0.72, 0.5, 0.36, c, 0, 0.5)
	circle(f, 0.68, 0.36, 0.26, lighter(c, 0.25))
	shape(f, 0.7, 0.74, 0.44, 0.32, lighter(c, 0.25), 0, 0.5)
end

builders.palette = function(f, c, a)
	circle(f, 0.5, 0.5, 0.9, c)
	circle(f, 0.62, 0.66, 0.2, a)
	circle(f, 0.3, 0.4, 0.14, Color3.fromRGB(255, 90, 110))
	circle(f, 0.48, 0.26, 0.14, Color3.fromRGB(255, 210, 70))
	circle(f, 0.7, 0.34, 0.14, Color3.fromRGB(90, 200, 255))
end

builders.elevator = function(f, c, a)
	shape(f, 0.5, 0.54, 0.82, 0.86, c, 0, 0.08)
	shape(f, 0.33, 0.58, 0.28, 0.66, a, 0, 0.04)
	shape(f, 0.67, 0.58, 0.28, 0.66, a, 0, 0.04)
	triangle(f, 0.5, 0.2, 0.07, a, "up")
end

-- Room id -> icon name.
Icons.roomIcon = {
	Freezer = "snowflake",
	Fan = "fan",
	Laundry = "drop",
	Greenhouse = "leaf",
	Magnet = "magnet",
}

-- Mission hazard id -> icon name.
Icons.hazardIcon = {
	flood = "drop",
	fire = "flame",
	gap = "arrowDown",
	carts = "suitcase",
	electric = "bolt",
	crates = "crate",
}

function Icons.has(name: string): boolean
	return builders[name] ~= nil
end

function Icons.make(name: string, color: Color3?, accent: Color3?): Frame
	local frame = Instance.new("Frame")
	frame.Name = "Icon_" .. name
	frame.BackgroundTransparency = 1
	frame.Size = UDim2.fromScale(1, 1)
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.5)
	local aspect = Instance.new("UIAspectRatioConstraint")
	aspect.AspectRatio = 1
	aspect.Parent = frame
	local builder = builders[name]
	local c = color or Theme.Colors.text
	local a = accent or Theme.Colors.panelDark
	if builder then
		builder(frame, c, a)
	else
		glyph(frame, "?", c)
	end
	-- Remember which shapes are accent details so tinting the icon keeps them readable.
	if a ~= c then
		for _, d in frame:GetDescendants() do
			local accent = (d:IsA("Frame") and d.BackgroundColor3 == a)
				or (d:IsA("TextLabel") and d.TextColor3 == a)
				or (d:IsA("UIStroke") and d.Color == a)
			if accent then
				d:SetAttribute("IconAccent", true)
			end
		end
	end
	return frame
end

-- Recolour an icon's main shapes (used for disabled / state changes). Accent details keep their colour so
-- multi-part icons (boards, faces, suitcases) stay readable.
function Icons.tint(icon: Instance, color: Color3)
	for _, d in icon:GetDescendants() do
		if d:GetAttribute("IconAccent") == true then
			continue
		end
		if d:IsA("Frame") and d.BackgroundTransparency < 1 and d.Name ~= "Shine" then
			d.BackgroundColor3 = color
		elseif d:IsA("UIStroke") then
			d.Color = color
		elseif d:IsA("TextLabel") then
			d.TextColor3 = color
		end
	end
end

return Icons
