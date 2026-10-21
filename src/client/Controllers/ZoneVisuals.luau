--!strict
--[[
	ZoneVisuals: renders every replicated hazard and puzzle state of the current level (S08, S09, R01-R13).

	The server owns the truth (zone snapshots, collision, crate positions, cart timelines); this module only
	draws it, on every client identically:

	  basins   water rising / draining from the drain, ice forming and melting, live-wire sparks
	  fires    warning flicker -> roaring flames with light and smoke -> steam when doused
	  vines    a leafy bridge growing from its planter (frosted while paused by cold)
	  plates   sink and glow when weighted; levers swing and show whether their circuit is live
	  keys     spinning golden keys that burst when collected
	  carts    luggage carts driven by the shared cart timeline (exactly where the server deals damage)
	  crates   smoothed copies of the server crates (the real ones stay invisible colliders)
	  wind     streaks along every active Fan lane; primed launch ramps pulse

	Zone sounds come from state transitions, so they play once per change for everyone, never on join.
	Everything for a level lives in one folder + trove and is torn down with the level.
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.Config.GameConfig)
local Geometry = require(Shared.World.Geometry)
local Palette = require(Shared.World.Palette)
local Props = require(Shared.World.Props)
local EffectModel = require(Shared.Logic.EffectModel)
local CartTimeline = require(Shared.Logic.CartTimeline)
local MathUtil = require(Shared.Util.MathUtil)
local Trove = require(Shared.Util.Trove)
local ClientState = require(script.Parent.Parent.Core.ClientState)
local RunInfo = require(script.Parent.Parent.Core.RunInfo)
local AudioController = require(script.Parent.AudioController)
local Vfx = require(script.Parent.Parent.Visual.Vfx)

local ZoneVisuals = {}
ZoneVisuals.priority = 40

local T = GameConfig.Effects

local WATER = Color3.fromRGB(64, 156, 218)
local WATER_LIVE = Color3.fromRGB(150, 220, 255)
local ICE = Color3.fromRGB(196, 234, 255)
local LEAF = Color3.fromRGB(86, 168, 72)
local LEAF_DARK = Color3.fromRGB(52, 120, 52)

type LoopHandle = AudioController.LoopHandle

type BasinVis = {
	id: string,
	deep: boolean,
	surfaceCF: CFrame,
	width: number,
	length: number,
	floorY: number,
	water: Part,
	sheen: Part,
	ice: { BasePart },
	sparks: { ParticleEmitter },
	frost: ParticleEmitter?,
	light: PointLight,
	electricLoop: LoopHandle?,
	waterLoop: LoopHandle?,
	phase: string,
	electrified: boolean,
	snap: any,
	settledKey: number, -- fill/ice/visibility last written, while nothing on it animates (-1: animating)
}

type FireVis = {
	id: string,
	flames: { ParticleEmitter },
	embers: { ParticleEmitter },
	smoke: { ParticleEmitter },
	light: PointLight,
	anchor: Part,
	loop: LoopHandle?,
	phase: string,
	snap: any,
}

type VineVis = {
	id: string,
	startCF: CFrame, -- at the planter end, LookVector along the bridge
	length: number,
	width: number,
	deck: Part,
	vines: { Part },
	leaves: { { part: Part, along: number } },
	phase: string,
	snap: any,
	shown: number,
}

type CartVis = { id: string, model: Model, tileCF: CFrame, range: number, speed: number, frost: ParticleEmitter? }
type CrateVis = { real: BasePart, visual: BasePart, loop: LoopHandle? }
type KeyVis = { id: string, model: Model, base: Vector3, taken: boolean, seed: number }
type LeverVis = { part: BasePart, base: CFrame, lamp: Part, id: string }

type Session = {
	level: any,
	model: Model,
	folder: Folder,
	trove: Trove.Trove,
	basins: { [string]: BasinVis },
	fires: { [string]: FireVis },
	vines: { [string]: VineVis },
	carts: { [string]: CartVis },
	crates: { [BasePart]: CrateVis },
	keys: { [string]: KeyVis },
	levers: { [string]: LeverVis },
	sparksByZone: { [string]: { ParticleEmitter } },
	windEmitters: { [string]: Part },
	ramps: { BasePart },
	rampsPrimed: boolean?,
	highlights: { SelectionBox },
	zoneParts: { [string]: BasePart },
	first: boolean,
}

local session: Session? = nil

-- Helpers -------------------------------------------------------------------------------------------------

local function visualPart(
	parent: Instance,
	name: string,
	size: Vector3,
	cf: CFrame,
	color: Color3,
	material: Enum.Material
): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Size = size
	part.CFrame = cf
	part.Color = color
	part.Material = material
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

local function attachmentAt(parent: BasePart, worldPosition: Vector3): Attachment
	local a = Instance.new("Attachment")
	a.WorldPosition = worldPosition
	a.Parent = parent
	return a
end

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

local function elapsedOf(snap: any): number
	if type(snap) ~= "table" or type(snap.since) ~= "number" then
		return math.huge
	end
	return math.max(0, serverNow() - snap.since)
end

-- Basins --------------------------------------------------------------------------------------------------

local function buildBasin(s: Session, zonePart: BasePart)
	local id = zonePart:GetAttribute("ZoneId") :: string
	local deep = zonePart:GetAttribute("Deep") == true
	local width = (zonePart:GetAttribute("Width") :: number?) or zonePart.Size.X
	local length = (zonePart:GetAttribute("Length") :: number?) or zonePart.Size.Z
	local surfaceCF = zonePart.CFrame
	local floorY = if deep
		then surfaceCF.Position.Y - (Geometry.Pit.Depth + Geometry.Pit.WaterSurface)
		else surfaceCF.Position.Y - 0.1
	local water = visualPart(
		s.folder,
		"Water_" .. id,
		Vector3.new(width - 0.1, 0.2, length - 0.1),
		surfaceCF,
		WATER,
		Enum.Material.Glass
	)
	water.Transparency = 1
	water.Reflectance = 0.04
	local sheen = visualPart(
		s.folder,
		"WaterSheen_" .. id,
		Vector3.new(width - 0.1, 0.05, length - 0.1),
		surfaceCF,
		Color3.fromRGB(190, 236, 255),
		Enum.Material.ForceField
	)
	sheen.Transparency = 1
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(150, 210, 255)
	light.Range = math.min(24, math.max(width, length))
	light.Brightness = 0
	light.Shadows = false
	light.Parent = water
	-- Sparks scattered over the surface for electrified water.
	local sparks = {}
	local count = math.clamp(math.floor(width * length / 40), 2, 6)
	for i = 1, count do
		local x = ((i - 0.5) / count - 0.5) * (width - 2)
		local z = (((i * 7) % count) / count - 0.5) * (length - 2)
		local a = attachmentAt(sheen, (surfaceCF * CFrame.new(x, 0.2, z)).Position)
		local e = Vfx.emitter(a, "sparks")
		e.Enabled = false
		local zap = Vfx.emitter(a, "zap")
		zap.Enabled = false
		table.insert(sparks, e)
		table.insert(sparks, zap)
	end
	local frostAttachment = attachmentAt(sheen, surfaceCF.Position + Vector3.new(0, 0.6, 0))
	local frost = Vfx.emitter(frostAttachment, "frost", {
		Shape = Enum.ParticleEmitterShape.Box,
	})
	frost.Enabled = false
	local ice: { BasePart } = {}
	for _, d in s.model:GetDescendants() do
		if d:IsA("BasePart") and d:HasTag("RN_IceCollider") and d:GetAttribute("ZoneId") == id then
			d.Transparency = 1
			d.Color = ICE
			d.Material = Enum.Material.Ice
			d.Reflectance = 0.15
			table.insert(ice, d)
		end
	end
	s.basins[id] = {
		id = id,
		deep = deep,
		surfaceCF = surfaceCF,
		width = width,
		length = length,
		floorY = floorY,
		water = water,
		sheen = sheen,
		ice = ice,
		sparks = sparks,
		frost = frost,
		light = light,
		electricLoop = nil,
		waterLoop = nil,
		phase = "",
		electrified = false,
		snap = nil,
		settledKey = -1,
	}
end

local function basinFill(vis: BasinVis): number
	local snap = vis.snap
	if type(snap) ~= "table" then
		return 0
	end
	return EffectModel.fillAt(snap.phase, snap.fill0 or 0, elapsedOf(snap), T :: any)
end

local function iceAlpha(vis: BasinVis): number
	-- 0 = no ice, 1 = solid ice
	local snap = vis.snap
	if type(snap) ~= "table" then
		return 0
	end
	local phase = snap.phase
	local e = elapsedOf(snap)
	if phase == "Freezing" then
		return math.clamp(e / T.FreezeSeconds, 0, 1)
	elseif phase == "Ice" or phase == "Thawing" then
		return 1
	elseif phase == "Melting" then
		return 1 - math.clamp(e / T.MeltSeconds, 0, 1)
	end
	return 0
end

local function renderBasin(vis: BasinVis, now: number)
	local fill = basinFill(vis)
	local surfaceY = vis.surfaceCF.Position.Y
	local alpha = iceAlpha(vis)
	local visible = fill > 0.01
	-- Bobbing deep water and live sparks move every frame; a settled basin (dry, frozen, still) is written
	-- once and then left alone.
	local animating = vis.electrified or (vis.deep and visible and alpha < 0.5)
	local key = math.round(fill * 500) + math.round(alpha * 500) * 1000
	if not animating and key == vis.settledKey then
		return
	end
	vis.settledKey = if animating then -1 else key
	if vis.deep then
		local height = math.max(0.2, fill * (surfaceY - vis.floorY))
		local centreY = vis.floorY + height / 2
		local bob = if visible and alpha < 0.5 then math.sin(now * 1.6) * 0.04 else 0
		local base = vis.surfaceCF * CFrame.new(0, centreY - surfaceY + bob, 0)
		vis.water.Size = Vector3.new(vis.width - 0.1, height, vis.length - 0.1)
		vis.water.CFrame = base
		vis.sheen.CFrame = base * CFrame.new(0, height / 2 + 0.03, 0)
	else
		vis.water.Size = Vector3.new(vis.width - 0.1, 0.16, vis.length - 0.1)
		vis.water.CFrame = vis.surfaceCF * CFrame.new(0, 0.02, 0)
		vis.sheen.CFrame = vis.surfaceCF * CFrame.new(0, 0.12, 0)
	end
	local live = vis.electrified
	local waterTransparency = if visible then (if vis.deep then 0.32 else 0.45) + alpha * 0.35 else 1
	vis.water.Transparency = waterTransparency
	vis.water.Color = if live then WATER:Lerp(WATER_LIVE, 0.5 + 0.5 * math.sin(now * 18)) else WATER
	vis.sheen.Transparency = if visible and alpha < 0.95 then 0.55 + alpha * 0.45 else 1
	for _, ice in vis.ice do
		ice.Transparency = if alpha > 0.01 then 1 - alpha * 0.82 else 1
	end
	vis.light.Brightness = if live then 1.4 + math.sin(now * 23) * 0.8 else 0
end

local function basinTransition(vis: BasinVis, snap: any, silent: boolean)
	local phase = if type(snap) == "table" then snap.phase else "Dry"
	local electrified = type(snap) == "table" and snap.electrified == true
	local previous = vis.phase
	vis.snap = snap
	vis.phase = phase
	local centre = vis.surfaceCF.Position
	if phase ~= previous and not silent then
		if phase == "Filling" then
			AudioController.at("water_fill", centre, { volume = 0.9 })
			Vfx.burst(centre, "splash", 18)
		elseif phase == "Draining" then
			AudioController.at("drain_gurgle", centre, { volume = 0.8 })
		elseif phase == "Freezing" then
			AudioController.at("freeze", centre, { volume = 1 })
			Vfx.burst(centre + Vector3.new(0, 1, 0), "frost", 40, {
				Speed = NumberRange.new(4, 10),
				SpreadAngle = Vector2.new(80, 80),
			})
			Vfx.flash(centre + Vector3.new(0, 2, 0), ICE, 3, 22, 0.5)
		elseif phase == "Thawing" then
			AudioController.at("ice_crack", centre, { volume = 0.8 })
		elseif phase == "Melting" then
			AudioController.at("ice_melt", centre, { volume = 0.7 })
		end
	end
	if vis.frost then
		(vis.frost :: ParticleEmitter).Enabled = phase == "Freezing" or phase == "Thawing"
	end
	-- Electricity on / off.
	if electrified ~= vis.electrified then
		vis.electrified = electrified
		for _, e in vis.sparks do
			e.Enabled = electrified
		end
		if electrified then
			if not silent then
				AudioController.at("electric_zap", centre, { volume = 0.9 })
			end
			vis.electricLoop = AudioController.loop("electric_loop", { position = centre, rolloffMax = 70 })
		elseif vis.electricLoop then
			(vis.electricLoop :: LoopHandle).stop(0.3)
			vis.electricLoop = nil
		end
		local s = session
		if s then
			local cableSparks: { ParticleEmitter } = s.sparksByZone[vis.id] or {}
			for _, e in cableSparks do
				e.Enabled = electrified
			end
		end
	end
	-- Gentle water ambience while liquid water is present.
	local wet = phase == "Water" or phase == "Filling" or phase == "Draining"
	if wet and not vis.waterLoop and vis.deep then
		vis.waterLoop = AudioController.loop("water_loop", { position = centre, rolloffMax = 60, volume = 0.6 })
	elseif not wet and vis.waterLoop then
		(vis.waterLoop :: LoopHandle).stop(0.6)
		vis.waterLoop = nil
	end
end

-- Fires ---------------------------------------------------------------------------------------------------

local function buildFire(s: Session, zonePart: BasePart)
	local id = zonePart:GetAttribute("ZoneId") :: string
	local cf = zonePart.CFrame
	local size = zonePart.Size
	local anchor = visualPart(
		s.folder,
		"Fire_" .. id,
		Vector3.new(size.X, 0.2, 1),
		cf * CFrame.new(0, -size.Y / 2 + 0.2, 0),
		Color3.new(0, 0, 0),
		Enum.Material.SmoothPlastic
	)
	anchor.Transparency = 1
	local flames, embers, smoke = {}, {}, {}
	local count = math.max(3, math.floor(size.X / 2.6))
	for i = 1, count do
		local x = ((i - 0.5) / count - 0.5) * (size.X - 1.4)
		local a = attachmentAt(anchor, (cf * CFrame.new(x, -size.Y / 2 + 0.6, 0)).Position)
		local flame = Vfx.emitter(a, "fire", { Size = Vfx.seq(2.4, 3.4, 0.8) })
		flame.Enabled = false
		table.insert(flames, flame)
		if i % 2 == 1 then
			local ember = Vfx.emitter(a, "embers")
			ember.Enabled = false
			table.insert(embers, ember)
			local sm = Vfx.emitter(a, "smoke", { Acceleration = Vector3.new(0, 3, 0) })
			sm.Enabled = false
			table.insert(smoke, sm)
		end
	end
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 150, 60)
	light.Range = 22
	light.Brightness = 0
	light.Shadows = false
	light.Parent = anchor
	s.fires[id] = {
		id = id,
		flames = flames,
		embers = embers,
		smoke = smoke,
		light = light,
		anchor = anchor,
		loop = nil,
		phase = "",
		snap = nil,
	}
