--!strict
--[[
	FlagsService: resolves feature flags for this server (S32 release & rollback).

	Defaults < environment overrides < live overrides read from the "RoomnappedConfig" DataStore at startup.
	Disabling a room or mission hides it from new runs only; profiles keep everything they own.
]]

local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local FeatureFlags = require(ReplicatedStorage.Shared.Config.FeatureFlags)
local Tables = require(ReplicatedStorage.Shared.Util.Tables)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local Registry = require(script.Parent.Parent.Core.Registry)
local StateServer = require(script.Parent.Parent.Core.StateServer)

local log = Log.new("Flags")

local FlagsService = {}

local flags: any = Tables.deepCopy(FeatureFlags.Defaults)
local environment = "live"

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

function FlagsService.Init()
	Registry.add("Flags", FlagsService)
	if RunService:IsStudio() then
		environment = "studio"
	elseif table.find(FeatureFlags.TestPlaceIds, game.PlaceId) then
		environment = "test"
	end
	merge(flags, FeatureFlags.Environments[environment])
end

function FlagsService.Start()
	publish()
	if environment == "studio" or game.PlaceId == 0 then
		return
	end
	task.spawn(function()
		local ok, result = pcall(function()
			local store = DataStoreService:GetDataStore("RoomnappedConfig")
			return store:GetAsync("flags/" .. environment)
		end)
		if ok and type(result) == "table" then
			merge(flags, result)
			log:Info("live flag overrides applied for", environment)
			publish()
		elseif not ok then
			log:Warn("could not read live flags:", result)
		end
	end)
end

return FlagsService
