--!strict
--[[
	AudioController: every sound in the game (A06, S29).

	* Four sound groups (Music, Effects, Ambience, Interface) follow the player's volume settings.
	* Every id comes from Config.AudioIds (licensed Creator Store audio - no synthesized sounds). Each name is
	  verified in the background; if an asset fails to load, the next alternate takes over, and running loops
	  are switched in place, so a removed asset never leaves the game silent.
	* A small music director picks the track for the current phase, crossfades between tracks, layers the
	  escape clock and the chase heartbeat, and plays the results sting.
]]

local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local AudioIds = require(Shared.Config.AudioIds)
local GameConfig = require(Shared.Config.GameConfig)
local Components = require(script.Parent.Parent.UI.Components)
local ClientState = require(script.Parent.Parent.Core.ClientState)
local RunInfo = require(script.Parent.Parent.Core.RunInfo)
local SettingsController = require(script.Parent.SettingsController)

export type GroupName = "Music" | "Effects" | "Ambience" | "Interface"

export type PlayOptions = {
	volume: number?,
	pitch: number?,
	group: GroupName?,
	position: Vector3?,
	parent: Instance?,
	looped: boolean?,
	rolloffMin: number?,
	rolloffMax: number?,
	fadeIn: number?,
	timePosition: number?,
}

export type LoopHandle = {
	sound: Sound,
	stop: (fade: number?) -> (),
	setVolume: (number, fade: number?) -> (),
	setPitch: (number) -> (),
}

local AudioController = {}

local GROUP_BASE: { [GroupName]: number } = { Music = 0.42, Effects = 0.9, Ambience = 0.6, Interface = 0.55 }
local GROUP_SETTING: { [GroupName]: string } =
	{ Music = "music", Effects = "sfx", Ambience = "ambience", Interface = "ui" }

-- Per-asset loudness trims so stings, loops and clicks sit together in the mix.
local TRIM: { [string]: number } = {
	ui_click = 0.55,
	ui_hover = 0.18,
	ui_toggle = 0.45,
	ui_open = 0.4,
	ui_close = 0.4,
	ui_error = 0.5,
	ui_notify = 0.45,
	ui_coin = 0.6,
	ui_countdown_tick = 0.5,
	ui_countdown_go = 0.6,
	ui_ready = 0.5,
	ui_success = 0.55,
	ui_reward = 0.5,
	capture_charge_loop = 0.45,
	caretaker_hum_loop = 0.6,
	caretaker_step = 0.45,
	caretaker_keys = 0.5,
	caretaker_search = 0.5,
	caretaker_alert = 0.7,
	clock_tick_loop = 0.35,
	heartbeat_loop = 0.6,
	hotel_ambience_loop = 0.45,
	electric_loop = 0.35,
	fire_loop = 0.45,
	water_loop = 0.35,
	wind_loop = 0.35,
	fan_motor_loop = 0.35,
	magnet_hum = 0.35,
	elevator_move_loop = 0.5,
	player_hurt = 0.55,
	player_downed = 0.6,
	room_unfold = 0.6,
	room_fold = 0.6,
	splash = 0.6,
	freeze = 0.6,
	ice_crack = 0.5,
	music_lobby = 0.8,
	music_explore = 0.7,
	music_escape = 0.75,
	music_tutorial = 0.75,
	music_results_win = 0.85,
	music_results_fail = 0.8,
}

local groups: { [GroupName]: SoundGroup } = {} :: any
local resolved: { [string]: number } = {}
local failedIds: { [number]: boolean } = {}
local liveLoops: { [Sound]: string } = {}
local muffles: { EqualizerSoundEffect } = {}

local function assetUrl(id: number): string
	return "rbxassetid://" .. tostring(id)
end

local function idFor(name: string): number?
	local entry = AudioIds[name]
	if not entry then
		return nil
	end
	return resolved[name] or entry.id
end

local function groupVolume(group: GroupName): number
	local settings = SettingsController.get() :: any
	local value = settings[GROUP_SETTING[group]]
	return GROUP_BASE[group] * (if type(value) == "number" then value else 1)