end

local function fireTransition(vis: FireVis, snap: any, silent: boolean)
	local phase = if type(snap) == "table" then snap.phase else "Out"
	local previous = vis.phase
	vis.snap = snap
	vis.phase = phase
	local burning = phase == "Burning"
	local warning = phase == "Warning"
	for _, e in vis.flames do
		e.Enabled = burning or warning
		Vfx.setRate(e, if burning then 36 else 6)
	end
	for _, e in vis.embers do
		e.Enabled = burning
	end
	for _, e in vis.smoke do
		e.Enabled = burning
	end
	local centre = vis.anchor.CFrame.Position + Vector3.new(0, 2, 0)
	if burning and not vis.loop then
		vis.loop = AudioController.loop("fire_loop", { position = centre, rolloffMax = 80 })
	elseif not burning and vis.loop then
		(vis.loop :: LoopHandle).stop(0.5)
		vis.loop = nil
	end
	if silent or phase == previous then
		return
	end
	if burning then
		AudioController.at("fire_ignite", centre, { volume = 1 })
		Vfx.burst(centre, "embers", 30, { Speed = NumberRange.new(10, 20) })
		Vfx.flash(centre, Color3.fromRGB(255, 160, 60), 5, 26, 0.5)
	elseif phase == "Out" and previous == "Burning" then
		AudioController.at("extinguish", centre, { volume = 1 })
		Vfx.burst(centre, "steam", 26)
	end
