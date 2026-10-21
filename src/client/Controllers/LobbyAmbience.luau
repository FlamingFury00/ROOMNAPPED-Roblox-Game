--!strict
--[[
	LobbyAmbience: small touches that make the lobby feel alive (S25, A08).

	* The floor dials over the departure elevators sweep across during a ride and settle back.
	* Lightning flickers in the night windows now and then, washing the hall in a cold flash.
	* The reception bell can be rung: click or tap it for a ding and a few sparkles.

	Everything is local to each client and does nothing while the lobby is out of sight.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local RunInfo = require(script.Parent.Parent.Core.RunInfo)
local AudioController = require(script.Parent.AudioController)
local Vfx = require(script.Parent.Parent.Visual.Vfx)
local Motion = require(script.Parent.Parent.UI.Motion)

local LobbyAmbience = {}
LobbyAmbience.priority = 80

local NEAR = 120 -- studs from the camera within which the lobby is worth animating

local function cameraPosition(): Vector3?
	local camera = Workspace.CurrentCamera
	return if camera then camera.CFrame.Position else nil
end

-- Floor dials --------------------------------------------------------------------------------------------

local DIAL_REST = math.rad(-70)
local DIAL_END = math.rad(70)

type Needle = { part: BasePart, hinge: CFrame }
local needles: { Needle } = {}
local sweepFrom, sweepTo = DIAL_REST, DIAL_REST
local sweepStart, sweepSeconds = 0, 1
local sweepStyle = Enum.EasingStyle.Sine
local dialAngle = DIAL_REST

local function addNeedle(instance: Instance)
	if not instance:IsA("BasePart") then
		return
	end
	local needle = { part = instance, hinge = instance.CFrame * CFrame.new(0, -instance.Size.Y / 2, 0) }
	table.insert(needles, needle)
	instance.CFrame = needle.hinge * CFrame.Angles(0, 0, -dialAngle) * CFrame.new(0, instance.Size.Y / 2, 0)
end

local function sweep(to: number, seconds: number, style: Enum.EasingStyle)
	sweepFrom, sweepTo = dialAngle, to
	sweepStart, sweepSeconds = os.clock(), if Motion.isReduced() then 0.01 else seconds
	sweepStyle = style
end

-- In-out easing: a sine glide, or a "back" settle that overshoots a little.
local function ease(t: number, style: Enum.EasingStyle): number
	if style == Enum.EasingStyle.Back then
		local c = 1.70158 * 1.525
		if t < 0.5 then
			return ((2 * t) ^ 2 * ((c + 1) * 2 * t - c)) / 2
		end
		return ((2 * t - 2) ^ 2 * ((c + 1) * (t * 2 - 2) + c) + 2) / 2
	end
	return -(math.cos(math.pi * t) - 1) / 2
end

local function stepDials()
	local t = math.clamp((os.clock() - sweepStart) / sweepSeconds, 0, 1)
	local angle = sweepFrom + (sweepTo - sweepFrom) * ease(t, sweepStyle)
	if math.abs(angle - dialAngle) < 1e-4 then
		return
	end
	dialAngle = angle
	for _, needle in needles do
		if needle.part.Parent then
			needle.part.CFrame = needle.hinge * CFrame.Angles(0, 0, -angle) * CFrame.new(0, needle.part.Size.Y / 2, 0)
		end
	end
end

-- Lightning --------------------------------------------------------------------------------------------

type Window = { part: BasePart, color: Color3, light: PointLight }
local windows: { Window } = {}
local nextStrike = os.clock() + 12

local function addWindow(instance: Instance)
	if not instance:IsA("BasePart") then
		return
	end
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(190, 210, 255)
	light.Range = 34
	light.Brightness = 0
	light.Shadows = false
	light.Parent = instance
	table.insert(windows, { part = instance, color = instance.Color, light = light })
end

local function flashWindows(strength: number)
	for _, w in windows do
		if w.part.Parent then
			w.part.Color = w.color:Lerp(Color3.fromRGB(225, 235, 255), strength)
			w.light.Brightness = 3.5 * strength
		end
	end
end

local function settleWindows(seconds: number)
	for _, w in windows do
		if w.part.Parent then
			TweenService:Create(w.part, TweenInfo.new(seconds, Enum.EasingStyle.Quad), { Color = w.color }):Play()
			TweenService:Create(w.light, TweenInfo.new(seconds, Enum.EasingStyle.Quad), { Brightness = 0 }):Play()
		end
	end
end

local function lobbyInView(): boolean
	local eye = cameraPosition()
	if not eye then
		return false
	end
	for _, w in windows do
		if w.part.Parent and (eye - w.part.CFrame.Position).Magnitude < NEAR then
			return true
		end
	end
	return false
end

local function stepLightning()
	if os.clock() < nextStrike then
		return
	end
	nextStrike = os.clock() + 14 + math.random() * 22
	if #windows == 0 or Motion.isReduced() or not lobbyInView() then
		return
	end
	-- A double flicker, then a slow fade.
	flashWindows(1)
	task.delay(0.07, flashWindows, 0.25)
	task.delay(0.16, flashWindows, 0.85)
	task.delay(0.21, settleWindows, 0.9)
end

-- Desk bell --------------------------------------------------------------------------------------------

local function addBell(instance: Instance)
	if not instance:IsA("Model") then
		return
	end
	-- Clicks find only queryable parts; the real bell model may arrive later and replace the fallback.
	local function clickable(d: Instance)
		if d:IsA("BasePart") then
			d.CanQuery = true
		end
	end
	for _, d in instance:GetDescendants() do
		clickable(d)
	end
	instance.DescendantAdded:Connect(clickable)
	local detector = Instance.new("ClickDetector")
	detector.MaxActivationDistance = 14
	detector.Parent = instance
	local lastRing = 0
	pcall(function()
		detector.MouseClick:Connect(function()
			if os.clock() - lastRing < 0.6 then
				return
			end
			lastRing = os.clock()
			local position = instance:GetPivot().Position
			AudioController.at("elevator_ding", position, { volume = 0.8, pitch = 1.05 + math.random() * 0.1 })
			Vfx.burst(position + Vector3.new(0, 0.8, 0), "magic", 8, { Speed = NumberRange.new(2, 5) })
		end)
	end)
end

-- Lifecycle --------------------------------------------------------------------------------------------

local function track(tag: string, add: (Instance) -> ())
	for _, instance in CollectionService:GetTagged(tag) do
		add(instance)
	end
	CollectionService:GetInstanceAddedSignal(tag):Connect(add)
end

function LobbyAmbience.start()
	track("RN_LobbyDialNeedle", addNeedle)
	track("RN_LobbyWindow", addWindow)
	track("RN_DeskBell", addBell)
	RunInfo.PhaseChanged:Connect(function(phase: string)
		if phase == "Launching" then
			sweep(DIAL_END, GameConfig.Squad.ElevatorRideSeconds, Enum.EasingStyle.Sine)
		elseif phase == "Prep" then
			sweep(DIAL_REST, 1.6, Enum.EasingStyle.Back)
		end
	end)
	RunService.Heartbeat:Connect(function()
		stepDials()
		stepLightning()
	end)
end

return LobbyAmbience
