--!strict
--[[
	CaretakerView: the hotel's Caretaker as every client sees it (S15, A03, A06, U08).

	The server simulates the Caretaker as a data entity and streams (serverTime, position, yaw, mode) at
	15 Hz over an unreliable remote. This view interpolates those snapshots ~0.12 s in the past (with short
	extrapolation for gaps), and animates a lanky, non-graphic bellhop built from parts:

	  Patrol      slow stride, warm lantern, idle key jingle
	  Investigate head tilts, a "?" pops above the hat
	  Search      scanning head, floor creaks, "?" stays
	  Chase/Hunt  fast stride, red eyes and lantern, louder steps and hum, "!" when it spots someone
	  Lunge       wind-up crouch, arms out
	  React       blown back / stunned: wobble and circling stars
	  Dormant     slumped asleep with floating Zs (tutorial)
	  Phase       fades into the walls and reappears in a puff
	  Alert       flash and scream when the room is stolen
	Cold (chilled) adds frost and a blue tint; bracing against wind leans it into the gust.

	Every state has a shape/motion/text cue as well as colour and sound, so it reads without dialogue.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.Config.GameConfig)
local Geometry = require(Shared.World.Geometry)
local MathUtil = require(Shared.Util.MathUtil)
local Net = require(Shared.Net.Net)
local ClientState = require(script.Parent.Parent.Core.ClientState)
local RunInfo = require(script.Parent.Parent.Core.RunInfo)
local AudioController = require(script.Parent.AudioController)
local CameraController = require(script.Parent.CameraController)
local Vfx = require(script.Parent.Parent.Visual.Vfx)
local Theme = require(script.Parent.Parent.UI.Theme)

local CaretakerView = {}
CaretakerView.priority = 45

local MODE_NAMES: { [number]: string } = {
	[0] = "Off",
	[1] = "Dormant",
	[2] = "Patrol",
	[3] = "Investigate",
	[4] = "Chase",
	[5] = "Search",
	[6] = "Alert",
	[7] = "Hunt",
	[8] = "Lunge",
	[9] = "React",
	[10] = "Phase",
}

local INTERP_DELAY = 0.12
local MAX_EXTRAPOLATE = 0.25
local HOVER = Geometry.Caretaker.HoverY

type Snapshot = { t: number, position: Vector3, yaw: number, mode: string }

type PartSpec = { part: BasePart, offset: CFrame }

type Rig = {
	model: Model,
	parts: { BasePart },
	-- named pieces for animation
	legL: BasePart,
	legR: BasePart,
	shoeL: BasePart,
	shoeR: BasePart,
	armL: BasePart,
	armR: BasePart,
	torso: BasePart,
	coatTail: BasePart,
	head: BasePart,
	hat: BasePart,
	brim: BasePart,
	eyeL: BasePart,
	eyeR: BasePart,
	lantern: BasePart,
	lanternFrame: BasePart,
	keyRing: BasePart,
	extras: { PartSpec }, -- parts rigidly attached to the torso / head / arms
	headExtras: { PartSpec },
	armRExtras: { PartSpec },
	armLExtras: { PartSpec },
	lanternLight: PointLight,
	eyeLight: PointLight,
	highlight: Highlight,
	frost: ParticleEmitter,
	sleepy: ParticleEmitter,
	badge: BillboardGui,
	badgeLabel: TextLabel,
	hum: AudioController.LoopHandle?,
	moveParts: { BasePart }, -- fixed order matching the animation buffer
}

local snapshots: { Snapshot } = {}
local cframeBuffer: { CFrame } = {}
local rig: Rig? = nil
local mode = "Gone"
local modeSince = 0
local stride = 0
local lastStepSign = 1
local lastPosition: Vector3? = nil
local smoothedSpeed = 0
local lastJingle = 0
local lastCreak = 0
local visibleAlpha = 1
local reactSpin = 0
local spottedUntil = 0

local COAT = Color3.fromRGB(150, 22, 36)
local GOLD = Color3.fromRGB(232, 184, 74)
local SKIN = Color3.fromRGB(196, 208, 200)
local DARK = Color3.fromRGB(28, 22, 26)

-- Rig construction -------------------------------------------------------------------------------------------

local function newPart(
	model: Model,
	name: string,
	size: Vector3,
	color: Color3,
	material: Enum.Material,
	shape: Enum.PartType?
): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = true
	part.Size = size
	part.Color = color
	part.Material = material
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	if shape then
		part.Shape = shape
	end
	part.Parent = model
	return part
end

local function buildRig(): Rig
	local model = Instance.new("Model")
	model.Name = "Caretaker"
	local parts: { BasePart } = {}
	local function add(p: Part): Part
		table.insert(parts, p)
		return p
	end
	local legL = add(newPart(model, "LegL", Vector3.new(0.6, 3.1, 0.6), DARK, Enum.Material.Fabric))
	local legR = add(newPart(model, "LegR", Vector3.new(0.6, 3.1, 0.6), DARK, Enum.Material.Fabric))
	local shoeL = add(
		newPart(model, "ShoeL", Vector3.new(0.75, 0.45, 1.3), Color3.fromRGB(16, 12, 14), Enum.Material.SmoothPlastic)
	)
	local shoeR = add(
		newPart(model, "ShoeR", Vector3.new(0.75, 0.45, 1.3), Color3.fromRGB(16, 12, 14), Enum.Material.SmoothPlastic)
	)
	local coatTail = add(newPart(model, "CoatTail", Vector3.new(2.2, 1.6, 1.25), COAT, Enum.Material.Fabric))
	local torso = add(newPart(model, "Torso", Vector3.new(2.5, 2.7, 1.45), COAT, Enum.Material.Fabric))
	local head = add(
		newPart(model, "Head", Vector3.new(1.75, 1.95, 1.75), SKIN, Enum.Material.SmoothPlastic, Enum.PartType.Ball)
	)
	local hat =
		add(newPart(model, "Hat", Vector3.new(0.9, 1.35, 1.35), COAT, Enum.Material.Fabric, Enum.PartType.Cylinder))
	local brim =
		add(newPart(model, "HatBand", Vector3.new(0.22, 1.42, 1.42), GOLD, Enum.Material.Foil, Enum.PartType.Cylinder))
	local eyeL = add(
		newPart(
			model,
			"EyeL",
			Vector3.new(0.34, 0.34, 0.34),
			Color3.fromRGB(255, 240, 180),
			Enum.Material.Neon,
			Enum.PartType.Ball
		)
	)
	local eyeR = add(
		newPart(
			model,
			"EyeR",
			Vector3.new(0.34, 0.34, 0.34),
			Color3.fromRGB(255, 240, 180),
			Enum.Material.Neon,
			Enum.PartType.Ball
		)
	)
	local armL = add(newPart(model, "ArmL", Vector3.new(0.55, 2.6, 0.55), COAT, Enum.Material.Fabric))
	local armR = add(newPart(model, "ArmR", Vector3.new(0.55, 2.6, 0.55), COAT, Enum.Material.Fabric))
	local lanternFrame =
		add(newPart(model, "LanternFrame", Vector3.new(0.75, 1, 0.75), Color3.fromRGB(60, 50, 40), Enum.Material.Metal))
	local lantern = add(
		newPart(
			model,
			"Lantern",
			Vector3.new(0.55, 0.55, 0.55),
			Color3.fromRGB(255, 200, 110),
			Enum.Material.Neon,
			Enum.PartType.Ball
		)
	)
	local keyRing =
		add(newPart(model, "KeyRing", Vector3.new(0.12, 0.8, 0.8), GOLD, Enum.Material.Foil, Enum.PartType.Cylinder))
	eyeL.CastShadow = false
	eyeR.CastShadow = false
	lantern.CastShadow = false

	local extras: { PartSpec } = {}
	local headExtras: { PartSpec } = {}
	local armRExtras: { PartSpec } = {}
	local armLExtras: { PartSpec } = {}
	local function extra(
		list: { PartSpec },
		name: string,
		size: Vector3,
		offset: CFrame,
		color: Color3,
		material: Enum.Material,
		shape: Enum.PartType?
	)
		local p: BasePart = add(newPart(model, name, size, color, material, shape))
		p.CastShadow = false
		table.insert(list, { part = p, offset = offset })
	end
	-- Torso details: shirt front, bow tie, buttons, collar, epaulettes.
	extra(
		extras,
		"Shirt",
		Vector3.new(0.8, 2.0, 0.08),
		CFrame.new(0, 0.2, -0.74),
		Color3.fromRGB(240, 236, 226),
		Enum.Material.SmoothPlastic
	)
	extra(extras, "BowTie", Vector3.new(0.9, 0.32, 0.12), CFrame.new(0, 1.1, -0.8), DARK, Enum.Material.SmoothPlastic)
	for i = 0, 2 do
		extra(
			extras,
			"Button",
			Vector3.new(0.2, 0.2, 0.2),
			CFrame.new(-0.62, 0.6 - i * 0.62, -0.74),
			GOLD,
			Enum.Material.Foil,
			Enum.PartType.Ball
		)
		extra(
			extras,
			"Button",
			Vector3.new(0.2, 0.2, 0.2),
			CFrame.new(0.62, 0.6 - i * 0.62, -0.74),
			GOLD,
			Enum.Material.Foil,
			Enum.PartType.Ball
		)
	end
	extra(extras, "Collar", Vector3.new(2.3, 0.3, 1.5), CFrame.new(0, 1.3, 0), GOLD, Enum.Material.Foil)
	extra(extras, "EpauletteL", Vector3.new(0.7, 0.18, 0.9), CFrame.new(-1.3, 1.36, 0), GOLD, Enum.Material.Foil)
	extra(extras, "EpauletteR", Vector3.new(0.7, 0.18, 0.9), CFrame.new(1.3, 1.36, 0), GOLD, Enum.Material.Foil)
	extra(extras, "NameTag", Vector3.new(0.6, 0.25, 0.08), CFrame.new(0.75, 0.9, -0.75), GOLD, Enum.Material.Foil)
	-- Face: brow and a long droopy moustache (stylised, not scary-graphic).
	extra(
		headExtras,
		"Brow",
		Vector3.new(1.2, 0.16, 0.2),
		CFrame.new(0, 0.42, -0.78) * CFrame.Angles(0, 0, 0),
		DARK,
		Enum.Material.SmoothPlastic
	)
	extra(
		headExtras,
		"MoustacheL",
		Vector3.new(0.7, 0.18, 0.18),
		CFrame.new(-0.36, -0.28, -0.84) * CFrame.Angles(0, 0, 0.35),
		DARK,
		Enum.Material.SmoothPlastic
	)
	extra(
		headExtras,
		"MoustacheR",
		Vector3.new(0.7, 0.18, 0.18),
		CFrame.new(0.36, -0.28, -0.84) * CFrame.Angles(0, 0, -0.35),
		DARK,
		Enum.Material.SmoothPlastic
	)
	extra(
		headExtras,
		"Nose",
		Vector3.new(0.3, 0.42, 0.3),
		CFrame.new(0, -0.02, -0.88),
		SKIN:Lerp(Color3.new(1, 0.85, 0.85), 0.3),
		Enum.Material.SmoothPlastic,
		Enum.PartType.Ball
	)
	-- Keys dangling from the ring.
	for i = 0, 2 do
		extra(
			armLExtras,
			"Key",
			Vector3.new(0.12, 0.55, 0.22),
			CFrame.new(0, -1.75 - (i % 2) * 0.1, -0.15 + i * 0.15) * CFrame.Angles(0.3 * i, 0, 0.2),
			GOLD,
			Enum.Material.Foil
		)
	end
	-- Lantern handle.
	extra(
		armRExtras,
		"LanternHandle",
		Vector3.new(0.1, 0.5, 0.6),
		CFrame.new(0, -1.45, 0),
		Color3.fromRGB(60, 50, 40),
		Enum.Material.Metal
	)

	local lanternLight = Instance.new("PointLight")
	lanternLight.Color = Color3.fromRGB(255, 190, 110)
	lanternLight.Range = 16
	lanternLight.Brightness = 1.6
	lanternLight.Shadows = true
	lanternLight.Parent = lantern
	local eyeLight = Instance.new("PointLight")
	eyeLight.Color = Color3.fromRGB(255, 230, 170)
	eyeLight.Range = 5
	eyeLight.Brightness = 1
	eyeLight.Shadows = false
	eyeLight.Parent = head

	local highlight = Instance.new("Highlight")
	highlight.FillTransparency = 1
	highlight.OutlineColor = Theme.Colors.red
	highlight.OutlineTransparency = 1
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Parent = model

	local frostAttachment = Instance.new("Attachment")
	frostAttachment.Parent = torso
	local frost = Vfx.emitter(frostAttachment, "frost", { Rate = 16, Speed = NumberRange.new(1, 3) })
	frost.Enabled = false
	local sleepyAttachment = Instance.new("Attachment")
	sleepyAttachment.Position = Vector3.new(0, 1.2, 0)
	sleepyAttachment.Parent = head
	local sleepy = Vfx.emitter(sleepyAttachment, "magic", {
		Texture = Vfx.Textures.circle,
		Rate = 1.5,
		Size = Vfx.seq(0.2, 0.5),
		Speed = NumberRange.new(1, 2),
		SpreadAngle = Vector2.new(15, 15),
		EmissionDirection = Enum.NormalId.Top,
		Lifetime = NumberRange.new(1.5, 2),
		Color = ColorSequence.new(Color3.fromRGB(200, 220, 255)),
	})
	sleepy.Enabled = false

	local badge = Instance.new("BillboardGui")
	badge.Name = "ModeBadge"
	badge.Size = UDim2.fromOffset(64, 64)
	badge.StudsOffsetWorldSpace = Vector3.new(0, 2.4, 0)
	badge.AlwaysOnTop = true
	badge.LightInfluence = 0
	badge.MaxDistance = 140
	badge.Enabled = false
	badge.Adornee = hat
	badge.Parent = model
	local badgeLabel = Instance.new("TextLabel")
	badgeLabel.Size = UDim2.fromScale(1, 1)
	badgeLabel.BackgroundTransparency = 1
	badgeLabel.Text = "?"
	badgeLabel.TextScaled = true
	badgeLabel.FontFace = Theme.Fonts.display
	badgeLabel.TextColor3 = Theme.Colors.gold
	badgeLabel.Parent = badge
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 3
	stroke.Color = Theme.Colors.ink
	stroke.Parent = badgeLabel

	model.Parent = Workspace
	local built: Rig = {
		model = model,
		parts = parts,
		legL = legL,
		legR = legR,
		shoeL = shoeL,
		shoeR = shoeR,
		armL = armL,
		armR = armR,
		torso = torso,
		coatTail = coatTail,
		head = head,
		hat = hat,
		brim = brim,
		eyeL = eyeL,
		eyeR = eyeR,
		lantern = lantern,
		lanternFrame = lanternFrame,
		keyRing = keyRing,
		extras = extras,
		headExtras = headExtras,
		armRExtras = armRExtras,
		armLExtras = armLExtras,
		lanternLight = lanternLight,
		eyeLight = eyeLight,
		highlight = highlight,
		frost = frost,
		sleepy = sleepy,
		badge = badge,
		badgeLabel = badgeLabel,
		hum = nil,
		moveParts = {},
	}
	local order: { BasePart } = {
		legL,
		legR,
		shoeL,
		shoeR,
		coatTail,
		torso,
		head,
		hat,
		brim,
		eyeL,
		eyeR,
		armL,
		armR,
		lanternFrame,
		lantern,
		keyRing,
	}
	for _, list in { extras, headExtras, armRExtras, armLExtras } do
		for _, spec in list do
			table.insert(order, spec.part)
		end
	end
	built.moveParts = order
	built.hum = AudioController.loop("caretaker_hum_loop", { parent = torso, rolloffMin = 10, rolloffMax = 90 })
	return built
end

local function destroyRig()
	local r = rig
	if not r then
		return
	end
	rig = nil
	if r.hum then
		r.hum.stop(0.4)
	end
	r.model:Destroy()
end

-- Snapshot interpolation ---------------------------------------------------------------------------------------

local function onSnapshot(t: any, position: any, yaw: any, code: any)
	if type(t) ~= "number" or typeof(position) ~= "Vector3" or type(yaw) ~= "number" then
		return
	end
	local last = snapshots[#snapshots]
	if last and t <= last.t then
		return
	end
	table.insert(snapshots, {
		t = t,
		position = position,
		yaw = yaw,
		mode = MODE_NAMES[if type(code) == "number" then code else 0] or "Off",
	})
	if #snapshots > 40 then
		table.remove(snapshots, 1)
	end
end

local function sample(renderTime: number): (Vector3?, number, Vector3)
	local count = #snapshots
	if count == 0 then
		return nil, 0, Vector3.zero
	end
	-- Drop history we will never need again (keep one snapshot before renderTime).
	while #snapshots >= 3 and snapshots[2].t < renderTime - 0.5 do
		table.remove(snapshots, 1)
	end
	count = #snapshots
	for i = count - 1, 1, -1 do
		local a, b = snapshots[i], snapshots[i + 1]
		if a.t <= renderTime and renderTime <= b.t then
			local span = math.max(1e-3, b.t - a.t)
			local alpha = (renderTime - a.t) / span
			local velocity = (b.position - a.position) / span
			if (b.position - a.position).Magnitude > 14 then
				-- Teleport (phase): snap instead of sliding through walls.
				return (if alpha < 0.5 then a.position else b.position),
					(if alpha < 0.5 then a.yaw else b.yaw),
					Vector3.zero
			end
			local yaw = a.yaw + MathUtil.angleDelta(a.yaw, b.yaw) * alpha
			return a.position:Lerp(b.position, alpha), yaw, velocity
		end
	end
	local last = snapshots[count]
	if renderTime > last.t then
		local prev = snapshots[count - 1]
		local velocity = if prev
			then (last.position - prev.position) / math.max(1e-3, last.t - prev.t)
			else Vector3.zero
		if velocity.Magnitude > 40 then
			velocity = Vector3.zero
		end
		local ahead = math.min(renderTime - last.t, MAX_EXTRAPOLATE)
		return last.position + velocity * ahead, last.yaw, velocity
	end
	local first = snapshots[1]
	return first.position, first.yaw, Vector3.zero
end

-- Animation ------------------------------------------------------------------------------------------------------

local MODE_STYLE: { [string]: { eye: Color3, lantern: Color3, badge: string?, badgeColor: Color3? } } = {
	Patrol = { eye = Color3.fromRGB(255, 240, 180), lantern = Color3.fromRGB(255, 196, 110) },
	Investigate = {
		eye = Color3.fromRGB(255, 190, 80),
		lantern = Color3.fromRGB(255, 180, 90),
		badge = "?",
		badgeColor = Theme.Colors.gold,
	},
	Search = {
		eye = Color3.fromRGB(255, 170, 60),
		lantern = Color3.fromRGB(255, 170, 80),
		badge = "?",
		badgeColor = Theme.Colors.orange,
	},
	Chase = {
		eye = Color3.fromRGB(255, 50, 40),
		lantern = Color3.fromRGB(255, 70, 50),
		badge = "!",
		badgeColor = Theme.Colors.red,
	},
	Hunt = { eye = Color3.fromRGB(255, 50, 40), lantern = Color3.fromRGB(255, 70, 50) },
	Lunge = {
		eye = Color3.fromRGB(255, 30, 30),
		lantern = Color3.fromRGB(255, 60, 40),
		badge = "!",
		badgeColor = Theme.Colors.red,
	},
	Alert = {
		eye = Color3.fromRGB(255, 40, 40),
		lantern = Color3.fromRGB(255, 60, 40),
		badge = "!!",
		badgeColor = Theme.Colors.red,
	},
	React = {
		eye = Color3.fromRGB(200, 220, 255),
		lantern = Color3.fromRGB(255, 196, 110),
		badge = "✦",
		badgeColor = Theme.Colors.goldLight,
	},
	Dormant = {
		eye = Color3.fromRGB(80, 80, 90),
		lantern = Color3.fromRGB(180, 140, 90),
		badge = "Z",
		badgeColor = Theme.Colors.blue,
	},
	Phase = { eye = Color3.fromRGB(180, 140, 255), lantern = Color3.fromRGB(170, 120, 255) },
	Off = { eye = Color3.fromRGB(80, 80, 90), lantern = Color3.fromRGB(120, 100, 80) },
}

local function applyModeStyle(r: Rig)
	local style = MODE_STYLE[mode] or MODE_STYLE.Patrol
	r.eyeL.Color = style.eye
	r.eyeR.Color = style.eye
	r.eyeLight.Color = style.eye
	r.lantern.Color = style.lantern
	r.lanternLight.Color = style.lantern
	local showBadge = style.badge ~= nil or os.clock() < spottedUntil
	r.badge.Enabled = showBadge
	r.badgeLabel.Text = if os.clock() < spottedUntil then "!" else style.badge or ""
	r.badgeLabel.TextColor3 = if os.clock() < spottedUntil
		then Theme.Colors.red
		else style.badgeColor or Theme.Colors.gold
	local hunting = mode == "Chase" or mode == "Hunt" or mode == "Lunge" or mode == "Alert"
	r.highlight.OutlineTransparency = if hunting then 0.2 else 1
	r.sleepy.Enabled = mode == "Dormant"
	if r.hum then
		(r.hum :: AudioController.LoopHandle).setVolume(
			if hunting then 1.2 elseif mode == "Dormant" then 0.25 else 0.7,
			0.5
		);
		(r.hum :: AudioController.LoopHandle).setPitch(if hunting then 1.12 else 1)
	end
end

local function setMode(newMode: string)
	if newMode == mode then
		return
	end
	local previous = mode
	mode = newMode
	modeSince = os.clock()
	local r = rig
	if r then
		applyModeStyle(r)
		local p = r.torso.Position
		if newMode == "Alert" then
			AudioController.at("caretaker_alert", p, { volume = 1.2, rolloffMax = 400 })
			Vfx.flash(p, Color3.fromRGB(255, 60, 40), 8, 50, 0.8)
			CameraController.shake(0.8, 0.8)
		elseif newMode == "Search" or newMode == "Investigate" then
			if previous ~= "Search" and previous ~= "Investigate" then
				AudioController.at("caretaker_search", p, { volume = 0.9 })
			end
		elseif newMode == "React" then
			Vfx.burst(
				r.head.Position + Vector3.new(0, 1, 0),
				"magic",
				14,
				{ Color = ColorSequence.new(Theme.Colors.goldLight) }
			)
		end
	end
end

local function partCF(root: CFrame, local_: CFrame): CFrame
	return root * local_
end

local function animate(r: Rig, position: Vector3, yaw: number, velocity: Vector3, dt: number)
	local now = os.clock()
	local flat = Vector3.new(velocity.X, 0, velocity.Z)
	local speed = flat.Magnitude
	smoothedSpeed += (speed - smoothedSpeed) * MathUtil.dampAlpha(8, dt)
	local s = smoothedSpeed
	local caretakerState = ClientState.get("global", "caretaker") or {}
	local chilled = caretakerState.chilled == true
	local braced = caretakerState.braced == true

	-- Stride: legs swing faster and wider with speed.
	local strideRate = if s > 0.3 then 1.6 + s * 0.42 else 0
	stride += strideRate * dt
	local swing = math.sin(stride * math.pi) * math.clamp(s / 9, 0, 1) * 0.75
	local sign = if math.sin(stride * math.pi) >= 0 then 1 else -1
	if sign ~= lastStepSign and s > 1 then
		lastStepSign = sign
		local volume = math.clamp(s / 14, 0.25, 1.1)
		AudioController.at("caretaker_step", position - Vector3.new(0, HOVER - 0.3, 0), {
			volume = volume,
			pitch = if s > 11 then 1.1 else 0.95,
			rolloffMin = 8,
			rolloffMax = if s > 11 then 140 else 90,
		})
	end
	-- Occasional key jingle and creaks.
	if s > 1 and now - lastJingle > 3.5 then
		lastJingle = now
		AudioController.at("caretaker_keys", position, { volume = 0.6, rolloffMax = 60 })
	end
	if mode == "Search" and now - lastCreak > 2.2 then
		lastCreak = now
		AudioController.at("caretaker_search", position, { volume = 0.5, rolloffMax = 60 })
	end

	-- Pose parameters per mode.
	local lean = math.clamp(s / 16, 0, 1) * 0.28 -- forward lean when moving fast
	local crouch = 0
	local headYaw = 0
	local headTilt = 0
	local armReach = 0
	local slump = 0
	local wobble = 0
	local t = now - modeSince
	if mode == "Investigate" then
		headTilt = 0.35 * math.sin(math.min(t * 3, math.pi / 2))
	elseif mode == "Search" then
		headYaw = math.sin(now * 1.8) * 0.9
	elseif mode == "Lunge" then
		crouch = math.min(1, t / GameConfig.Caretaker.LungeWindupSeconds) * 0.8
		armReach = 1
		lean = 0.45
	elseif mode == "Chase" or mode == "Hunt" then
		armReach = 0.45
	elseif mode == "Alert" then
		armReach = 1
		headTilt = -0.3
	elseif mode == "React" then
		wobble = math.sin(now * 14) * 0.25 * math.max(0, 1 - t / GameConfig.Caretaker.ReactSeconds)
		reactSpin += dt * 6
	elseif mode == "Dormant" then
		slump = 1
	end
	if braced then
		lean = -0.25 -- leaning into the gust
	end

	local bob = math.abs(math.sin(stride * math.pi)) * 0.14 * math.clamp(s / 6, 0, 1)
	local idleBreath = math.sin(now * 1.7) * 0.05
	local base = CFrame.new(position + Vector3.new(0, bob + idleBreath - crouch * 0.6 - slump * 1.1, 0))
		* CFrame.Angles(0, yaw, 0)
	-- Hips sit at the root; legs hang below.
	local hips = base * CFrame.new(0, -0.2, 0)
	local legL = hips * CFrame.new(-0.55, 0, 0) * CFrame.Angles(swing - slump * 1.2, 0, 0) * CFrame.new(0, -1.55, 0)
	local legR = hips * CFrame.new(0.55, 0, 0) * CFrame.Angles(-swing - slump * 1.2, 0, 0) * CFrame.new(0, -1.55, 0)
	local shoeL = legL * CFrame.new(0, -1.55, -0.3)
	local shoeR = legR * CFrame.new(0, -1.55, -0.3)
	local body = hips * CFrame.Angles(-lean - slump * 0.5, 0, wobble)
	local coatTail = body * CFrame.new(0, 0.55, 0.05)
	local torso = body * CFrame.new(0, 2.0, 0)
	local neck = torso * CFrame.new(0, 1.35, 0)
	local head = neck * CFrame.Angles(headTilt * 0.5 + slump * 0.6, headYaw, headTilt) * CFrame.new(0, 1.0, -0.1)
	local hat = head * CFrame.new(0, 1.15, 0.05) * CFrame.Angles(0, 0, math.pi / 2)
	local band = head * CFrame.new(0, 0.62, 0.05) * CFrame.Angles(0, 0, math.pi / 2)
	local eyeL = head * CFrame.new(-0.38, 0.12, -0.78)
	local eyeR = head * CFrame.new(0.38, 0.12, -0.78)
	local armSwing = -swing * 0.8
	local shoulderL = torso * CFrame.new(-1.5, 1.0, 0)
	local shoulderR = torso * CFrame.new(1.5, 1.0, 0)
	local armL = shoulderL
		* CFrame.Angles(armSwing - armReach * 1.3 - slump * 0.2, 0, -0.12 - armReach * 0.2)
		* CFrame.new(0, -1.25, 0)
	local armR = shoulderR
		* CFrame.Angles(-armSwing * 0.6 - armReach * 1.1 - slump * 0.2, 0, 0.1 + armReach * 0.15)
		* CFrame.new(0, -1.25, 0)
	-- Lantern swings like a pendulum from the right hand.
	local pendulum = math.sin(now * 2.6) * 0.18 + swing * 0.3
	local hand = armR * CFrame.new(0, -1.35, 0)
	local lanternFrame = CFrame.new(hand.Position)
		* CFrame.Angles(0, yaw, 0)
		* CFrame.Angles(pendulum, 0, 0)
		* CFrame.new(0, -0.75, 0)
	local lantern = lanternFrame
	local keyRing = armL * CFrame.new(0, -1.35, 0) * CFrame.Angles(0, math.pi / 2, 0)

	-- Reuse one CFrame buffer in the same order as moveParts (built once per rig).
	local buffer = cframeBuffer
	local n = 0
	local function put(cf: CFrame)
		n += 1
		buffer[n] = cf
	end
	put(legL)
	put(legR)
	put(shoeL)
	put(shoeR)
	put(coatTail)
	put(torso)
	put(head)
	put(hat)
	put(band)
	put(eyeL)
	put(eyeR)
	put(armL)
	put(armR)
	put(lanternFrame)
	put(lantern)
	put(keyRing)
	for _, spec in r.extras do
		put(partCF(torso, spec.offset))
	end
	for _, spec in r.headExtras do
		put(partCF(head, spec.offset))
	end
	for _, spec in r.armRExtras do
		put(partCF(armR, spec.offset))
	end
	for _, spec in r.armLExtras do
		put(partCF(armL, spec.offset))
	end
	Workspace:BulkMoveTo(r.moveParts, buffer, Enum.BulkMoveMode.FireCFrameChanged)

	-- Lantern flicker, eye glow, frost, phase fade.
	r.lanternLight.Brightness = 1.5 + math.sin(now * 11) * 0.12 + math.sin(now * 23) * 0.08
	r.frost.Enabled = chilled
	local tint = if chilled then Color3.fromRGB(150, 200, 255) else COAT
	r.torso.Color = tint
	r.coatTail.Color = tint
	r.armL.Color = tint
	r.armR.Color = tint
	r.hat.Color = tint
	local targetAlpha = if mode == "Phase" then 0.15 elseif mode == "Off" then 0 else 1
	visibleAlpha += (targetAlpha - visibleAlpha) * MathUtil.dampAlpha(6, dt)
	local transparency = 1 - visibleAlpha
	for _, part in r.parts do
		part.LocalTransparencyModifier = transparency
	end
	r.badge.StudsOffsetWorldSpace = Vector3.new(0, 2.4 + math.sin(now * 3) * 0.15, 0)
	if mode == "React" then
		r.badge.StudsOffsetWorldSpace += Vector3.new(math.cos(reactSpin) * 0.8, 0, math.sin(reactSpin) * 0.8)
	end
end

-- Lifecycle ----------------------------------------------------------------------------------------------------

local function wanted(): boolean
	local state = ClientState.get("global", "caretaker")
	local m = if type(state) == "table" then state.mode else nil
	return RunInfo.inRunPhase() and RunInfo.level() ~= nil and m ~= nil and m ~= "Gone"
end

local function step(dt: number)
	if not wanted() then
		if rig then
			destroyRig()
		end
		table.clear(snapshots)
		lastPosition = nil
		return
	end
	local renderTime = Workspace:GetServerTimeNow() - INTERP_DELAY
	local position, yaw, velocity = sample(renderTime)
	if not position then
		return
	end
	local r: Rig
	if rig then
		r = rig :: Rig
	else
		r = buildRig()
		rig = r
		mode = ""
		local state = ClientState.get("global", "caretaker") or {}
		setMode(state.mode or "Patrol")
		applyModeStyle(r)
	end
	lastPosition = position
	animate(r, position :: Vector3, yaw, velocity, dt)
	if os.clock() < spottedUntil + 0.05 then
		applyModeStyle(r)
	end
end

-- Position for other systems (HUD threat arrow, hints). Nil when no caretaker is active.
function CaretakerView.position(): Vector3?
	if not rig then
		return nil
	end
	return lastPosition
end

function CaretakerView.mode(): string
	return mode
end

function CaretakerView.start()
	Net.listen("CaretakerSnapshot", onSnapshot)
	ClientState.observe("global", "caretaker", function(state: any)
		if type(state) == "table" and type(state.mode) == "string" then
			if rig then
				setMode(state.mode)
			else
				mode = state.mode
			end
		end
	end)
	Net.listen("Effect", function(name: any, params: any)
		local r = rig
		if not r then
			return
		end
		if name == "caretakerSpotted" then
			spottedUntil = os.clock() + 1.4
			applyModeStyle(r)
			AudioController.at("caretaker_alert", r.torso.Position, { volume = 0.55, pitch = 1.25 })
		elseif name == "caretakerPhase" then
			Vfx.burst(r.torso.Position, "poof", 16, { Color = ColorSequence.new(Color3.fromRGB(170, 130, 255)) })
		elseif name == "caretakerReappear" and type(params) == "table" and typeof(params.position) == "Vector3" then
			Vfx.burst(params.position, "poof", 20, { Color = ColorSequence.new(Color3.fromRGB(170, 130, 255)) })
			AudioController.at("caretaker_keys", params.position, { volume = 0.9 })
		elseif name == "caretakerLunge" then
			AudioController.at("caretaker_grab", r.torso.Position, { volume = 0.9 })
		end
	end)
	RunService.RenderStepped:Connect(step)
end

return CaretakerView