end

local function renderFire(vis: FireVis, now: number)
	if vis.phase == "Burning" then
		vis.light.Brightness = 2.2 + math.sin(now * 17) * 0.35 + math.sin(now * 7.3) * 0.25
	elseif vis.phase == "Warning" then
		-- Telegraph: a stuttering glow that grows toward re-ignition.
		local e = elapsedOf(vis.snap)
		local k = math.clamp(e / T.FireWarningSeconds, 0, 1)
		vis.light.Brightness = if math.sin(now * 20) > 0.2 then 0.4 + k * 1.4 else 0.1
	else
		vis.light.Brightness = 0
	end
end

-- Vines ---------------------------------------------------------------------------------------------------

local function buildVine(s: Session, zonePart: BasePart)
	local id = zonePart:GetAttribute("ZoneId") :: string
	local cf = zonePart.CFrame
	local size = zonePart.Size
	-- The bridge grows from its planter end (local +Z) toward local -Z.
	local startCF = cf * CFrame.new(0, size.Y / 2 - 0.05, size.Z / 2)
	local deck = visualPart(
		s.folder,
		"VineDeck_" .. id,
		Vector3.new(size.X - 0.6, 0.5, 0.1),
		startCF,
		LEAF,
		Enum.Material.LeafyGrass
	)
	deck.Transparency = 1
	local vines = {}
	for _, x in { -size.X / 2 + 0.35, size.X / 2 - 0.35 } do
		local vine = visualPart(
			s.folder,
			"Vine_" .. id,
			Vector3.new(0.5, 0.5, 0.1),
			startCF * CFrame.new(x, 0.2, 0),
			LEAF_DARK,
			Enum.Material.Grass
		)
		vine.Transparency = 1
		vine:SetAttribute("OffsetX", x)
		table.insert(vines, vine)
	end
	local leaves = {}
	local rng = MathUtil.rng(MathUtil.hash(id))
	local n = math.floor(size.Z / 1.1)
	for i = 1, n do
		local along = (i - 0.5) / n * size.Z
		local x = (rng() - 0.5) * (size.X - 0.4)
		local leaf = visualPart(
			s.folder,
			"Leaf",
			Vector3.new(0.9, 0.08, 0.6),
			startCF
				* CFrame.new(x, 0.32 + rng() * 0.1, -along)
				* CFrame.Angles(rng() * 0.5, rng() * math.pi * 2, rng() * 0.4),
			LEAF:Lerp(Color3.fromRGB(150, 220, 90), rng() * 0.6),
			Enum.Material.SmoothPlastic
		)
		leaf.Transparency = 1
		table.insert(leaves, { part = leaf, along = along })
	end
	s.vines[id] = {
		id = id,
		startCF = startCF,
		length = size.Z,
		width = size.X,
		deck = deck,
		vines = vines,
		leaves = leaves,
		phase = "",
		snap = nil,
		shown = -1,
	}