end

local function applyVolumes()
	for name, group in groups do
		group.Volume = groupVolume(name :: GroupName)
	end
end

local function ensureGroups()
	for name in GROUP_BASE do
		local existing = SoundService:FindFirstChild("RN_" .. name)
		local group: SoundGroup
		if existing and existing:IsA("SoundGroup") then
			group = existing
		else
			group = Instance.new("SoundGroup")
			group.Name = "RN_" .. name
			group.Parent = SoundService
		end
		groups[name :: GroupName] = group
		if name == "Effects" or name == "Ambience" then
			local eq = Instance.new("EqualizerSoundEffect")
			eq.Name = "Muffle"
			eq.LowGain = 2
			eq.MidGain = -6
			eq.HighGain = -24
			eq.Enabled = false
			eq.Parent = group
			table.insert(muffles, eq)
		end
	end
	applyVolumes()
end

-- Verification ----------------------------------------------------------------------------------------

local function probe(id: number): boolean
	local sound = Instance.new("Sound")
	sound.SoundId = assetUrl(id)
	local status: Enum.AssetFetchStatus? = nil
	local ok = pcall(function()
		ContentProvider:PreloadAsync({ sound }, function(_contentId: string, fetchStatus: Enum.AssetFetchStatus)
			status = fetchStatus
		end)
	end)
	sound:Destroy()
	return ok and status == Enum.AssetFetchStatus.Success
end

local function switchLoops(name: string, id: number)
	for sound, soundName in liveLoops do
		if soundName == name and sound.Parent then
			local playing = sound.IsPlaying
			sound.SoundId = assetUrl(id)
			if playing then
				sound:Play()
			end
		end
	end
end

local function verify(name: string)
	local entry = AudioIds[name]
	if not entry then
		return
	end
	local candidates = { entry.id }
	for _, alt in entry.alternates do
		table.insert(candidates, alt)
	end
	for _, id in candidates do
		if not failedIds[id] then
			if probe(id) then
				if resolved[name] ~= id and id ~= entry.id then
					resolved[name] = id
					switchLoops(name, id)
				end
				resolved[name] = id
				return
			end
			failedIds[id] = true
		end
	end
end

local PRIORITY = {
	"ui_click",
	"ui_hover",
	"ui_open",
	"ui_close",
	"ui_toggle",
	"ui_error",
	"ui_notify",
	"music_lobby",
	"music_tutorial",
	"music_explore",
	"room_select",
	"room_unfold",
	"room_fold",
	"freeze",
}

local function verifyAll()
	local done: { [string]: boolean } = {}
	for _, name in PRIORITY do
		verify(name)
		done[name] = true
	end
	local rest = {}
	for name in AudioIds do
		if not done[name] then
			table.insert(rest, name)
		end
	end
	table.sort(rest)
	for _, name in rest do
		verify(name)
	end
end

-- Playback ----------------------------------------------------------------------------------------------

local function tweenVolume(sound: Sound, target: number, seconds: number): Tween?
	if seconds <= 0 then
		sound.Volume = target
		return nil
	end
	local tween = TweenService:Create(sound, TweenInfo.new(seconds, Enum.EasingStyle.Sine), { Volume = target })
	tween:Play()
	return tween
end

