--!strict
--[[
	CargoService: the captured room travels as one shared suitcase (S13, S14, U09).

	* Any active roster player can pick it up; the carrier moves a little slower.
	* Downing, leaving or disconnecting drops it safely where the carrier stood; if that spot is unsafe (over
	  a pit, out of bounds) it returns to the carrier's last safe checkpoint.
	* The newly captured room cannot be deployed during the run - it only becomes usable once banked.
	* Carrying it into the extraction elevator banks it and ends the run with success.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.Config.GameConfig)
local RoomDefs = require(Shared.Config.RoomDefs)
local RoomPrefabs = require(Shared.World.RoomPrefabs)
local MathUtil = require(Shared.Util.MathUtil)
local Net = require(Shared.Net.Net)
local Registry = require(script.Parent.Parent.Core.Registry)
local StateServer = require(script.Parent.Parent.Core.StateServer)
local RunTypes = require(script.Parent.Parent.Core.RunTypes)
local Attach = require(script.Parent.Parent.Core.Attach)

type Run = RunTypes.Run
type RosterEntry = RunTypes.RosterEntry

type CargoState = "None" | "Carried" | "Dropped" | "Banked"

type Scratch = {
	state: CargoState,
	carrier: number?,
	position: Vector3?,
	roomId: string,
	model: Model?,
	since: number,
}

local CargoService = {}

local global = StateServer.global("global")

local function scratch(run: Run?): Scratch?
	if not run then
		return nil
	end
	return run.scratch.cargo
end

local function publish(run: Run)
	local s = scratch(run)
	if not s then
		return
	end
	local carrierEntry = if s.carrier then run.roster[s.carrier] else nil
	global:Set({ "cargo" }, {
		state = s.state,
		carrier = if s.carrier then tostring(s.carrier) else nil,
		carrierName = if carrierEntry then carrierEntry.display else nil,
		position = s.position,
		room = s.roomId,
		since = workspace:GetServerTimeNow(),
	})
end

local function setCarryAttribute(entry: RosterEntry?, carrying: boolean)
	if entry and entry.player.Parent == Players then
		entry.player:SetAttribute("Carrying", if carrying then true else nil)
	end
end

local function makeModel(roomId: string, suitcase: string?): Model
	local def = RoomDefs.byId[roomId]
	local model = RoomPrefabs.suitcase(suitcase, 1.35, if def then def.color else nil)
	model.Name = "CargoSuitcase"
	model:SetAttribute("Cargo", true)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d:AddTag("RN_Cargo")
		end
	end
	return model
end

function CargoService.carrierOf(run: Run?): number?
	local s = scratch(run)
	return if s and s.state == "Carried" then s.carrier else nil
end

function CargoService.isBanked(run: Run): boolean
	local s = scratch(run)
	return s ~= nil and s.state == "Banked"
end

function CargoService.state(run: Run?): string
	local s = scratch(run)
	return if s then s.state else "None"
end

-- Current world position of the cargo (carried or dropped).
function CargoService.position(run: Run?): Vector3?
	local s = scratch(run)
	if not s or s.state == "None" or s.state == "Banked" then
		return nil
	end
	if s.state == "Carried" and s.carrier then
		local entry = (run :: Run).roster[s.carrier]
		if entry then
			return Registry.get("Characters").position(entry.player)
		end
	end
	return s.position
end

function CargoService.droppedPosition(run: Run?): Vector3?
	local s = scratch(run)
	if s and s.state == "Dropped" then
		return s.position
	end
	return nil
end

local function attachTo(run: Run, entry: RosterEntry): boolean
	local s = scratch(run) :: Scratch
	local character = entry.player.Character
	if s.model then
		s.model:Destroy()
		s.model = nil
	end
	Registry.get("Rooms").clearHeld(entry.player)
	if not character then
		return false
	end
	local model = makeModel(s.roomId, entry.suitcase)
	if not Attach.toHand(character, model) then
		model:Destroy()
		return false
	end
	s.model = model
	return true
end

-- Is a drop position safe ground (not over a pit or outside the level)?
local function isSafeDrop(run: Run, position: Vector3): boolean
	local b = run.runtime.bounds
	if
		position.Y < b.min.Y + 30
		or position.X < b.min.X
		or position.X > b.max.X
		or position.Z < b.min.Z
		or position.Z > b.max.Z
	then
		return false
	end
	for _, pit in run.runtime.pits do
		if MathUtil.pointInBoxXZ(pit.box.cf, pit.box.size, position, 0.5) then
			local zone = pit.zone
			if not (zone and run.effect:basinSolid(zone)) then
				return false
			end
		end
	end
	for _, floor in run.runtime.safeFloors do
		if MathUtil.pointInBox(floor.cf, floor.size, position, 1) then
			return true
		end
	end
	-- Inside a deployed room counts as safe.
	return Registry.get("Rooms").roomAt(run, position) ~= nil
end

local function placeDropped(run: Run, position: Vector3)
	local s = scratch(run) :: Scratch
	if s.model then
		s.model:Destroy()
	end
	local model = makeModel(s.roomId, nil)
	-- Rest on the floor: raycast down from the drop point.
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { run.model }
	local hit = workspace:Raycast(position + Vector3.new(0, 2, 0), Vector3.new(0, -12, 0), params)
	local floorY = if hit then hit.Position.Y else position.Y - 3
	local rest = Vector3.new(position.X, floorY + 3.9, position.Z)
	Attach.place(model, CFrame.new(rest) * CFrame.Angles(0, math.rad(25), 0))
	model.Parent = run.model
	s.model = model
	s.position = rest
end

function CargoService.spawnCargo(run: Run, entry: RosterEntry, roomId: string)
	local s: Scratch = {
		state = "Carried",
		carrier = entry.userId,
		position = nil,
		roomId = roomId,
		model = nil,
		since = os.clock(),
	}
	run.scratch.cargo = s
	if attachTo(run, entry) then
		setCarryAttribute(entry, true)
	else
		s.state = "Dropped"
		s.carrier = nil
		placeDropped(run, run.runtime.target.capturePoint)
	end
	publish(run)
	Registry.get("Expedition").publishRosterEntry(run, entry)
end

function CargoService.drop(run: Run, entry: RosterEntry, reason: string)
	local s = scratch(run)
	if not s or s.state ~= "Carried" or s.carrier ~= entry.userId then
		return
	end
	local position = Registry.get("Characters").position(entry.player)
	local dropAt: Vector3
	if position and isSafeDrop(run, position) then
		local look = Vector3.zero
		local root = Registry.get("Characters").root(entry.player)
		if root then
			look = root.CFrame.LookVector * GameConfig.Cargo.DropOffset
		end
		local ahead = position + Vector3.new(look.X, 0, look.Z)
		dropAt = if isSafeDrop(run, ahead) then ahead else position
	else
		local safe = entry.lastSafe or run.runtime.spawns[1]
		dropAt = safe.Position
	end
	s.state = "Dropped"
	s.carrier = nil
	s.since = os.clock()
	setCarryAttribute(entry, false)
	placeDropped(run, dropAt)
	publish(run)
	Registry.get("Expedition").publishRosterEntry(run, entry)
	Net.fireAll("Effect", "cargoDrop", { position = s.position, reason = reason })
end

function CargoService.pickup(run: Run, entry: RosterEntry): boolean
	local s = scratch(run)
	if not s or s.state ~= "Dropped" then
		return false
	end
	if entry.health.status ~= "Active" then
		return false
	end
	s.state = "Carried"
	s.carrier = entry.userId
	s.position = nil
	s.since = os.clock()
	if not attachTo(run, entry) then
		return false
	end
	setCarryAttribute(entry, true)
	publish(run)
	Registry.get("Expedition").publishRosterEntry(run, entry)
	Net.fireAll("Effect", "cargoPickup", { userId = entry.key })
	return true
end

function CargoService.onCarrierDowned(run: Run, entry: RosterEntry)
	CargoService.drop(run, entry, "downed")
end

function CargoService.onPlayerLeft(run: Run, entry: RosterEntry)
	CargoService.drop(run, entry, "left")
end

function CargoService.onCharacterSpawned(run: Run, entry: RosterEntry)
	local s = scratch(run)
	if s and s.state == "Carried" and s.carrier == entry.userId then
		attachTo(run, entry)
		setCarryAttribute(entry, true)
	end
end

function CargoService.startRun(run: Run)
	run.scratch.cargo = nil
	global:Set({ "cargo" }, { state = "None" })
end

function CargoService.step(run: Run, _dt: number)
	local s = scratch(run)
	if not s then
		return
	end
	if s.state == "Carried" and s.carrier then
		local entry = run.roster[s.carrier]
		if not entry or not entry.connected or entry.left then
			s.state = "Dropped"
			s.carrier = nil
			placeDropped(run, run.runtime.target.capturePoint)
			publish(run)
			return
		end
		if entry.health.status ~= "Active" then
			CargoService.drop(run, entry, "downed")
			return
		end
		local position = Registry.get("Characters").position(entry.player)
		if position then
			local exit = run.runtime.exit
			if
				Registry.get("Expedition").phase() == "Escape"
				and MathUtil.pointInBox(exit.cf, exit.size, position, 0.5)
			then
				s.state = "Banked"
				s.carrier = nil
				setCarryAttribute(entry, false)
				if s.model then
					s.model:Destroy()
					s.model = nil
				end
				publish(run)
				Net.fireAll("Effect", "cargoBanked", { userId = entry.key })
				return
			end
		end
	elseif s.state == "Dropped" and s.position then
		-- Dropped cargo resting on ice that has since melted (or any unsafe spot) returns to safety.
		if not isSafeDrop(run, s.position) then
			local fallback = run.runtime.target.capturePoint
			placeDropped(run, fallback)
			publish(run)
			Net.fireAll("Effect", "cargoReturned", { position = s.position })
		end
	end
end

function CargoService.endRun(run: Run)
	local s = scratch(run)
	if s and s.carrier then
		setCarryAttribute(run.roster[s.carrier], false)
	end
	for _, entry in run.roster do
		setCarryAttribute(entry, false)
		local character = entry.player.Character
		if character then
			local held = character:FindFirstChild("CargoSuitcase")
			if held then
				held:Destroy()
			end
		end
	end
	if s and s.model then
		s.model:Destroy()
	end
	run.scratch.cargo = nil
end

function CargoService.Init()
	Registry.add("Cargo", CargoService)
end

function CargoService.Start()
	Net.on("DropCargo", function(player: Player)
		local Expedition = Registry.get("Expedition")
		local run = Expedition.current()
		local entry = Expedition.entry(player)
		if run and entry then
			CargoService.drop(run, entry, "manual")
		end
	end)
end

return CargoService
