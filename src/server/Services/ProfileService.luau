--!strict
--[[
	ProfileService: player save data lifecycle (S21, S22, S29, U20).

	* Loads with a session lock as soon as a player joins; until the profile is Ready the player cannot
	  ready up, change loadout or buy anything ("unloaded profiles cannot interact or purchase").
	* A load failure is reported to the client with a Retry action and never replaced by blank data.
	* Autosaves dirty profiles, saves and releases on leave and on shutdown (BindToClose).
	* saveNow() lets reward grants show "Saving..." until the write is confirmed.
	* When DataStores are unavailable (Studio without API access / unpublished place) an in-memory store with
	  the identical contract is used and the client is told progress will not persist.
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.Config.GameConfig)
local RoomDefs = require(Shared.Config.RoomDefs)
local SkinDefs = require(Shared.Config.SkinDefs)
local ProfileSchema = require(Shared.Logic.ProfileSchema)
local Signal = require(Shared.Util.Signal)
local Tables = require(Shared.Util.Tables)
local Log = require(Shared.Util.Log)
local Net = require(Shared.Net.Net)
local Registry = require(script.Parent.Parent.Core.Registry)
local StateServer = require(script.Parent.Parent.Core.StateServer)
local ProfileStore = require(script.Parent.Parent.Core.ProfileStore)
local MemoryStore = require(script.Parent.Parent.Core.MemoryStore)
local Engine = require(Shared.Util.Engine)

local log = Log.new("Profiles")

local STORE_NAME = "RoomnappedProfiles_v1"
local LOCK_STEAL_AGE = 300

type Profile = ProfileSchema.Profile
type Status = "Loading" | "Ready" | "Failed" | "Newer" | "Released"

type Session = {
	player: Player,
	userId: number,
	key: string,
	status: Status,
	data: Profile?,
	dirty: boolean,
	saving: boolean,
	lockLost: boolean,
	savedAt: number,
}

local ProfileService = {}
ProfileService.Loaded = Signal.new() -- (player, profile)
ProfileService.Failed = Signal.new() -- (player, status)
ProfileService.Changed = Signal.new() -- (player, profile)

local sessions: { [Player]: Session } = {}
local store: ProfileStore.Store
local usingMemory = false
local sessionId = if Engine.jobId() ~= "" then Engine.jobId() else HttpService:GenerateGUID(false)
local shuttingDown = false

local function contentInfo(): ProfileSchema.ContentInfo
	local Flags = Registry.get("Flags")
	return {
		isRoomKnown = function(id: string): boolean
			return RoomDefs.byId[id] ~= nil
		end,
		isRoomEnabled = function(id: string): boolean
			return Flags.isRoomEnabled(id)
		end,
		starterRooms = GameConfig.Loadout.StarterRooms,
		defaultSkins = SkinDefs.defaultForRoom,
		defaultSuitcase = SkinDefs.defaultSuitcase,
		skinTarget = function(id: string): string?
			local skin = SkinDefs.byId[id]
			if not skin then
				return nil
			end
			return if skin.kind == "suitcase" then "suitcase" else skin.room
		end,
	}
end

local function makeDefault(): Profile
	return ProfileSchema.default(
		os.time(),
		GameConfig.Loadout.StarterRooms,
		SkinDefs.defaultForRoom,
		SkinDefs.defaultSuitcase
	)
end

local function resolveStore(): (any, boolean)
	if Engine.placeId() == 0 then
		return MemoryStore.new(), true
	end
	local ok, dataStore = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	if not ok then
		return MemoryStore.new(), true
	end
	if RunService:IsStudio() then
		local probeOk = pcall(function()
			(dataStore :: DataStore):GetAsync("probe")
		end)
		if not probeOk then
			return MemoryStore.new(), true
		end
	end
	return dataStore, false
end

-- Client-facing view of the profile (no ledger internals).
local function view(session: Session): any
	local data = session.data
	if not data then
		return { status = session.status, memory = usingMemory }
	end
	return {
		status = session.status,
		memory = usingMemory,
		rooms = Tables.deepCopy(data.rooms),
		loadout = table.clone(data.loadout),
		skins = Tables.deepCopy(data.skins),
		credits = data.credits,
		settings = Tables.deepCopy(data.settings),
		stats = {
			runs = data.stats.runs,
			extractions = data.stats.extractions,
			captures = data.stats.captures,
			keys = data.stats.keys,
			deploys = data.stats.deploys,
			combos = data.stats.combos,
			cleared = Tables.deepCopy(data.stats.cleared),
			bestTimes = Tables.deepCopy(data.stats.bestTimes),
		},
		tutorialDone = data.tutorialDone,
		rewardChoice = Tables.deepCopy(data.rewardChoice),
		interruptedRunId = data.flags.interruptedRunId,
	}
end

local function publish(session: Session)
	if session.player.Parent ~= Players then
		return
	end
	StateServer.private(session.player):Set({ "profile" }, view(session))
end

local function setSaving(player: Player, state: string)
	if player.Parent == Players then
		StateServer.private(player):Set({ "saving" }, state)
	end
end

local function performSave(session: Session, release: boolean): boolean
	if session.status ~= "Ready" or session.lockLost or session.data == nil then
		return false
	end
	while session.saving do
		task.wait(0.1)
	end
	session.saving = true
	local snapshot = Tables.deepCopy(session.data)
	snapshot.lastSeenAt = os.time()
	session.dirty = false
	local ok, lost = store:save(session.key, session.userId, snapshot, release)
	session.saving = false
	if ok then
		session.savedAt = os.clock()
	else
		session.dirty = true
	end
	if lost then
		session.lockLost = true
		log:Warn("session lock lost for", session.userId)
		if session.player.Parent == Players then
			session.player:Kick("Your ROOMNAPPED progress was opened in another server. Please rejoin.")
		end
	end
	return ok
end

local function load(session: Session)
	session.status = "Loading"
	publish(session)
	local status, profile = store:load(session.key, session.userId)
	if status == "Ready" then
		session.data = profile
		session.status = "Ready"
		local data = profile :: Profile
		if data.flags.lastVersion ~= GameConfig.Version then
			data.flags.lastVersion = GameConfig.Version
			session.dirty = true
		end
		if session.player.Parent ~= Players then
			-- Player left while loading: release the lock immediately.
			performSave(session, true)
			session.status = "Released"
			return
		end
		publish(session)
		ProfileService.Loaded:Fire(session.player, data)
	else
		session.status = status :: Status
		publish(session)
		ProfileService.Failed:Fire(session.player, status)
		log:Warn("profile load failed for", session.userId, status)
	end
end

-- Public API ------------------------------------------------------------------------------------------

function ProfileService.isReady(player: Player): boolean
	local session = sessions[player]
	return session ~= nil and session.status == "Ready" and session.data ~= nil
end

function ProfileService.status(player: Player): string
	local session = sessions[player]
	return if session then session.status else "Missing"
end

function ProfileService.get(player: Player): Profile?
	local session = sessions[player]
	if session and session.status == "Ready" then
		return session.data
	end
	return nil
end

function ProfileService.usingMemoryStore(): boolean
	return usingMemory
end

-- Mutate a loaded profile. Returns false if the profile is not ready (no write happens).
function ProfileService.update(player: Player, mutate: (Profile) -> ()): boolean
	local session = sessions[player]
	if not session or session.status ~= "Ready" or not session.data then
		return false
	end
	mutate(session.data :: Profile)
	session.dirty = true
	publish(session)
	ProfileService.Changed:Fire(player, session.data)
	return true
end

-- Save immediately (yields). Shows Saving/Saved/Error on the client.
function ProfileService.saveNow(player: Player): boolean
	local session = sessions[player]
	if not session then
		return false
	end
	setSaving(player, "Saving")
	local ok = performSave(session, false)
	setSaving(player, if ok then "Saved" else "Error")
	return ok
end

function ProfileService.retry(player: Player)
	local session = sessions[player]
	if session and session.status == "Failed" then
		task.spawn(load, session)
	end
end

local function onPlayerAdded(player: Player)
	local session: Session = {
		player = player,
		userId = player.UserId,
		key = "u_" .. player.UserId,
		status = "Loading",
		data = nil,
		dirty = false,
		saving = false,
		lockLost = false,
		savedAt = os.clock(),
	}
	sessions[player] = session
	task.spawn(load, session)
end

local function onPlayerRemoving(player: Player)
	local session = sessions[player]
	if not session then
		return
	end
	if session.status == "Ready" and not shuttingDown then
		task.spawn(function()
			performSave(session, true)
			session.status = "Released"
			if sessions[player] == session then
				sessions[player] = nil
			end
		end)
	elseif not shuttingDown then
		sessions[player] = nil
	end
end

function ProfileService.Init()
	Registry.add("Profiles", ProfileService)
end

function ProfileService.Start()
	local dataStore, memory = resolveStore()
	usingMemory = memory
	if memory then
		log:Warn("DataStores unavailable - using an in-memory profile store (progress will not persist)")
	end
	store = ProfileStore.new({
		store = dataStore,
		sessionId = sessionId,
		placeId = Engine.placeId(),
		now = os.time,
		wait = task.wait,
		budget = if memory
			then nil
			else function(): number
				return DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.UpdateAsync)
			end,
		migrate = ProfileSchema.migrate,
		makeDefault = makeDefault,
		sanitize = function(data: any): any
			return ProfileSchema.sanitize(data, makeDefault(), contentInfo())
		end,
		loadAttempts = GameConfig.Data.LoadAttempts,
		saveAttempts = GameConfig.Data.SaveAttempts,
		retryBaseSeconds = GameConfig.Data.RetryBaseSeconds,
		lockWaitSeconds = GameConfig.Data.LockWaitSeconds,
		lockStealAge = LOCK_STEAL_AGE,
	})

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end

	Net.on("RetryProfile", function(player: Player)
		ProfileService.retry(player)
	end)

	-- Autosave loop.
	task.spawn(function()
		while true do
			task.wait(10)
			for _, session in sessions do
				if session.status == "Ready" and session.dirty and not session.saving then
					if os.clock() - session.savedAt >= GameConfig.Data.AutosaveSeconds then
						task.spawn(performSave, session, false)
					end
				end
			end
		end
	end)

	game:BindToClose(function()
		shuttingDown = true
		local pending = 0
		for _, session in sessions do
			if session.status == "Ready" then
				pending += 1
				task.spawn(function()
					performSave(session, true)
					pending -= 1
				end)
			end
		end
		local started = os.clock()
		while pending > 0 and os.clock() - started < 25 do
			task.wait(0.2)
		end
	end)
end

return ProfileService