-- Play a sound. 2D unless `position` or a spatial `parent` (BasePart/Attachment) is given.
function AudioController.play(name: string, opts: PlayOptions?): Sound?
	local o: PlayOptions = opts or {}
	local id = idFor(name)
	if not id then
		return nil
	end
	local sound = Instance.new("Sound")
	sound.Name = name
	sound.SoundId = assetUrl(id)
	local volume = (o.volume or 1) * (TRIM[name] or 0.65)
	sound.Volume = if o.fadeIn then 0 else volume
	sound.PlaybackSpeed = o.pitch or 1
	sound.SoundGroup = groups[(o.group or "Effects") :: GroupName]
	sound.Looped = o.looped == true
	if o.timePosition then
		sound.TimePosition = o.timePosition
	end
	local holder: Instance? = nil
	if o.position then
		local attachment = Instance.new("Attachment")
		attachment.Name = "SoundAt_" .. name
		attachment.WorldPosition = o.position
		attachment.Parent = Workspace.Terrain
		holder = attachment
		sound.Parent = attachment
	elseif o.parent then
		sound.Parent = o.parent
	else
		sound.Parent = SoundService
	end
	if o.position or (o.parent and (o.parent:IsA("BasePart") or o.parent:IsA("Attachment"))) then
		sound.RollOffMode = Enum.RollOffMode.InverseTapered
		sound.RollOffMinDistance = o.rolloffMin or 12
		sound.RollOffMaxDistance = o.rolloffMax or 140
	end
	sound:Play()
	if o.fadeIn then
		tweenVolume(sound, volume, o.fadeIn :: number)
	end
	if sound.Looped then
		liveLoops[sound] = name
		sound.Destroying:Connect(function()
			liveLoops[sound] = nil
		end)
	else
		local function cleanup()
			if holder then
				holder:Destroy()
			else
				sound:Destroy()
			end
		end
		sound.Ended:Once(cleanup)
		-- Safety net for sounds that never load or never fire Ended.
		task.delay(30, function()
			if sound.Parent then
				cleanup()
			end
		end)
	end
	return sound
end

function AudioController.ui(name: string, volume: number?)
	AudioController.play(name, { group = "Interface", volume = volume })
end

function AudioController.at(name: string, position: Vector3, opts: PlayOptions?): Sound?
	local o: PlayOptions = if opts then table.clone(opts) else {}
	o.position = position
	return AudioController.play(name, o)
end

-- A managed loop. Stop it through the handle (fades out, then destroys).
function AudioController.loop(name: string, opts: PlayOptions?): LoopHandle?
	local o: PlayOptions = if opts then table.clone(opts) else {}
	o.looped = true
	local sound = AudioController.play(name, o)
	if not sound then
		return nil
	end
	local base = TRIM[name] or 0.65
	local stopped = false
	local handle: LoopHandle = {
		sound = sound,
		stop = function(fade: number?)
			if stopped then
				return
			end
			stopped = true
			local seconds = fade or 0.4
			local holder = if sound.Parent
					and sound.Parent:IsA("Attachment")
					and sound.Parent.Parent == Workspace.Terrain
				then sound.Parent
				else nil
			local tween = tweenVolume(sound, 0, seconds)
			local function finish()
				if holder then
					holder:Destroy()
				else
					sound:Destroy()
				end
			end
			if tween then
				tween.Completed:Once(finish)
			else
				finish()
			end
		end,
		setVolume = function(v: number, fade: number?)
			if stopped then
				return
			end
			tweenVolume(sound, v * base, fade or 0.25)
		end,
		setPitch = function(p: number)
			sound.PlaybackSpeed = p
		end,
	}
	return handle
end

-- Muffle world sounds (downed / spectating) with a low-pass style EQ.
function AudioController.setMuffled(enabled: boolean)
	for _, eq in muffles do
		eq.Enabled = enabled
	end
end

-- Music director ------------------------------------------------------------------------------------------

local currentMusicName: string? = nil
local currentMusic: LoopHandle? = nil
local stingPlaying = false
local ambience: LoopHandle? = nil
local ambienceName: string? = nil
local clockLoop: LoopHandle? = nil
local heartbeat: LoopHandle? = nil
local duck = 1

function AudioController.setMusic(name: string?, fade: number?)
	if name == currentMusicName then
		return
	end
	local seconds = fade or 1.2
	if currentMusic then
		currentMusic.stop(seconds)
		currentMusic = nil
	end
	currentMusicName = name
	if name then
		currentMusic = AudioController.loop(name, { group = "Music", fadeIn = seconds, volume = duck })
	end
end

-- Temporarily lower the music (cinematics, results).
function AudioController.setDuck(value: number, fade: number?)
	duck = value
	if currentMusic then
		currentMusic.setVolume(value, fade or 0.4)
	end
