--!strict
--[[
	RunInfo: typed convenience views over the replicated run state (global channel) for client systems.

	Everything here is read-only: the server owns the run. Signals fire once per real change so
	controllers can rebuild per-run visuals when a level appears or disappears.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local ClientState = require(script.Parent.ClientState)

local RunInfo = {}

RunInfo.PhaseChanged = Signal.new() -- (phase, previous)
RunInfo.LevelChanged = Signal.new() -- (levelInfo?)
RunInfo.RosterChanged = Signal.new() -- (roster)
RunInfo.StatusChanged = Signal.new() -- (myStatus, previous)

local IN_RUN: { [string]: boolean } = { Launching = true, Explore = true, Capture = true, Escape = true }
local ACTIVE: { [string]: boolean } = { Explore = true, Capture = true, Escape = true }

local localPlayer = Players.LocalPlayer
local myKey = tostring(localPlayer.UserId)

local phase = "Prep"
local level: any = nil
local roster: { [string]: any } = {}
local myStatus = "None"

function RunInfo.myKey(): string
	return myKey
end

function RunInfo.phase(): string
	return phase
end

-- Launching / Explore / Capture / Escape.
function RunInfo.inRunPhase(): boolean
	return IN_RUN[phase] == true
end

-- Explore / Capture / Escape: the level is playable.
function RunInfo.isActivePhase(): boolean
	return ACTIVE[phase] == true
end

function RunInfo.serverNow(): number
	return Workspace:GetServerTimeNow()
end

function RunInfo.run(): { [string]: any }
	return ClientState.get("global", "run") or {}
end

function RunInfo.level(): any
	return level
end

function RunInfo.roster(): { [string]: any }
	return roster
end

function RunInfo.entry(key: string): any
	return roster[key]
end

function RunInfo.myEntry(): any
	return roster[myKey]
end

-- True when the local player is part of the current expedition (and has not left it).
function RunInfo.isParticipant(): boolean
	local entry = roster[myKey]
	return entry ~= nil and entry.status ~= "Left" and IN_RUN[phase] == true
end

-- Local roster status: Active / Downed / Recovering / Eliminated / Left / Disconnected / None.
function RunInfo.myStatus(): string
	return myStatus
end

function RunInfo.isTutorial(): boolean
	return RunInfo.run().tutorial == true
end

function RunInfo.missionId(): string?
	return RunInfo.run().mission
end

-- Display name for a roster key (falls back to the Player object, then the key).
function RunInfo.displayName(key: string): string
	local entry = roster[key]
	if entry and entry.display then
		return entry.display
	end
	local userId = tonumber(key)
	local player = if userId then Players:GetPlayerByUserId(userId) else nil
	return if player then player.DisplayName else key
end

-- Player object for a roster key (nil if they are not in this server any more).
function RunInfo.playerFor(key: string): Player?
	local userId = tonumber(key)
	return if userId then Players:GetPlayerByUserId(userId) else nil
end

-- The built level model (workspace.Expedition.Level_*), if a run is loaded.
function RunInfo.levelModel(): Model?
	local folder = Workspace:FindFirstChild("Expedition")
	if not folder then
		return nil
	end
	for _, child in folder:GetChildren() do
		if child:IsA("Model") and string.sub(child.Name, 1, 6) == "Level_" then
			return child
		end
	end
	return nil
end

-- Waits (bounded) until the level model replicated; returns nil on timeout.
function RunInfo.waitForLevelModel(timeout: number?): Model?
	local deadline = os.clock() + (timeout or 10)
	repeat
		local model = RunInfo.levelModel()
		if model then
			return model
		end
		task.wait(0.1)
	until os.clock() > deadline
	return nil
end

local function refreshStatus()
	local entry = roster[myKey]
	local status = if entry and IN_RUN[phase] then entry.status or "Active" else "None"
	if status ~= myStatus then
		local previous = myStatus
		myStatus = status
		RunInfo.StatusChanged:Fire(status, previous)
	end
end

function RunInfo.start()
	ClientState.observe("global", "run.phase", function(value: any)
		local p = if type(value) == "string" then value else "Prep"
		if p ~= phase then
			local previous = phase
			phase = p
			RunInfo.PhaseChanged:Fire(p, previous)
			refreshStatus()
		end
	end)
	ClientState.observe("global", "level", function(value: any)
		if value ~= level then
			level = value
			RunInfo.LevelChanged:Fire(value)
		end
	end)
	ClientState.observe("global", "roster", function(value: any)
		roster = if type(value) == "table" then value else {}
		RunInfo.RosterChanged:Fire(roster)
		refreshStatus()
	end)
end

return RunInfo
