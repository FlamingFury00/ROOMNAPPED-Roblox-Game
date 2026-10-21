--!strict
--[[
	PingController: chat-free coordination (U11).

	* Tap Ping (G / D-pad up / the HUD ping button) for a contextual ping where you aim: a socket door
	  becomes "Use a room here", a hazard becomes "Danger!", anything else "Here". Downed players always
	  ping "Help!".
	* Hold Ping to open a four-way wheel (move the mouse / right stick / tap) and release to choose.
	* Teammates' pings appear as labelled world markers with distance, plus an arrow at the screen edge when
	  off-screen; each kind has its own icon, colour and word.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.Config.GameConfig)
local Strings = require(Shared.Config.Strings)
local MathUtil = require(Shared.Util.MathUtil)
local Signal = require(Shared.Util.Signal)
local Net = require(Shared.Net.Net)
local ClientState = require(script.Parent.Parent.Core.ClientState)
local RunInfo = require(script.Parent.Parent.Core.RunInfo)
local Device = require(script.Parent.Parent.Core.Device)
local InputController = require(script.Parent.InputController)
local AudioController = require(script.Parent.AudioController)
local Theme = require(script.Parent.Parent.UI.Theme)
local Create = require(script.Parent.Parent.UI.Create)
local Icons = require(script.Parent.Parent.UI.Icons)
local Components = require(script.Parent.Parent.UI.Components)
local UIRoot = require(script.Parent.Parent.UI.UIRoot)
local Responsive = require(script.Parent.Parent.UI.Responsive)

local PingController = {}
PingController.priority = 70

PingController.WheelChanged = Signal.new() -- (open: boolean)

local C = Theme.Colors
local localPlayer = Players.LocalPlayer

local KIND_STYLE: { [string]: { color: Color3, icon: string, key: string } } = {
	help = { color = C.red, icon = "alert", key = "ping.help" },
	here = { color = C.blue, icon = "pin", key = "ping.here" },
	room = { color = C.purple, icon = "door", key = "ping.room" },
	danger = { color = C.orange, icon = "flame", key = "ping.danger" },
}
local WHEEL_ORDER = { "here", "room", "danger", "help" } -- up, right, down, left
local HOLD_FOR_WHEEL = 0.32

type Marker = {
	gui: BillboardGui,
	anchor: Attachment,
	distance: TextLabel,
	arrow: Frame,
	expires: number,
	position: Vector3,
	kind: string,
}

local markers: { Marker } = {}
local pressStarted: number? = nil
local wheelOpen = false
local wheelChoice: string? = nil
local wheelFrame: Frame? = nil
local wheelSlices: { [string]: Frame } = {}
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

-- Aiming ----------------------------------------------------------------------------------------------------

local function aimRay(): (Vector3, Vector3)
	local camera = Workspace.CurrentCamera :: Camera
	local screenPoint: Vector2
	if Device.isKeyboard() then
		screenPoint = UserInputService:GetMouseLocation()
	else
		screenPoint = camera.ViewportSize / 2
	end
	local ray = camera:ViewportPointToRay(screenPoint.X, screenPoint.Y)
	return ray.Origin, ray.Direction
end

local function aimPoint(): (Vector3?, BasePart?)
	local origin, direction = aimRay()
	local ignore: { Instance } = {}
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(ignore, player.Character)
		end
	end
	local preview = Workspace:FindFirstChild("RN_PlacementPreview")
	if preview then
		table.insert(ignore, preview)
	end
	rayParams.FilterDescendantsInstances = ignore
	local result = Workspace:Raycast(origin, direction * GameConfig.Pings.MaxDistance, rayParams)
	if result then
		return result.Position, result.Instance :: BasePart
	end
	return nil, nil
end

local function contextualKind(point: Vector3): (string, string?)
	if localPlayer:GetAttribute("Downed") == true then
		return "help", nil
	end
	local level = RunInfo.level()
	if level then
		for socketId, socket in level.sockets do
			if
				(socket.interactPoint - point).Magnitude < 7
				or ((socket.doorCF :: CFrame).Position - point).Magnitude < 6
			then
				return "room", socketId
			end
		end
		local zones = ClientState.get("global", "zones") or {}
		for id, fire in level.fires or {} do
			local zone = zones[id]
			if
				type(zone) == "table"
				and zone.phase ~= "Out"
				and MathUtil.pointInBox(fire.volume.cf, fire.volume.size, point, 3)
			then
				return "danger", nil
			end
		end
		for _, cart in level.carts or {} do
			if MathUtil.pointInBox(cart.tileCF, Vector3.new(16, 10, 12), point, 1) then
				return "danger", nil
			end
		end
		for id, basin in level.basins or {} do
			local zone = zones[id]
			if
				type(zone) == "table"
				and zone.electrified
				and MathUtil.pointInBox(basin.surface.cf, basin.surface.size + Vector3.new(0, 6, 0), point, 1)
			then
				return "danger", nil
			end
		end
	end
	return "here", nil
end

local function sendPing(kind: string, point: Vector3?, target: string?)
	if not RunInfo.isParticipant() or not RunInfo.isActivePhase() then
		return
	end
	local position = point
	if not position then
		local character = localPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			position = root.CFrame.Position
		end
	end
	if not position then
		return
	end
	Net.send("Ping", kind, position, target)
end

function PingController.quickPing()
	local point = aimPoint()
	if localPlayer:GetAttribute("Downed") == true then
		sendPing("help", nil, nil)
		return
	end
	if not point then
		return
	end
	local kind, target = contextualKind(point :: Vector3)
	sendPing(kind, point, target)
end

function PingController.pingKind(kind: string)
	local point = aimPoint()
	local target: string? = nil
	if point then
		local _, socketId = contextualKind(point :: Vector3)
		target = socketId
	end
	sendPing(kind, if kind == "help" then nil else point, if kind == "room" then target else nil)
end

-- Wheel -------------------------------------------------------------------------------------------------------

local function buildWheel()
	if wheelFrame then
		return
	end
	local frame = Create.new("Frame", {
		Name = "PingWheel",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(300, 300),
		BackgroundTransparency = 1,
		Visible = false,
		Parent = UIRoot.Overlay,
	})
	local offsets = {
		here = UDim2.fromScale(0.5, 0.14),
		room = UDim2.fromScale(0.86, 0.5),
		danger = UDim2.fromScale(0.5, 0.86),
		help = UDim2.fromScale(0.14, 0.5),
	}
	for _, kind in WHEEL_ORDER do
		local style = KIND_STYLE[kind]
		local slice = Create.new("TextButton", {
			Name = kind,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = offsets[kind],
			Size = UDim2.fromOffset(104, 104),
			BackgroundColor3 = C.panelDark,
			BackgroundTransparency = 0.1,
			Text = "",
			AutoButtonColor = false,
			Parent = frame,
		}, {
			Create.corner(Theme.Radius.pill),
			Create.stroke(style.color, 3, 0),
		})
		local iconHolder = Create.new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 14),
			Size = UDim2.fromOffset(42, 42),
			BackgroundTransparency = 1,
			Parent = slice,
		})
		Icons.make(style.icon, style.color, C.ink).Parent = iconHolder
		Components.label({
			text = Strings.t(style.key),
			font = Theme.Fonts.heading,
			textSize = 17,
			align = Enum.TextXAlignment.Center,
			size = UDim2.new(1, -8, 0, 30),
			position = UDim2.new(0, 4, 1, -38),
			stroke = true,
			wrap = true,
			parent = slice,
		})
		slice.Activated:Connect(function()
			-- A clicked slice ends this press: the wheel must not reopen (or ping again) while Ping is held.
			pressStarted = nil
			PingController.pingKind(kind)
			PingController.closeWheel(false)
		end)
		wheelSlices[kind] = slice
	end
	wheelFrame = frame
