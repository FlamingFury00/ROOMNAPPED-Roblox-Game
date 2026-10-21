--!strict
--[[
	Haptics: short controller rumbles for the moments that land on the player personally - a hit, being
	downed, the room folding into the suitcase (S29). Gamepads only, and off with Camera Shake or Reduced
	Motion, like the camera kick each one accompanies.
]]

local HapticService = game:GetService("HapticService")

local Device = require(script.Parent.Parent.Core.Device)
local SettingsController = require(script.Parent.SettingsController)

local Haptics = {}

local GAMEPAD = Enum.UserInputType.Gamepad1
local MOTOR = Enum.VibrationMotor.Large

local token = 0

local function supported(): boolean
	local ok, result = pcall(function(): boolean
		return HapticService:IsVibrationSupported(GAMEPAD) and HapticService:IsMotorSupported(GAMEPAD, MOTOR)
	end)
	return ok and result == true
end

-- Rumble at `strength` (0-1) for `seconds`; a newer pulse replaces an older one.
function Haptics.pulse(strength: number, seconds: number)
	if not Device.isGamepad() then
		return
	end
	local settings = SettingsController.get()
	if not settings.cameraShake or settings.reducedMotion or not supported() then
		return
	end
	token += 1
	local mine = token
	pcall(function()
		HapticService:SetMotor(GAMEPAD, MOTOR, math.clamp(strength, 0, 1))
	end)
	task.delay(seconds, function()
		if mine == token then
			pcall(function()
				HapticService:SetMotor(GAMEPAD, MOTOR, 0)
			end)
		end
	end)
end

return Haptics
