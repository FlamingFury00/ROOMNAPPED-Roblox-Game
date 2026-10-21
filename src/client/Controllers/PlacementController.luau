--!strict
--[[
	PlacementController: choosing a room and previewing where it will unfold (S05, S06, S07, U04, U05).

	* 1 / 2 (D-pad left/right, or tapping a quickbar slot) pulls that room's suitcase out; pressing it again
	  puts it away. The server shows the suitcase in hand for everyone.
	* While a suitcase is out, the nearest socket door in range becomes the candidate. The preview frames the
	  door in the room's colour, outlines every zone that room would change from that door and, for Fans,
	  runs arrows along the wind lane (R / Y turns the fan). Blocked placements frame the door in red and
	  name the reason with the same DeployRules the server uses, so the explanation always matches.
	* If the selected room is already unfolded, the action becomes "Recall" (from anywhere), and the preview
	  warns when someone is still inside it.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.Config.GameConfig)
local Geometry = require(Shared.World.Geometry)
local RoomDefs = require(Shared.Config.RoomDefs)
local DeployRules = require(Shared.Logic.DeployRules)
local MathUtil = require(Shared.Util.MathUtil)
local Signal = require(Shared.Util.Signal)
local Net = require(Shared.Net.Net)
local ClientState = require(script.Parent.Parent.Core.ClientState)
local RunInfo = require(script.Parent.Parent.Core.RunInfo)
local InputController = require(script.Parent.InputController)
local AudioController = require(script.Parent.AudioController)
local WorldController = require(script.Parent.WorldController)
local ZoneVisuals = require(script.Parent.ZoneVisuals)
local Theme = require(script.Parent.Parent.UI.Theme)

local PlacementController = {}
PlacementController.priority = 55

PlacementController.SelectionChanged = Signal.new() -- (slot)
PlacementController.CandidateChanged = Signal.new() -- (candidate?)

export type Candidate = {
	kind: "deploy" | "recall",
	slot: number,
	roomId: string,
	socketId: string?,
	dir: string?,
	valid: boolean,
	reason: string, -- DeployRules reason
	reasonParams: { [string]: any }?,
	position: Vector3,
	noEffect: boolean,
}

local DIR_ORDER = { "Forward", "Backward", "Across" }
local localPlayer = Players.LocalPlayer

local selectedSlot = 0
local chosenDir: { [string]: string } = {} -- socketId -> direction picked with Rotate
local lastActionAt = -math.huge
local candidate: Candidate? = nil
local candidateKey = ""

-- Preview visuals
local previewFolder: Folder? = nil
local frameParts: { Part } = {}
local arrows: { { left: Part, right: Part } } = {}
local magnetBoxes: { SelectionBox } = {}
local highlightKey = ""
local arrowLane: any = nil

-- State helpers -------------------------------------------------------------------------------------------

local function rootPosition(): Vector3?
	local character = localPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root.CFrame.Position
	end
	return nil
end

local function loadout(): { string }
	local entry = RunInfo.myEntry()
	if entry and type(entry.loadout) == "table" then
		return entry.loadout
	end
	return {}
end

local function deployedSockets(): { [number]: string }
	local out = {}
	local entry = RunInfo.myEntry()
	if entry and type(entry.deployed) == "table" then
		for key, socketId in entry.deployed do
			local slot = tonumber(key)
			if slot then
				out[slot] = socketId
			end
		end
	end
	return out
end

local function deployState(): DeployRules.DeployState
	local claims = {}
	local sockets = ClientState.get("global", "sockets")
	if type(sockets) == "table" then
		for socketId, info in sockets do
			claims[socketId] = { owner = tonumber(info.owner) or 0, slot = info.slot or 0, room = info.room or "" }
		end
	end
	local valid = {}
	local level = RunInfo.level()
	if level and type(level.sockets) == "table" then
		for socketId in level.sockets do
			valid[socketId] = true
		end
	end
	-- The rooms switched off when this run launched (the server judges deploys by the same snapshot).
	local snapshot = RunInfo.run().disabledRooms
	local disabled = if type(snapshot) == "table" then snapshot else {}
	return {
		phase = RunInfo.phase(),
		sockets = claims,
		validSockets = valid,
		disabledRooms = disabled,
		perPlayerCap = GameConfig.Deploy.ActivePerPlayer,
		teamCap = GameConfig.Deploy.ActivePerTeam,
	}
end

local function playerView(distance: number?): DeployRules.PlayerView
	local entry = RunInfo.myEntry()
	return {
		userId = localPlayer.UserId,
		inRoster = RunInfo.isParticipant(),
		active = entry ~= nil and entry.status == "Active",
		loadout = loadout(),
		deployed = deployedSockets(),
		distanceToSocket = distance,
		range = GameConfig.Deploy.Range,
		cooldownRemaining = math.max(0, lastActionAt + GameConfig.Deploy.PlayerCooldownSeconds - os.clock()),
	}
end

-- Names of characters (and the suitcase) inside a room - mirrors the server's recall check.
local function occupantsOf(socketId: string): { string }
	local level = RunInfo.level()
	local socket = level and level.sockets and level.sockets[socketId]
	local out = {}
	if not socket then
		return out
	end
	local cf, size = Geometry.roomOccupancy(socket.roomCF)
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") and MathUtil.pointInBox(cf, size, root.CFrame.Position, 0.25) then
			table.insert(out, player.DisplayName)
		end
	end
	local cargo = ClientState.get("global", "cargo")
	if type(cargo) == "table" and cargo.state == "Dropped" and typeof(cargo.position) == "Vector3" then
		if MathUtil.pointInBox(cf, size, cargo.position, 0.25) then
			table.insert(out, "suitcase")
		end
	end
	return out
end

local function allowedDirs(socket: any): { string }
	local out = {}
	if type(socket.lanes) == "table" then
		for _, dir in DIR_ORDER do
			if socket.lanes[dir] then
				table.insert(out, dir)
			end
		end
	end
	return out
end

local function dirFor(socketId: string, socket: any): string?
	local dirs = allowedDirs(socket)
	if #dirs == 0 then
		return nil
	end
	local chosen = chosenDir[socketId]
	if chosen and table.find(dirs, chosen) then
		return chosen
	end
	return if socket.defaultDir and table.find(dirs, socket.defaultDir) then socket.defaultDir else dirs[1]
end

local function linksFor(roomId: string, socket: any): (boolean, { string }, { string })
	-- Returns (hasEffectHere, zoneIdsToOutline, crateIdsToOutline)
	local def = RoomDefs.get(roomId)
	local effect = if def then def.effect else ""
	local links = socket.links or {}
	local zones: { string } = {}
	local crates: { string } = {}
	local function addZone(id: string)
		table.insert(zones, id)
		-- Fires are linked through their pool; outline both.
		if string.sub(id, -5) ~= "_pool" then
			table.insert(zones, id .. "_pool")
		end
	end
	if effect == "cold" and type(links.cold) == "table" then
		for _, id in links.cold do
			addZone(id)
		end
	elseif effect == "water" and type(links.water) == "string" then
		addZone(links.water)
	elseif effect == "vine" and type(links.vine) == "string" then
		addZone(links.vine)
	elseif effect == "magnet" and type(links.magnet) == "table" then
		for _, id in links.magnet do
			table.insert(crates, id)
		end
	end
	local has = #zones > 0 or #crates > 0 or effect == "wind" or effect == "cold"
	return has, zones, crates
end

-- Candidate resolution ----------------------------------------------------------------------------------------

local function resolve(): Candidate?
	if selectedSlot == 0 or not RunInfo.isParticipant() or not RunInfo.isActivePhase() then
		return nil
	end
	local level = RunInfo.level()
	local position = rootPosition()
	if not level or not position then
		return nil
	end
	local roomId = loadout()[selectedSlot]
	if not roomId then
		return nil
	end
	local deployed = deployedSockets()
	local deployedSocket = deployed[selectedSlot]
	if deployedSocket then
		-- Recall from anywhere.
		local occupants = occupantsOf(deployedSocket)
		local ok, reason = DeployRules.canRecall(deployState(), playerView(nil), selectedSlot, #occupants)
		local socket = level.sockets[deployedSocket]
		return {
			kind = "recall",
			slot = selectedSlot,
			roomId = roomId,
			socketId = deployedSocket,
			dir = nil,
			valid = ok,
			reason = reason,
			reasonParams = if #occupants > 0 then { who = table.concat(occupants, ", ") } else nil,
			position = if socket then socket.interactPoint else position,
			noEffect = false,
		}
	end
	-- Nearest socket door in range.
	local bestId: string? = nil
	local bestDistance = math.huge
	for socketId, socket in level.sockets do
		local d = (position - socket.interactPoint).Magnitude
		if d < bestDistance then
			bestDistance = d
			bestId = socketId
		end
	end
	if not bestId or bestDistance > GameConfig.Deploy.Range + 6 then
		return nil
	end
	local socketId = bestId :: string
	local socket = level.sockets[socketId]
	local ok, reason = DeployRules.canDeploy(deployState(), playerView(bestDistance), selectedSlot, socketId, true)
	local def = RoomDefs.get(roomId)
	local dir = if def and def.directional then dirFor(socketId, socket) else nil
	local hasEffect = linksFor(roomId, socket)
	return {
		kind = "deploy",
		slot = selectedSlot,
		roomId = roomId,
		socketId = socketId,
		dir = dir,
		valid = ok,
		reason = reason,
		reasonParams = nil,
		position = socket.interactPoint,
		noEffect = not hasEffect,
	}
end

-- Preview visuals ---------------------------------------------------------------------------------------------

local function previewParent(): Folder
	if previewFolder and previewFolder.Parent then
		return previewFolder :: Folder
	end
	local folder = Instance.new("Folder")
	folder.Name = "RN_PlacementPreview"
	folder.Parent = Workspace
	previewFolder = folder
	return folder
end

local function neonPart(name: string, size: Vector3): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Size = size
	part.Parent = previewParent()
	return part
end

local function clearArrows()
	for _, arrow in arrows do
		arrow.left:Destroy()
		arrow.right:Destroy()
	end
	table.clear(arrows)
	arrowLane = nil
end

local function clearMagnetBoxes()
	for _, box in magnetBoxes do
		box:Destroy()
	end
	table.clear(magnetBoxes)
end

local function clearPreview()
	for _, part in frameParts do
		part:Destroy()
	end
	table.clear(frameParts)
	clearArrows()
	clearMagnetBoxes()
	if highlightKey ~= "" then
		ZoneVisuals.clearHighlight()
		highlightKey = ""
	end
end

local function showFrame(doorCF: CFrame, color: Color3)
	if #frameParts == 0 then
		local w, h = Geometry.SocketDoor.Width, Geometry.SocketDoor.Height
		local specs: { { size: Vector3, offset: CFrame } } = {
			{ size = Vector3.new(0.35, h + 0.4, 0.35), offset = CFrame.new(-w / 2 - 0.1, h / 2, -0.25) },
			{ size = Vector3.new(0.35, h + 0.4, 0.35), offset = CFrame.new(w / 2 + 0.1, h / 2, -0.25) },
			{ size = Vector3.new(w + 0.6, 0.35, 0.35), offset = CFrame.new(0, h + 0.2, -0.25) },
			{ size = Vector3.new(w + 0.6, 0.12, 2.6), offset = CFrame.new(0, 0.07, -1.5) },
		}
		for i, spec in specs do
			local part = neonPart("DoorFrame" .. i, spec.size)
			part:SetAttribute("Offset", spec.offset)
			table.insert(frameParts, part)
		end
	end
	local pulse = 0.5 + 0.5 * math.sin(os.clock() * 5)
	for i, part in frameParts do
		local offset = part:GetAttribute("Offset") :: CFrame
		part.CFrame = doorCF * offset
		part.Color = color
		part.Transparency = if i == 4 then 0.55 + 0.25 * pulse else 0.05 + 0.25 * pulse
	end
end

local function showArrows(lane: any, color: Color3)
	if arrowLane ~= lane then
		clearArrows()
		arrowLane = lane
		for _ = 1, 6 do
			local left = neonPart("ArrowL", Vector3.new(0.35, 0.12, 2))
			local right = neonPart("ArrowR", Vector3.new(0.35, 0.12, 2))
			table.insert(arrows, { left = left, right = right })
		end
	end
	local vector: Vector3 = lane.vector
	local laneCF: CFrame = lane.cf
	local length = if math.abs(laneCF.LookVector:Dot(vector)) > 0.5 then lane.size.Z else lane.size.X
	local start = laneCF.Position - vector * (length / 2) - Vector3.new(0, lane.size.Y / 2 - 0.15, 0)
	local t = os.clock()
	for i, arrow in arrows do
		local along = ((i - 1) / #arrows + (t * 0.35) % 1 / #arrows) * length
		local p = start + vector * along
		local base = CFrame.lookAt(p, p + vector)
		arrow.left.CFrame = base * CFrame.Angles(0, math.rad(35), 0) * CFrame.new(0, 0, 0.8)
		arrow.right.CFrame = base * CFrame.Angles(0, math.rad(-35), 0) * CFrame.new(0, 0, 0.8)
		local fade = math.sin(math.clamp(along / length, 0, 1) * math.pi)
		for _, part in { arrow.left, arrow.right } do
			part.Color = color
			part.Transparency = 1 - 0.85 * fade
		end
	end
end

local function updatePreview(c: Candidate?)
	if not c or c.kind ~= "deploy" or not c.socketId then
		clearPreview()
		return
	end
	local level = RunInfo.level()
	local socket = level and level.sockets[c.socketId :: string]
	if not socket then
		clearPreview()
		return
	end
	local def = RoomDefs.get(c.roomId)
	local roomColor = if def then def.glow else Theme.Colors.gold
	local color = if c.valid then roomColor else Theme.Colors.red
	showFrame(socket.doorCF, color)
	local _, zones, crates = linksFor(c.roomId, socket)
	local key = (c.socketId :: string) .. ":" .. c.roomId .. ":" .. tostring(c.valid)
	if key ~= highlightKey then
		highlightKey = key
		ZoneVisuals.highlight(zones, color)
		clearMagnetBoxes()
		local visuals = Workspace:FindFirstChild("RN_ZoneVisuals")
		for _, crateId in crates do
			local target = if visuals then visuals:FindFirstChild("Crate_" .. crateId .. "_Visual") else nil
			if target and target:IsA("BasePart") then
				local box = Instance.new("SelectionBox")
				box.Adornee = target
				box.Color3 = color
				box.LineThickness = 0.1
				box.SurfaceColor3 = color
				box.SurfaceTransparency = 0.8
				box.Parent = previewParent()
				table.insert(magnetBoxes, box)
			end
		end
	end
	if c.dir and socket.lanes[c.dir] then
		local lane = level.lanes[socket.lanes[c.dir]]
		if lane then
			showArrows(lane, color)
		end
	else
		clearArrows()
	end
end

-- Public API ------------------------------------------------------------------------------------------------

function PlacementController.selectedSlot(): number
	return selectedSlot
end

function PlacementController.candidate(): Candidate?
	return candidate
end

function PlacementController.select(slot: number)
	if slot < 0 or slot > GameConfig.Loadout.Slots then
		return
	end
	if slot ~= 0 and (not RunInfo.isParticipant() or RunInfo.myStatus() ~= "Active") then
		return
	end
	if slot == selectedSlot then
		slot = 0
	end
	selectedSlot = slot
	Net.send("SelectSlot", slot)
	WorldController.setHoldingSuitcase(slot ~= 0)
	AudioController.ui(if slot ~= 0 then "room_select" else "ui_close", 0.8)
	PlacementController.SelectionChanged:Fire(slot)
end

-- Cycle the Fan direction for the current candidate socket.
function PlacementController.rotate()
	local c = candidate
	if not c or c.kind ~= "deploy" or not c.socketId or not c.dir then
		return
	end
	local level = RunInfo.level()
	local socket = level and level.sockets[c.socketId :: string]
	if not socket then
		return
	end
	local dirs = allowedDirs(socket)
	if #dirs < 2 then
		return
	end
	local index = table.find(dirs, c.dir :: string) or 0
	chosenDir[c.socketId :: string] = dirs[index % #dirs + 1]
	AudioController.ui("ui_toggle", 0.8)
end

-- Execute the candidate (InteractionController calls this when Use is pressed).
function PlacementController.execute(): boolean
	local c = candidate
	if not c then
		return false
	end
	if not c.valid then
		AudioController.ui("placement_invalid", 1)
		return false
	end
	lastActionAt = os.clock()
	if c.kind == "deploy" and c.socketId then
		Net.send("RequestDeploy", c.socketId :: string, c.slot, c.dir)
	elseif c.kind == "recall" then
		Net.send("RequestRecall", c.slot)
	end
	-- Put the suitcase away after using it; the room itself is the feedback.
	selectedSlot = 0
	Net.send("SelectSlot", 0)
	WorldController.setHoldingSuitcase(false)
	PlacementController.SelectionChanged:Fire(0)
	return true
end

function PlacementController.start()
	InputController.on("Slot1", function(state)
		if state == "Begin" then
			PlacementController.select(1)
		end
	end)
	InputController.on("Slot2", function(state)
		if state == "Begin" then
			PlacementController.select(2)
		end
	end)
	InputController.on("Rotate", function(state)
		if state == "Begin" then
			PlacementController.rotate()
		end
	end)
	InputController.on("Cancel", function(state)
		if state == "Begin" and selectedSlot ~= 0 then
			PlacementController.select(selectedSlot)
		end
	end)
	-- Drop the selection whenever we can no longer act.
	local function reset()
		if selectedSlot ~= 0 then
			selectedSlot = 0
			WorldController.setHoldingSuitcase(false)
			PlacementController.SelectionChanged:Fire(0)
		end
		table.clear(chosenDir)
	end
	RunInfo.PhaseChanged:Connect(function(phase: string)
		if phase ~= "Explore" and phase ~= "Escape" and phase ~= "Capture" then
			reset()
		end
	end)
	RunInfo.StatusChanged:Connect(function(status: string)
		if status ~= "Active" then
			reset()
		end
	end)
	RunService.Heartbeat:Connect(function()
		local c = resolve()
		local key = if c
			then table.concat({
				c.kind,
				tostring(c.slot),
				c.socketId or "",
				c.dir or "",
				tostring(c.valid),
				c.reason,
				if c.reasonParams then tostring(c.reasonParams.who) else "",
			}, "|")
			else ""
		candidate = c
		if key ~= candidateKey then
			candidateKey = key
			PlacementController.CandidateChanged:Fire(c)
		end
		updatePreview(c)
	end)
end

return PlacementController
