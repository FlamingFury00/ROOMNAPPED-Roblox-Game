--!strict
--[[
	Device: which input family the player is using right now (S29, U06).

	The kind follows the last input the player actually used, so a laptop with a touch screen or a PC
	with a controller plugged in shows the prompts for whatever the player touched last. Prompts,
	hints and the touch action buttons all listen to Device.Changed.
]]

local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Signal = require(ReplicatedStorage.Shared.Util.Signal)

export type Kind = "keyboard" | "touch" | "gamepad"

local Device = {}

Device.Changed = Signal.new() -- (kind)

local function classify(inputType: Enum.UserInputType): Kind?
	if inputType == Enum.UserInputType.Touch then
		return "touch" :: Kind
	elseif
		inputType == Enum.UserInputType.Gamepad1
		or inputType == Enum.UserInputType.Gamepad2
		or inputType == Enum.UserInputType.Gamepad3
		or inputType == Enum.UserInputType.Gamepad4
	then
		return "gamepad" :: Kind
	elseif
		inputType == Enum.UserInputType.Keyboard
		or inputType == Enum.UserInputType.MouseButton1
		or inputType == Enum.UserInputType.MouseButton2
		or inputType == Enum.UserInputType.MouseButton3
		or inputType == Enum.UserInputType.MouseWheel
		or inputType == Enum.UserInputType.MouseMovement
	then
		return "keyboard" :: Kind
	end
	return nil
end

local function initialKind(): Kind
	local fromLast: Kind? = classify(UserInputService:GetLastInputType())
	if fromLast ~= nil then
		return fromLast :: Kind
	end
	if GuiService:IsTenFootInterface() then
		return "gamepad" :: Kind
	end
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		return "touch" :: Kind
	end
	return "keyboard" :: Kind
end

local current: Kind = initialKind()

UserInputService.LastInputTypeChanged:Connect(function(inputType: Enum.UserInputType)
	local kind: Kind? = classify(inputType)
	-- Mouse movement on touch devices is emulated; never let it flip a touch player to keyboard prompts.
	if kind == "keyboard" and inputType == Enum.UserInputType.MouseMovement and current == "touch" then
		return
	end
	if kind ~= nil and kind ~= current then
		current = kind :: Kind
		Device.Changed:Fire(kind)
	end
end)

function Device.kind(): Kind
	return current
end

function Device.isTouch(): boolean
	return current == "touch"
end

function Device.isGamepad(): boolean
	return current == "gamepad"
end

function Device.isKeyboard(): boolean
	return current == "keyboard"
end

-- True when the device has a touch screen at all (used to keep touch buttons available).
function Device.hasTouch(): boolean
	return UserInputService.TouchEnabled
end

-- Small landscape screens (phones). Used to compact layouts and enlarge touch targets.
function Device.isSmallScreen(): boolean
	local camera = Workspace.CurrentCamera
	if not camera then
		return false
	end
	local size = camera.ViewportSize
	return math.min(size.X, size.Y) < 500
end

-- Suffix for device specific string keys ("hint.deploy.keyboard" ...).
function Device.hintSuffix(): string
	return current
end

return Device
