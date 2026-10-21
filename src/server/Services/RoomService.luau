--!strict
--[[
	RoomService: unfolding rooms into sockets and folding them back (S05, S06, S07, S19, R06, R11, R13, A04).

	* Requests are validated with DeployRules on the server; the first valid claim on a socket wins.
	* A room only vanishes when its occupancy zone holds no player and no cargo; a blocked recall tells the
	  owner exactly who or what must leave (U07).
	* Removing a room immediately removes its effect source; shared zones recompute from what remains (R13).
	* Rooms of players who leave become orphaned and fold automatically once empty (S19).
	* Deploying never costs anything; capacity is freed by recalling (R06).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.Config.GameConfig)
local RoomDefs = require(Shared.Config.RoomDefs)
local DeployRules = require(Shared.Logic.DeployRules)
local RoomPrefabs = require(Shared.World.RoomPrefabs)
local Geometry = require(Shared.World.Geometry)
local MathUtil = require(Shared.Util.MathUtil)
local Net = require(Shared.Net.Net)
local Registry = require(script.Parent.Parent.Core.Registry)
local StateServer = require(script.Parent.Parent.Core.StateServer)
local RunTypes = require(script.Parent.Parent.Core.RunTypes)
local Attach = require(script.Parent.Parent.Core.Attach)

type Run = RunTypes.Run
type RosterEntry = RunTypes.RosterEntry

type RoomRecord = {
	socketId: string,
	owner: number,
	ownerName: string,
	slot: number,
	roomId: string,
	skin: string,
	dir: string?,
	model: Model,
	orphaned: boolean,
	state: "Unfolding" | "Active" | "Folding",
	since: number,
}

type Scratch = {
	rooms: { [string]: RoomRecord },
	doors: { [string]: { BasePart } },
	markers: { [string]: BasePart },
	folder: Folder,
}

local RoomService = {}

local global = StateServer.global("global")

local function serverNow(): number
	return workspace:GetServerTimeNow()
end

local function scratch(run: Run): Scratch
	return run.scratch.rooms
end

local function setSocketDoors(run: Run, socketId: string, open: boolean)
	local doors = scratch(run).doors[socketId]
	if doors then
		for _, door in doors do
			door:SetAttribute("Open", open)
			door.CanCollide = not open
		end
	end
	local marker = scratch(run).markers[socketId]
	if marker then
		marker:SetAttribute("Occupied", open)
	end
end

local function publishSocket(_run: Run, record: RoomRecord?)
	if not record then
		return
	end
	global:Set({ "sockets", record.socketId }, {
		room = record.roomId,
		owner = tostring(record.owner),
		ownerName = record.ownerName,
		slot = record.slot,
		dir = record.dir,
		skin = record.skin,
		state = record.state,
		since = record.since,
		orphaned = record.orphaned,
	})
end

-- Effect sources for EffectModel: socket -> channel (folding rooms no longer emit).
function RoomService.activeSources(run: Run): { [string]: string }
	local out = {}
	local s = scratch(run)
	if not s then
		return out
	end
	for socketId, record in s.rooms do
		if record.state ~= "Folding" then
			out[socketId] = (RoomDefs.byId[record.roomId] :: any).effect
		end
	end
	return out
end

-- Active wind lanes (lane runtime records) from deployed Fan rooms.
function RoomService.activeLanes(run: Run): { any }
	local out = {}
	local s = scratch(run)
	if not s then
		return out
	end
	for socketId, record in s.rooms do
		if record.state ~= "Folding" and record.roomId == "Fan" and record.dir then
			local socket = run.runtime.sockets[socketId]
			local laneId = socket and socket.lanes[record.dir :: string]
			local lane = laneId and run.runtime.lanes[laneId]
			if lane then
				table.insert(out, lane)
			end
		end
	end
	table.sort(out, function(a, b)
		return a.id < b.id
	end)
	return out
end

-- Active magnets: { socketId, crates, anchor (Vector3) }.
function RoomService.activeMagnets(run: Run): { any }
	local out = {}
	local s = scratch(run)
	if not s then
		return out
	end
	for socketId, record in s.rooms do
		if record.state ~= "Folding" and record.roomId == "Magnet" then
			local socket = run.runtime.sockets[socketId]
			if socket and socket.links.magnet then
				table.insert(
					out,
					{ socketId = socketId, crates = socket.links.magnet, anchor = socket.doorCF.Position }
				)
			end
		end
	end
	return out
end

-- Sockets with an active Freezer whose cold links include `zoneId` (carts use this).
function RoomService.isCold(run: Run, zoneId: string): boolean
	for socketId, effect in RoomService.activeSources(run) do
		if effect == "cold" then
			local socket = run.runtime.sockets[socketId]
			if socket and socket.links.cold and table.find(socket.links.cold, zoneId) then
				return true
			end
		end
	end
	return false
end

-- Names of players (and "the suitcase") inside a room's occupancy zone (S07).
function RoomService.occupants(run: Run, socketId: string): { string }
	local socket = run.runtime.sockets[socketId]
	local out = {}
	if not socket then
		return out
	end
	local cf, size = Geometry.roomOccupancy(socket.roomCF)
	local Characters = Registry.get("Characters")
	for _, player in Players:GetPlayers() do
		local position = Characters.position(player)
		if position and MathUtil.pointInBox(cf, size, position, 0.25) then
			table.insert(out, player.DisplayName)
		end
	end
	local cargo = Registry.get("Cargo").position(run)
	if cargo and MathUtil.pointInBox(cf, size, cargo, 0.25) then
		table.insert(out, "suitcase")
	end
	return out
end

function RoomService.roomAt(run: Run, position: Vector3): string?
	local s = scratch(run)
	if not s then
		return nil
	end
	for socketId in s.rooms do
		local socket = run.runtime.sockets[socketId]
		local cf, size = Geometry.roomOccupancy(socket.roomCF)
		if MathUtil.pointInBox(cf, size, position, 0.5) then
			return socketId
		end
	end
	return nil
end

local function deployState(run: Run): DeployRules.DeployState
	local claims = {}
	for socketId, record in scratch(run).rooms do
		claims[socketId] = { owner = record.owner, slot = record.slot, room = record.roomId }
	end
	local valid = {}
	for socketId in run.runtime.sockets do
		valid[socketId] = true
	end
	local disabled = {}
	local Flags = Registry.get("Flags")
	for id in RoomDefs.byId do
		if not Flags.isRoomEnabled(id) then
			disabled[id] = true
		end
	end
	return {
		phase = Registry.get("Expedition").phase(),
		sockets = claims,
		validSockets = valid,
		disabledRooms = disabled,
		perPlayerCap = GameConfig.Deploy.ActivePerPlayer,
		teamCap = GameConfig.Deploy.ActivePerTeam,
	}
end

local function playerView(run: Run, entry: RosterEntry, socketId: string?): DeployRules.PlayerView
	local distance: number? = nil
	if socketId then
		local socket = run.runtime.sockets[socketId]
		local position = Registry.get("Characters").position(entry.player)
		if socket and position then
			distance = (position - socket.interactPoint).Magnitude
		end
	end
	return {
		userId = entry.userId,
		inRoster = true,
		active = entry.health.status == "Active",
		loadout = entry.loadout,
		deployed = entry.deployed,
		distanceToSocket = distance,
		range = GameConfig.Deploy.Range + GameConfig.Interaction.RangeTolerance,
		cooldownRemaining = math.max(0, entry.cooldownUntil - os.clock()),
	}
end

local function refreshEffects(run: Run)
	Registry.get("Effects").setSources(run, RoomService.activeSources(run))
end

-- Deploy -----------------------------------------------------------------------------------------------

function RoomService.deploy(player: Player, socketId: string, slot: number, dir: string?): (boolean, string)
	local Expedition = Registry.get("Expedition")
	local run = Expedition.current()
	local entry = Expedition.entry(player)
	if not run or not entry or run.ended then
		return false, "NotInRun"
	end
	local ok, reason = DeployRules.canDeploy(deployState(run), playerView(run, entry, socketId), slot, socketId, true)
	if not ok then
		return false, reason
	end
	local roomId = entry.loadout[slot]
	local def = RoomDefs.byId[roomId]
	local socket = run.runtime.sockets[socketId]
	local chosenDir: string? = nil
	if def.directional then
		if dir and socket.lanes[dir] then
			chosenDir = dir
		else
			chosenDir = socket.defaultDir
		end
	end
	local skin = entry.skins[roomId]
	local model = RoomPrefabs.build(roomId, skin, socket.roomCF, run.id .. socketId)
	model.Name = "Room_" .. socketId
	model:SetAttribute("SocketId", socketId)
	model:SetAttribute("Owner", entry.userId)
	model.Parent = scratch(run).folder
	local record: RoomRecord = {
		socketId = socketId,
		owner = entry.userId,
		ownerName = entry.display,
		slot = slot,
		roomId = roomId,
		skin = model:GetAttribute("SkinId") :: string,
		dir = chosenDir,
		model = model,
		orphaned = false,
		state = "Unfolding",
		since = serverNow(),
	}
	scratch(run).rooms[socketId] = record
	entry.deployed[slot] = socketId
	entry.cooldownUntil = os.clock() + GameConfig.Deploy.PlayerCooldownSeconds
	setSocketDoors(run, socketId, true)
	publishSocket(run, record)
	refreshEffects(run)
	Expedition.publishRosterEntry(run, entry)
	Registry.get("Caretaker").onRoomsChanged(run)
	Registry.get("Caretaker").noise(run, socket.interactPoint, GameConfig.Noise.Deploy)
	run.stats.deploys += 1
	run.stats.roomsUsed[roomId] = true
	if not run.stats.firstDeployAt then
		run.stats.firstDeployAt = os.clock()
	end
	Registry.get("Expedition").fireRun("roomUnfold", { socket = socketId, room = roomId, owner = entry.key })
	Registry.get("Telemetry").deployed(run, entry, roomId, socketId)
	Registry.get("Profiles").update(player, function(profile: any)
		profile.stats.deploys += 1
	end)
	task.delay(GameConfig.Deploy.UnfoldSeconds, function()
		local s = run.scratch.rooms
		if s and s.rooms[socketId] == record and record.state == "Unfolding" then
			record.state = "Active"
			publishSocket(run, record)
		end
	end)
	return true, "Ok"
end

local function fold(run: Run, record: RoomRecord)
	if record.state == "Folding" then
		return
	end
	record.state = "Folding"
	record.since = serverNow()
	publishSocket(run, record)
	refreshEffects(run)
	local socket = run.runtime.sockets[record.socketId]
	Registry.get("Expedition").fireRun("roomFold", { socket = record.socketId, room = record.roomId })
	Registry.get("Caretaker").noise(run, socket.interactPoint, GameConfig.Noise.Recall)
	task.delay(GameConfig.Deploy.FoldSeconds, function()
		local s = run.scratch.rooms
		if not s or s.rooms[record.socketId] ~= record then
			return
		end
		s.rooms[record.socketId] = nil
		record.model:Destroy()
		setSocketDoors(run, record.socketId, false)
		global:Delete({ "sockets", record.socketId })
		local owner = run.roster[record.owner]
		if owner and owner.deployed[record.slot] == record.socketId then
			owner.deployed[record.slot] = nil
			Registry.get("Expedition").publishRosterEntry(run, owner)
		end
		Registry.get("Caretaker").onRoomsChanged(run)
	end)
end

function RoomService.recall(player: Player, slot: number): (boolean, string, { string }?)
	local Expedition = Registry.get("Expedition")
	local run = Expedition.current()
	local entry = Expedition.entry(player)
	if not run or not entry or run.ended then
		return false, "NotInRun", nil
	end
	local socketId = entry.deployed[slot]
	local occupants = if socketId then RoomService.occupants(run, socketId) else {}
	local ok, reason = DeployRules.canRecall(deployState(run), playerView(run, entry, nil), slot, #occupants)
	if not ok then
		return false, reason, occupants
	end
	local record = scratch(run).rooms[socketId :: string]
	entry.cooldownUntil = os.clock() + GameConfig.Deploy.PlayerCooldownSeconds
	run.stats.recalls += 1
	fold(run, record)
	return true, "Ok", nil
end

-- Debug: spawn any room into a socket for the first participant (S28).
function RoomService.debugSpawn(run: Run, socketId: string, roomId: string): string
	if not run.runtime.sockets[socketId] or scratch(run).rooms[socketId] then
		return "socket unavailable"
	end
	if not RoomDefs.byId[roomId] then
		return "unknown room"
	end
	local socket = run.runtime.sockets[socketId]
	local model = RoomPrefabs.build(roomId, nil, socket.roomCF, "debug")
	model.Parent = scratch(run).folder
	local record: RoomRecord = {
		socketId = socketId,
		owner = 0,
		ownerName = "debug",
		slot = 0,
		roomId = roomId,
		skin = model:GetAttribute("SkinId") :: string,
		dir = socket.defaultDir,
		model = model,
		orphaned = true,
		state = "Active",
		since = serverNow(),
	}
	scratch(run).rooms[socketId] = record
	setSocketDoors(run, socketId, true)
	publishSocket(run, record)
	refreshEffects(run)
	return "spawned " .. roomId .. " at " .. socketId
end

-- Held suitcase (A04: suitcase equip) --------------------------------------------------------------------

local function clearHeld(character: Model?)
	if not character then
		return
	end
	local held = character:FindFirstChild("HeldSuitcase")
	if held then
		held:Destroy()
	end
end

-- The suitcase in a player's hand always shows their selected room, except while they are not Active or
-- are carrying the stolen room (the cargo suitcase takes the hand).
function RoomService.refreshHeld(player: Player)
	local Expedition = Registry.get("Expedition")
	local entry = Expedition.entry(player)
	local character = player.Character
	clearHeld(character)
	if not entry or not character or entry.selectedSlot == 0 or entry.health.status ~= "Active" then
		return
	end
	if Registry.get("Cargo").carrierOf(Expedition.current()) == entry.userId then
		return
	end
	local roomId = entry.loadout[entry.selectedSlot]
	local def = RoomDefs.byId[roomId]
	local case = RoomPrefabs.suitcase(entry.suitcase, 0.8, if def then def.color else nil)
	case.Name = "HeldSuitcase"
	Attach.toHand(character, case)
end

local function onSelectSlot(player: Player, slot: number)
	local entry = Registry.get("Expedition").entry(player)
	if not entry or not player.Character then
		return
	end
	if slot < 0 or slot > #entry.loadout then
		return
	end
	if entry.selectedSlot == slot then
		return
	end
	entry.selectedSlot = slot
	RoomService.refreshHeld(player)
end

function RoomService.clearHeld(player: Player)
	clearHeld(player.Character)
end

-- Lifecycle --------------------------------------------------------------------------------------------

function RoomService.startRun(run: Run)
	local folder = Instance.new("Folder")
	folder.Name = "Rooms"
	folder.Parent = run.model
	local s: Scratch = { rooms = {}, doors = {}, markers = {}, folder = folder }
	for _, d in run.model:GetDescendants() do
		if d:IsA("BasePart") then
			local socketId = d:GetAttribute("SocketId")
			if type(socketId) == "string" then
				if d:HasTag("RN_Door") then
					s.doors[socketId] = s.doors[socketId] or {}
					table.insert(s.doors[socketId], d)
				elseif d:HasTag("RN_SocketMarker") then
					s.markers[socketId] = d
				end
			end
		end
	end
	run.scratch.rooms = s
	global:Set({ "sockets" }, {})
end

function RoomService.step(run: Run, _dt: number)
	local s = scratch(run)
	if not s then
		return
	end
	-- Orphaned rooms fold once nobody (and no cargo) is inside (S19).
	for _, record in s.rooms do
		if record.orphaned and record.state == "Active" and record.owner ~= 0 then
			if #RoomService.occupants(run, record.socketId) == 0 then
				fold(run, record)
			end
		end
	end
end

function RoomService.onPlayerLeft(run: Run, entry: RosterEntry)
	local s = scratch(run)
	if not s then
		return
	end
	for _, record in s.rooms do
		if record.owner == entry.userId then
			record.orphaned = true
			publishSocket(run, record)
		end
	end
	RoomService.clearHeld(entry.player)
end

function RoomService.endRun(run: Run)
	for _, entry in run.roster do
		if entry.player.Parent == Players then
			RoomService.clearHeld(entry.player)
		end
	end
	run.scratch.rooms = nil
end

function RoomService.Init()
	Registry.add("Rooms", RoomService)
end

function RoomService.Start()
	Net.on("RequestDeploy", function(player: Player, socketId: string, slot: number, dir: string?)
		local ok, reason = RoomService.deploy(player, socketId, slot, dir)
		if not ok then
			Net.fire(player, "Toast", "error", DeployRules.reasonKey(reason :: any), { socket = socketId })
		end
	end)
	Net.on("RequestRecall", function(player: Player, slot: number)
		local ok, reason, occupants = RoomService.recall(player, slot)
		if not ok then
			Net.fire(player, "Toast", "error", DeployRules.reasonKey(reason :: any), {
				who = if occupants then table.concat(occupants, ", ") else "",
			})
		end
	end)
	Net.on("SelectSlot", onSelectSlot)
end

return RoomService
