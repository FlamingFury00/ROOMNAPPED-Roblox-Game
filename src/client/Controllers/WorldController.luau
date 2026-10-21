--!strict
--[[
	WorldController: makes the hotel feel alive on every client (A01, A03, U08).

	* Doors (tag RN_Door): the server only flips the `Open` attribute and collision; clients slide the panel
	  by its `OpenOffset` with sound, so doors are smooth at any network rate.
	* Lamps (tag RN_Lamp): a few lamps per level flicker; during the escape every light in the level shifts to
	  a pulsing alarm red.
	* Socket markers glow brighter while you hold a room suitcase, the capture marker breathes until the room
	  is stolen, and captured-room cargo tags pulse.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage.Shared
local MathUtil = require(Shared.Util.MathUtil)
local RunInfo = require(script.Parent.Parent.Core.RunInfo)
local ClientState = require(script.Parent.Parent.Core.ClientState)
local AudioController = require(script.Parent.AudioController)
local Motion = require(script.Parent.Parent.UI.Motion)
local Toasts = require(script.Parent.Parent.UI.Toasts)

local WorldController = {}
WorldController.priority = 30

type DoorRecord = { part: BasePart, closed: CFrame, offset: Vector3, open: boolean, tween: Tween? }
-- Every light a lamp part holds (a ceiling lamp pools light with a spot and glows with a point light).
type LampLight = { light: Light, color: Color3, brightness: number }
type LampRecord = {
	part: BasePart,
	lights: { LampLight },
	flicker: boolean,
	seed: number,
	alarmed: boolean,
}

local doors: { [BasePart]: DoorRecord } = {}
local lamps: { [BasePart]: LampRecord } = {}
local markers: { [BasePart]: number } = {}
local alarm = false
local holdingSuitcase = false

-- Doors -------------------------------------------------------------------------------------------------

local function doorSound(record: DoorRecord, opening: boolean)
	local part = record.part
	local kind = if part:GetAttribute("GateId") ~= nil
		then "gate"
		elseif part:GetAttribute("Elevator") or part:GetAttribute("LobbyElevator") then "elevator"
		else "door"
	-- Two-panel doors would play twice; only the panel on the positive side speaks.
	if record.offset.X < 0 and kind ~= "gate" then
		return
	end
	local name = if kind == "gate"
		then "metal_clank"
		elseif kind == "elevator" then "elevator_doors"
		else if opening then "door_open" else "door_close"
	-- Gates can open far from the lever or plate that opened them: louder, and the squad is told.
	AudioController.play(name, { parent = part, volume = 0.8, rolloffMax = if kind == "gate" then 160 else 90 })
	if kind == "gate" and opening and RunInfo.isParticipant() then
		Toasts.key("key", "toast.gateOpened", nil)
	end
end

local function applyDoor(record: DoorRecord, open: boolean, instant: boolean)
	if record.tween then
		record.tween:Cancel()
		record.tween = nil
	end
	record.open = open
	local goal = if open then record.closed * CFrame.new(record.offset) else record.closed
	if instant or Motion.isReduced() then
		record.part.CFrame = goal
		if not instant then
			doorSound(record, open) -- no slide with Reduced Motion, but the sound and the gate news still play
		end
		return
	end
	local tween = TweenService:Create(
		record.part,
		TweenInfo.new(if open then 0.5 else 0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ CFrame = goal }
	)
	record.tween = tween
	tween:Play()
	doorSound(record, open)
end

local function addDoor(instance: Instance)
	if not instance:IsA("BasePart") or doors[instance] then
		return
	end
	local part = instance
	local offset = part:GetAttribute("OpenOffset")
	if typeof(offset) ~= "Vector3" then
		return
	end
	local record: DoorRecord = {
		part = part,
		closed = part.CFrame,
		offset = offset :: Vector3,
		open = false,
		tween = nil,
	}
	doors[part] = record
	applyDoor(record, part:GetAttribute("Open") == true, true)
	part:GetAttributeChangedSignal("Open"):Connect(function()
		local open = part:GetAttribute("Open") == true
		if open ~= record.open then
			applyDoor(record, open, false)
		end
	end)
end

local function removeDoor(instance: Instance)
	if instance:IsA("BasePart") then
		local record = doors[instance]
		if record and record.tween then
			record.tween:Cancel()
		end
		doors[instance] = nil
	end
end

-- Lamps -------------------------------------------------------------------------------------------------

local ALARM_COLOR = Color3.fromRGB(255, 70, 50)

local function addLamp(instance: Instance)
	if not instance:IsA("BasePart") or lamps[instance] then
		return
	end
	local part = instance
	local lights: { LampLight } = {}
	for _, child in part:GetChildren() do
		if child:IsA("Light") then
			table.insert(lights, { light = child, color = child.Color, brightness = child.Brightness })
		end
	end
	-- Roughly one lamp in twelve flickers (stable per lamp so it does not change on rejoin).
	local seed = MathUtil.hash(part:GetFullName()) % 1000
	local levelModel = RunInfo.levelModel()
	local alarmed = alarm and #lights > 0 and levelModel ~= nil and part:IsDescendantOf(levelModel)
	lamps[part] = {
		part = part,
		lights = lights,
		flicker = seed % 12 == 0 and #lights > 0,
		seed = seed,
		alarmed = alarmed,
	}
	if alarmed then
		for _, entry in lights do
			entry.light.Color = entry.color:Lerp(ALARM_COLOR, 0.65)
		end
	end
end

local function removeLamp(instance: Instance)
	if instance:IsA("BasePart") then
		lamps[instance] = nil
	end
end

local function setAlarm(enabled: boolean)
	if alarm == enabled then
		return
	end
	alarm = enabled
	local levelModel = RunInfo.levelModel()
	for part, record in lamps do
		if #record.lights > 0 then
			local inLevel = levelModel ~= nil and part:IsDescendantOf(levelModel)
			-- Only the hotel's lamps raise the alarm; the lobby stays calm for players waiting there.
			record.alarmed = enabled and inLevel
			for _, entry in record.lights do
				if record.alarmed then
					entry.light.Color = entry.color:Lerp(ALARM_COLOR, 0.65)
				else
					entry.light.Color = entry.color
					entry.light.Brightness = entry.brightness
				end
			end
		end
	end
end

local lampAccumulator = 0
local function stepLamps(dt: number)
	lampAccumulator += dt
	if lampAccumulator < 1 / 15 then
		return
	end
	lampAccumulator = 0
	local t = os.clock()
	local pulse = 0.55 + 0.45 * math.sin(t * 5.2)
	for part, record in lamps do
		if part.Parent and (record.alarmed or record.flicker) then
			local factor = 1
			if record.alarmed then
				factor = 0.45 + 0.75 * pulse
			else
				-- Mostly steady with short stutters.
				local n = math.sin(t * 13 + record.seed) * math.sin(t * 7.7 + record.seed * 0.37)
				factor = if n > 0.82 then 0.15 else 1
			end
			for _, entry in record.lights do
				entry.light.Brightness = entry.brightness * factor
			end
		end
	end
end

-- Markers -------------------------------------------------------------------------------------------------

local function addMarker(instance: Instance)
	if instance:IsA("BasePart") then
		markers[instance] = instance.Transparency
	end
end

local function removeMarker(instance: Instance)
	if instance:IsA("BasePart") then
		markers[instance] = nil
	end
end

local function stepMarkers()
	local t = os.clock()
	local breathe = 0.5 + 0.5 * math.sin(t * 3)
	local target = ClientState.get("global", "rooms.target")
	local captured = type(target) == "table" and target.state ~= "Intact"
	for part, base in markers do
		if part.Parent then
			if part:HasTag("RN_CaptureMarker") then
				part.Transparency = if captured then 1 else 0.25 + 0.35 * breathe
			elseif part:HasTag("RN_SocketMarker") then
				local occupied = part:GetAttribute("Occupied") == true
				if occupied then
					part.Transparency = 1
				elseif holdingSuitcase then
					part.Transparency = 0.1 + 0.3 * breathe
				else
					part.Transparency = base
				end
			elseif part:HasTag("RN_CargoGlow") then
				part.Transparency = 0.1 * breathe
			end
		end
	end
end

-- Public --------------------------------------------------------------------------------------------------

-- PlacementController tells us when a suitcase is in hand so free socket doors invite placement.
function WorldController.setHoldingSuitcase(value: boolean)
	holdingSuitcase = value
end

local function track(tag: string, add: (Instance) -> (), remove: (Instance) -> ())
	for _, instance in CollectionService:GetTagged(tag) do
		task.spawn(add, instance)
	end
	CollectionService:GetInstanceAddedSignal(tag):Connect(add)
	CollectionService:GetInstanceRemovedSignal(tag):Connect(remove)
end

-- Models that finish loading on the server after this client built its own slots (moving carts) replace
-- those slots' fallbacks here too.
local function watchAssets()
	local Assets = require(Shared.World.Assets)
	local function onKey(child: Instance)
		task.defer(function()
			Assets.upgrade(child.Name, true)
		end)
	end
	local function attach(folder: Instance)
		folder.ChildAdded:Connect(onKey)
	end
	local existing = ReplicatedStorage:FindFirstChild(Assets.FOLDER)
	if existing then
		attach(existing)
	else
		local connection: RBXScriptConnection? = nil
		connection = ReplicatedStorage.ChildAdded:Connect(function(child: Instance)
			if child.Name == Assets.FOLDER then
				attach(child)
				if connection then
					connection:Disconnect()
				end
			end
		end)
	end
end

function WorldController.start()
	watchAssets()
	track("RN_Door", addDoor, removeDoor)
	track("RN_Lamp", addLamp, removeLamp)
	track("RN_SocketMarker", addMarker, removeMarker)
	track("RN_CaptureMarker", addMarker, removeMarker)
	track("RN_CargoGlow", addMarker, removeMarker)
	RunInfo.PhaseChanged:Connect(function(phase: string)
		setAlarm(phase == "Escape" or phase == "Capture")
	end)
	RunService.Heartbeat:Connect(function(dt: number)
		stepLamps(dt)
		stepMarkers()
	end)
end

return WorldController