end

local function renderVine(vis: VineVis, now: number)
	local snap = vis.snap
	local progress = 0
	if type(snap) == "table" then
		progress = EffectModel.vineProgressAt(snap.phase, snap.progress0 or 0, elapsedOf(snap), T :: any)
	end
	local paused = type(snap) == "table" and snap.phase == "Paused"
	if math.abs(progress - vis.shown) < 0.002 and not paused then
		return
	end
	vis.shown = progress
	local len = math.max(0.05, progress * vis.length)
	local visible = progress > 0.01
	vis.deck.Size = Vector3.new(vis.width - 0.6, 0.5, len)
	vis.deck.CFrame = vis.startCF * CFrame.new(0, -0.1, -len / 2)
	vis.deck.Transparency = if visible then 0 else 1
	local tint = if paused then Color3.fromRGB(170, 210, 230) else LEAF
	vis.deck.Color = tint
	for _, vine in vis.vines do
		local x = vine:GetAttribute("OffsetX") :: number
		vine.Size = Vector3.new(0.5, 0.5, len)
		vine.CFrame = vis.startCF * CFrame.new(x, 0.25 + math.sin(now * 2) * 0.03, -len / 2)
		vine.Transparency = if visible then 0 else 1
	end
	for _, leaf in vis.leaves do
		leaf.part.Transparency = if leaf.along <= len then 0 else 1
	end
