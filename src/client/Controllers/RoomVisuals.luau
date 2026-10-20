--!strict
--[[
	RoomVisuals: rooms unfolding out of suitcases, folding back, and living while deployed (A02, A04, U08).

	* Unfold: the replicated room model starts tiny at its doorway and springs to full size (Model:ScaleTo
	  around the doorway pivot) with a poof, a ring in the room colour and the unfold sound.
	* Fold: the reverse, timed to finish before the server removes the room.
	* Capture: the target room swirls and shrinks into the doorway while the cinematic plays.
	* While deployed: Fans spin and roar, Freezers spill cold mist into the hall, Laundries churn and bubble,
	  Greenhouses shed leaves and Magnets hum with field lines to the crates they pull.

	The real collision always comes from the server's full-size model; the animation is purely visual and
	short (under a second), and late joiners simply see the finished room.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.Config.GameConfig)
local RoomDefs = require(Shared.Config.RoomDefs)
local Net = require(Shared.Net.Net)
local Trove = require(Shared.Util.Trove)
local ClientState = require(script.Parent.Parent.Core.ClientState)
local RunInfo = require(script.Parent.Parent.Core.RunInfo)
local AudioController = require(script.Parent.AudioController)
local CameraController = require(script.Parent.CameraController)
local Vfx = require(script.Parent.Parent.Visual.Vfx)
local Motion = require(script.Parent.Parent.UI.Motion)

local RoomVisuals = {}
RoomVisuals.priority = 40

type LoopHandle = AudioController.LoopHandle

type RoomRecord = {
	model: Model,
	socketId: string,
	roomId: string,
	trove: any, -- Trove (kept as any: the solver mis-compares its generic methods across record copies)
	spinner: Model?,
	spinnerBase: CFrame?,
	spinAxis: Vector3?,
	spin: number,
	spinSpeed: number,
	clothes: { { part: BasePart, base: CFrame } },
	loops: { LoopHandle },
	beams: { Beam },
	folding: boolean,
	scaling: boolean,
	scaleToken: number,
}

local rooms: { [Model]: RoomRecord } = {}
local runTrove: Trove.Trove? = nil

-- Scaling ----------------------------------------------------------------------------------------------

-- Animate a model's scale around a world pivot. Yields until finished (or superseded).
local function scaleAround(
	record: RoomRecord,
	pivot: CFrame,
	from: number,
	to: number,
	seconds: number,
	style: Enum.EasingStyle
)
	local model = record.model
	local primary = model.PrimaryPart
	if not primary then
		return
	end
	record.scaleToken += 1
	local token = record.scaleToken
	record.scaling = true
	local originalOffset = primary.PivotOffset
	primary.PivotOffset = primary.CFrame:ToObjectSpace(pivot)
	local function setScale(s: number)
		if model.Parent then
			pcall(function()
				model:ScaleTo(math.max(0.02, s))
			end)
		end
	end
	if Motion.isReduced() then
		setScale(to)
		primary.PivotOffset = originalOffset
		record.scaling = false
		return
	end
	setScale(from)
	local started = os.clock()
	while model.Parent and token == record.scaleToken do
		local t = math.clamp((os.clock() - started) / seconds, 0, 1)
		local eased = TweenService:GetValue(t, style, Enum.EasingDirection.Out)
		setScale(from + (to - from) * eased)
		if t >= 1 then
			break
		end
		RunService.RenderStepped:Wait()
	end
	if model.Parent and token == record.scaleToken then
		primary.PivotOffset = originalOffset
		record.scaling = false
	end
end

local function doorPivot(record: RoomRecord): CFrame?
	local level = RunInfo.level()
	local socket = level and level.sockets and level.sockets[record.socketId]
	if socket then
		return socket.roomCF :: CFrame
	end
	return nil
end

-- Living rooms -------------------------------------------------------------------------------------------

local function setupLife(record: RoomRecord)
	local model = record.model
	local roomId = record.roomId
	local def = RoomDefs.get(roomId)
	local color = if def then def.glow else Color3.new(1, 1, 1)
	local outlet = model:FindFirstChild("Outlet")
	local outletPart: BasePart? = if outlet and outlet:IsA("BasePart") then outlet else nil
	local level = RunInfo.level()
	local socket = level and level.sockets and level.sockets[record.socketId]

	if roomId == "Fan" then
		local spinner = model:FindFirstChild("Spinner")
		if spinner and spinner:IsA("Model") then
			record.spinner = spinner
			record.spinnerBase = spinner:GetPivot()
			record.spinAxis = if socket then (socket.roomCF :: CFrame).LookVector else spinner:GetPivot().LookVector
		end
		record.spinSpeed = 0
		local loop =
			AudioController.loop("fan_motor_loop", { parent = outletPart or model.PrimaryPart, rolloffMax = 80 })
		if loop then
			table.insert(record.loops, loop)
		end
		local wind = AudioController.loop("wind_loop", { parent = outletPart or model.PrimaryPart, rolloffMax = 110 })
		if wind then
			table.insert(record.loops, wind)
		end
	elseif roomId == "Freezer" then
		if outletPart and socket then
			-- Cold air spilling out of the doorway and rolling along the floor.
			local door: CFrame = socket.doorCF
			local mistPart = Instance.new("Part")
			mistPart.Name = "ColdSpill"
			mistPart.Anchored = true
			mistPart.CanCollide = false
			mistPart.CanQuery = false
			mistPart.CanTouch = false
			mistPart.Transparency = 1
			mistPart.Size = Vector3.new(7, 2, 0.5)
			mistPart.CFrame = door * CFrame.new(0, 1.2, -0.3)
			mistPart.Parent = model
			Vfx.emitter(mistPart, "mist", {
				EmissionDirection = Enum.NormalId.Front,
				Speed = NumberRange.new(3, 6),
				Acceleration = Vector3.new(0, -1, 0),
				Rate = 10,
			})
			Vfx.emitter(mistPart, "frost", { EmissionDirection = Enum.NormalId.Front, Rate = 6 })
		end
	elseif roomId == "Laundry" then
		for _, d in model:GetDescendants() do
			if d:IsA("BasePart") and d.Name == "Clothes" then
				table.insert(record.clothes, { part = d, base = d.CFrame })
			end
		end
		if outletPart then
			local a = Instance.new("Attachment")
			a.Parent = outletPart
			Vfx.emitter(
				a,
				"splash",
				{ Rate = 6, Speed = NumberRange.new(6, 10), EmissionDirection = Enum.NormalId.Front }
			)
		end
		local loop = AudioController.loop("water_loop", { parent = outletPart or model.PrimaryPart, rolloffMax = 70 })
		if loop then
			table.insert(record.loops, loop)
		end
	elseif roomId == "Greenhouse" then
		if outletPart then
			Vfx.emitter(outletPart, "leaves", { Rate = 4, EmissionDirection = Enum.NormalId.Front })
		end
	elseif roomId == "Magnet" then
		local loop = AudioController.loop("magnet_hum", { parent = outletPart or model.PrimaryPart, rolloffMax = 80 })
		if loop then
			table.insert(record.loops, loop)
		end
		-- Field lines from the magnet tips to every linked crate.
		local links = socket and socket.links and socket.links.magnet
		local tips = {}
		for _, d in model:GetDescendants() do
			if d:IsA("BasePart") and d.Name == "MagnetTip" then
				table.insert(tips, d)
			end
		end
		local levelModel = RunInfo.levelModel()
		if type(links) == "table" and levelModel and #tips > 0 then
			for i, crateId in links do
				local crate = levelModel:FindFirstChild("Crate_" .. crateId, true)
				local visual = Workspace:FindFirstChild("RN_ZoneVisuals")
				local target = if visual then visual:FindFirstChild("Crate_" .. crateId .. "_Visual") else nil
				local targetPart = target or crate
				if targetPart and targetPart:IsA("BasePart") then
					local a0 = Instance.new("Attachment")
					a0.Parent = tips[(i - 1) % #tips + 1]
					local a1 = Instance.new("Attachment")
					a1.Parent = targetPart
					record.trove:Add(a1)
					local beam = Instance.new("Beam")
					beam.Attachment0 = a0
					beam.Attachment1 = a1
					beam.Texture = Vfx.Textures.vortex
					beam.TextureMode = Enum.TextureMode.Wrap
					beam.TextureLength = 4
					beam.TextureSpeed = 2.5
					beam.LightEmission = 1
					beam.LightInfluence = 0
					beam.Color = ColorSequence.new(color)
					beam.Transparency = NumberSequence.new(0.35)
					beam.Width0 = 1.2
					beam.Width1 = 0.6
					beam.CurveSize0 = 3
					beam.CurveSize1 = -2
					beam.FaceCamera = true
					beam.Parent = a0
					table.insert(record.beams, beam)
				end
			end
		end
	end
end

local function stepLife(record: RoomRecord, dt: number)
	-- Never fight the unfold / fold scaling: animated parts hold still until it finishes.
	if record.scaling then
		return
	end
	if record.spinner and record.spinnerBase and record.spinAxis then
		local target = if record.folding then 0 else 16
		record.spinSpeed += (target - record.spinSpeed) * math.min(1, dt * 1.6)
		record.spin = (record.spin + record.spinSpeed * dt) % (math.pi * 2)
		local base = record.spinnerBase :: CFrame
		local rotation = CFrame.fromAxisAngle(record.spinAxis :: Vector3, record.spin)
		local spinner = record.spinner :: Model
		if spinner.Parent then
			spinner:PivotTo(CFrame.new(base.Position) * rotation * base.Rotation)
		end
	end
	if #record.clothes > 0 then
		local t = os.clock()
		for i, item in record.clothes do
			if item.part.Parent then
				local angle = t * 5 + i
				item.part.CFrame = item.base
					* CFrame.new(math.cos(angle) * 0.35, math.sin(angle) * 0.35, 0)
					* CFrame.Angles(0, 0, angle)
			end
		end
	end
end

-- Lifecycle --------------------------------------------------------------------------------------------

local function release(record: RoomRecord)
	for _, loop in record.loops do
		loop.stop(0.3)
	end
	table.clear(record.loops)
	for _, beam in record.beams do
		beam:Destroy()
	end
	table.clear(record.beams)
	record.trove:Destroy()
end

local function onRoomAdded(model: Instance)
	if not model:IsA("Model") or rooms[model] then
		return
	end
	local socketId = model:GetAttribute("SocketId")
	local roomId = model:GetAttribute("RoomId")
	if type(socketId) ~= "string" or type(roomId) ~= "string" then
		return
	end
	-- Wait for the model's parts to replicate.
	local deadline = os.clock() + 3
	while not model.PrimaryPart and os.clock() < deadline and model.Parent do
		task.wait()
	end
	if not model.Parent then
		return
	end
	local record: RoomRecord = {
		model = model,
		socketId = socketId,
		roomId = roomId,
		trove = Trove.new(),
		spinner = nil,
		spinnerBase = nil,
		spinAxis = nil,
		spin = 0,
		spinSpeed = 0,
		clothes = {},
		loops = {},
		beams = {},
		folding = false,
		scaling = false,
		scaleToken = 0,
	}
	rooms[model] = record
	record.trove:Connect(model.AncestryChanged, function()
		if not model:IsDescendantOf(Workspace) then
			rooms[model] = nil
			release(record)
		end
	end)
	-- Capture animated parts at full scale before any unfold scaling starts.
	setupLife(record)
	-- Unfold animation only when we saw the deploy happen (not on late join).
	local info = ClientState.get("global", "sockets." .. socketId)
	local since = if type(info) == "table" and type(info.since) == "number" then info.since else 0
	local fresh = Workspace:GetServerTimeNow() - since < GameConfig.Deploy.UnfoldSeconds
	local pivot = doorPivot(record)
	if fresh and pivot then
		local def = RoomDefs.get(roomId)
		local color = if def then def.glow else Color3.new(1, 1, 1)
		local doorPoint = (pivot :: CFrame) * Vector3.new(0, 4, 0.5)
		AudioController.at("room_unfold", doorPoint, { volume = 1 })
		Vfx.burst(doorPoint, "poof", 18)
		Vfx.burst(doorPoint, "magic", 16, { Color = ColorSequence.new(color) })
		Vfx.ring((pivot :: CFrame).Position + Vector3.new(0, 0.2, 0), color, 9, 0.5)
		Vfx.flash(doorPoint, color, 4, 26, 0.4)
		local character = game:GetService("Players").LocalPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") and (root.Position - doorPoint).Magnitude < 30 then
			CameraController.shake(0.35, 0.3)
		end
		task.spawn(function()
			scaleAround(record, pivot :: CFrame, 0.04, 1, GameConfig.Deploy.UnfoldSeconds, Enum.EasingStyle.Back)
		end)
	end
end

local function onFold(socketId: string)
	for model, record in rooms do
		if record.socketId == socketId and not record.folding then
			record.folding = true
			local pivot = doorPivot(record)
			if pivot then
				local def = RoomDefs.get(record.roomId)
				local color = if def then def.glow else Color3.new(1, 1, 1)
				local doorPoint = (pivot :: CFrame) * Vector3.new(0, 4, 0.5)
				AudioController.at("room_fold", doorPoint, { volume = 1 })
				Vfx.burst(doorPoint, "poof", 14)
				Vfx.ring((pivot :: CFrame).Position + Vector3.new(0, 0.2, 0), color, 6, 0.4)
				task.spawn(function()
					scaleAround(
						record,
						pivot :: CFrame,
						1,
						0.04,
						GameConfig.Deploy.FoldSeconds * 0.85,
						Enum.EasingStyle.Quad
					)
				end)
			end
			for _, beam in record.beams do
				beam.Enabled = false
			end
			local _ = model
		end
	end
end

-- Target room capture: swirl and shrink into the doorway.
local function onCapture(position: Vector3?)
	local levelModel = RunInfo.levelModel()
	local target = levelModel and levelModel:FindFirstChild("TargetRoom")
	if not target or not target:IsA("Model") then
		return
	end
	local level = RunInfo.level()
	local pivot: CFrame? = if level and level.target then level.target.roomCF else nil
	local record: RoomRecord = {
		model = target,
		socketId = "target",
		roomId = (target:GetAttribute("RoomId") :: string?) or "",
		trove = Trove.new(),
		spinner = nil,
		spinnerBase = nil,
		spinAxis = nil,
		spin = 0,
		spinSpeed = 0,
		clothes = {},
		loops = {},
		beams = {},
		folding = true,
		scaling = false,
		scaleToken = 0,
	}
	local centre = position or target:GetPivot().Position
	AudioController.at("capture_success", centre, { volume = 1 })
	AudioController.at("room_fold", centre, { volume = 1, pitch = 0.8 })
	local swirl = Instance.new("Part")
	swirl.Anchored = true
	swirl.CanCollide = false
	swirl.CanQuery = false
	swirl.CanTouch = false
	swirl.Transparency = 1
	swirl.Size = Vector3.new(8, 10, 1)
	swirl.CFrame = if pivot then (pivot :: CFrame) * CFrame.new(0, 5, -1) else CFrame.new(centre)
	swirl.Parent = Workspace
	Vfx.emitter(swirl, "magic", { Rate = 60, Speed = NumberRange.new(2, 6) })
	local vortex = Vfx.emitter(swirl, "zap", {
		Texture = Vfx.Textures.vortex,
		Rate = 10,
		Size = Vfx.seq(4, 9),
		Lifetime = NumberRange.new(0.4, 0.7),
		Color = ColorSequence.new(Color3.fromRGB(255, 220, 120)),
	})
	local _ = vortex
	task.delay(GameConfig.Capture.FoldCinematicSeconds, function()
		swirl:Destroy()
	end)
	if pivot then
		task.spawn(function()
			scaleAround(
				record,
				pivot :: CFrame,
				1,
				0.04,
				GameConfig.Capture.FoldCinematicSeconds * 0.72,
				Enum.EasingStyle.Quint
			)
		end)
	end
	Vfx.burst(centre, "confetti", 60)
	Vfx.flash(centre, Color3.fromRGB(255, 230, 150), 6, 40, 0.8)
	CameraController.shake(0.5, 0.6)
end

local function attachRun()
	if runTrove then
		runTrove:Destroy()
		runTrove = nil
	end
	for model, record in rooms do
		rooms[model] = nil
		release(record)
	end
	local levelModel = RunInfo.waitForLevelModel(15)
	if not levelModel then
		return
	end
	local trove = Trove.new()
	runTrove = trove
	local function watchRooms(folder: Instance)
		for _, child in folder:GetChildren() do
			task.spawn(onRoomAdded, child)
		end
		trove:Connect(folder.ChildAdded, function(child: Instance)
			task.spawn(onRoomAdded, child)
		end)
	end
	local existing = levelModel:FindFirstChild("Rooms")
	if existing then
		watchRooms(existing)
	else
		trove:Connect(levelModel.ChildAdded, function(child: Instance)
			if child.Name == "Rooms" then
				watchRooms(child)
			end
		end)
	end
end

function RoomVisuals.start()
	RunInfo.LevelChanged:Connect(function(level: any)
		if level then
			task.spawn(attachRun)
		else
			if runTrove then
				runTrove:Destroy()
				runTrove = nil
			end
		end
	end)
	if RunInfo.level() then
		task.spawn(attachRun)
	end
	Net.listen("Effect", function(name: any, params: any)
		if type(params) ~= "table" then
			return
		end
		if name == "roomFold" and type(params.socket) == "string" then
			onFold(params.socket)
		elseif name == "capture" then
			onCapture(if typeof(params.position) == "Vector3" then params.position else nil)
		end
	end)
	-- Fold state can also arrive through replication before (or without) the Effect event.
	ClientState.observe("global", "sockets", function(sockets: any)
		if type(sockets) ~= "table" then
			return
		end
		for socketId, info in sockets do
			if type(info) == "table" and info.state == "Folding" then
				onFold(socketId)
			end
		end
	end)
	RunService.Heartbeat:Connect(function(dt: number)
		for _, record in rooms do
			stepLife(record, dt)
		end
	end)
end

return RoomVisuals