end

function PingController.openWheel()
	buildWheel()
	wheelOpen = true
	wheelChoice = nil
	local frame = wheelFrame :: Frame
	frame.Visible = true
	AudioController.ui("ui_open", 0.6)
	PingController.WheelChanged:Fire(true)
end

function PingController.isWheelOpen(): boolean
	return wheelOpen
end

function PingController.closeWheel(send: boolean)
	if not wheelOpen then
		return
	end
	wheelOpen = false
	if wheelFrame then
		(wheelFrame :: Frame).Visible = false
	end
	if send and wheelChoice then
		PingController.pingKind(wheelChoice :: string)
	end
	wheelChoice = nil
	PingController.WheelChanged:Fire(false)
end

local function updateWheelChoice()
	if not wheelOpen then
		return
	end
	local camera = Workspace.CurrentCamera :: Camera
	local direction = Vector2.zero
	if Device.isGamepad() then
		local state = UserInputService:GetGamepadState(Enum.UserInputType.Gamepad1)
		for _, input in state do
			if input.KeyCode == Enum.KeyCode.Thumbstick2 then
				direction = Vector2.new(input.Position.X, -input.Position.Y)
			end
		end
	else
		direction = UserInputService:GetMouseLocation() - camera.ViewportSize / 2
		direction /= 60
	end
	local choice: string? = nil
	if direction.Magnitude > 0.5 then
		if math.abs(direction.X) > math.abs(direction.Y) then
			choice = if direction.X > 0 then "room" else "help"
		else
			choice = if direction.Y < 0 then "here" else "danger"
		end
	end
	wheelChoice = choice
	for kind, slice in wheelSlices do
		slice.BackgroundColor3 = if kind == choice then KIND_STYLE[kind].color:Lerp(C.panelDark, 0.4) else C.panelDark
	end