end

local function vineTransition(vis: VineVis, snap: any, silent: boolean)
	local phase = if type(snap) == "table" then snap.phase else "Retracted"
	local previous = vis.phase
	vis.snap = snap
	vis.phase = phase
	vis.shown = -1
	if silent or phase == previous then
		return
	end
	local p = vis.startCF.Position
	if phase == "Growing" then
		AudioController.at("vine_grow", p, { volume = 0.9 })
		Vfx.burst(p + Vector3.new(0, 1, 0), "leaves", 16)
	elseif phase == "Grown" then
		Vfx.burst((vis.startCF * CFrame.new(0, 1, -vis.length / 2)).Position, "leaves", 24, {
			Shape = Enum.ParticleEmitterShape.Box,
		})
	end
end

-- Plates, levers, cable sparks ------------------------------------------------------------------------------

local function setupPlate(s: Session, part: BasePart)
	local base = part.CFrame
	local baseColor = part.Color
	local function apply(silent: boolean)
		local active = part:GetAttribute("Active") == true
		local goal = if active then base * CFrame.new(0, -0.1, 0) else base
		TweenService:Create(part, TweenInfo.new(0.15), { CFrame = goal }):Play()
		part.Color = if active then Color3.fromRGB(110, 240, 130) else baseColor
		if not silent then
			AudioController.at(
				"pressure_plate",
				part.CFrame.Position,
				{ volume = 0.8, pitch = if active then 1 else 0.85 }
			)
		end
	end
	apply(true)
	s.trove:Connect(part:GetAttributeChangedSignal("Active"), function()
		apply(false)
	end)
end

local function setupLever(s: Session, part: BasePart)
	local id = part:GetAttribute("LeverId") :: string
	local base = part.CFrame
	-- The status lamp sits above the warning sign on the lever panel (runtime cf is 1 stud in front of it).
	local info = s.level.levers and s.level.levers[id]
	local lampCF = if info then (info.cf :: CFrame) * CFrame.new(0, 3.3, 0.8) else base * CFrame.new(0, 2.4, 0)
	local lamp = visualPart(
		s.folder,
		"LeverLamp_" .. id,
		Vector3.new(0.55, 0.55, 0.55),
		lampCF,
		Color3.fromRGB(255, 70, 60),
		Enum.Material.Neon
	)
	lamp.Shape = Enum.PartType.Ball
	local record: LeverVis = { part = part, base = base, lamp = lamp, id = id }
	s.levers[id] = record
	local function apply(animate: boolean)
		local flipped = part:GetAttribute("Flipped") == true
		local pivot = base * CFrame.new(0, -0.9, 0)
		local goal = if flipped then pivot * CFrame.Angles(1.2, 0, 0) * CFrame.new(0, 0.9, 0) else base
		if animate then
			TweenService:Create(part, TweenInfo.new(0.22, Enum.EasingStyle.Back), { CFrame = goal }):Play()
		else
			part.CFrame = goal
		end
	end
	apply(false)
	s.trove:Connect(part:GetAttributeChangedSignal("Flipped"), function()
		apply(true)
	end)
end

-- A lever's lamp is red while any circuit it controls is live, green when all are off.
local function refreshLeverLamps(s: Session)
	local powers = s.level.powers
	if type(powers) ~= "table" then
		return
	end
	for leverId, record in s.levers do
		local live = false
		for powerId, power in powers do
			if table.find(power.levers, leverId) then
				local zone = ClientState.get("global", "zones." .. powerId)
				local on = if type(zone) == "table" and zone.on ~= nil then zone.on else power.default
				if on then
					live = true
				end
			end
		end
		record.lamp.Color = if live then Color3.fromRGB(255, 70, 60) else Color3.fromRGB(90, 240, 120)
	end
end

local function setupCableSpark(s: Session, part: BasePart)
	local zoneId = part:GetAttribute("ZoneId")
	if type(zoneId) ~= "string" then
		return
	end
	local a = Instance.new("Attachment")
	a.Parent = part
	local sparks = Vfx.emitter(a, "sparks", { Rate = 30 })
	sparks.Enabled = false
	local zap = Vfx.emitter(a, "zap")
	zap.Enabled = false
	s.sparksByZone[zoneId] = s.sparksByZone[zoneId] or {}
	table.insert(s.sparksByZone[zoneId], sparks)
	table.insert(s.sparksByZone[zoneId], zap)
end

-- Keys ------------------------------------------------------------------------------------------------------

