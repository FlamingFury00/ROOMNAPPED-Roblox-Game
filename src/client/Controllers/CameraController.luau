--!strict
--[[
	CameraController: camera feel on top of the default Roblox camera (S29, U12).

	* shake(amplitude, duration) - trauma-style shake that decays smoothly (off with Camera Shake = off or
	  Reduced Motion).
	* punchFov(amount, seconds) - brief field-of-view kick for launches, alarms and captures.
	* cinematic(shots) - short scripted shots (capture fold, escape start) that always hand the camera back
	  to the player, even if something errors mid-shot.

	Effects are applied after the default camera updates each frame, so player control is never fought.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

local Net = require(ReplicatedStorage.Shared.Net.Net)
local SettingsController = require(script.Parent.SettingsController)
local Motion = require(script.Parent.Parent.UI.Motion)

local CameraController = {}
CameraController.priority = 15

export type Shot = {
	cframe: CFrame, -- camera CFrame at the end of this shot
	focus: Vector3?,
	seconds: number,
	fov: number?,
	style: Enum.EasingStyle?,
}

type Shake = { amplitude: number, duration: number, frequency: number, started: number, seed: number }

local BASE_FOV = 70

local shakes: { Shake } = {}
local fovOffset = 0
local fovTween: NumberValue? = nil
local cinematicDepth = 0
local cinematicToken = 0

local function camera(): Camera
	return Workspace.CurrentCamera :: Camera
end

local function shakeAllowed(): boolean
	local settings = SettingsController.get()
	return settings.cameraShake and not settings.reducedMotion
end

function CameraController.shake(amplitude: number, duration: number, frequency: number?)
	if not shakeAllowed() or amplitude <= 0 then
		return
	end
	if #shakes > 6 then
		table.remove(shakes, 1)
	end
	table.insert(shakes, {
		amplitude = amplitude,
		duration = math.max(0.05, duration),
		frequency = frequency or 18,
		started = os.clock(),
		seed = math.random() * 1000,
	})
end

function CameraController.punchFov(amount: number, seconds: number?)
	if Motion.isReduced() then
		return
	end
	if fovTween then
		fovTween:Destroy()
	end
	local value = Instance.new("NumberValue")
	value.Value = amount
	fovTween = value
	local tween = TweenService:Create(
		value,
		TweenInfo.new(seconds or 0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Value = 0 }
	)
	tween:Play()
	tween.Completed:Once(function()
		if fovTween == value then
			fovTween = nil
		end
		value:Destroy()
	end)
end

function CameraController.isCinematic(): boolean
	return cinematicDepth > 0
end

-- Play a list of shots, then return control. Yields until done. Safe to call while another cinematic plays
-- (the newer one wins).
function CameraController.cinematic(shots: { Shot }, holdSeconds: number?)
	cinematicToken += 1
	local token = cinematicToken
	local cam = camera()
	cinematicDepth += 1
	local ok: boolean, err: any = pcall(function()
		cam.CameraType = Enum.CameraType.Scriptable
		for _, shot in shots do
			if token ~= cinematicToken then
				return
			end
			local goal: { [string]: any } = { CFrame = shot.cframe }
			if shot.fov then
				goal.FieldOfView = shot.fov
			end
			local tween = TweenService:Create(
				cam,
				TweenInfo.new(shot.seconds, shot.style or Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
				goal
			)
			tween:Play()
			tween.Completed:Wait()
		end
		if holdSeconds and holdSeconds > 0 then
			task.wait(holdSeconds)
		end
	end)
	cinematicDepth -= 1
	if token == cinematicToken then
		CameraController.restore()
	end
	if not ok then
		warn("[Camera] cinematic failed:", err)
	end
end

-- Hand the camera back to the player.
function CameraController.restore()
	local cam = camera()
	cam.CameraType = Enum.CameraType.Custom
	cam.FieldOfView = BASE_FOV
	local character = Players.LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid and cam.CameraSubject == nil then
		cam.CameraSubject = humanoid
	end
end

-- Smooth noise in [-1, 1] (sum of sines; cheap and seamless).
local function wobble(t: number, seed: number): number
	return math.sin(t * 1.0 + seed) * 0.5 + math.sin(t * 2.3 + seed * 1.7) * 0.3 + math.sin(t * 4.1 + seed * 0.3) * 0.2
end

local function step()
	local cam = camera()
	if cinematicDepth > 0 then
		return
	end
	local now = os.clock()
	local offset = Vector3.zero
	local roll = 0
	for i = #shakes, 1, -1 do
		local s = shakes[i]
		local t = (now - s.started) / s.duration
		if t >= 1 then
			table.remove(shakes, i)
		else
			local fade = (1 - t) * (1 - t)
			local phase = (now - s.started) * s.frequency
			offset += Vector3.new(wobble(phase, s.seed), wobble(phase, s.seed + 11), 0) * s.amplitude * fade
			roll += wobble(phase, s.seed + 23) * s.amplitude * fade * 0.02
		end
	end
	if offset.Magnitude > 0 or roll ~= 0 then
		cam.CFrame = cam.CFrame * CFrame.new(offset * 0.35) * CFrame.Angles(0, 0, roll)
	end
	local punch = if fovTween then fovTween.Value else 0
	if punch ~= fovOffset then
		fovOffset = punch
		cam.FieldOfView = BASE_FOV + punch
	end
end

function CameraController.start()
	RunService:BindToRenderStep("RN_CameraFx", Enum.RenderPriority.Camera.Value + 1, step)
	-- Server teleports (falls, checkpoints, elevator): drop any shake so the snap reads cleanly.
	Net.listen("Teleported", function()
		table.clear(shakes)
	end)
	SettingsController.Changed:Connect(function()
		if not shakeAllowed() then
			table.clear(shakes)
		end
	end)
end

return CameraController
