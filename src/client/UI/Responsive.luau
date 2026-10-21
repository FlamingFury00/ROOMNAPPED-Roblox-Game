--!strict
--[[
	Responsive: lays every screen out on a virtual 1280x720 canvas and scales it to the real, safe-area
	sized ScreenGui (U01). Phones get a minimum scale so text and touch targets stay readable; the player's
	Text & UI size setting multiplies on top.

	Usage: local root = Responsive.root(screenGui) -- parent your UI to `root`
]]

local Theme = require(script.Parent.Theme)
local Signal = require(game:GetService("ReplicatedStorage").Shared.Util.Signal)

local Responsive = {}

local userScale = 1
local roots: { { gui: ScreenGui, frame: Frame, scale: UIScale } } = {}
Responsive.Changed = Signal.new()

-- 0.62 keeps small text near 11pt and 80px buttons above the 44pt touch-target minimum on phones.
local MIN_SCALE = 0.62
local MAX_SCALE = 1.55

local function compute(size: Vector2): number
	local reference = Theme.Reference
	local s = math.min(size.X / reference.X, size.Y / reference.Y)
	return math.clamp(s, MIN_SCALE, MAX_SCALE) * userScale
end

local function apply(entry: { gui: ScreenGui, frame: Frame, scale: UIScale })
	local size = entry.gui.AbsoluteSize
	if size.X <= 0 or size.Y <= 0 then
		return
	end
	local s = compute(size)
	entry.scale.Scale = s
	entry.frame.Size = UDim2.fromScale(1 / s, 1 / s)
end

function Responsive.root(gui: ScreenGui, name: string?): Frame
	local frame = Instance.new("Frame")
	frame.Name = name or "Root"
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Position = UDim2.fromScale(0, 0)
	frame.AnchorPoint = Vector2.zero
	frame.Size = UDim2.fromScale(1, 1)
	local scale = Instance.new("UIScale")
	scale.Name = "ResponsiveScale"
	scale.Parent = frame
	frame.Parent = gui
	local entry = { gui = gui, frame = frame, scale = scale }
	table.insert(roots, entry)
	apply(entry)
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		apply(entry)
		Responsive.Changed:Fire()
	end)
	return frame
end

-- Current scale for a gui (1 when unknown).
function Responsive.scaleOf(gui: ScreenGui): number
	for _, entry in roots do
		if entry.gui == gui then
			return entry.scale.Scale
		end
	end
	return 1
end

-- Virtual canvas size (in reference pixels) of a responsive root.
function Responsive.canvasSize(gui: ScreenGui): Vector2
	local size = gui.AbsoluteSize
	return size / compute(size)
end

-- Convert a viewport point (Camera:WorldToViewportPoint) to offset pixels inside a responsive root of `gui`.
function Responsive.toCanvas(gui: ScreenGui, viewportPoint: Vector2): Vector2
	local scale = Responsive.scaleOf(gui)
	return (viewportPoint - gui.AbsolutePosition) / math.max(scale, 1e-3)
end

function Responsive.setUserScale(value: number)
	local clamped = math.clamp(value, 0.85, 1.3)
	if clamped == userScale then
		return
	end
	userScale = clamped
	for _, entry in roots do
		apply(entry)
	end
	Responsive.Changed:Fire()
end

-- True on narrow, touch-first screens (phones in landscape).
function Responsive.isCompact(gui: ScreenGui): boolean
	local size = gui.AbsoluteSize
	return size.Y < 500 or size.X < 900
end

return Responsive
