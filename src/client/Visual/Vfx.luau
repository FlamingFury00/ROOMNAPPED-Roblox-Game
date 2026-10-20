--!strict
--[[
	Vfx: particle presets and one-shot effects built only from engine-bundled textures
	(content/textures/particles/* and content/textures/*.png ship inside every Roblox client, so they always
	load, cost no upload and need no moderation).

	* Vfx.emitter(parent, preset, overrides?) - a configured, continuously emitting ParticleEmitter.
	* Vfx.burst(position, preset, count, overrides?) - fire-and-forget burst at a world position.
	* Vfx.ring(position, color, radius, seconds) - expanding shockwave disc.
	* Vfx.flash(position, color, brightness, range, seconds) - short light flash.

	Low Effects mode scales emission down (S29, A12) instead of removing feedback entirely, so information
	conveyed by an effect is never lost - only its density.
]]

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

local lowEffects = false

function Vfx.setLowEffects(value: boolean)
	lowEffects = value
end

function Vfx.isLowEffects(): boolean
	return lowEffects
end

local function densityScale(): number
	return if lowEffects then GameConfig.Performance.LowEffectsParticleScale else 1
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
		Texture = Vfx.Textures.fire,
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
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-60, 60),
		ZOffset = 0.5,
	},
	embers = {
		Texture = Vfx.Textures.fireSparks,
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
		Texture = Vfx.Textures.smoke,
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
		Texture = Vfx.Textures.smoke,
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
		Texture = Vfx.Textures.sparkles,
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
		Texture = Vfx.Textures.smoke,
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
		Texture = Vfx.Textures.star,
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
		Texture = Vfx.Textures.fireSparks,
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
		Texture = Vfx.Textures.vortex,
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
		Texture = Vfx.Textures.square,
		Color = colors(Color3.fromRGB(120, 210, 90), Color3.fromRGB(60, 150, 60)),
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
		Texture = Vfx.Textures.smoke,
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
		Texture = Vfx.Textures.star,
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
		Texture = Vfx.Textures.puff,
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
		Texture = Vfx.Textures.square,
		Color = colors(Color3.fromRGB(235, 250, 255)),
		LightEmission = 0.6,
		LightInfluence = 0,
		Size = seq(0.08, 0.12, 0.05),
		Squash = seq(-2.6),
		Transparency = seq(1, 0.55, 0.55, 1),
		Lifetime = NumberRange.new(0.5, 0.9),
		Rate = 26,
		Speed = NumberRange.new(26, 36),
		SpreadAngle = Vector2.new(3, 3),
		Orientation = Enum.ParticleOrientation.VelocityParallel,
		LockedToPart = false,
	},
	glowOrb = {
		Texture = Vfx.Textures.glow,
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
}

-- Create a configured emitter. `Rate` is scaled by the Low Effects setting at creation time.
function Vfx.emitter(parent: Instance, preset: string, overrides: { [string]: any }?): ParticleEmitter
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "Vfx_" .. preset
	local config = PRESETS[preset] or PRESETS.magic
	for key, value in config do
		(emitter :: any)[key] = value
	end
	if overrides then
		for key, value in overrides do
			(emitter :: any)[key] = value
		end
	end
	if not config.Rate and not (overrides and overrides.Rate) then
		emitter.Rate = 0
	end
	emitter.Rate *= densityScale()
	emitter.Parent = parent
	return emitter
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
