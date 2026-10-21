--!strict
--[[
	LightingController: the mood of each place (A01, A03, S29).

	The lobby is warm and golden; each hotel wing gets its own grade from its Palette theme (fog, ambient)
	plus a tint; the escape adds an alarm-red pulse; being downed drains the colour out of the world.
	All changes are client-side and tweened. Low Effects mode turns off depth of field and softens bloom.
]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage.Shared
local Palette = require(Shared.World.Palette)
local RunInfo = require(script.Parent.Parent.Core.RunInfo)
local SettingsController = require(script.Parent.SettingsController)
local Vfx = require(script.Parent.Parent.Visual.Vfx)

local LightingController = {}
LightingController.priority = 25

type Mood = {
	ambient: Color3,
	outdoor: Color3,
	fog: Color3,
	fogStart: number,
	fogEnd: number,
	tint: Color3,
	saturation: number,
	contrast: number,
	brightness: number,
	exposure: number,
	bloom: number,
	haze: number,
	atmosphereColor: Color3,
}

local THEME_TINT: { [string]: Color3 } = {
	classic = Color3.fromRGB(255, 244, 232),
	laundry = Color3.fromRGB(236, 248, 255),
	boiler = Color3.fromRGB(255, 232, 214),
	greenhouse = Color3.fromRGB(240, 255, 236),
	vault = Color3.fromRGB(236, 238, 255),
	frost = Color3.fromRGB(228, 242, 255),
	lobby = Color3.fromRGB(255, 240, 220),
}

local function moodFor(themeId: string, isLobby: boolean): Mood
	local theme = Palette.get(themeId)
	return {
		ambient = theme.ambient,
		outdoor = theme.ambient:Lerp(Color3.new(1, 1, 1), 0.05),
		fog = theme.fog,
		fogStart = if isLobby then 90 else 50,
		fogEnd = if isLobby then 520 else 360,
		tint = THEME_TINT[themeId] or Color3.new(1, 1, 1),
		saturation = if isLobby then 0.12 else 0.08,
		contrast = 0.1,
		brightness = 0.02,
		exposure = if isLobby then 0.3 else 0.15,
		bloom = 0.55,
		haze = if isLobby then 0.6 else 1.4,
		atmosphereColor = theme.fog:Lerp(Color3.new(1, 1, 1), 0.15),
	}
end

local atmosphere: Atmosphere
local bloom: BloomEffect
local grade: ColorCorrectionEffect
local alarmGrade: ColorCorrectionEffect
local depth: DepthOfFieldEffect

local currentMood: Mood? = nil
local alarm = false
local muted = false

local function ensure<T>(className: string, name: string): T
	local existing = Lighting:FindFirstChild(name)
	if existing and existing.ClassName == className then
		return existing :: any
	end
	local instance = Instance.new(className)
	instance.Name = name
	instance.Parent = Lighting
	return instance :: any
end

local function tween(instance: Instance, seconds: number, goal: { [string]: any })
	TweenService:Create(instance, TweenInfo.new(seconds, Enum.EasingStyle.Sine), goal):Play()
end

local function applyMood(mood: Mood, seconds: number)
	currentMood = mood
	tween(Lighting, seconds, {
		Ambient = mood.ambient,
		OutdoorAmbient = mood.outdoor,
		FogColor = mood.fog,
		FogStart = mood.fogStart,
		FogEnd = mood.fogEnd,
		ExposureCompensation = mood.exposure,
	})
	tween(atmosphere, seconds, { Haze = mood.haze, Color = mood.atmosphereColor, Decay = mood.fog })
	tween(grade, seconds, {
		TintColor = mood.tint,
		Saturation = if muted then -0.75 else mood.saturation,
		Contrast = mood.contrast,
		Brightness = mood.brightness,
	})
	tween(bloom, seconds, { Intensity = if SettingsController.get().lowEffects then 0.25 else mood.bloom })
end

local lastMoodKey = ""

local function refresh(seconds: number?)
	local level = RunInfo.level()
	local inRun = RunInfo.inRunPhase() and level ~= nil and RunInfo.isParticipant()
	local themeId = if inRun then level.theme or "classic" else "lobby"
	local key = themeId .. (if inRun then ":run" else ":lobby")
	if key == lastMoodKey and seconds ~= 0 then
		return
	end
	lastMoodKey = key
	local mood = if inRun then moodFor(themeId, false) else moodFor("lobby", true)
	applyMood(mood, seconds or 1.2)
end

local function applySettings()
	local low = SettingsController.get().lowEffects
	depth.Enabled = not low
	Vfx.setLowEffects(low)
	if currentMood then
		bloom.Intensity = if low then 0.25 else (currentMood :: Mood).bloom
	end
end

function LightingController.setMuted(value: boolean)
	if muted == value then
		return
	end
	muted = value
	if currentMood then
		-- Tween the whole grade: a tween touching only Saturation would cancel a mood tween still in flight
		-- (TweenService cancels the older tween), leaving the previous wing's tint behind.
		local mood = currentMood :: Mood
		tween(grade, 0.6, {
			TintColor = mood.tint,
			Saturation = if muted then -0.75 else mood.saturation,
			Contrast = mood.contrast,
			Brightness = mood.brightness,
		})
	end
end

function LightingController.start()
	atmosphere = ensure("Atmosphere", "RN_Atmosphere")
	atmosphere.Density = 0.32
	atmosphere.Offset = 0
	atmosphere.Glare = 0
	bloom = ensure("BloomEffect", "RN_Bloom")
	bloom.Size = 28
	bloom.Threshold = 1.45
	grade = ensure("ColorCorrectionEffect", "RN_Grade")
	alarmGrade = ensure("ColorCorrectionEffect", "RN_Alarm")
	alarmGrade.TintColor = Color3.new(1, 1, 1)
	alarmGrade.Enabled = true
	depth = ensure("DepthOfFieldEffect", "RN_Depth")
	depth.FarIntensity = 0.12
	depth.FocusDistance = 40
	depth.InFocusRadius = 60
	depth.NearIntensity = 0

	refresh(0)
	applySettings()
	SettingsController.Changed:Connect(applySettings)
	RunInfo.LevelChanged:Connect(function()
		refresh(1.5)
	end)
	-- The escape alarm is for the squad in the hotel, not for players waiting in the lobby.
	local function refreshAlarm()
		local phase = RunInfo.phase()
		alarm = (phase == "Escape" or phase == "Capture") and RunInfo.isParticipant()
	end
	RunInfo.PhaseChanged:Connect(function()
		refreshAlarm()
		refresh(1.2)
	end)
	RunInfo.RosterChanged:Connect(function()
		refreshAlarm()
		refresh(1.2)
	end)
	RunInfo.StatusChanged:Connect(function(status: string)
		LightingController.setMuted(status == "Downed" or status == "Recovering" or status == "Eliminated")
	end)
	-- Alarm pulse: a gentle red breathing tint during the escape (static red with Reduced Motion).
	RunService.Heartbeat:Connect(function()
		if alarm then
			local settings = SettingsController.get()
			local pulse = if settings.reducedMotion then 0.5 else 0.5 + 0.5 * math.sin(os.clock() * 4.4)
			alarmGrade.TintColor = Color3.new(1, 1 - 0.16 * pulse, 1 - 0.2 * pulse)
		elseif alarmGrade.TintColor ~= Color3.new(1, 1, 1) then
			alarmGrade.TintColor = Color3.new(1, 1, 1)
		end
	end)
end

return LightingController
