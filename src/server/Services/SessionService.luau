--!strict
--[[
	SessionService: one 1-4 player squad per server (S17, S25, U15-U17).

	* Presence: every player gets a lobby card (profile status, ready flag, leader, device).
	* Ready: pressing PLAY (or walking into the departure elevator) readies a player. The first ready player
	  starts a countdown which shortens once everyone present is ready; at zero the ready players launch.
	* The squad leader (longest-present player) picks the mission; each player picks their own reward
	  target. First-time leaders are routed to the tutorial mission.
	* Loadout and cosmetics can only change outside a run (S05). Credits are only ever spent on cosmetic
	  skins and each purchase deducts exactly once (U16).
	* Players joining mid-run wait in the lobby and can never alter the running mission or inherit its
	  rewards (S17).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.Config.GameConfig)
local MissionDefs = require(Shared.Config.MissionDefs)
local RoomDefs = require(Shared.Config.RoomDefs)
local SkinDefs = require(Shared.Config.SkinDefs)
local ProfileSchema = require(Shared.Logic.ProfileSchema)
local RewardRules = require(Shared.Logic.RewardRules)
local Mastery = require(Shared.Logic.Mastery)
local Net = require(Shared.Net.Net)
local Log = require(Shared.Util.Log)
local Registry = require(script.Parent.Parent.Core.Registry)
local StateServer = require(script.Parent.Parent.Core.StateServer)

local log = Log.new("Session")

local SessionService = {}

type Presence = {
	joinOrder: number,
	ready: boolean,
	waiting: boolean,
	device: string,
	locale: string,
	replay: boolean,
	-- Walking into the departure elevator only readies a player who has been seen outside it since the last
	-- run, so nobody standing in (or arriving back into) the car is launched without choosing to.
	zoneArmed: boolean,
}

local global = StateServer.global("global")
local presence: { [Player]: Presence } = {}
local joinCounter = 0
local leader: Player? = nil
local selectedMission = MissionDefs.tutorialId
local countdownEndsAt: number? = nil

local VALID_DEVICES: { [string]: boolean } = { touch = true, keyboard = true, gamepad = true, vr = true }

local function serverNow(): number
	return workspace:GetServerTimeNow()
end

local function profiles()
	return Registry.get("Profiles")
end

function SessionService.joinOrder(player: Player): number
	local p = presence[player]
	return if p then p.joinOrder else math.huge
end

function SessionService.deviceOf(player: Player): string
	local p = presence[player]
	return if p then p.device else "unknown"
end

function SessionService.leader(): Player?
	return leader
end

function SessionService.selectedMission(): string
	return selectedMission
end

local function publishPlayer(player: Player)
	local p = presence[player]
	if not p then
		return
	end
	local profile = profiles().get(player)
	global:Set({ "players", tostring(player.UserId) }, {
		name = player.Name,
		display = player.DisplayName,
		ready = p.ready,
		waiting = p.waiting,
		profile = profiles().status(player),
		leader = leader == player,
		device = p.device,
		order = p.joinOrder,
		-- The squad sees who brings which rooms before launching.
		loadout = if profile then table.clone(profile.loadout) else nil,
	})
end

local function publishLobby()
	local readyCount, total = 0, 0
	for _, p in presence do
		if not p.waiting then
			total += 1
			if p.ready then
				readyCount += 1
			end
		end
	end
	global:Set({ "lobby" }, {
		mission = selectedMission,
		countdownEndsAt = countdownEndsAt,
		ready = readyCount,
		total = total,
		leader = if leader then tostring(leader.UserId) else nil,
	})
end

local function refreshPreviews(player: Player)
	local profile = profiles().get(player)
	if not profile then
		return
	end
	local previews = {}
	for _, mission in MissionDefs.list do
		local preview = RewardRules.preview(profile :: any, mission :: any, GameConfig.Rewards)
		previews[mission.id] = {
			kind = preview.kind,
			item = preview.item,
			credits = preview.credits,
			choice = RewardRules.choiceFor(profile :: any, mission :: any),
			unlocked = MissionDefs.isUnlocked(mission, profile.tutorialDone, profile.stats.extractions),
		}
	end
	StateServer.private(player):Set({ "missions" }, previews)
end

-- Leader & mission --------------------------------------------------------------------------------------

local function missionAllowedFor(player: Player?, missionId: string): boolean
	local mission = MissionDefs.get(missionId)
	if not mission or not Registry.get("Flags").isMissionEnabled(missionId) then
		return false
	end
	if not player then
		return mission.tutorial
	end
	local profile = profiles().get(player)
	if not profile then
		return mission.tutorial
	end
	if not profile.tutorialDone then
		return mission.tutorial
	end
	return MissionDefs.isUnlocked(mission, profile.tutorialDone, profile.stats.extractions)
end

local function defaultMissionFor(player: Player?): string
	local profile = if player then profiles().get(player) else nil
	if not profile or not profile.tutorialDone then
		-- The tutorial, unless it is switched off; launches re-check, so a disabled pick never starts.
		return MissionDefs.tutorialId
	end
	-- First unlocked mission the leader has not cleared yet, else the latest unlocked one.
	local latest = MissionDefs.tutorialId
	for _, mission in MissionDefs.list do
		if not mission.tutorial and missionAllowedFor(player, mission.id) then
			latest = mission.id
			if (profile.stats.cleared[mission.id] or 0) == 0 then
				return mission.id
			end
		end
	end
	return latest
end

local function electLeader()
	local best: Player? = nil
	for player, p in presence do
		if best == nil or p.joinOrder < presence[best :: Player].joinOrder then
			best = player
		end
	end
	if best ~= leader then
		local previous = leader
		leader = best
		if previous and presence[previous] then
			publishPlayer(previous)
		end
		if leader then
			publishPlayer(leader)
		end
	end
	if not missionAllowedFor(leader, selectedMission) then
		selectedMission = defaultMissionFor(leader)
	end
	publishLobby()
end

-- Ready & countdown --------------------------------------------------------------------------------------

local function canReady(player: Player): (boolean, string?)
	local p = presence[player]
	if not p then
		return false, nil
	end
	local phase = Registry.get("Expedition").phase()
	if phase ~= "Prep" then
		return false, "toast.runInProgress"
	end
	if not profiles().isReady(player) then
		return false, "toast.profileNotReady"
	end
	local profile = profiles().get(player)
	if not profile or #profile.loadout ~= 2 then
		return false, "toast.loadoutInvalid"
	end
	-- One squad of up to MaxPlayers per server, whatever the place's player limit is set to.
	if not p.ready then
		local readyCount = 0
		for _, other in presence do
			if other.ready then
				readyCount += 1
			end
		end
		if readyCount >= GameConfig.Squad.MaxPlayers then
			return false, "toast.squadFull"
		end
	end
	return true, nil
end

function SessionService.setReady(player: Player, ready: boolean, viaZone: boolean?)
	local p = presence[player]
	if not p then
		return
	end
	if ready then
		local ok, reason = canReady(player)
		if not ok then
			if reason and not viaZone then
				Net.fire(player, "Toast", "error", reason, {})
			end
			return
		end
		if p.ready then
			return
		end
		p.ready = true
		if not viaZone then
			local index = 0
			for _, other in presence do
				if other.ready then
					index += 1
				end
			end
			Registry.get("Characters").teleport(player, Registry.get("Lobby").readySpot(index))
		end
		Net.fire(player, "Effect", "ready", {})
	else
		if not p.ready then
			return
		end
		p.ready = false
		if not viaZone then
			Registry.get("Characters").teleport(player, Registry.get("Lobby").spawnFor(p.joinOrder))
		end
	end
	publishPlayer(player)
	publishLobby()
end

function SessionService.markReplay(player: Player)
	local p = presence[player]
	if p then
		p.replay = true
	end
end

local function updateCountdown()
	local Expedition = Registry.get("Expedition")
	if Expedition.phase() ~= "Prep" then
		if countdownEndsAt ~= nil then
			countdownEndsAt = nil
			publishLobby()
		end
		return
	end
	local readyPlayers, eligible = {}, 0
	for player, p in presence do
		if not p.waiting and profiles().isReady(player) then
			eligible += 1
			if p.ready then
				table.insert(readyPlayers, player)
			end
		end
	end
	if #readyPlayers == 0 then
		if countdownEndsAt ~= nil then
			countdownEndsAt = nil
			publishLobby()
		end
		return
	end
	-- Never launch more than one squad (first come, first served).
	if #readyPlayers > GameConfig.Squad.MaxPlayers then
		table.sort(readyPlayers, function(a: Player, b: Player): boolean
			return presence[a].joinOrder < presence[b].joinOrder
		end)
		for i = #readyPlayers, GameConfig.Squad.MaxPlayers + 1, -1 do
			table.remove(readyPlayers, i)
		end
	end
	eligible = math.min(eligible, GameConfig.Squad.MaxPlayers)
	local now = serverNow()
	local changed = false
	if countdownEndsAt == nil then
		countdownEndsAt = now + GameConfig.Squad.LaunchCountdownSeconds
		changed = true
	end
	if #readyPlayers >= eligible then
		local quick = now + GameConfig.Squad.AllReadyCountdownSeconds
		if (countdownEndsAt :: number) > quick then
			countdownEndsAt = quick
			changed = true
		end
	end
	if changed then
		publishLobby()
	end
	if now >= (countdownEndsAt :: number) then
		countdownEndsAt = nil
		if not missionAllowedFor(leader, selectedMission) then
			selectedMission = defaultMissionFor(leader)
		end
		if not missionAllowedFor(leader, selectedMission) then
			-- Nothing this squad may play is open (e.g. the tutorial is switched off for a new leader). Step
			-- everyone out of the elevator too, or its ready zone would ready them straight back up.
			for _, player in readyPlayers do
				SessionService.setReady(player, false, false)
				Net.fire(player, "Toast", "error", "toast.missionClosed", {})
			end
			publishLobby()
			return
		end
		local launched = Expedition.launch(readyPlayers, selectedMission)
		if not launched then
			log:Warn("launch failed; clearing ready flags")
			for _, player in readyPlayers do
				SessionService.setReady(player, false, true)
			end
		end
		publishLobby()
	end
end

-- Hooks from ExpeditionService --------------------------------------------------------------------------

function SessionService.onLaunch(run: any)
	for player, p in presence do
		if run.roster[player.UserId] then
			p.ready = false
			p.replay = false
		end
		publishPlayer(player)
	end
	publishLobby()
end

function SessionService.onPrep(acks: { [number]: string }, tutorialCleared: boolean?)
	for player, p in presence do
		p.waiting = false
		p.ready = false
		p.zoneArmed = false
		publishPlayer(player)
	end
	electLeader()
	-- Someone just finished Check-In: PLAY AGAIN (labelled NEXT MISSION on the results) moves on to the first
	-- real mission - the easiest one, whoever leads.
	if tutorialCleared and selectedMission == MissionDefs.tutorialId then
		for _, mission in MissionDefs.list do
			if not mission.tutorial and missionAllowedFor(leader, mission.id) then
				selectedMission = mission.id
				break
			end
		end
	end
	for player, p in presence do
		if p.replay or acks[player.UserId] == "replay" then
			p.replay = false
			task.defer(SessionService.setReady, player, true)
		end
		refreshPreviews(player)
	end
	publishLobby()
end

-- Remote handlers -----------------------------------------------------------------------------------------

local function inRun(player: Player): boolean
	return Registry.get("Expedition").entry(player) ~= nil
end

local function onSetLoadout(player: Player, a: string, b: string)
	if inRun(player) then
		Net.fire(player, "Toast", "error", "toast.loadoutLocked", {})
		return
	end
	if a == b or not RoomDefs.byId[a] or not RoomDefs.byId[b] then
		return
	end
	local Flags = Registry.get("Flags")
	if not Flags.isRoomEnabled(a) or not Flags.isRoomEnabled(b) then
		Net.fire(player, "Toast", "error", "toast.roomDisabled", {})
		return
	end
	local ok = profiles().update(player, function(profile: any)
		if profile.rooms[a] and profile.rooms[b] then
			profile.loadout = { a, b }
		end
	end)
	if ok then
		Net.fire(player, "Effect", "equip", { room = a })
	end
end

local function onSelectMission(player: Player, missionId: string)
	if leader ~= player then
		Net.fire(player, "Toast", "error", "toast.leaderOnly", {})
		return
	end
	if Registry.get("Expedition").phase() ~= "Prep" then
		return
	end
	if not missionAllowedFor(player, missionId) then
		Net.fire(player, "Toast", "error", "toast.missionLocked", {})
		return
	end
	selectedMission = missionId
	publishLobby()
end

local function onSelectReward(player: Player, missionId: string, rewardId: string)
	local mission = MissionDefs.get(missionId)
	if not mission or not table.find(mission.rewardSkins, rewardId) then
		return
	end
	profiles().update(player, function(profile: any)
		profile.rewardChoice[missionId] = rewardId
	end)
	refreshPreviews(player)
end

local function skinTarget(skin: SkinDefs.SkinDef): string
	return if skin.kind == "suitcase" then "suitcase" else skin.room :: string
end

local function onEquipSkin(player: Player, target: string, skinId: string)
	local skin = SkinDefs.get(skinId)
	if not skin or skinTarget(skin) ~= target then
		return
	end
	if inRun(player) then
		Net.fire(player, "Toast", "error", "toast.loadoutLocked", {})
		return
	end
	profiles().update(player, function(profile: any)
		if profile.skins.owned[skinId] then
			profile.skins.equipped[target] = skinId
		end
	end)
end

local function onBuySkin(player: Player, skinId: string)
	local skin = SkinDefs.get(skinId)
	if not skin or skin.source ~= "shop" or not skin.price then
		return
	end
	if not Registry.get("Flags").feature("shop") then
		return
	end
	local price = skin.price :: number
	local result = "error"
	local ok = profiles().update(player, function(profile: any)
		if profile.skins.owned[skinId] then
			result = "owned"
			return
		end
		if skin.kind == "room" and not profile.rooms[skin.room :: string] then
			result = "locked"
			return
		end
		if profile.credits < price then
			result = "poor"
			return
		end
		profile.credits -= price
		profile.skins.owned[skinId] = true
		profile.skins.equipped[skinTarget(skin)] = skinId
		result = "bought"
	end)
	if not ok then
		Net.fire(player, "Toast", "error", "toast.profileNotReady", {})
		return
	end
	if result == "bought" then
		Net.fire(player, "Toast", "success", "toast.bought", { item = skin.nameKey })
		Net.fire(player, "Effect", "purchase", { skin = skinId })
		Registry.get("Telemetry").purchase(player, skinId, price)
		task.spawn(profiles().saveNow, player)
	elseif result == "poor" then
		Net.fire(player, "Toast", "error", "toast.notEnoughCredits", {})
	elseif result == "locked" then
		Net.fire(player, "Toast", "error", "toast.roomLocked", {})
	end
end

local function onSaveSettings(player: Player, settings: any)
	profiles().update(player, function(profile: any)
		profile.settings = ProfileSchema.cleanSettings(settings, profile.settings)
	end)
end

local function onClientReady(player: Player, device: string, locale: string?)
	local p = presence[player]
	if not p then
		return
	end
	p.device = if VALID_DEVICES[device] then device else "unknown"
	p.locale = if type(locale) == "string" then string.sub(locale, 1, 12) else ""
	publishPlayer(player)
	Registry.get("Telemetry").clientReady(player, p.device)
end

local function onFeedback(player: Player, rating: number, tag: string?)
	if rating < 1 or rating > 5 then
		return
	end
	profiles().update(player, function(profile: any)
		profile.feedbackCount += 1
	end)
	Registry.get("Telemetry").feedback(player, rating, tag)
end

-- Lifecycle --------------------------------------------------------------------------------------------------

local function onPlayerAdded(player: Player)
	joinCounter += 1
	local runActive = Registry.get("Expedition").phase() ~= "Prep"
	presence[player] = {
		joinOrder = joinCounter,
		ready = false,
		waiting = runActive,
		device = "unknown",
		locale = "",
		replay = false,
		zoneArmed = false,
	}
	electLeader()
	publishPlayer(player)
	publishLobby()
	if runActive then
		task.delay(3, function()
			if player.Parent == Players then
				Net.fire(player, "Toast", "info", "toast.waitingForRun", {})
			end
		end)
	end
end

local function onPlayerRemoving(player: Player)
	presence[player] = nil
	global:Delete({ "players", tostring(player.UserId) })
	if leader == player then
		leader = nil
	end
	electLeader()
	publishLobby()
end

function SessionService.Init()
	Registry.add("Session", SessionService)
	global:Set({ "players" }, {})
	publishLobby()
end

function SessionService.Start()
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end
	local Profiles = profiles()
	Profiles.Loaded:Connect(function(player: Player, profile: any)
		-- Medal suitcases for stars earned before they existed (checked on a copy; written only if due).
		local probe = { stats = profile.stats, skins = { owned = table.clone(profile.skins.owned) } }
		if #Mastery.grant(probe) > 0 then
			Profiles.update(player, function(p: any)
				Mastery.grant(p)
			end)
		end
		publishPlayer(player)
		refreshPreviews(player)
		if leader == player then
			electLeader()
		end
		-- Tell players who dropped out of an expedition that its unbanked loot was lost (U20).
		if profile.flags.interruptedRunId ~= "" then
			Net.fire(player, "Toast", "warn", "toast.interruptedRun", {})
			Profiles.update(player, function(p: any)
				p.flags.interruptedRunId = ""
			end)
		end
		if Profiles.usingMemoryStore() then
			Net.fire(player, "Toast", "warn", "toast.memoryStore", {})
		end
	end)
	Profiles.Failed:Connect(function(player: Player)
		publishPlayer(player)
	end)
	Profiles.Changed:Connect(function(player: Player)
		refreshPreviews(player)
		publishPlayer(player) -- a loadout change shows in the squad list
	end)

	-- A mission switched off live is never launched: the leader's pick falls back to an allowed one.
	Registry.get("Flags").Changed:Connect(function()
		if not missionAllowedFor(leader, selectedMission) then
			selectedMission = defaultMissionFor(leader)
		end
		for player in presence do
			refreshPreviews(player)
		end
		publishLobby()
	end)

	Net.on("ClientReady", onClientReady)
	Net.on("SetReady", function(player: Player, ready: boolean)
		SessionService.setReady(player, ready, false)
	end)
	Net.on("SetLoadout", onSetLoadout)
	Net.on("SelectMission", onSelectMission)
	Net.on("SelectReward", onSelectReward)
	Net.on("EquipSkin", onEquipSkin)
	Net.on("BuySkin", onBuySkin)
	Net.on("SaveSettings", onSaveSettings)
	Net.on("Feedback", onFeedback)
	Net.on("TutorialStep", function(player: Player, step: string)
		Registry.get("Telemetry").tutorialStep(player, step)
	end)

	-- Ready zone (walking into the departure elevator) and countdown.
	task.spawn(function()
		local Lobby = Registry.get("Lobby")
		local Characters = Registry.get("Characters")
		while true do
			task.wait(0.25)
			if Registry.get("Expedition").phase() == "Prep" then
				for player, p in presence do
					local position = Characters.position(player)
					if position and not p.waiting then
						local inside = Lobby.isInReadyZone(position)
						if not inside then
							p.zoneArmed = true
						end
						if inside and not p.ready and p.zoneArmed then
							SessionService.setReady(player, true, true)
						elseif not inside and p.ready then
							SessionService.setReady(player, false, true)
						end
					end
				end
			end
			updateCountdown()
		end
	end)
end

return SessionService