end

-- Markers -----------------------------------------------------------------------------------------------------

local function removeMarker(marker: Marker)
	local index = table.find(markers, marker)
	if index then
		table.remove(markers, index)
	end
	marker.gui:Destroy()
	marker.anchor:Destroy()
	marker.arrow:Destroy()
end

local function addMarker(info: any)
	if type(info) ~= "table" or typeof(info.position) ~= "Vector3" or type(info.kind) ~= "string" then
		return
	end
	local style = KIND_STYLE[info.kind] or KIND_STYLE.here
	-- One marker per player: a new ping replaces the old one; a clear just removes it.
	for _, marker in table.clone(markers) do
		if marker.gui:GetAttribute("From") == info.from then
			removeMarker(marker)
		end
	end
	if info.clear == true then
		return
	end
	local anchor = Instance.new("Attachment")
	anchor.WorldPosition = info.position
	anchor.Parent = Workspace.Terrain
	local gui = Create.new("BillboardGui", {
		Name = "RN_Ping",
		Size = UDim2.fromOffset(170, 96),
		StudsOffsetWorldSpace = Vector3.new(0, 2.5, 0),
		AlwaysOnTop = true,
		LightInfluence = 0,
		Adornee = anchor,
		Parent = localPlayer:WaitForChild("PlayerGui"),
	})
	gui:SetAttribute("From", info.from)
	local bubble = Create.new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.fromOffset(46, 46),
		BackgroundColor3 = style.color,
		Parent = gui,
	}, { Create.corner(Theme.Radius.pill), Create.stroke(C.white, 2.5, 0) })
	local iconHolder = Create.new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.64, 0.64),
		BackgroundTransparency = 1,
		Parent = bubble,
	})
	Icons.make(style.icon, C.white, style.color).Parent = iconHolder
	Components.label({
		text = string.format("%s · %s", Strings.t(style.key), tostring(info.name or "")),
		font = Theme.Fonts.heading,
		textSize = 16,
		color = C.text,
		align = Enum.TextXAlignment.Center,
		size = UDim2.new(1, 0, 0, 22),
		position = UDim2.fromOffset(0, 50),
		stroke = true,
		parent = gui,
	})
	local distance = Components.label({
		text = "",
		font = Theme.Fonts.bodyBold,
		textSize = 14,
		color = C.textDim,
		align = Enum.TextXAlignment.Center,
		size = UDim2.new(1, 0, 0, 18),
		position = UDim2.fromOffset(0, 72),
		stroke = true,
		parent = gui,
	})
	-- Off-screen arrow on the HUD.
	local arrow = Create.new("Frame", {
		Name = "PingArrow",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(40, 40),
		BackgroundColor3 = style.color,
		Visible = false,
		Parent = UIRoot.Hud,
	}, { Create.corner(Theme.Radius.pill), Create.stroke(C.white, 2, 0) })
	local arrowIcon = Create.new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.6, 0.6),
		BackgroundTransparency = 1,
		Parent = arrow,
	})
	Icons.make(style.icon, C.white, style.color).Parent = arrowIcon
	local marker: Marker = {
		gui = gui,
		anchor = anchor,
		distance = distance,
		arrow = arrow,
		expires = if type(info.expires) == "number" then info.expires else Workspace:GetServerTimeNow() + 6,
		position = info.position,
		kind = info.kind,
	}
	table.insert(markers, marker)
	AudioController.ui("ui_notify", 0.7)
