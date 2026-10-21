--!strict
--[[
	DebugService: private test commands (S28). Only the experience owner, group admins, listed admin user ids
	(FeatureFlags) and everyone in Studio may use them; every command is re-checked on the server, so public
	players can never invoke them even with a modified client.

	Commands (from the in-game debug panel):
	  phase <capture|win|fail|prep>   force the run state machine along legal transitions
	  room <socketId> <roomId>        spawn any room into a free socket
	  give room <id> | credits <n> | skin <id> | all
	  down | heal | disconnect        simulate a downed player / heal / a disconnect (leaves the run)
	  caretaker <on|off>
	  tp <start|target|exit|safe>
	  time <seconds>                  set the remaining escape time
	  runid | stats                   print the run id / instance and connection stats
	  tutorial <reset|done>           toggle the tutorial flag
	  resetprofile                    wipe your own profile (Studio memory store only)
	  failsaves <n>                   the next n profile store requests fail (Studio memory store only)
	  flag <room|mission|feature> <on|off>   switch content on or off on this server only (rollback rehearsal)
]]

local GroupService = game:GetService("GroupService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local RoomDefs = require(Shared.Config.RoomDefs)
local SkinDefs = require(Shared.Config.SkinDefs)
local Net = require(Shared.Net.Net)
local Log = require(Shared.Util.Log)
local Registry = require(script.Parent.Parent.Core.Registry)
local StateServer = require(script.Parent.Parent.Core.StateServer)

local log = Log.new("Debug")

local DebugService = {}

local adminCache: { [Player]: boolean } = {}

-- Rank of a player in a group (0 when not a member or the lookup fails). GroupService:GetGroupsAsync is the
-- non-deprecated way to read group ranks; one call covers every group the player belongs to.
local function rankIn(player: Player, groupId: number): number
	local ok, groups = pcall(function()
		return GroupService:GetGroupsAsync(player.UserId)
	end)
	if not ok or type(groups) ~= "table" then
		return 0
	end
	for _, info in groups do
		if type(info) == "table" and info.Id == groupId and type(info.Rank) == "number" then
			return info.Rank
		end
	end
	return 0
end

function DebugService.isAdmin(player: Player): boolean
	local cached = adminCache[player]
	if cached ~= nil then
		return cached
	end
	local Flags = Registry.get("Flags")
	local admin = false
	if RunService:IsStudio() then
		admin = true
	elseif Flags.feature("debugTools") then
		if game.CreatorType == Enum.CreatorType.User and player.UserId == game.CreatorId then
			admin = true
		elseif game.CreatorType == Enum.CreatorType.Group then
			admin = rankIn(player, game.CreatorId) >= 254
		end
		if not admin and table.find(Flags.adminUserIds(), player.UserId) then
			admin = true
		end
		local group = Flags.adminGroup()
		if not admin and group then
			admin = rankIn(player, group.id) >= group.minRank
		end
	end
	adminCache[player] = admin
	return admin
end

local function reply(player: Player, text: string)
	Net.fire(player, "DebugReply", text)
	log:Info(player.Name, text)
end

local function countInstances(): (number, number)
	local parts, total = 0, 0
	for _, d in workspace:GetDescendants() do
		total += 1
		if d:IsA("BasePart") then
			parts += 1
		end
	end
	return total, parts
end

local function onDebug(player: Player, command: string, a: string?, b: string?)
	if not DebugService.isAdmin(player) then
		return
	end
	local Expedition = Registry.get("Expedition")
	local run = Expedition.current()
	local entry = Expedition.entry(player)
	local Profiles = Registry.get("Profiles")

	if command == "phase" then
		reply(player, Expedition.debugForce(a or ""))
	elseif command == "room" then
		if not run then
			return reply(player, "no run")
		end
		reply(player, Registry.get("Rooms").debugSpawn(run, a or "", b or ""))
	elseif command == "give" then
		if a == "room" and b and RoomDefs.byId[b] then
			Profiles.update(player, function(p: any)
				p.rooms[b] = true
			end)
			reply(player, "granted room " .. b)
		elseif a == "credits" then
			local amount = math.clamp(tonumber(b) or 0, -100000, 100000)
			Profiles.update(player, function(p: any)
				p.credits = math.max(0, p.credits + amount)
			end)
			reply(player, "credits adjusted by " .. amount)
		elseif a == "skin" and b and SkinDefs.byId[b] then
			Profiles.update(player, function(p: any)
				p.skins.owned[b] = true
			end)
			reply(player, "granted skin " .. b)
		elseif a == "all" then
			Profiles.update(player, function(p: any)
				for id in RoomDefs.byId do
					p.rooms[id] = true
				end
				for id in SkinDefs.byId do
					p.skins.owned[id] = true
				end
				p.tutorialDone = true
				p.stats.extractions = math.max(p.stats.extractions, 10)
			end)
			reply(player, "unlocked everything")
		else
			reply(player, "usage: give room <id> | credits <n> | skin <id> | all")
		end
	elseif command == "down" then
		if run and entry then
			Registry.get("Health").forceDown(run, entry)
			reply(player, "downed")
		end
	elseif command == "heal" then
		if run and entry then
			Registry.get("Health").heal(run, entry)
			reply(player, "healed")
		end
	elseif command == "disconnect" then
		Expedition.leave(player)
		reply(player, "simulated leaving the run")
	elseif command == "caretaker" then
		Registry.get("Caretaker").setDebugEnabled(run, a ~= "off")
		reply(player, "caretaker " .. (if a == "off" then "off" else "on"))
	elseif command == "tp" then
		if not run then
			return reply(player, "no run")
		end
		local Characters = Registry.get("Characters")
		if a == "target" then
			Characters.teleport(player, CFrame.new(run.runtime.target.capturePoint + Vector3.new(0, 1, 0)))
		elseif a == "exit" then
			Characters.teleport(player, run.runtime.exit.cf)
		elseif a == "safe" and entry and entry.lastSafe then
			Characters.teleport(player, entry.lastSafe)
		else
			Characters.teleport(player, run.runtime.spawns[1])
		end
		reply(player, "teleported")
	elseif command == "time" then
		Expedition.debugSetEscapeTime(tonumber(a) or 10)
		reply(player, "escape timer set")
	elseif command == "runid" then
		reply(player, "run id: " .. (if run then run.id else "none") .. " phase: " .. Expedition.phase())
	elseif command == "stats" then
		local total, parts = countInstances()
		reply(
			player,
			string.format("workspace instances %d, parts %d, rejected remotes %d", total, parts, Net.rejected)
		)
	elseif command == "tutorial" then
		Profiles.update(player, function(p: any)
			p.tutorialDone = a == "done"
		end)
		reply(player, "tutorial flag " .. (if a == "done" then "done" else "reset"))
	elseif command == "resetprofile" then
		if Profiles.usingMemoryStore() then
			Profiles.update(player, function(p: any)
				p.rooms = { Freezer = true, Fan = true }
				p.loadout = { "Freezer", "Fan" }
				p.credits = 0
				p.tutorialDone = false
				p.stats.extractions = 0
				p.stats.cleared = {}
			end)
			reply(player, "profile reset (memory store)")
		else
			reply(player, "resetprofile is only available with the Studio memory store")
		end
	elseif command == "flag" then
		if a and (b == "on" or b == "off") and Registry.get("Flags").setTestOverride(a, b == "on") then
			reply(player, string.format("%s switched %s on this server", a, b :: string))
		else
			reply(player, "usage: flag <room|mission|feature id> <on|off>")
		end
	elseif command == "failsaves" then
		local count = tonumber(a) or 0
		if Profiles.injectStoreFailures(count) then
			reply(player, string.format("the next %d store requests will fail", count))
		else
			reply(player, "failsaves is only available with the Studio memory store")
		end
	else
		reply(player, "unknown command " .. command)
	end
end

function DebugService.Init()
	Registry.add("Debug", DebugService)
end

function DebugService.Start()
	Net.on("Debug", onDebug)
	local function announce(player: Player)
		task.spawn(function()
			if DebugService.isAdmin(player) then
				StateServer.private(player):Set({ "admin" }, true)
			end
		end)
	end
	Players.PlayerAdded:Connect(announce)
	for _, player in Players:GetPlayers() do
		announce(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		adminCache[player] = nil
	end)
end

return DebugService