end

function AudioController.setAmbience(name: string?)
	if name == ambienceName then
		return
	end
	if ambience then
		ambience.stop(1.5)
		ambience = nil
	end
	ambienceName = name
	if name then
		ambience = AudioController.loop(name, { group = "Ambience", fadeIn = 2 })
	end
end

function AudioController.playSting(name: string)
	AudioController.setMusic(nil, 0.4)
	stingPlaying = true
	local sound = AudioController.play(name, { group = "Music" })
	local released = false
	local function release()
		if released then
			return
		end
		released = true
		stingPlaying = false
		AudioController.refreshMusic()
	end
	if sound then
		sound.Ended:Once(release)
	end
	task.delay(9, release)
end

local function desiredMusic(): string?
	local phase = RunInfo.phase()
	if phase == "Prep" then
		return "music_lobby"
	elseif phase == "Launching" then
		return nil
	elseif phase == "Explore" then
		return if RunInfo.isTutorial() then "music_tutorial" else "music_explore"
	elseif phase == "Capture" or phase == "Escape" then
		return "music_escape"
	elseif phase == "Results" then
		-- Results are shown back in the lobby: the sting plays first, then the lobby theme returns.
		return "music_lobby"
	end
	return nil
end

function AudioController.refreshMusic()
	if stingPlaying then
		return
	end
	AudioController.setMusic(desiredMusic())
	AudioController.setAmbience(if RunInfo.isActivePhase() then "hotel_ambience_loop" else nil)
end

local function updateTension()
	-- Escape clock: ticks during the final warning window.
	local run = RunInfo.run()
	local escapeEndsAt = run.escapeEndsAt
	local phase = RunInfo.phase()
	local remaining = if type(escapeEndsAt) == "number" then escapeEndsAt - RunInfo.serverNow() else math.huge
	local wantClock = (phase == "Escape" or phase == "Capture")
		and remaining <= GameConfig.Escape.WarningSeconds
		and remaining > 0
	if wantClock and not clockLoop then
		clockLoop = AudioController.loop("clock_tick_loop", { group = "Effects", fadeIn = 0.3 })
	elseif not wantClock and clockLoop then
		clockLoop.stop(0.3)
		clockLoop = nil
	end
	-- Heartbeat while the Caretaker is after the local player.
	local caretaker = ClientState.get("global", "caretaker") or {}
	local mode = caretaker.mode
	local chasingMe = caretaker.target == RunInfo.myKey() and (mode == "Chase" or mode == "Lunge" or mode == "Hunt")
	local wantHeartbeat = chasingMe and RunInfo.isActivePhase()
	if wantHeartbeat and not heartbeat then
		heartbeat = AudioController.loop("heartbeat_loop", { group = "Effects", fadeIn = 0.6 })
	elseif not wantHeartbeat and heartbeat then
		heartbeat.stop(1)
		heartbeat = nil
	end
end

function AudioController.start()
	ensureGroups()
	SettingsController.Changed:Connect(function()
		applyVolumes()
	end)
	Components.setSoundHook(function(name: string)
		AudioController.ui(name)
	end)
	task.spawn(verifyAll)

	RunInfo.PhaseChanged:Connect(function(phase: string, previous: string)
		if phase == "Results" and previous ~= "Prep" then
			local outcome = RunInfo.run().outcome
			AudioController.playSting(if outcome == "Success" then "music_results_win" else "music_results_fail")
			return
		end
		AudioController.refreshMusic()
	end)
	RunInfo.StatusChanged:Connect(function(status: string)
		AudioController.setMuffled(status == "Downed" or status == "Recovering" or status == "Eliminated")
	end)
	ClientState.Ready:Connect(function()
		AudioController.refreshMusic()
	end)
	if ClientState.isReady() then
		AudioController.refreshMusic()
	end
	task.spawn(function()
		while true do
			task.wait(0.25)
			updateTension()
		end
	end)
end

return AudioController
