--!strict
--[[
	FlagsService: resolves feature flags for this server (S32 release & rollback).

	Defaults < environment overrides < live overrides from the "RoomnappedConfig" DataStore < admin test
	overrides (this server only). Live overrides are read at startup and re-read every few minutes, so a
	rollback reaches running servers too. Disabling a room or mission hides it from new runs only; profiles
	keep everything they own. `Changed` fires whenever the resolved flags change.
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local FeatureFlags = require(ReplicatedStorage.Shared.Config.FeatureFlags)
local Tables = require(ReplicatedStorage.Shared.Util.Tables)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local Registry = require(script.Parent.Parent.Core.Registry)
local StateServer = require(script.Parent.Parent.Core.StateServer)

local log = Log.new("Flags")

local FlagsService = {}
FlagsService.Changed = Signal.new()

local REFRESH_SECONDS = 300

local flags: any = Tables.deepCopy(FeatureFlags.Defaults)
local environment = "live"
local liveOverrides: any = nil
local testOverrides: any = {}

local function merge(target: any, source: any)
	if type(source) ~= "table" then
		return
	end
	for k, v in source do
		if type(v) == "table" and type(target[k]) == "table" and #v == 0 then
			merge(target[k], v)
		else
			target[k] = Tables.deepCopy(v)
		end
	end
end

function FlagsService.environment(): string
	return environment
end

function FlagsService.isRoomEnabled(roomId: string): boolean
	return flags.rooms[roomId] ~= false
end

function FlagsService.isMissionEnabled(missionId: string): boolean
	return flags.missions[missionId] ~= false
end

function FlagsService.feature(name: string): boolean
	return flags.features[name] == true
end

function FlagsService.adminUserIds(): { number }
	return flags.adminUserIds or {}
end

function FlagsService.adminGroup(): any
	return flags.adminGroup
end

function FlagsService.all(): any
	return flags
end

-- Live overrides come from a hand-edited DataStore entry: keep only known flags with values of the right type,
-- so a typo can never break flag lookups (or the refresh loop). Returns the clean overrides and what was dropped.
local function cleanOverrides(raw: any): (any, { string })
	local clean: any = {}
	local dropped: { string } = {}
	if type(raw) ~= "table" then
		return clean, dropped
	end
	for key, value in raw do
		local defaults = (FeatureFlags.Defaults :: any)[key]
		if (key == "rooms" or key == "missions" or key == "features") and type(value) == "table" then
			clean[key] = {}
			for id, enabled in value do
				if type(enabled) == "boolean" and defaults[id] ~= nil then
					clean[key][id] = enabled
				else
					table.insert(dropped, tostring(key) .. "." .. tostring(id))
				end
			end
		elseif key == "adminUserIds" and type(value) == "table" then
			clean.adminUserIds = {}
			for _, id in value do
				if type(id) == "number" and id > 0 and id == math.floor(id) then
					table.insert(clean.adminUserIds, id)
				else
					table.insert(dropped, "adminUserIds." .. tostring(id))
				end
			end
		elseif
			key == "adminGroup"
			and type(value) == "table"
			and type(value.id) == "number"
			and value.id > 0
			and type(value.minRank) == "number"
			-- Rank 0 is everyone outside the group: such an entry would make every player an admin.
			and value.minRank >= 1
			and value.minRank <= 255
		then
			clean.adminGroup = { id = value.id, minRank = value.minRank }
		else
			table.insert(dropped, tostring(key))
		end
	end
	return clean, dropped
end

FlagsService.cleanOverrides = cleanOverrides -- exposed for tests

local function resolve(): any
	local resolved = Tables.deepCopy(FeatureFlags.Defaults)
	merge(resolved, FeatureFlags.Environments[environment])
	merge(resolved, liveOverrides)
	merge(resolved, testOverrides)
	return resolved
end

local function publish()
	local disabledRooms = {}
	for id, enabled in flags.rooms do
		if enabled == false then
			disabledRooms[id] = true
		end
	end
	local disabledMissions = {}
	for id, enabled in flags.missions do
		if enabled == false then
			disabledMissions[id] = true
		end
	end
	StateServer.global("global"):Set({ "flags" }, {
		environment = environment,
		disabledRooms = disabledRooms,
		disabledMissions = disabledMissions,
		features = Tables.deepCopy(flags.features),
	})
end

local function apply()
	flags = resolve()
	publish()
	FlagsService.Changed:Fire()
end

-- Admin test command: switch one room, mission or feature on or off on this server only (until it restarts).
-- Returns false for an unknown flag.
function FlagsService.setTestOverride(id: string, enabled: boolean): boolean
	local group = if flags.rooms[id] ~= nil
		then "rooms"
		elseif flags.missions[id] ~= nil then "missions"
		elseif flags.features[id] ~= nil then "features"
		else nil
	if not group then
		return false
	end
	testOverrides[group] = testOverrides[group] or {}
	testOverrides[group][id] = enabled
	apply()
	return true
end

function FlagsService.Init()
	Registry.add("Flags", FlagsService)
	if RunService:IsStudio() then
		environment = "studio"
	elseif table.find(FeatureFlags.TestPlaceIds, game.PlaceId) then
		environment = "test"
	end
	flags = resolve()
end

function FlagsService.Start()
	publish()
	if environment == "studio" or game.PlaceId == 0 then
		return
	end
	task.spawn(function()
		local applied = ""
		while true do
			local ok, result = pcall(function()
				local store = DataStoreService:GetDataStore("RoomnappedConfig")
				return store:GetAsync("flags/" .. environment)
			end)
			if ok then
				-- A missing key means "no overrides" (removing an override takes effect too).
				local live, dropped = cleanOverrides(result)
				local encoded = HttpService:JSONEncode(live)
				if encoded ~= applied then
					if #dropped > 0 then
						log:Warn("ignored unknown or malformed live flags:", table.concat(dropped, ", "))
					end
					local previous = liveOverrides
					liveOverrides = live
					local applyOk, problem = pcall(function(): any
						apply()
						return nil
					end)
					if applyOk then
						applied = encoded
						log:Info("live flag overrides applied for", environment)
					else
						liveOverrides = previous
						log:Warn("could not apply live flags:", problem)
					end
				end
			else
				-- Keep the flags we have; a read failure must never switch content back on or off.
				log:Warn("could not read live flags:", result)
			end
			task.wait(REFRESH_SECONDS)
		end
	end)
end

return FlagsService
