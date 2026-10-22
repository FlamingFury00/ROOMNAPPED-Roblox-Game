--!strict
--[[
	LightingController: the mood of each place (A01, A03, S29).

	The lobby is warm and golden; each hotel wing gets its own grade from its Palette theme (fog, ambient)
	plus a tint; the escape adds an alarm-red pulse; being downed drains the colour out of the world.
	All changes are client-side and tweened.

	Low Effects (the setting, or switched on for the session when frames keep running long during a run - a
	session-only value the Settings toggle shows and the player can switch back off) turns off depth of field
	and light shadows, softens bloom and thins particles.
]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Palette = require(Shared.World.Palette)
local RunInfo = require(script.Parent.Parent.Core.RunInfo)
local SettingsController = require(script.Parent.SettingsController)
local Vfx = require(script.Parent.Parent.Visual.Vfx)
local Toasts = require(script.Parent.Parent.UI.Toasts)

local LightingController = {}
LightingController.priority = 25

type Mood = {
	ambient: Color3,
	outdoor: Color3,
	fog: Color3,
	density: number, -- Atmosphere density: how quickly a corridor fades into haze
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
		density = if isLobby then 0.28 else 0.34,
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

-- Automatic Low Effects: frames averaging longer than this for this long during a run.
local AUTO_LOW_FRAME_SECONDS = 1 / 28
local AUTO_LOW_AFTER_SECONDS = 8
local autoTried = false -- one attempt per session
local slowFor = 0
local averageFrame = 1 / 60
local lowApplied: boolean? = nil
-- Lights whose shadows Low Effects switched off, to switch back on. A strong table: the engine may collect an
-- Instance's Lua object while the light lives on, which would drop it from a weak one. Destroyed lights are
-- dropped whenever more are switched off.
local unshadowed: { [Light]: boolean } = {}

local function lowEffects(): boolean
	return SettingsController.get().lowEffects
end

local function applyShadows(root: Instance?, low: boolean)
	if low then
		for light in unshadowed do
			if light.Parent == nil then
				unshadowed[light] = nil
			end
		end
		if root then
			for _, d in root:GetDescendants() do
				if d:IsA("Light") and d.Shadows then
					d.Shadows = false
					unshadowed[d] = true
				end
			end
		end
	else
		for light in unshadowed do
			if light.Parent then
				light.Shadows = true
			end
		end
		table.clear(unshadowed)
	end
end

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
	-- With an Atmosphere in Lighting, Roblox ignores the legacy Fog* properties: distance haze is the
	-- Atmosphere's job.
	tween(Lighting, seconds, {
		Ambient = mood.ambient,
		OutdoorAmbient = mood.outdoor,
		ExposureCompensation = mood.exposure,
	})
	tween(atmosphere, seconds, {
		Density = mood.density,
		Haze = mood.haze,
		Color = mood.atmosphereColor,
		Decay = mood.fog,
	})
	tween(grade, seconds, {
		TintColor = mood.tint,
		Saturation = if muted then -0.75 else mood.saturation,
		Contrast = mood.contrast,
		Brightness = mood.brightness,
	})
	tween(bloom, seconds, { Intensity = if lowEffects() then 0.25 else mood.bloom })
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
	local low = lowEffects()
	if low == lowApplied then
		return
	end
	lowApplied = low
	depth.Enabled = not low
	Vfx.setLowEffects(low)
	if currentMood then
		bloom.Intensity = if low then 0.25 else (currentMood :: Mood).bloom
	end
	applyShadows(Workspace, low)
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
	alarmGrade.Enabled = false -- only during the escape alarm
	depth = ensure("DepthOfFieldEffect", "RN_Depth")
	depth.FarIntensity = 0.12
	depth.FocusDistance = 40
	depth.InFocusRadius = 60
	depth.NearIntensity = 0

	refresh(0)
	applySettings()
	SettingsController.Changed:Connect(applySettings)
	RunInfo.LevelChanged:Connect(function(level: any)
		refresh(1.5)
		-- A new wing arrives with its own shadowed lamps.
		if level and lowEffects() then
			task.spawn(function()
				applyShadows(RunInfo.waitForLevelModel(10), true)
			end)
		end
	end)
	-- The escape alarm is for the squad in the hotel, not for players waiting in the lobby.
	local function refreshAlarm()
		local phase = RunInfo.phase()
		alarm = (phase == "Escape" or phase == "Capture") and RunInfo.isParticipant()
		alarmGrade.Enabled = alarm
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
	RunService.Heartbeat:Connect(function(dt: number)
		-- A device that keeps dropping frames in a run gets Low Effects for the session (not saved), measured
		-- only while the player is in an active run.
		if not autoTried and not lowEffects() and RunInfo.isActivePhase() and RunInfo.isParticipant() then
			averageFrame += (math.min(dt, 0.5) - averageFrame) * 0.1
			slowFor = if averageFrame > AUTO_LOW_FRAME_SECONDS then slowFor + dt else 0
			if slowFor >= AUTO_LOW_AFTER_SECONDS then
				autoTried = true
				if SettingsController.setSessionOverride("lowEffects", true) then
					Toasts.key("info", "toast.autoLowEffects", nil)
				end
			end
		elseif slowFor > 0 then
			slowFor = 0
			averageFrame = 1 / 60
		end
		if alarm then
			local settings = SettingsController.get()
			local pulse = if settings.reducedMotion then 0.5 else 0.5 + 0.5 * math.sin(os.clock() * 4.4)
			alarmGrade.TintColor = Color3.new(1, 1 - 0.16 * pulse, 1 - 0.2 * pulse)
		end
	end)
end

return LightingController