local function buildKey(s: Session, anchor: BasePart)
	local id = anchor:GetAttribute("KeyId") :: string
	local model = Instance.new("Model")
	model.Name = "Key_" .. id
	local gold = Color3.fromRGB(255, 206, 70)
	local function piece(name: string, size: Vector3, cf: CFrame, shape: Enum.PartType?): Part
		local p = visualPart(model, name, size, cf, gold, Enum.Material.Foil)
		p.Reflectance = 0.25
		if shape then
			p.Shape = shape
		end
		return p
	end
	local bow = piece(
		"Bow",
		Vector3.new(0.25, 1.1, 1.1),
		CFrame.new(0, 0.55, 0) * CFrame.Angles(0, math.pi / 2, 0),
		Enum.PartType.Cylinder
	)
	piece("Shaft", Vector3.new(0.22, 1.5, 0.22), CFrame.new(0, -0.6, 0))
	piece("Tooth1", Vector3.new(0.45, 0.2, 0.18), CFrame.new(0.3, -1.2, 0))
	piece("Tooth2", Vector3.new(0.35, 0.2, 0.18), CFrame.new(0.25, -0.85, 0))
	local glow = Instance.new("PointLight")
	glow.Color = gold
	glow.Range = 9
	glow.Brightness = 1.2
	glow.Shadows = false
	glow.Parent = bow
	local a = Instance.new("Attachment")
	a.Parent = bow
	Vfx.emitter(a, "magic", { Rate = 3, Speed = NumberRange.new(0.5, 1.5), Lifetime = NumberRange.new(0.8, 1.4) })
	model.PrimaryPart = bow
	model.WorldPivot = CFrame.new()
	model.Parent = s.folder
	s.keys[id] =
		{ id = id, model = model, base = anchor.CFrame.Position, taken = false, seed = MathUtil.hash(id) % 100 }
end

local function renderKey(key: KeyVis, now: number)
	if key.taken then
		return
	end
	local bob = math.sin(now * 2.2 + key.seed) * 0.25
	key.model:PivotTo(CFrame.new(key.base + Vector3.new(0, bob, 0)) * CFrame.Angles(0, now * 1.8 + key.seed, 0.25))
end

local function updateKeys(s: Session, taken: any, silent: boolean)
	for id, key in s.keys do
		local isTaken = type(taken) == "table" and taken[id] ~= nil
		if isTaken and not key.taken then
			key.taken = true
			local p = key.model:GetPivot().Position
			key.model:Destroy()
			if not silent then
				Vfx.burst(p, "magic", 30)
				Vfx.ring(p - Vector3.new(0, 2, 0), Color3.fromRGB(255, 210, 90), 5, 0.5)
			end
		end
	end
end

-- Carts -----------------------------------------------------------------------------------------------------

local function buildCart(s: Session, id: string, info: any, theme: Palette.Theme)
	local holder = Instance.new("Folder")
	holder.Name = "Cart_" .. id
	holder.Parent = s.folder
	local tileCF: CFrame = info.tileCF
	Props.luggageCart(holder, tileCF, theme, MathUtil.rng(MathUtil.hash(id)))
	local model = holder:FindFirstChildWhichIsA("Model")
	if not model then
		return
	end
	model.WorldPivot = tileCF
	model.Parent = s.folder
	holder:Destroy()
	-- One shadow from the biggest piece (the cart moves every frame; small parts would only cost).
	local biggest: BasePart? = nil
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.CastShadow = false
			if not biggest or d.Size.Magnitude > (biggest :: BasePart).Size.Magnitude then
				biggest = d
			end
		end
	end
	if biggest then
		(biggest :: BasePart).CastShadow = true
	end
	-- A warning light on top (whatever model the cart is), so carts read as hazards even in the dark; frost
	-- drifts from it while the cart is chilled.
	local boxCF, boxSize = model:GetBoundingBox()
	local beacon = visualPart(
		model,
		"Beacon",
		Vector3.new(0.5, 0.5, 0.5),
		CFrame.new(boxCF.Position + Vector3.new(0, boxSize.Y / 2 + 0.35, 0)),
		Color3.fromRGB(255, 120, 40),
		Enum.Material.Neon
	)
	beacon.Shape = Enum.PartType.Ball
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 140, 60)
	light.Range = 10
	light.Brightness = 1
	light.Shadows = false
	light.Parent = beacon
	local a = Instance.new("Attachment")
	a.Position = Vector3.new(0, -boxSize.Y / 2, 0)
	a.Parent = beacon
	local frost: ParticleEmitter? = Vfx.emitter(a, "frost", { Rate = 14 })
	if frost then
		(frost :: ParticleEmitter).Enabled = false
	end
	s.carts[id] = { id = id, model = model, tileCF = tileCF, range = info.range, speed = info.speed, frost = frost }
end

local function renderCarts(s: Session, now: number)
	local timelines = ClientState.get("global", "carts")
	if type(timelines) ~= "table" then
		return
	end
	for id, cart in s.carts do
		local timeline = timelines[id]
		if type(timeline) == "table" then
			local x = CartTimeline.offset(timeline :: any, cart.range, cart.speed, now)
			local rattle = if timeline.pinned == 0 then math.sin(now * 30) * 0.03 else 0
			cart.model:PivotTo(cart.tileCF * CFrame.new(x, rattle, 0))
			if cart.frost then
				(cart.frost :: ParticleEmitter).Enabled = (timeline.coldMul or 1) < 1
			end
		end
	end
end

-- Crates (smoothed copies) ------------------------------------------------------------------------------------

