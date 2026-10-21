--!strict
--[[
	SettingsController: the player's comfort and audio settings (U19, S29).

	Changes apply instantly on the client and are saved to the profile after a short pause (one remote call
	per burst of slider movement). The saved profile copy wins when it first arrives; after that local edits
	are authoritative until they are saved, so a slow round trip never snaps a slider back.

	The game can also set a session-only value (automatic Low Effects on a struggling device). It shows in
	get() - so the Settings toggle reads it - but is never saved, and once the player changes that setting
	themselves this session, their choice wins and the game leaves it alone.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Net = require(Shared.Net.Net)
local ProfileSchema = require(Shared.Logic.ProfileSchema)
local Signal = require(Shared.Util.Signal)
local Tables = require(Shared.Util.Tables)
local ClientState = require(script.Parent.Parent.Core.ClientState)
local Motion = require(script.Parent.Parent.UI.Motion)
local Responsive = require(script.Parent.Parent.UI.Responsive)

export type Settings = ProfileSchema.Settings

local SettingsController = {}

SettingsController.Changed = Signal.new() -- (settings, key?)

local SAVE_DELAY = 1.2

local saved: Settings = ProfileSchema.defaultSettings() -- what the profile holds (and what is saved)
local overrides: { [string]: any } = {} -- session-only values set by the game; never saved
local chosen: { [string]: boolean } = {} -- settings the player changed this session
local current: Settings = saved -- saved values with the session overrides on top (what get() returns)
local dirty = false
local saveToken = 0
local receivedFromProfile = false

local function rebuild()
	if next(overrides) == nil then
		current = saved
		return
	end
	local merged = table.clone(saved)
	for key, value in overrides do
		(merged :: any)[key] = value
	end
	current = merged
end

local function apply(key: string?)
	Motion.setReduced(current.reducedMotion)
	Responsive.setUserScale(current.textScale)
	SettingsController.Changed:Fire(current, key)
end

local function scheduleSave()
	dirty = true
	saveToken += 1
	local token = saveToken
	task.delay(SAVE_DELAY, function()
		if token ~= saveToken or not dirty then
			return
		end
		dirty = false
		Net.send("SaveSettings", table.clone(saved))
	end)
end

function SettingsController.get(): Settings
	return current
end

function SettingsController.value(key: string): any
	return (current :: any)[key]
end

-- Set one setting (validated with the same rules as the server). The player's choice replaces any session
-- override of the same setting.
function SettingsController.set(key: string, value: any)
	chosen[key] = true
	local hadOverride = overrides[key] ~= nil
	overrides[key] = nil
	local cleaned = ProfileSchema.cleanSettings({ [key] = value }, saved)
	local changed = (cleaned :: any)[key] ~= (saved :: any)[key]
	if not changed and not hadOverride then
		return
	end
	if changed then
		saved = cleaned
	end
	rebuild()
	apply(key)
	if changed then
		scheduleSave()
	end
end

-- A session-only value set by the game itself (never saved). Refused when the player already chose this
-- setting this session, or when it would change nothing. Returns whether it took effect.
function SettingsController.setSessionOverride(key: string, value: any): boolean
	if chosen[key] or (current :: any)[key] == value then
		return false
	end
	overrides[key] = value
	rebuild()
	apply(key)
	return true
end

function SettingsController.start()
	apply(nil)
	ClientState.observe("me", "profile.settings", function(value: any)
		if type(value) ~= "table" then
			return
		end
		-- Adopt the saved copy when it first arrives or whenever nothing local is pending (and only re-apply
		-- when it actually differs: the profile republishes for many other reasons).
		if not receivedFromProfile or not dirty then
			local incoming = ProfileSchema.cleanSettings(value, ProfileSchema.defaultSettings())
			local first = not receivedFromProfile
			receivedFromProfile = true
			if first or not Tables.deepEqual(incoming, saved) then
				saved = incoming
				rebuild()
				apply(nil)
			end
		end
	end)
end

return SettingsController
