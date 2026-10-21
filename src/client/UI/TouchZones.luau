--!strict
--[[
	TouchZones: where Roblox's own touch controls sit, so the HUD never covers them (U01, A11).

	Roblox draws the thumbstick and the jump button in its TouchGui, in screen pixels inside the core-UI
	safe area. While touch controls are in use the HUD keeps two zones empty:

	  * stick - the thumbstick zone: the left 40 % of the screen below its top third. The dynamic thumbstick
	    appears wherever a thumb lands there and the classic one sits there too, so nothing may be drawn on it.
	  * jump  - the jump button plus a margin. The action buttons are arranged around it, never on it.

	Rects are in canvas units of a responsive root (Responsive.root), ready to use as offset positions. Until
	Roblox has created its TouchGui the zones use the layouts of the default controls: the thumbstick zone,
	and the union of the current and the older jump button positions (Roblox switches between them).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Device = require(script.Parent.Parent.Core.Device)
local Responsive = require(script.Parent.Responsive)

export type Rect = { x0: number, y0: number, x1: number, y1: number }

export type Zones = {
	active: boolean, -- touch controls are on screen
	canvas: Vector2, -- canvas size of the gui
	stick: Rect, -- never draw here: the thumbstick zone
	jump: Rect, -- never draw here: the jump button and its margin
	jumpButton: Rect, -- the jump button itself
	jumpCenter: Vector2,
	jumpSize: number, -- diameter of the jump button
	margin: number, -- canvas units of the margin kept around the controls
}

local TouchZones = {}

TouchZones.Changed = Signal.new() -- (zones) for a tracked gui

-- Screen pixels kept clear around the jump button and the thumbstick zone (fingers outgrow the art).
local MARGIN_PX = 10
-- DynamicThumbstickFrame: Size (0.4, 2/3) from (0, 1/3) of the touch control frame (landscape).
local STICK_WIDTH = 0.4
local STICK_TOP = 1 / 3

function TouchZones.rect(x0: number, y0: number, x1: number, y1: number): Rect
	return { x0 = x0, y0 = y0, x1 = x1, y1 = y1 }
end

function TouchZones.intersects(a: Rect, b: Rect): boolean
	return a.x0 < b.x1 and b.x0 < a.x1 and a.y0 < b.y1 and b.y0 < a.y1
end

function TouchZones.union(a: Rect, b: Rect): Rect
	return {
		x0 = math.min(a.x0, b.x0),
		y0 = math.min(a.y0, b.y0),
		x1 = math.max(a.x1, b.x1),
		y1 = math.max(a.y1, b.y1),
	}
end

function TouchZones.grow(r: Rect, by: number): Rect
	return { x0 = r.x0 - by, y0 = r.y0 - by, x1 = r.x1 + by, y1 = r.y1 + by }
end

-- Rect of an offset-positioned item centred at (x, y).
function TouchZones.centred(x: number, y: number, w: number, h: number): Rect
	return { x0 = x - w / 2, y0 = y - h / 2, x1 = x + w / 2, y1 = y + h / 2 }
end

-- Touch controls are on screen while the player is using touch input.
function TouchZones.active(): boolean
	return Device.isTouch()
end

local function screenRect(object: GuiBase2d): Rect?
	local size = object.AbsoluteSize
	if size.X <= 0 or size.Y <= 0 then
		return nil
	end
	local p = object.AbsolutePosition
	return { x0 = p.X, y0 = p.Y, x1 = p.X + size.X, y1 = p.Y + size.Y }
end

local function child(parent: Instance?, name: string): GuiObject?
	local found = parent and parent:FindFirstChild(name)
	return if found and found:IsA("GuiObject") then found else nil
end

-- Screen-pixel zones: (stick, jumpButton).
local function screenZones(gui: ScreenGui): (Rect, Rect)
	-- Roblox's TouchGui sits next to our ScreenGuis in the PlayerGui.
	local playerGui = gui.Parent
	local touchGui = playerGui and playerGui:FindFirstChild("TouchGui")
	local frame = child(touchGui, "TouchControlFrame")
	local frameRect = (frame and screenRect(frame)) or screenRect(gui) or TouchZones.rect(0, 0, 1280, 720)
	local w, h = frameRect.x1 - frameRect.x0, frameRect.y1 - frameRect.y0

	local stick =
		TouchZones.rect(frameRect.x0, frameRect.y0 + h * STICK_TOP, frameRect.x0 + w * STICK_WIDTH, frameRect.y1)
	local stickFrame = child(frame, "DynamicThumbstickFrame") or child(frame, "ThumbstickFrame")
	local realStick = stickFrame and screenRect(stickFrame)
	if realStick then
		-- The dynamic frame reaches past the safe area on the left; only the part on screen matters.
		stick = TouchZones.union(
			stick,
			TouchZones.rect(math.max(realStick.x0, frameRect.x0), realStick.y0, realStick.x1, realStick.y1)
		)
	end

	local jumpObject = child(frame, "JumpButton")
	local jump = jumpObject and screenRect(jumpObject)
	if not jump then
		local small = math.min(w, h) <= 500
		-- Current controls: 72 / 120 px, inset 64 / (100, 112) from the bottom-right corner.
		local size = if small then 72 else 120
		local current = TouchZones.rect(
			frameRect.x1 - (if small then 64 else 100) - size,
			frameRect.y1 - (if small then 64 else 112) - size,
			frameRect.x1 - (if small then 64 else 100),
			frameRect.y1 - (if small then 64 else 112)
		)
		-- Older controls: 70 / 120 px at (1, -(1.5 size - 10), 1, -size - 20) or (1, ..., 1, -1.75 size).
		local oldSize = if small then 70 else 120
		local oldX = frameRect.x1 - (oldSize * 1.5 - 10)
		local oldY = if small then frameRect.y1 - oldSize - 20 else frameRect.y1 - oldSize * 1.75
		jump = TouchZones.union(current, TouchZones.rect(oldX, oldY, oldX + oldSize, oldY + oldSize))
	end
	return stick, jump :: Rect
end

function TouchZones.get(gui: ScreenGui): Zones
	local scale = math.max(Responsive.scaleOf(gui), 1e-3)
	local origin = gui.AbsolutePosition
	local function toCanvas(r: Rect): Rect
		return {
			x0 = (r.x0 - origin.X) / scale,
			y0 = (r.y0 - origin.Y) / scale,
			x1 = (r.x1 - origin.X) / scale,
			y1 = (r.y1 - origin.Y) / scale,
		}
	end
	local stickPx, jumpPx = screenZones(gui)
	local margin = MARGIN_PX / scale
	local stick = toCanvas(stickPx)
	local jumpButton = toCanvas(jumpPx)
	return {
		active = TouchZones.active(),
		canvas = Responsive.canvasSize(gui),
		stick = TouchZones.rect(stick.x0 - margin, stick.y0 - margin, stick.x1 + margin, stick.y1 + margin),
		jump = TouchZones.grow(jumpButton, margin),
		jumpButton = jumpButton,
		jumpCenter = Vector2.new((jumpButton.x0 + jumpButton.x1) / 2, (jumpButton.y0 + jumpButton.y1) / 2),
		jumpSize = math.min(jumpButton.x1 - jumpButton.x0, jumpButton.y1 - jumpButton.y0),
		margin = margin,
	}
end

local function signature(zones: Zones): string
	local function r(rect: Rect): string
		return string.format(
			"%d,%d,%d,%d",
			math.round(rect.x0),
			math.round(rect.y0),
			math.round(rect.x1),
			math.round(rect.y1)
		)
	end
	return string.format(
		"%s|%d,%d|%s|%s",
		tostring(zones.active),
		math.round(zones.canvas.X),
		math.round(zones.canvas.Y),
		r(zones.stick),
		r(zones.jump)
	)
end

local tracked: { [ScreenGui]: string } = {}
local started = false

local function refresh()
	for gui, last in tracked do
		local zones = TouchZones.get(gui)
		local sig = signature(zones)
		if sig ~= last then
			tracked[gui] = sig
			TouchZones.Changed:Fire(zones, gui)
		end
	end
end

-- Watch a gui: Changed fires (zones, gui) whenever its zones move, the screen changes or touch input starts
-- or stops. Roblox can rebuild its TouchGui at any time, so active zones are re-read twice a second.
function TouchZones.track(gui: ScreenGui)
	if tracked[gui] ~= nil then
		return
	end
	tracked[gui] = signature(TouchZones.get(gui))
	if started then
		return
	end
	started = true
	Device.Changed:Connect(refresh)
	Responsive.Changed:Connect(refresh)
	local clock = 0
	RunService.Heartbeat:Connect(function(dt: number)
		clock += dt
		if clock >= 0.5 then
			clock = 0
			refresh()
		end
	end)
end

return TouchZones
