--!strict
--[[
	RunTypes: shared shape of an expedition run on the server.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EffectModel = require(ReplicatedStorage.Shared.Logic.EffectModel)
local HealthModel = require(ReplicatedStorage.Shared.Logic.HealthModel)
local LayoutTypes = require(ReplicatedStorage.Shared.World.LayoutTypes)
local MissionDefs = require(ReplicatedStorage.Shared.Config.MissionDefs)
local Trove = require(ReplicatedStorage.Shared.Util.Trove)

export type RosterEntry = {
	userId: number,
	key: string, -- tostring(userId), used as the replicated map key
	player: Player,
	name: string,
	display: string,
	connected: boolean,
	left: boolean,
	loadout: { string },
	skins: { [string]: string },
	suitcase: string,
	deployed: { [number]: string },
	cooldownUntil: number,
	health: HealthModel.HealthState,
	lastSafe: CFrame?,
	device: string,
	rewardChoice: string?,
	selectedSlot: number,
	damageTaken: number,
}

export type RunStats = {
	deploys: number,
	recalls: number,
	combos: { [string]: boolean },
	comboOrder: { string },
	keys: { [string]: number },
	anyDowns: boolean,
	firstDeployAt: number?,
	roomsUsed: { [string]: boolean },
}

export type Run = {
	id: string,
	mission: MissionDefs.MissionDef,
	layout: LayoutTypes.LayoutDef,
	tutorial: boolean,
	solo: boolean,
	roster: { [number]: RosterEntry },
	order: { number },
	model: Model,
	runtime: LayoutTypes.Runtime,
	effect: EffectModel.Model,
	trove: Trove.Trove,
	startedAt: number,
	exploreStartedAt: number,
	captured: boolean,
	captureAt: number?,
	escapeEndsAt: number?,
	stats: RunStats,
	ended: boolean,
	outcome: string?,
	-- Rooms switched off when the run launched: a run finishes with the rooms it started with, whatever the
	-- live flags do meanwhile.
	disabledRooms: { [string]: boolean },
	scratch: { [string]: any }, -- per-service run state
}

return {}
