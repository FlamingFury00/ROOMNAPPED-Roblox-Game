--!strict
--[[
	SettingsController: the player's comfort and audio settings (U19, S29).

	Changes apply instantly on the client and are saved to the profile after a short pause (one remote call
	per burst of slider movement). The saved profile copy wins when it first arrives; after that local edits
	are authoritative until they are saved, so a slow round trip never snaps a slider back.
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

local current: Settings = ProfileSchema.defaultSettings()
local dirty = false
local saveToken = 0
local receivedFromProfile = false

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
		Net.send("SaveSettings", table.clone(current))
	end)
end

function SettingsController.get(): Settings
	return current
end

function SettingsController.value(key: string): any
	return (current :: any)[key]
end

-- Set one setting (validated with the same rules as the server).
function SettingsController.set(key: string, value: any)
	local cleaned = ProfileSchema.cleanSettings({ [key] = value }, current)
	if (cleaned :: any)[key] == (current :: any)[key] then
		return
	end
	current = cleaned
	apply(key)
	scheduleSave()
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
			if first or not Tables.deepEqual(incoming, current) then
				current = incoming
				apply(nil)
			end
		end
	end)
end

return SettingsController