local function setupCrate(s: Session, real: BasePart)
	local visual = real:Clone()
	visual.Name = real.Name .. "_Visual"
	visual.CanCollide = false
	visual.CanQuery = false
	visual.CanTouch = false
	for _, tag in visual:GetTags() do
		visual:RemoveTag(tag)
	end
	visual.Parent = s.folder
	real.LocalTransparencyModifier = 1
	for _, child in real:GetChildren() do
		if child:IsA("SurfaceGui") then
			child.Enabled = false
		end
	end
	local record: CrateVis = { real = real, visual = visual, loop = nil }
	s.crates[real] = record
	s.trove:Connect(real:GetAttributeChangedSignal("Moving"), function()
		local moving = real:GetAttribute("Moving") == true
		if moving and not record.loop then
			record.loop = AudioController.loop("crate_slide", { parent = visual, rolloffMax = 70, volume = 0.8 })
		elseif not moving and record.loop then
			(record.loop :: LoopHandle).stop(0.25)
			record.loop = nil
		end
	end)
end

local function renderCrates(s: Session, dt: number)
	local alpha = MathUtil.dampAlpha(22, dt)
	for real, record in s.crates do
		if real.Parent == nil then
			record.visual:Destroy()
			s.crates[real] = nil
		else
			local target = real.CFrame
			local current = record.visual.CFrame
			if (current.Position - target.Position).Magnitude > 6 then
				record.visual.CFrame = target
			else
				record.visual.CFrame = current:Lerp(target, alpha)
			end
		end
	end
end

-- Wind lanes & launch ramps -------------------------------------------------------------------------------------

local function refreshWind(s: Session)
	local sockets = ClientState.get("global", "sockets")
	local wanted: { [string]: any } = {}
	if type(sockets) == "table" then
		for socketId, info in sockets do
			if info.room == "Fan" and info.state ~= "Folding" and type(info.dir) == "string" then
				local socket = s.level.sockets[socketId]
				local laneId = socket and socket.lanes[info.dir]
				local lane = laneId and s.level.lanes[laneId]
				if lane then
					wanted[laneId] = lane
				end
			end
		end
	end
	for laneId, part in s.windEmitters do
		if not wanted[laneId] then
			part:Destroy()
			s.windEmitters[laneId] = nil
		end
	end
	for laneId, lane in wanted do
		if not s.windEmitters[laneId] then
			local vector: Vector3 = lane.vector
			local centre: Vector3 = lane.cf.Position
			-- Orient the emitter box so its Front face blows along the lane.
			local right = vector:Cross(Vector3.yAxis)
			local width = if math.abs(lane.cf.RightVector:Dot(right)) > 0.5 then lane.size.X else lane.size.Z
			local length = if math.abs(lane.cf.LookVector:Dot(vector)) > 0.5 then lane.size.Z else lane.size.X
			local emitterPart = visualPart(
				s.folder,
				"Wind_" .. laneId,
				Vector3.new(width - 1, 7, 1),
				CFrame.lookAt(centre - vector * (length / 2 - 1), centre - vector * (length / 2 - 1) + vector),
				Color3.new(1, 1, 1),
				Enum.Material.SmoothPlastic
			)
			emitterPart.Transparency = 1
			Vfx.emitter(emitterPart, "wind", {
				EmissionDirection = Enum.NormalId.Front,
				Lifetime = NumberRange.new(length / 34, length / 28),
				Rate = math.clamp(width * 2.4, 12, 40),
			})
			s.windEmitters[laneId] = emitterPart
		end
	end
end

local function renderRamps(s: Session, now: number)
	if #s.ramps == 0 then
		return
	end
	local primed = false
	for _, part in s.windEmitters do
		local laneId = string.sub(part.Name, 6)
		local lane = s.level.lanes[laneId]
		if lane and type(lane.slides) == "table" and #lane.slides > 0 then
			for _, launchId in lane.slides do
				local launch = s.level.launches[launchId]
				local basin = launch and launch.basin and s.basins[launch.basin]
				if basin and iceAlpha(basin) >= 1 then
					primed = true
				end
			end
		end
	end
	-- Primed ramps pulse every frame; resting ones are written once.
	if not primed and s.rampsPrimed == false then
		return
	end
	local changed = primed ~= s.rampsPrimed
	s.rampsPrimed = primed
	local pulse = 0.5 + 0.5 * math.sin(now * 6)
	for _, ramp in s.ramps do
		ramp.Color = if primed
			then Color3.fromRGB(255, 220, 60):Lerp(Color3.fromRGB(255, 255, 255), pulse)
			else Color3.fromRGB(240, 200, 60)
		if changed then
			ramp.Material = if primed then Enum.Material.Neon else Enum.Material.DiamondPlate
		end
	end
end

-- Placement highlights (U05) ---------------------------------------------------------------------------------

-- Outline the zones a socket would affect (PlacementController).
function ZoneVisuals.highlight(zoneIds: { string }, color: Color3)
	local s = session
	if not s then
		return
	end
	ZoneVisuals.clearHighlight()
	for _, id in zoneIds do
		local part = s.zoneParts[id]
		if part then
			local box = Instance.new("SelectionBox")
			box.Name = "PreviewOutline"
			box.Adornee = part
			box.Color3 = color
			box.SurfaceColor3 = color
			box.LineThickness = 0.12
			box.SurfaceTransparency = 0.82
			box.Transparency = 0.1
			box.Parent = s.folder
			table.insert(s.highlights, box)
		end
	end
end

function ZoneVisuals.clearHighlight()
	local s = session
	if not s then
		return
	end
	for _, box in s.highlights do
		box:Destroy()
	end
	table.clear(s.highlights)
