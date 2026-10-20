--!strict
--[[
	Motion: tween helpers that respect the Reduced Motion setting (S29).

	When reduced motion is on, positional/scale animations snap to their end state and only short fades
	remain, so the interface never relies on movement to communicate.
]]

local TweenService = game:GetService("TweenService")

local Theme = require(script.Parent.Theme)

local Motion = {}

local reduced = false

function Motion.setReduced(value: boolean)
	reduced = value
end

function Motion.isReduced(): boolean
	return reduced
end

function Motion.tween(instance: Instance, info: TweenInfo, goal: { [string]: any }): Tween?
	if reduced then
		for key, value in goal do
			(instance :: any)[key] = value
		end
		return nil
	end
	local tween = TweenService:Create(instance, info, goal)
	tween:Play()
	return tween
end

-- Fades always play (they are gentle and help readability), but are shorter with reduced motion.
function Motion.fade(instance: Instance, info: TweenInfo, goal: { [string]: any }): Tween
	local tweenInfo = info
	if reduced then
		tweenInfo = TweenInfo.new(math.min(info.Time, 0.12))
	end
	local tween = TweenService:Create(instance, tweenInfo, goal)
	tween:Play()
	return tween
end

local function scaleOf(guiObject: GuiObject): UIScale
	local existing = guiObject:FindFirstChild("MotionScale")
	if existing and existing:IsA("UIScale") then
		return existing
	end
	local scale = Instance.new("UIScale")
	scale.Name = "MotionScale"
	scale.Parent = guiObject
	return scale
end

-- A quick "pop" used for confirmations and new information.
function Motion.pop(guiObject: GuiObject, from: number?)
	if reduced then
		return
	end
	local scale = scaleOf(guiObject)
	scale.Scale = from or 0.85
	TweenService:Create(scale, Theme.Tween.pop, { Scale = 1 }):Play()
end

-- Grow-in from zero (panels opening).
function Motion.growIn(guiObject: GuiObject)
	local scale = scaleOf(guiObject)
	if reduced then
		scale.Scale = 1
		return
	end
	scale.Scale = 0.6
	TweenService:Create(scale, Theme.Tween.pop, { Scale = 1 }):Play()
end

-- Subtle press feedback.
function Motion.press(guiObject: GuiObject, down: boolean)
	local scale = scaleOf(guiObject)
	local target = if down then 0.94 else 1
	if reduced then
		scale.Scale = 1
		return
	end
	TweenService:Create(scale, Theme.Tween.fast, { Scale = target }):Play()
end

function Motion.hover(guiObject: GuiObject, over: boolean)
	if reduced then
		return
	end
	local scale = scaleOf(guiObject)
	TweenService:Create(scale, Theme.Tween.fast, { Scale = if over then 1.05 else 1 }):Play()
end

-- Horizontal shake for errors (replaced by a colour flash with reduced motion).
function Motion.shake(guiObject: GuiObject)
	if reduced then
		return
	end
	local origin = guiObject.Position
	task.spawn(function()
		for i = 1, 6 do
			local offset = (if i % 2 == 0 then 1 else -1) * (7 - i)
			guiObject.Position = origin + UDim2.fromOffset(offset, 0)
			task.wait(0.03)
		end
		guiObject.Position = origin
	end)
end

return Motion
