--!strict
--[[
	Vfx: particle presets and one-shot effects.

	Presets draw on curated free Creator Store particle images (flipbook flames and cartoon smoke,
	snowflakes, sparks, leaves, wind streaks ...; docs/CONTENT_OWNERSHIP.md). Each has an engine-bundled
	fallback (content/textures/particles/*, shipped inside every client): Vfx.preload checks the curated
	images at startup and any that fail to load are swapped for their fallbacks in every later emitter.

	* Vfx.emitter(parent, preset, overrides?) - a configured, continuously emitting ParticleEmitter.
	* Vfx.burst(position, preset, count, overrides?) - fire-and-forget burst at a world position.
	* Vfx.ring(position, color, radius, seconds) - expanding shockwave disc.
	* Vfx.flash(position, color, brightness, range, seconds) - short light flash.

	Low Effects mode scales emission down (S29, A12) instead of removing feedback entirely, so information
	conveyed by an effect is never lost - only its density. Continuous emitters remember their full rate, so
	switching the mode rescales the ones already in the world.
]]

local ContentProvider = game:GetService("ContentProvider")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)

local Vfx = {}

Vfx.Textures = {
	sparkles = "rbxasset://textures/particles/sparkles_main.dds",
	fire = "rbxasset://textures/particles/fire_main.dds",
	fireSparks = "rbxasset://textures/particles/fire_sparks_main.dds",
	smoke = "rbxasset://textures/particles/smoke_main.dds",
	explosionCore = "rbxasset://textures/particles/explosion01_core_main.dds",
	implosion = "rbxasset://textures/particles/explosion01_implosion_main.dds",
	shockwave = "rbxasset://textures/particles/explosion01_shockwave_main.dds",
	puff = "rbxasset://textures/particles/explosion01_smoke_main.dds",
	glow = "rbxasset://textures/particles/forcefield_glow_main.dds",
	vortex = "rbxasset://textures/particles/forcefield_vortex_main.dds",
	square = "rbxasset://textures/particles/SquareParticle.png",
	star = "rbxasset://textures/sparkle.png",
	softGlow = "rbxasset://textures/glow.png",
	circle = "rbxasset://textures/whiteCircle.png",
}

export type Curated = {
	id: string,
	fallback: string,
	flipbook: Enum.ParticleFlipbookLayout?,
	failed: boolean,
}

local function curated(id: number, fallback: string, flipbook: Enum.ParticleFlipbookLayout?): Curated
	return { id = "rbxassetid://" .. tostring(id), fallback = fallback, flipbook = flipbook, failed = false }
end

-- Image asset ids (A10), each with the engine texture used if it cannot load.
Vfx.Curated = {
	smokePuff = curated(716847870, Vfx.Textures.smoke),
	cartoonSmoke = curated(11632052078, Vfx.Textures.puff, Enum.ParticleFlipbookLayout.Grid8x8),
	flame = curated(12360893247, Vfx.Textures.fire, Enum.ParticleFlipbookLayout.Grid4x4),
	ember = curated(133927008003451, Vfx.Textures.fireSparks),
	spark = curated(11469784323, Vfx.Textures.fireSparks),
	droplet = curated(113689065664958, Vfx.Textures.sparkles),
	snowflake = curated(137831468, Vfx.Textures.star),
	star = curated(81834701835654, Vfx.Textures.star),
	glow = curated(12820082481, Vfx.Textures.glow),
	leaf = curated(14873729766, Vfx.Textures.square),
	windStreak = curated(125456829699116, Vfx.Textures.square),
	bolt = curated(7151778302, Vfx.Textures.vortex),
	bubble = curated(131012657102345, Vfx.Textures.circle),
	heart = curated(264486777, Vfx.Textures.star),
	coin = curated(87971732430791, Vfx.Textures.star),
	swirl = curated(17386861497, Vfx.Textures.vortex),
	shard = curated(124108901053016, Vfx.Textures.star),
} :: { [string]: Curated }

local lowEffects = false
-- Continuous emitters and their full-density rate. A strong table: the engine may collect an Instance's Lua
-- object while the emitter lives on, which would drop it from a weak one. Destroyed emitters are swept out.
local tracked: { [ParticleEmitter]: number } = {}
local addedSinceSweep = 0
local SWEEP_EVERY = 100

local function sweepTracked()
	for emitter in tracked do
		if emitter.Parent == nil then
			tracked[emitter] = nil
		end
	end
end

local function densityScale(): number
	return if lowEffects then GameConfig.Performance.LowEffectsParticleScale else 1
end

function Vfx.setLowEffects(value: boolean)
	if value == lowEffects then
		return
	end
	lowEffects = value
	local scale = densityScale()
	for emitter, rate in tracked do
		if emitter.Parent then
			emitter.Rate = rate * scale
		else
			tracked[emitter] = nil
		end
	end
end

function Vfx.isLowEffects(): boolean
	return lowEffects
end

-- Change a continuous emitter's full-density rate (scaled for Low Effects now and on later changes).
function Vfx.setRate(emitter: ParticleEmitter, rate: number)
	if tracked[emitter] == nil then
		addedSinceSweep += 1
		if addedSinceSweep >= SWEEP_EVERY then
			addedSinceSweep = 0
			sweepTracked()
		end
	end
	tracked[emitter] = rate
	emitter.Rate = rate * densityScale()
end

local function seq(...: number): NumberSequence
	local values = { ... }
	if #values == 1 then
		return NumberSequence.new(values[1])
	end
	local keypoints = {}
	for i, v in values do
		table.insert(keypoints, NumberSequenceKeypoint.new((i - 1) / (#values - 1), v))
	end
	return NumberSequence.new(keypoints)
end

local function colors(...: Color3): ColorSequence
	local values = { ... }
	if #values == 1 then
		return ColorSequence.new(values[1])
	end
	local keypoints = {}
	for i, c in values do
		table.insert(keypoints, ColorSequenceKeypoint.new((i - 1) / (#values - 1), c))
	end
	return ColorSequence.new(keypoints)
end

Vfx.seq = seq
Vfx.colors = colors

type Preset = { [string]: any }

local PRESETS: { [string]: Preset } = {
	fire = {
		Curated = "flame",
		FlipbookMode = Enum.ParticleFlipbookMode.Loop,
		FlipbookFramerate = NumberRange.new(16, 24),
		FlipbookStartRandom = true,
		Color = colors(Color3.fromRGB(255, 236, 140), Color3.fromRGB(255, 140, 40), Color3.fromRGB(200, 50, 20)),
		LightEmission = 1,
		LightInfluence = 0,
		Size = seq(2.2, 3, 0.6),
		Transparency = seq(0.6, 0.1, 1),
		Lifetime = NumberRange.new(0.5, 0.9),
		Rate = 36,
		Speed = NumberRange.new(4, 8),
		SpreadAngle = Vector2.new(12, 12),
		Acceleration = Vector3.new(0, 6, 0),
		Rotation = NumberRange.new(-10, 10),
		RotSpeed = NumberRange.new(-12, 12),
		ZOffset = 0.5,
	},
	embers = {
		Curated = "ember",
		Color = colors(Color3.fromRGB(255, 220, 120), Color3.fromRGB(255, 110, 40)),
		LightEmission = 1,
		LightInfluence = 0,
		Size = seq(0.35, 0.2, 0),
		Transparency = seq(0, 0.2, 1),
		Lifetime = NumberRange.new(0.8, 1.6),
		Rate = 10,
		Speed = NumberRange.new(5, 10),
		SpreadAngle = Vector2.new(35, 35),
		Acceleration = Vector3.new(0, 4, 0),
	},
	smoke = {
		Curated = "smokePuff",
		Color = colors(Color3.fromRGB(90, 80, 76), Color3.fromRGB(40, 36, 34)),
		LightInfluence = 0.6,
		Size = seq(2, 5, 7),
		Transparency = seq(0.7, 0.55, 1),
		Lifetime = NumberRange.new(1.8, 2.8),
		Rate = 6,
		Speed = NumberRange.new(2, 4),
		SpreadAngle = Vector2.new(20, 20),
		Acceleration = Vector3.new(0, 1.5, 0),
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-25, 25),
	},
	steam = {
		Curated = "smokePuff",
		Color = colors(Color3.fromRGB(240, 246, 250)),
		LightInfluence = 0.4,
		Size = seq(1.5, 5, 8),
		Transparency = seq(0.3, 0.5, 1),
		Lifetime = NumberRange.new(1, 1.8),
		Speed = NumberRange.new(6, 12),
		SpreadAngle = Vector2.new(60, 60),
		Acceleration = Vector3.new(0, 4, 0),
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-40, 40),
	},
	splash = {
		Curated = "droplet",
		Color = colors(Color3.fromRGB(220, 245, 255), Color3.fromRGB(120, 200, 255)),
		LightEmission = 0.4,
		Size = seq(0.6, 0.4, 0),
		Transparency = seq(0, 0.3, 1),
		Lifetime = NumberRange.new(0.6, 1),
		Speed = NumberRange.new(14, 26),
		SpreadAngle = Vector2.new(35, 35),
		Acceleration = Vector3.new(0, -60, 0),
		EmissionDirection = Enum.NormalId.Top,
	},
	mist = {
		Curated = "smokePuff",
		Color = colors(Color3.fromRGB(210, 240, 255)),
		LightInfluence = 0.3,
		LightEmission = 0.2,
		Size = seq(1.5, 4, 6),
		Transparency = seq(0.8, 0.6, 1),
		Lifetime = NumberRange.new(1.6, 2.6),
		Rate = 8,
		Speed = NumberRange.new(2, 4),
		SpreadAngle = Vector2.new(25, 25),
		Acceleration = Vector3.new(0, -0.6, 0),
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-20, 20),
	},
	frost = {
		Curated = "snowflake",
		Color = colors(Color3.fromRGB(230, 250, 255), Color3.fromRGB(150, 220, 255)),
		LightEmission = 0.8,
		LightInfluence = 0,
		Size = seq(0.25, 0.35, 0),
		Transparency = seq(0.1, 0.2, 1),
		Lifetime = NumberRange.new(1.2, 2.2),
		Rate = 10,
		Speed = NumberRange.new(1, 3),
		SpreadAngle = Vector2.new(180, 180),
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-90, 90),
	},
	sparks = {
		Curated = "spark",
		Orientation = Enum.ParticleOrientation.VelocityParallel,
		Color = colors(Color3.fromRGB(255, 255, 255), Color3.fromRGB(140, 210, 255)),
		LightEmission = 1,
		LightInfluence = 0,
		Size = seq(0.5, 0.2, 0),
		Lifetime = NumberRange.new(0.15, 0.4),
		Rate = 22,
		Speed = NumberRange.new(10, 18),
		SpreadAngle = Vector2.new(70, 70),
		Acceleration = Vector3.new(0, -30, 0),
	},
	zap = {
		Curated = "bolt",
		Color = colors(Color3.fromRGB(170, 230, 255), Color3.fromRGB(90, 160, 255)),
		LightEmission = 1,
		LightInfluence = 0,
		Size = seq(1.4, 2.4),
		Transparency = seq(0.2, 1),
		Lifetime = NumberRange.new(0.12, 0.25),
		Rate = 12,
		Speed = NumberRange.new(0, 0.5),
		Rotation = NumberRange.new(0, 360),
	},
	leaves = {
		Curated = "leaf",
		Color = colors(Color3.fromRGB(235, 255, 225), Color3.fromRGB(190, 235, 170)),
		LightInfluence = 0.8,
		Size = seq(0.35, 0.3),
		Transparency = seq(0, 0, 1),
		Lifetime = NumberRange.new(1.4, 2.4),
		Rate = 6,
		Speed = NumberRange.new(2, 5),
		SpreadAngle = Vector2.new(60, 60),
		Acceleration = Vector3.new(0, -6, 0),
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-200, 200),
	},
	confetti = {
		Texture = Vfx.Textures.square,
		Color = colors(
			Color3.fromRGB(255, 90, 120),
			Color3.fromRGB(255, 210, 70),
			Color3.fromRGB(90, 220, 140),
			Color3.fromRGB(100, 170, 255)
		),
		LightEmission = 0.3,
		Size = seq(0.45, 0.35),
		Transparency = seq(0, 0, 1),
		Lifetime = NumberRange.new(1.6, 2.6),
		Speed = NumberRange.new(18, 34),
		SpreadAngle = Vector2.new(50, 50),
		Acceleration = Vector3.new(0, -35, 0),
		Drag = 2,
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-300, 300),
		EmissionDirection = Enum.NormalId.Top,
	},
	dust = {
		Curated = "cartoonSmoke",
		FlipbookMode = Enum.ParticleFlipbookMode.OneShot,
		Color = colors(Color3.fromRGB(200, 180, 150)),
		LightInfluence = 0.8,
		Size = seq(1, 3, 4),
		Transparency = seq(0.4, 0.6, 1),
		Lifetime = NumberRange.new(0.8, 1.4),
		Speed = NumberRange.new(6, 10),
		SpreadAngle = Vector2.new(80, 10),
		Acceleration = Vector3.new(0, 1, 0),
		Drag = 4,
		Rotation = NumberRange.new(0, 360),
	},
	magic = {
		Curated = "star",
		Color = colors(Color3.fromRGB(255, 250, 200), Color3.fromRGB(255, 200, 70)),
		LightEmission = 1,
		LightInfluence = 0,
		Size = seq(0.6, 0.9, 0),
		Transparency = seq(0, 0.2, 1),
		Lifetime = NumberRange.new(0.6, 1.2),
		Speed = NumberRange.new(4, 10),
		SpreadAngle = Vector2.new(180, 180),
		Drag = 3,
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-180, 180),
	},
	poof = {
		Curated = "cartoonSmoke",
		FlipbookMode = Enum.ParticleFlipbookMode.OneShot,
		Color = colors(Color3.fromRGB(255, 255, 255), Color3.fromRGB(230, 220, 240)),
		LightInfluence = 0.5,
		LightEmission = 0.2,
		Size = seq(2, 6, 8),
		Transparency = seq(0.2, 0.6, 1),
		Lifetime = NumberRange.new(0.5, 0.9),
		Speed = NumberRange.new(6, 12),
		SpreadAngle = Vector2.new(180, 180),
		Drag = 5,
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-60, 60),
	},
	wind = {
		-- A soft horizontal streak, turned a quarter so it lies along the velocity.
		Curated = "windStreak",
		Rotation = NumberRange.new(90, 90),
		Color = colors(Color3.fromRGB(235, 250, 255)),
		LightEmission = 0.6,
		LightInfluence = 0,
		Size = seq(0.9, 1.6, 0.8),
		Transparency = seq(1, 0.55, 0.55, 1),
		Lifetime = NumberRange.new(0.5, 0.9),
		Rate = 26,
		Speed = NumberRange.new(26, 36),
		SpreadAngle = Vector2.new(3, 3),
		Orientation = Enum.ParticleOrientation.VelocityParallel,
		LockedToPart = false,
	},
	glowOrb = {
		Curated = "glow",
		Color = colors(Color3.fromRGB(255, 220, 120)),
		LightEmission = 1,
		LightInfluence = 0,
		Size = seq(2.4, 3),
		Transparency = seq(0.5, 0.7, 1),
		Lifetime = NumberRange.new(0.4, 0.6),
		Rate = 8,
		Speed = NumberRange.new(0, 0),
		LockedToPart = true,
	},
	bubbles = {
		Curated = "bubble",
		Color = colors(Color3.fromRGB(255, 255, 255)),
		LightEmission = 0.3,
		LightInfluence = 0.4,
		Size = seq(0.4, 0.8, 0.9),
		Transparency = seq(0.1, 0.2, 1),
		Lifetime = NumberRange.new(1.6, 3),
		Rate = 5,
		Speed = NumberRange.new(1, 3),
		SpreadAngle = Vector2.new(50, 50),
		Acceleration = Vector3.new(0, 1.2, 0),
		Drag = 0.6,
	},
	hearts = {
		Curated = "heart",
		Color = colors(Color3.fromRGB(255, 255, 255)),
		LightEmission = 0.6,
		LightInfluence = 0,
		Size = seq(0.6, 1.1, 0),
		Transparency = seq(0, 0.1, 1),
		Lifetime = NumberRange.new(0.8, 1.4),
		Speed = NumberRange.new(4, 9),
		SpreadAngle = Vector2.new(60, 60),
		Acceleration = Vector3.new(0, 3, 0),
		Drag = 2,
		Rotation = NumberRange.new(-20, 20),
		EmissionDirection = Enum.NormalId.Top,
	},
	coins = {
		Curated = "coin",
		Color = colors(Color3.fromRGB(255, 255, 255)),
		LightEmission = 0.4,
		LightInfluence = 0,
		Size = seq(0.9, 0.9, 0),
		Transparency = seq(0, 0, 1),
		Lifetime = NumberRange.new(1, 1.6),
		Speed = NumberRange.new(12, 22),
		SpreadAngle = Vector2.new(45, 45),
		Acceleration = Vector3.new(0, -40, 0),
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-240, 240),
		EmissionDirection = Enum.NormalId.Top,
	},
	swirl = {
		Curated = "swirl",
		Color = colors(Color3.fromRGB(255, 236, 160), Color3.fromRGB(190, 140, 255)),
		LightEmission = 1,
		LightInfluence = 0,
		Size = seq(3, 6, 1),
		Transparency = seq(0.4, 0.2, 1),
		Lifetime = NumberRange.new(0.6, 1),
		Rate = 14,
		Speed = NumberRange.new(0, 1),
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-420, -260),
		LockedToPart = true,
	},
	shards = {
		Curated = "shard",
		Color = colors(Color3.fromRGB(235, 250, 255)),
		LightEmission = 0.5,
		LightInfluence = 0.3,
		Size = seq(0.8, 0.6, 0),
		Transparency = seq(0, 0.1, 1),
		Lifetime = NumberRange.new(0.6, 1.1),
		Speed = NumberRange.new(10, 18),
		SpreadAngle = Vector2.new(180, 180),
		Acceleration = Vector3.new(0, -40, 0),
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-300, 300),
	},
}

-- Create a configured emitter. `Rate` is scaled by the Low Effects setting at creation time.
function Vfx.emitter(parent: Instance, preset: string, overrides: { [string]: any }?): ParticleEmitter
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "Vfx_" .. preset
	local config = PRESETS[preset] or PRESETS.magic
	for key, value in config do
		if key == "Curated" then
			local image = Vfx.Curated[value]
			if image and not image.failed then
				emitter.Texture = image.id
				if image.flipbook then
					emitter.FlipbookLayout = image.flipbook
				end
			elseif image then
				emitter.Texture = image.fallback
			end
		elseif string.sub(key, 1, 8) ~= "Flipbook" then
			(emitter :: any)[key] = value
		end
	end
	-- Flipbook timing only means something on a flipbook texture.
	if emitter.FlipbookLayout ~= Enum.ParticleFlipbookLayout.None then
		for key, value in config do
			if string.sub(key, 1, 8) == "Flipbook" then
				(emitter :: any)[key] = value
			end
		end
	end
	if overrides then
		for key, value in overrides do
			(emitter :: any)[key] = value
		end
	end
	if not config.Rate and not (overrides and overrides.Rate) then
		emitter.Rate = 0
	end
	if emitter.Rate > 0 then
		Vfx.setRate(emitter, emitter.Rate)
	end
	emitter.Parent = parent
	return emitter
end

-- Check the curated images once (client start); any that cannot load fall back to engine textures from then on.
function Vfx.preload()
	local ids: { string } = {}
	local byId: { [string]: Curated } = {}
	for _, image in Vfx.Curated do
		table.insert(ids, image.id)
		byId[image.id] = image
	end
	pcall(function()
		ContentProvider:PreloadAsync(ids, function(contentId: string, status: Enum.AssetFetchStatus)
			local image = byId[contentId]
			if image and status ~= Enum.AssetFetchStatus.Success then
				image.failed = true
			end
		end)
	end)
end

-- Fire-and-forget burst at a world position.
function Vfx.burst(position: Vector3, preset: string, count: number, overrides: { [string]: any }?)
	local attachment = Instance.new("Attachment")
	attachment.Name = "VfxBurst"
	attachment.WorldPosition = position
	attachment.Parent = Workspace.Terrain
	local o: { [string]: any } = if overrides then table.clone(overrides) else {}
	o.Rate = 0
	local emitter = Vfx.emitter(attachment, preset, o)
	local n = math.max(1, math.floor(count * densityScale() + 0.5))
	emitter:Emit(n)
	Debris:AddItem(attachment, emitter.Lifetime.Max + 0.5)
end

-- Expanding neon disc lying flat (shockwave / landing / room pop).
function Vfx.ring(position: Vector3, color: Color3, radius: number, seconds: number?)
	local duration = seconds or 0.45
	local part = Instance.new("Part")
	part.Name = "VfxRing"
	part.Shape = Enum.PartType.Cylinder
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = color
	part.Transparency = 0.25
	part.Size = Vector3.new(0.12, 1, 1)
	part.CFrame = CFrame.new(position) * CFrame.Angles(0, 0, math.rad(90))
	part.Parent = Workspace.Terrain
	local tween = TweenService:Create(
		part,
		TweenInfo.new(duration, Enum.EasingStyle.Quart, Enum.EasingDirection.Out),
		{ Size = Vector3.new(0.12, radius * 2, radius * 2), Transparency = 1 }
	)
	tween:Play()
	Debris:AddItem(part, duration + 0.1)
end

-- Short light flash (does not cast shadows, so it is cheap on every device).
function Vfx.flash(position: Vector3, color: Color3, brightness: number, range: number, seconds: number?)
	local duration = seconds or 0.35
	local attachment = Instance.new("Attachment")
	attachment.WorldPosition = position
	attachment.Parent = Workspace.Terrain
	local light = Instance.new("PointLight")
	light.Color = color
	light.Brightness = brightness
	light.Range = range
	light.Shadows = false
	light.Parent = attachment
	TweenService:Create(light, TweenInfo.new(duration, Enum.EasingStyle.Quad), { Brightness = 0 }):Play()
	Debris:AddItem(attachment, duration + 0.1)
end

return Vfx