end

-- Zone position for other systems (pings, hints).
function ZoneVisuals.zonePosition(zoneId: string): Vector3?
	local s = session
	if not s then
		return nil
	end
	local part = s.zoneParts[zoneId]
	return if part then part.CFrame.Position else nil
end

-- Session lifecycle ------------------------------------------------------------------------------------------

local function applyZones(s: Session, zones: any, silent: boolean)
	if type(zones) ~= "table" then
		return
	end
	for id, vis in s.basins do
		local snap = zones[id]
		if snap ~= vis.snap then
			basinTransition(vis, snap, silent)
		end
	end
	for id, vis in s.fires do
		local snap = zones[id]
		if snap ~= vis.snap then
			fireTransition(vis, snap, silent)
		end
	end
	for id, vis in s.vines do
		local snap = zones[id]
		if snap ~= vis.snap then
			vineTransition(vis, snap, silent)
		end
	end
	refreshLeverLamps(s)
end

local function teardown()
	local s = session
	if not s then
		return
	end
	session = nil
	for _, vis in s.basins do
		if vis.electricLoop then
			(vis.electricLoop :: LoopHandle).stop(0.2)
		end
		if vis.waterLoop then
			(vis.waterLoop :: LoopHandle).stop(0.2)
		end
	end
	for _, vis in s.fires do
		if vis.loop then
			(vis.loop :: LoopHandle).stop(0.2)
		end
	end
	for _, record in s.crates do
		if record.loop then
			(record.loop :: LoopHandle).stop(0.1)
		end
	end
	s.trove:Destroy()
	s.folder:Destroy()
end

local function build(level: any)
	teardown()
	local model = RunInfo.waitForLevelModel(15)
	if not model or RunInfo.level() ~= level then
		return
	end
	local folder = Instance.new("Folder")
	folder.Name = "RN_ZoneVisuals"
	folder.Parent = Workspace
	local s: Session = {
		level = level,
		model = model,
		folder = folder,
		trove = Trove.new(),
		basins = {},
		fires = {},
		vines = {},
		carts = {},
		crates = {},
		keys = {},
		levers = {},
		sparksByZone = {},
		windEmitters = {},
		ramps = {},
		highlights = {},
		zoneParts = {},
		first = true,
	}
	session = s
	local theme = Palette.get(level.theme or "classic")
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			if d:HasTag("RN_Zone") then
				local id = d:GetAttribute("ZoneId")
				local kind = d:GetAttribute("ZoneKind")
				if type(id) == "string" then
					s.zoneParts[id] = d
				end
				if kind == "basin" then
					buildBasin(s, d)
				elseif kind == "fire" then
					buildFire(s, d)
				elseif kind == "vine" then
					buildVine(s, d)
				end
			elseif d:HasTag("RN_Plate") then
				setupPlate(s, d)
			elseif d:HasTag("RN_Lever") then
				setupLever(s, d)
			elseif d:HasTag("RN_CableSpark") then
				setupCableSpark(s, d)
			elseif d:HasTag("RN_Key") then
				buildKey(s, d)
			elseif d:HasTag("RN_Crate") then
				setupCrate(s, d)
			elseif d:HasTag("RN_LaunchRamp") then
				table.insert(s.ramps, d)
			end
		end
	end
	if type(level.carts) == "table" then
		for id, info in level.carts do
			buildCart(s, id, info, theme)
		end
	end
	-- Initial state without transition sounds, then live updates.
	applyZones(s, ClientState.get("global", "zones"), true)
	updateKeys(s, ClientState.get("global", "keys"), true)
	refreshWind(s)
	s.trove:Add(ClientState.observe("global", "zones", function(zones: any)
		if session == s then
			applyZones(s, zones, false)
		end
	end))
	s.trove:Add(ClientState.observe("global", "keys", function(keys: any)
		if session == s then
			updateKeys(s, keys, false)
		end
	end))
	s.trove:Add(ClientState.observe("global", "sockets", function()
		if session == s then
			refreshWind(s)
		end
	end))
	s.trove:Connect(RunService.Heartbeat, function(dt: number)
		-- Players waiting in the lobby do not see the wing: no per-frame work for them.
		if not RunInfo.isParticipant() then
			return
		end
		local now = serverNow()
		local clock = os.clock()
		for _, vis in s.basins do
			renderBasin(vis, clock)
		end
		for _, vis in s.fires do
			renderFire(vis, clock)
		end
		for _, vis in s.vines do
			renderVine(vis, clock)
		end
		for _, key in s.keys do
			renderKey(key, clock)
		end
		renderCarts(s, now)
		renderCrates(s, dt)
		renderRamps(s, clock)
	end)
end

function ZoneVisuals.start()
	RunInfo.LevelChanged:Connect(function(level: any)
		if level then
			task.spawn(build, level)
		else
			teardown()
		end
	end)
	if RunInfo.level() then
		task.spawn(build, RunInfo.level())
	end
	-- If the level model is removed before the state clears (teardown order), drop visuals with it.
	CollectionService:GetInstanceRemovedSignal("RN_Zone"):Connect(function()
		local s = session
		if s and s.model.Parent == nil then
			teardown()
		end
	end)
end

return ZoneVisuals