end

local function updateMarkers()
	local now = Workspace:GetServerTimeNow()
	local camera = Workspace.CurrentCamera :: Camera
	local character = localPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local origin = if root and root:IsA("BasePart") then root.CFrame.Position else camera.CFrame.Position
	for _, marker in table.clone(markers) do
		if now >= marker.expires then
			removeMarker(marker)
			continue
		end
		marker.distance.Text = string.format("%dm", math.floor((marker.position - origin).Magnitude / 3 + 0.5))
		local screen, onScreen = camera:WorldToViewportPoint(marker.position)
		if onScreen then
			marker.arrow.Visible = false
		else
			-- Project to the screen edge (flip when behind the camera).
			local viewport = camera.ViewportSize
			local centre = viewport / 2
			local direction = Vector2.new(screen.X, screen.Y) - centre
			if screen.Z < 0 then
				direction = -direction
			end
			if direction.Magnitude < 1 then
				direction = Vector2.new(0, -1)
			end
			direction = direction.Unit
			local margin = 46
			local scaleX = (viewport.X / 2 - margin) / math.max(1e-3, math.abs(direction.X))
			local scaleY = (viewport.Y / 2 - margin) / math.max(1e-3, math.abs(direction.Y))
			local edge = centre + direction * math.min(scaleX, scaleY)
			-- Convert viewport pixels to the HUD's virtual canvas.
			local p = Responsive.toCanvas(UIRoot.Guis.Hud, edge)
			if p.X == p.X and p.Y == p.Y and math.abs(p.X) < 1e5 and math.abs(p.Y) < 1e5 then
				marker.arrow.Position = UDim2.fromOffset(math.round(p.X), math.round(p.Y))
				marker.arrow.Visible = true
			end
		end
	end
end

function PingController.start()
	InputController.on("Ping", function(state)
		if state == "Begin" then
			pressStarted = os.clock()
		else
			if wheelOpen then
				PingController.closeWheel(true)
			elseif pressStarted then
				PingController.quickPing()
			end
			pressStarted = nil
		end
	end)
	Net.listen("PingMarker", addMarker)
	RunService.RenderStepped:Connect(function()
		if pressStarted and not wheelOpen and os.clock() - (pressStarted :: number) >= HOLD_FOR_WHEEL then
			PingController.openWheel()
		end
		updateWheelChoice()
		if #markers > 0 then
			updateMarkers()
		end
	end)
	RunInfo.PhaseChanged:Connect(function()
		for _, marker in table.clone(markers) do
			removeMarker(marker)
		end
		PingController.closeWheel(false)
	end)
end

return PingController
