--!strict
--[[
	Props: hand-tuned decorative props built from primitives (A01 hotel kit).

	Every prop takes a world CFrame `cf` whose position is the prop's base (floor contact or wall mount
	point) and whose LookVector faces the viewer (away from the wall, into the corridor). Props are pure
	decoration: no collision, no queries, and only the bigger pieces cast shadows.
]]

local Kit = require(script.Parent.Kit)
local Palette = require(script.Parent.Palette)
local Assets = require(script.Parent.Assets)
local Artwork = require(script.Parent.Parent.Content.Artwork)

type Theme = Palette.Theme
type Rng = () -> number

local Props = {}

local decor = Kit.decor
local M = Enum.Material
local FONT_SERIF = Font.new("rbxasset://fonts/families/Fondamento.json", Enum.FontWeight.Bold)
local FONT_SIGN = Font.new("rbxasset://fonts/families/FredokaOne.json", Enum.FontWeight.Bold)

local function at(cf: CFrame, x: number, y: number, z: number): CFrame
	-- Local offsets: x right, y up, z toward the viewer (out of the wall).
	return cf * CFrame.new(x, y, -z)
end

local function pick<T>(rng: Rng, list: { T }): T
	return list[math.clamp(math.floor(rng() * #list) + 1, 1, #list)]
end

-- A private generator for a fallback prop, drawn from `rng` once, so a level's decoration (which walls get
-- doors, where props stand) is the same whether a slot ends up holding a real model or its fallback.
local function subRng(rng: Rng): Rng
	local state = math.floor(rng() * 2147483645) + 1
	return function(): number
		state = (state * 16807) % 2147483647
		return state / 2147483647
	end
end

-- Variant index for an asset slot (stable per prop).
local function variantOf(rng: Rng): number
	return math.floor(rng() * 64) + 1
end

-- Lighting --------------------------------------------------------------------------------------------
-- Every light fixture is an asset slot (a curated model or the procedural fixture) plus a light rig kept
-- outside the slot, so swapping the model in never removes a light. Rig parts carry the RN_Lamp tag the
-- client uses for flicker and the escape alarm.

local function lightRig(parent: Instance, name: string, cf: CFrame): Part
	local rig = Kit.part(parent, {
		name = name,
		cf = cf,
		size = Vector3.new(0.3, 0.3, 0.3),
		transparency = 1,
		shadow = false,
	})
	rig:AddTag("RN_Lamp")
	return rig
end

function Props.wallSconce(parent: Instance, cf: CFrame, theme: Theme, light: boolean?, shadows: boolean?): Part
	local slot = Assets.place(parent, "wallSconce", cf, function(model: Model, at0: CFrame)
		decor(model, "Plate", at(at0, 0, -0.3, 0.06), Vector3.new(0.7, 1.4, 0.12), theme.brass, M.Foil)
		decor(model, "Arm", at(at0, 0, -0.45, 0.45), Vector3.new(0.16, 0.16, 0.8), theme.brass, M.Foil)
		Kit.cylinder(model, {
			name = "Cup",
			cf = at(at0, 0, -0.32, 0.85) * CFrame.Angles(0, 0, math.pi / 2),
			size = Vector3.new(0.3, 0.55, 0.55),
			color = theme.brass,
			material = M.Foil,
		})
		local shade = Kit.cylinder(model, {
			name = "Shade",
			cf = at(at0, 0, 0.3, 0.85) * CFrame.Angles(0, 0, math.pi / 2),
			size = Vector3.new(1.05, 0.95, 0.95),
			color = Color3.fromRGB(255, 226, 180),
			material = M.Fabric,
		})
		shade.Transparency = 0.12
		local bulb = Kit.ball(model, {
			name = "Bulb",
			cf = at(at0, 0, 0.18, 0.85),
			size = Vector3.new(0.42, 0.42, 0.42),
			color = theme.lamp,
			material = M.Neon,
		})
		bulb.CastShadow = false
	end)
	local _ = slot
	local rig = lightRig(parent, "SconceLight", at(cf, 0, 0.2, 0.9))
	if light ~= false then
		local l = Kit.pointLight(rig, theme.lamp, theme.lampBrightness * 0.7, 12, shadows)
		l.Name = "Light"
	end
	return rig
end

function Props.ceilingLamp(parent: Instance, cf: CFrame, theme: Theme, shadows: boolean?): Part
	-- `cf` is the ceiling mount point; the lamp hangs down. A downward spot pools light on the carpet and a
	-- soft point light makes the fixture glow.
	Assets.place(parent, "ceilingLamp", cf, function(model: Model, mount: CFrame)
		decor(model, "Canopy", mount * CFrame.new(0, -0.12, 0), Vector3.new(0.9, 0.24, 0.9), theme.brass, M.Foil)
		decor(model, "Rod", mount * CFrame.new(0, -0.9, 0), Vector3.new(0.14, 1.5, 0.14), theme.brass, M.Foil)
		Kit.cylinder(model, {
			name = "Shade",
			cf = mount * CFrame.new(0, -1.95, 0) * CFrame.Angles(0, 0, math.pi / 2),
			size = Vector3.new(0.85, 2.4, 2.4),
			color = Color3.fromRGB(250, 228, 190),
			material = M.Fabric,
			shadow = false,
		})
		Kit.cylinder(model, {
			name = "Band",
			cf = mount * CFrame.new(0, -2.36, 0) * CFrame.Angles(0, 0, math.pi / 2),
			size = Vector3.new(0.12, 2.46, 2.46),
			color = theme.brass,
			material = M.Foil,
			shadow = false,
		})
		local bulb = Kit.ball(model, {
			name = "Bulb",
			cf = mount * CFrame.new(0, -2.3, 0),
			size = Vector3.new(0.8, 0.8, 0.8),
			color = theme.lamp,
			material = M.Neon,
		})
		bulb.CastShadow = false
	end)
	local rig = lightRig(parent, "CeilingLight", cf * CFrame.new(0, -2.6, 0))
	local spot = Kit.spotLight(rig, theme.lamp, theme.lampBrightness * 1.5, 20, 120, Enum.NormalId.Bottom, shadows)
	spot.Name = "Light"
	local glow = Kit.pointLight(rig, theme.lamp, theme.lampBrightness * 0.45, 10, false)
	glow.Name = "Glow"
	return rig
end

local function buildChandelier(parent: Instance, cf: CFrame, theme: Theme, scale: number?): Part
	local s = scale or 1
	local model = Kit.model(parent, "Chandelier")
	decor(model, "Chain", cf * CFrame.new(0, -1.5 * s, 0), Vector3.new(0.2, 3 * s, 0.2), theme.brass, M.Metal)
	Kit.cylinder(model, {
		name = "Ring",
		cf = cf * CFrame.new(0, -3.2 * s, 0) * CFrame.Angles(0, 0, math.pi / 2),
		size = Vector3.new(0.4 * s, 5 * s, 5 * s),
		color = theme.brass,
		material = M.Foil,
	})
	local center = Kit.ball(model, {
		name = "Bulb",
		cf = cf * CFrame.new(0, -3.4 * s, 0),
		size = Vector3.new(1.4, 1.4, 1.4) * s,
		color = theme.lamp,
		material = M.Neon,
	})
	for i = 0, 7 do
		local angle = i / 8 * math.pi * 2
		local p = cf * CFrame.new(math.cos(angle) * 2.4 * s, -2.9 * s, math.sin(angle) * 2.4 * s)
		decor(model, "Candle", p, Vector3.new(0.3, 0.8, 0.3) * s, Color3.fromRGB(250, 244, 230), M.SmoothPlastic)
		Kit.ball(model, {
			name = "Flame",
			cf = p * CFrame.new(0, 0.6 * s, 0),
			size = Vector3.new(0.32, 0.45, 0.32) * s,
			color = theme.lamp,
			material = M.Neon,
		})
		decor(
			model,
			"Crystal",
			p * CFrame.new(0, -0.9 * s, 0),
			Vector3.new(0.25, 0.7, 0.25) * s,
			Color3.fromRGB(230, 245, 255),
			M.Glass
		)
	end
	return center
end

-- A grand chandelier hanging from `cf` (the ceiling mount); its light rig stays outside the asset slot.
function Props.chandelier(parent: Instance, cf: CFrame, theme: Theme, scale: number?): Part
	local s = scale or 1
	Assets.place(parent, "chandelier", cf, function(slot: Model, mount: CFrame)
		buildChandelier(slot, mount, theme, s)
	end, { scale = s })
	local rig = lightRig(parent, "ChandelierLight", cf * CFrame.new(0, -3.4 * s, 0))
	local light = Kit.pointLight(rig, theme.lamp, theme.lampBrightness * 1.4, 34, true)
	light.Name = "Light"
	local fill = Kit.spotLight(rig, theme.lamp, theme.lampBrightness * 0.9, 30, 140, Enum.NormalId.Bottom, false)
	fill.Name = "Fill"
	return rig
end

-- Wall decoration -----------------------------------------------------------------------------------

local PAINTING_SCENES = {
	{ Color3.fromRGB(110, 160, 210), Color3.fromRGB(70, 130, 80), Color3.fromRGB(250, 230, 150) }, -- landscape
	{ Color3.fromRGB(40, 40, 70), Color3.fromRGB(30, 30, 40), Color3.fromRGB(250, 250, 210) }, -- night sea
	{ Color3.fromRGB(210, 120, 90), Color3.fromRGB(120, 60, 50), Color3.fromRGB(255, 210, 120) }, -- sunset
	{ Color3.fromRGB(60, 50, 70), Color3.fromRGB(90, 40, 50), Color3.fromRGB(255, 240, 160) }, -- portrait
	{ Color3.fromRGB(180, 200, 190), Color3.fromRGB(60, 110, 100), Color3.fromRGB(240, 120, 120) }, -- garden
}

-- A framed painting: a classic artwork (Content/Artwork) in a gilded frame, or a procedural scene when no
-- artwork fits. `cf` = the frame's centre on the wall, facing out.
function Props.painting(parent: Instance, cf: CFrame, theme: Theme, rng: Rng, width: number?, height: number?)
	local w, h = width or 4, height or 3
	local roll = rng()
	local sceneRng = subRng(rng)
	-- The frame takes the painting's shape (fitted inside the space it was given), so art never stretches.
	local art = Artwork.pick(roll, w / h)
	if art then
		if art.aspect > w / h then
			h = w / art.aspect
		else
			w = h * art.aspect
		end
	end
	local model = Kit.model(parent, "Painting")
	-- Gilded frame: four mitred-looking bars around a dark backing, with an inner lip.
	local border = 0.32
	local gold = theme.brass
	decor(model, "Backing", at(cf, 0, 0, 0.06), Vector3.new(w + 0.1, h + 0.1, 0.12), Color3.fromRGB(26, 20, 18))
	for _, side in { -1, 1 } do
		decor(
			model,
			"FrameV",
			at(cf, side * (w / 2 + border / 2), 0, 0.17),
			Vector3.new(border, h + border * 2, 0.34),
			gold,
			M.Foil
		)
		decor(model, "FrameH", at(cf, 0, side * (h / 2 + border / 2), 0.17), Vector3.new(w, border, 0.34), gold, M.Foil)
		decor(
			model,
			"LipV",
			at(cf, side * (w / 2 - 0.05), 0, 0.15),
			Vector3.new(0.1, h, 0.08),
			gold:Lerp(Color3.new(0, 0, 0), 0.25),
			M.Foil
		)
		decor(
			model,
			"LipH",
			at(cf, 0, side * (h / 2 - 0.05), 0.15),
			Vector3.new(w, 0.1, 0.08),
			gold:Lerp(Color3.new(0, 0, 0), 0.25),
			M.Foil
		)
	end
	if art then
		local canvas =
			decor(model, "Canvas", at(cf, 0, 0, 0.14), Vector3.new(w - 0.1, h - 0.1, 0.04), Color3.new(1, 1, 1))
		local decal = Instance.new("Decal")
		decal.Name = "Art"
		decal.Face = Enum.NormalId.Front
		decal.Texture = "rbxassetid://" .. tostring(art.image)
		decal.Parent = canvas
		return
	end
	local scene = pick(sceneRng, PAINTING_SCENES)
	decor(
		model,
		"Sky",
		at(cf, 0, h * 0.18, 0.14),
		Vector3.new(w - 0.1, h * 0.64 - 0.05, 0.04),
		scene[1],
		M.SmoothPlastic
	)
	decor(
		model,
		"Ground",
		at(cf, 0, -h * 0.32 + 0.03, 0.14),
		Vector3.new(w - 0.1, h * 0.36 - 0.05, 0.04),
		scene[2],
		M.SmoothPlastic
	)
	local variant = sceneRng()
	if variant < 0.33 then
		-- A glowing moon / sun.
		Kit.cylinder(model, {
			name = "Orb",
			cf = at(cf, w * 0.22, h * 0.2, 0.17) * CFrame.Angles(0, math.pi / 2, 0),
			size = Vector3.new(0.03, h * 0.3, h * 0.3),
			color = scene[3],
			material = M.Neon,
		})
	elseif variant < 0.66 then
		-- A tiny hotel silhouette with one lit window.
		decor(
			model,
			"Hotel",
			at(cf, -w * 0.15, -h * 0.05, 0.17),
			Vector3.new(w * 0.3, h * 0.42, 0.03),
			Color3.fromRGB(30, 26, 32)
		)
		decor(
			model,
			"Window",
			at(cf, -w * 0.15, h * 0.02, 0.19),
			Vector3.new(w * 0.06, h * 0.08, 0.02),
			scene[3],
			M.Neon
		)
	else
		-- Portrait silhouette: a suspicious bellhop (a flat disc for the head).
		Kit.cylinder(model, {
			name = "Head",
			cf = at(cf, 0, h * 0.08, 0.17) * CFrame.Angles(0, math.pi / 2, 0),
			size = Vector3.new(0.03, h * 0.3, h * 0.3),
			color = Color3.fromRGB(26, 22, 30),
		})
		decor(
			model,
			"Cap",
			at(cf, 0, h * 0.26, 0.18),
			Vector3.new(h * 0.28, h * 0.1, 0.03),
			Color3.fromRGB(150, 30, 40)
		)
		decor(model, "EyeL", at(cf, -h * 0.05, h * 0.1, 0.19), Vector3.new(h * 0.05, h * 0.03, 0.02), scene[3], M.Neon)
		decor(model, "EyeR", at(cf, h * 0.05, h * 0.1, 0.19), Vector3.new(h * 0.05, h * 0.03, 0.02), scene[3], M.Neon)
	end
end

function Props.mirror(parent: Instance, cf: CFrame, theme: Theme)
	Assets.place(parent, "mirror", cf, function(slot: Model, at0: CFrame)
		Props.mirrorFallback(slot, at0, theme)
	end)
end

function Props.mirrorFallback(parent: Instance, cf: CFrame, theme: Theme)
	local model = Kit.model(parent, "Mirror")
	decor(model, "Frame", at(cf, 0, 0, 0.1), Vector3.new(3.4, 4.6, 0.2), theme.brass, M.Foil)
	local glass =
		decor(model, "Glass", at(cf, 0, 0, 0.21), Vector3.new(3, 4.2, 0.05), Color3.fromRGB(200, 220, 230), M.Glass)
	glass.Reflectance = 0.45
end

function Props.wallClock(parent: Instance, cf: CFrame, theme: Theme)
	Assets.place(parent, "wallClock", cf, function(slot: Model, at0: CFrame)
		Props.wallClockFallback(slot, at0, theme)
	end)
end

function Props.wallClockFallback(parent: Instance, cf: CFrame, theme: Theme)
	local model = Kit.model(parent, "Clock")
	Kit.cylinder(model, {
		name = "Rim",
		cf = at(cf, 0, 0, 0.12) * CFrame.Angles(0, math.pi / 2, 0),
		size = Vector3.new(0.24, 2.2, 2.2),
		color = theme.brass,
		material = M.Foil,
	})
	Kit.cylinder(model, {
		name = "Face",
		cf = at(cf, 0, 0, 0.25) * CFrame.Angles(0, math.pi / 2, 0),
		size = Vector3.new(0.04, 1.9, 1.9),
		color = Color3.fromRGB(246, 238, 220),
	})
	decor(
		model,
		"HourHand",
		at(cf, 0.18, 0.18, 0.3) * CFrame.Angles(0, 0, -math.pi / 4),
		Vector3.new(0.08, 0.6, 0.03),
		Color3.fromRGB(20, 20, 20)
	)
	decor(model, "MinuteHand", at(cf, 0, 0.38, 0.31), Vector3.new(0.06, 0.8, 0.03), Color3.fromRGB(20, 20, 20))
end

function Props.exitSign(parent: Instance, cf: CFrame, arrow: string)
	local model = Kit.model(parent, "ExitSign")
	local plate =
		decor(model, "Plate", at(cf, 0, 0, 0.12), Vector3.new(2.6, 0.9, 0.18), Color3.fromRGB(20, 120, 60), M.Neon)
	plate.Transparency = 0.1
	Kit.surfaceText(plate, {
		face = Enum.NormalId.Front,
		text = if arrow == "left"
			then "◀ EXIT"
			elseif arrow == "right" then "EXIT ▶"
			elseif arrow == "back" then "▼ EXIT"
			else "EXIT ▲",
		color = Color3.fromRGB(235, 255, 240),
		font = FONT_SIGN,
		lightInfluence = 0,
		brightness = 2,
	})
	plate:AddTag("RN_ExitSign")
end

function Props.roomNumber(parent: Instance, cf: CFrame, theme: Theme, number: string)
	local plaque = decor(parent, "Number", at(cf, 0, 0, 0.06), Vector3.new(1.3, 0.55, 0.08), theme.brass, M.Foil)
	Kit.surfaceText(plaque, {
		face = Enum.NormalId.Front,
		text = number,
		color = Color3.fromRGB(40, 28, 20),
		font = FONT_SERIF,
	})
end

-- Decorative hotel door on a wall. `cf` = bottom-centre on the wall's inner face. The wall's lower trim
-- leaves a gap of 6.1 studs for it (LevelBuilder DOOR_GAP): casing with plinth blocks, a head and cornice,
-- a four-panel slab with brass knob, kick plate, number plaque and peephole.
function Props.decorDoor(parent: Instance, cf: CFrame, theme: Theme, number: string, rng: Rng)
	local model = Kit.model(parent, "Door")
	local w, h = 5, 8.6
	local casing = theme.doorFrame
	local slabColor = theme.door
	local panelColor = theme.door:Lerp(Color3.new(0, 0, 0), 0.14)
	local raise = theme.door:Lerp(Color3.new(1, 1, 1), 0.06)
	local trim = theme.trimMaterial
	local function piece(
		name: string,
		x: number,
		y: number,
		z: number,
		size: Vector3,
		color: Color3,
		material: Enum.Material?
	): Part
		local part = decor(model, name, at(cf, x, y, z), size, color, material or theme.doorMaterial)
		part.CastShadow = false
		return part
	end
	-- Slab, flush with the wall.
	piece("Slab", 0, h / 2, 0.06, Vector3.new(w, h, 0.12), slabColor)
	-- Four sunk panels with raised fields.
	for _, column in { -1, 1 } do
		for row, spec in { { 1.15, 3.2 }, { 4.85, 7.75 } } do
			local y0, y1 = spec[1], spec[2]
			local px = column * (w / 4 + 0.05)
			piece("Panel" .. row, px, (y0 + y1) / 2, 0.135, Vector3.new(w / 2 - 0.75, y1 - y0, 0.03), panelColor)
			piece("Raise" .. row, px, (y0 + y1) / 2, 0.165, Vector3.new(w / 2 - 1.15, y1 - y0 - 0.4, 0.04), raise)
		end
	end
	-- Casing: jambs on plinth blocks, a head and a cornice.
	for _, side in { -1, 1 } do
		piece("Casing", side * (w / 2 + 0.27), (h + 0.55) / 2, 0.14, Vector3.new(0.54, h + 0.55, 0.28), casing, trim)
		piece("Plinth", side * (w / 2 + 0.27), 0.5, 0.17, Vector3.new(0.62, 1, 0.34), casing, trim)
	end
	piece("Head", 0, h + 0.55, 0.15, Vector3.new(w + 1.3, 0.6, 0.3), casing, trim)
	piece("Cornice", 0, h + 0.97, 0.2, Vector3.new(w + 1.7, 0.24, 0.4), casing, trim)
	-- Brass: knob on its plate, kick plate, number plaque, peephole.
	piece("KnobPlate", w / 2 - 0.62, h * 0.47, 0.135, Vector3.new(0.34, 0.9, 0.03), theme.brass, M.Foil)
	Kit.ball(model, {
		name = "Knob",
		cf = at(cf, w / 2 - 0.62, h * 0.47, 0.32),
		size = Vector3.new(0.36, 0.36, 0.36),
		color = theme.brass,
		material = M.Foil,
	})
	piece("KickPlate", 0, 0.55, 0.13, Vector3.new(w - 0.5, 0.8, 0.02), theme.brass, M.Foil)
	Kit.cylinder(model, {
		name = "Peephole",
		cf = at(cf, 0, 5.9, 0.14) * CFrame.Angles(0, math.pi / 2, 0),
		size = Vector3.new(0.06, 0.22, 0.22),
		color = theme.brass,
		material = M.Foil,
	})
	Props.roomNumber(model, at(cf, 0, 7.05, 0.12), theme, number)
	if rng() < 0.2 then
		local hanger = decor(
			model,
			"DoNotDisturb",
			at(cf, w / 2 - 0.62, h * 0.38, 0.2),
			Vector3.new(0.62, 1.3, 0.04),
			Color3.fromRGB(176, 32, 44)
		)
		Kit.surfaceText(hanger, {
			face = Enum.NormalId.Front,
			text = "SHH",
			color = Color3.new(1, 1, 1),
			font = FONT_SIGN,
		})
	end
	-- Light leaking under the door (some rooms are "occupied").
	if rng() < 0.35 then
		local glow = decor(model, "Glow", at(cf, 0, 0.03, 0.18), Vector3.new(w - 0.5, 0.06, 0.24), theme.lamp, M.Neon)
		glow.CastShadow = false
	end
end

-- Floor props ---------------------------------------------------------------------------------------

function Props.plant(parent: Instance, cf: CFrame, theme: Theme, rng: Rng, scale: number?)
	local s = scale or 1
	local variant = variantOf(rng)
	local leafRng = subRng(rng)
	Assets.place(parent, if s < 0.9 then "smallPlant" else "bigPlant", cf, function(slot: Model, at0: CFrame)
		Props.plantFallback(slot, at0, theme, leafRng, s)
	end, { variant = variant, scale = s })
end

function Props.plantFallback(parent: Instance, cf: CFrame, theme: Theme, rng: Rng, scale: number?)
	local s = scale or 1
	local model = Kit.model(parent, "Plant")
	Kit.cylinder(model, {
		name = "Pot",
		cf = cf * CFrame.new(0, 0.9 * s, 0) * CFrame.Angles(0, 0, math.pi / 2),
		size = Vector3.new(1.8 * s, 1.7 * s, 1.7 * s),
		color = theme.pot,
		material = M.Marble,
		shadow = true,
	})
	Kit.cylinder(model, {
		name = "Rim",
		cf = cf * CFrame.new(0, 1.85 * s, 0) * CFrame.Angles(0, 0, math.pi / 2),
		size = Vector3.new(0.25 * s, 1.95 * s, 1.95 * s),
		color = theme.pot:Lerp(Color3.new(1, 1, 1), 0.2),
		material = M.Marble,
	})
	decor(
		model,
		"Soil",
		cf * CFrame.new(0, 1.9 * s, 0),
		Vector3.new(1.4, 0.15, 1.4) * s,
		Color3.fromRGB(60, 40, 30),
		M.Ground
	)
	local leaves = 6 + math.floor(rng() * 4)
	for i = 1, leaves do
		local yaw = (i / leaves) * math.pi * 2 + rng() * 0.5
		local tilt = 0.5 + rng() * 0.5
		local len = (2.2 + rng() * 1.4) * s
		local leafCF = cf
			* CFrame.new(0, 2 * s, 0)
			* CFrame.Angles(0, yaw, 0)
			* CFrame.Angles(tilt, 0, 0)
			* CFrame.new(0, len / 2, 0)
		local leaf = decor(
			model,
			"Leaf",
			leafCF,
			Vector3.new(0.7 * s, len, 0.12 * s),
			theme.plant:Lerp(Color3.new(0, 0, 0), rng() * 0.25),
			M.LeafyGrass
		)
		leaf.CastShadow = true
	end
end

function Props.bench(parent: Instance, cf: CFrame, theme: Theme, variant: number?)
	Assets.place(parent, "bench", cf, function(slot: Model, at0: CFrame)
		Props.benchFallback(slot, at0, theme)
	end, { variant = variant })
end

function Props.benchFallback(parent: Instance, cf: CFrame, theme: Theme)
	local model = Kit.model(parent, "Bench")
	decor(model, "Seat", cf * CFrame.new(0, 1.5, 0), Vector3.new(4.4, 0.6, 1.8), theme.carpet, M.Fabric).CastShadow =
		true
	decor(model, "Back", cf * CFrame.new(0, 2.7, 0.75), Vector3.new(4.4, 1.9, 0.35), theme.carpet, M.Fabric)
	decor(model, "Base", cf * CFrame.new(0, 0.9, 0), Vector3.new(4, 0.6, 1.5), theme.wainscot, M.Wood)
	for _, x in { -1.9, 1.9 } do
		decor(model, "Leg", cf * CFrame.new(x, 0.3, 0), Vector3.new(0.3, 0.6, 1.4), theme.brass, M.Metal)
	end
end

-- Console table (2.7 studs tall) with a lamp or a vase of flowers on top.
local TABLE_TOP = 2.7

function Props.sideTable(parent: Instance, cf: CFrame, theme: Theme, rng: Rng)
	local variant = variantOf(rng)
	Assets.place(parent, "sideTable", cf, function(slot: Model, at0: CFrame)
		local model = Kit.model(slot, "SideTable")
		decor(model, "Top", at0 * CFrame.new(0, TABLE_TOP - 0.1, 0), Vector3.new(2.4, 0.2, 1.4), theme.wainscot, M.Wood).CastShadow =
			true
		for _, x in { -1, 1 } do
			for _, z in { -0.5, 0.5 } do
				decor(model, "Leg", at0 * CFrame.new(x, 1.25, z), Vector3.new(0.18, 2.5, 0.18), theme.wainscot, M.Wood)
			end
		end
	end, { variant = variant })
	local top = cf * CFrame.new(0, TABLE_TOP, 0)
	if rng() < 0.5 then
		-- Table lamp (its light stays outside the slot).
		Assets.place(parent, "tableLamp", top, function(slot: Model, at0: CFrame)
			decor(slot, "LampBase", at0 * CFrame.new(0, 0.4, 0), Vector3.new(0.5, 0.8, 0.5), theme.brass, M.Metal)
			Kit.cylinder(slot, {
				name = "LampShade",
				cf = at0 * CFrame.new(0, 1.2, 0) * CFrame.Angles(0, 0, math.pi / 2),
				size = Vector3.new(0.8, 1.3, 1.3),
				color = Color3.fromRGB(250, 226, 180),
				material = M.Fabric,
			})
		end, { variant = variant })
		local rig = lightRig(parent, "TableLampLight", top * CFrame.new(0, 1.2, 0))
		Kit.pointLight(rig, theme.lamp, 0.6, 8, false)
	else
		-- Vase with flowers.
		local flowerRng = subRng(rng)
		Assets.place(parent, "flowerVase", top, function(slot: Model, at0: CFrame)
			Kit.cylinder(slot, {
				name = "Vase",
				cf = at0 * CFrame.new(0, 0.5, 0) * CFrame.Angles(0, 0, math.pi / 2),
				size = Vector3.new(1, 0.7, 0.7),
				color = Color3.fromRGB(70, 110, 170),
				material = M.Glass,
			})
			for i = 1, 3 do
				local a = i * 2.1
				Kit.ball(slot, {
					name = "Flower",
					cf = at0 * CFrame.new(math.cos(a) * 0.3, 1.35 + i * 0.08, math.sin(a) * 0.3),
					size = Vector3.new(0.45, 0.45, 0.45),
					color = pick(
						flowerRng,
						{ Color3.fromRGB(240, 90, 120), Color3.fromRGB(250, 220, 90), Color3.fromRGB(240, 240, 255) }
					),
					material = M.SmoothPlastic,
				})
			end
		end, { variant = variant })
	end
end

function Props.luggageCart(parent: Instance, cf: CFrame, theme: Theme, rng: Rng): Model
	local variant = variantOf(rng)
	local bagRng = subRng(rng)
	return Assets.place(parent, "luggageCart", cf, function(slot: Model, at0: CFrame)
		Props.luggageCartFallback(slot, at0, theme, bagRng)
	end, { variant = variant })
end

function Props.luggageCartFallback(parent: Instance, cf: CFrame, theme: Theme, rng: Rng)
	local model = Kit.model(parent, "LuggageCart")
	decor(model, "Deck", cf * CFrame.new(0, 0.9, 0), Vector3.new(4.6, 0.3, 2.4), Color3.fromRGB(150, 30, 40), M.Carpet).CastShadow =
		true
	for _, x in { -2.1, 2.1 } do
		decor(model, "Post", cf * CFrame.new(x, 3.4, 0), Vector3.new(0.22, 5, 0.22), theme.brass, M.Foil)
	end
	decor(model, "Bar", cf * CFrame.new(0, 5.9, 0), Vector3.new(4.4, 0.22, 0.22), theme.brass, M.Foil)
	for _, x in { -1.8, 1.8 } do
		for _, z in { -0.9, 0.9 } do
			Kit.cylinder(model, {
				name = "Wheel",
				cf = cf * CFrame.new(x, 0.4, z),
				size = Vector3.new(0.3, 0.8, 0.8),
				color = Color3.fromRGB(30, 30, 30),
				material = M.Rubber,
			})
		end
	end
	local colors = {
		Color3.fromRGB(130, 80, 50),
		Color3.fromRGB(70, 110, 170),
		Color3.fromRGB(180, 60, 60),
		Color3.fromRGB(90, 140, 90),
	}
	local y = 1.05
	for i = 1, 2 + math.floor(rng() * 2) do
		local w, hh, d = 2.6 - i * 0.3, 1.2, 1.6 - i * 0.1
		local bag = decor(
			model,
			"Bag",
			cf * CFrame.new((rng() - 0.5) * 0.6, y + hh / 2, 0) * CFrame.Angles(0, (rng() - 0.5) * 0.4, 0),
			Vector3.new(w, hh, d),
			pick(rng, colors),
			M.Leather
		)
		bag.CastShadow = true
		y += hh
	end
end

function Props.wetFloorSign(parent: Instance, cf: CFrame)
	Assets.place(parent, "wetFloorSign", cf, function(slot: Model, at0: CFrame)
		Props.wetFloorSignFallback(slot, at0)
	end)
end

function Props.wetFloorSignFallback(parent: Instance, cf: CFrame)
	local model = Kit.model(parent, "WetFloor")
	local yellow = Color3.fromRGB(250, 210, 40)
	local front = decor(
		model,
		"Front",
		cf * CFrame.new(0, 1.3, -0.35) * CFrame.Angles(-0.25, 0, 0),
		Vector3.new(1.4, 2.6, 0.08),
		yellow
	)
	decor(model, "Back", cf * CFrame.new(0, 1.3, 0.35) * CFrame.Angles(0.25, 0, 0), Vector3.new(1.4, 2.6, 0.08), yellow)
	Kit.surfaceText(front, {
		face = Enum.NormalId.Front,
		text = "WET\nFLOOR",
		color = Color3.fromRGB(30, 30, 30),
		font = FONT_SIGN,
	})
end

function Props.fireExtinguisher(parent: Instance, cf: CFrame)
	Assets.place(parent, "fireExtinguisher", cf, function(slot: Model, at0: CFrame)
		Props.fireExtinguisherFallback(slot, at0)
	end)
end

function Props.fireExtinguisherFallback(parent: Instance, cf: CFrame)
	local model = Kit.model(parent, "Extinguisher")
	Kit.cylinder(model, {
		name = "Body",
		cf = cf * CFrame.new(0, 1.4, 0) * CFrame.Angles(0, 0, math.pi / 2),
		size = Vector3.new(2, 0.7, 0.7),
		color = Color3.fromRGB(200, 30, 30),
		material = M.Metal,
	})
	decor(model, "Nozzle", cf * CFrame.new(0, 2.55, 0), Vector3.new(0.3, 0.3, 0.3), Color3.fromRGB(30, 30, 30))
end

-- Broken plank fringe along a pit edge. `cf` = edge centre at floor level, LookVector toward the pit.
function Props.brokenEdge(parent: Instance, cf: CFrame, width: number, theme: Theme, rng: Rng)
	local count = math.max(2, math.floor(width / 1.6))
	for i = 1, count do
		local x = -width / 2 + (i - 0.5) * (width / count)
		local len = 0.4 + rng() * 1.6
		local plank = decor(
			parent,
			"Splinter",
			cf * CFrame.new(x, -0.25, -len / 2) * CFrame.Angles((rng() - 0.3) * 0.5, 0, (rng() - 0.5) * 0.2),
			Vector3.new(width / count * 0.9, 0.5, len),
			theme.floor:Lerp(Color3.new(0, 0, 0), 0.15 + rng() * 0.2),
			M.WoodPlanks
		)
		plank.CastShadow = true
	end
end

-- Charred debris pile used by fire hazards. `cf` = pile centre on the floor.
function Props.debrisPile(parent: Instance, cf: CFrame, width: number, rng: Rng)
	local model = Kit.model(parent, "Debris")
	local charred = { Color3.fromRGB(40, 32, 28), Color3.fromRGB(64, 46, 36), Color3.fromRGB(90, 60, 40) }
	for i = 1, 9 do
		local x = (rng() - 0.5) * width
		local size = Vector3.new(1 + rng() * 2.2, 0.6 + rng() * 1.6, 1 + rng() * 1.8)
		local piece = decor(
			model,
			"Charred",
			cf * CFrame.new(x, size.Y / 2, (rng() - 0.5) * 2.4) * CFrame.Angles(0, rng() * math.pi, (rng() - 0.5) * 0.6),
			size,
			pick(rng, charred),
			if i % 3 == 0 then M.Leather else M.Wood
		)
		piece.CastShadow = true
		if i == 4 then
			piece.Name = "Suitcase"
		end
	end
end

function Props.pipeRun(parent: Instance, from: Vector3, to: Vector3, diameter: number, color: Color3)
	local length = (to - from).Magnitude
	if length < 0.05 then
		return
	end
	local mid = (from + to) / 2
	local cf = CFrame.lookAt(mid, to) * CFrame.Angles(0, math.pi / 2, 0)
	Kit.cylinder(parent, {
		name = "Pipe",
		cf = cf,
		size = Vector3.new(length, diameter, diameter),
		color = color,
		material = M.Metal,
	})
end

-- A rug with a border; returns the inner field (for a patterned carpet).
function Props.rug(parent: Instance, cf: CFrame, size: Vector2, base: Color3, border: Color3): Part
	decor(parent, "RugBorder", cf * CFrame.new(0, 0.04, 0), Vector3.new(size.X, 0.06, size.Y), border, M.Carpet)
	return decor(
		parent,
		"Rug",
		cf * CFrame.new(0, 0.08, 0),
		Vector3.new(size.X - 0.7, 0.06, size.Y - 0.7),
		base,
		M.Carpet
	)
end

function Props.umbrellaStand(parent: Instance, cf: CFrame, theme: Theme)
	Assets.place(parent, "umbrellaStand", cf, function(slot: Model, at0: CFrame)
		Props.umbrellaStandFallback(slot, at0, theme)
	end)
end

function Props.umbrellaStandFallback(parent: Instance, cf: CFrame, theme: Theme)
	local model = Kit.model(parent, "UmbrellaStand")
	Kit.cylinder(model, {
		name = "Stand",
		cf = cf * CFrame.new(0, 1, 0) * CFrame.Angles(0, 0, math.pi / 2),
		size = Vector3.new(2, 1, 1),
		color = theme.brass,
		material = M.Metal,
	})
	for i, color in { Color3.fromRGB(200, 40, 60), Color3.fromRGB(40, 80, 160), Color3.fromRGB(30, 30, 30) } do
		decor(
			model,
			"Umbrella",
			cf * CFrame.new((i - 2) * 0.25, 2.4, 0) * CFrame.Angles(0, 0, (i - 2) * 0.12),
			Vector3.new(0.22, 2.6, 0.22),
			color,
			M.Fabric
		)
	end
end

-- Corridor extras -----------------------------------------------------------------------------------
-- `cf` = bottom centre on the floor, LookVector facing the corridor (the fallback's front is +z in `at`).

function Props.vendingMachine(parent: Instance, cf: CFrame, theme: Theme, variant: number?)
	Assets.place(parent, "vendingMachine", cf, function(slot: Model, at0: CFrame)
		local model = Kit.model(slot, "VendingMachine")
		decor(
			model,
			"Cabinet",
			at0 * CFrame.new(0, 3.4, 0),
			Vector3.new(3.2, 6.8, 2.6),
			Color3.fromRGB(110, 70, 44),
			M.Wood
		).CastShadow =
			true
		local window = decor(
			model,
			"Window",
			at(at0, -0.35, 4, 1.32),
			Vector3.new(2.1, 3.8, 0.08),
			Color3.fromRGB(180, 220, 230),
			M.Glass
		)
		window.Transparency = 0.35
		for row = 0, 3 do
			decor(
				model,
				"Shelf",
				at(at0, -0.35, 2.4 + row * 0.95, 1.05),
				Vector3.new(2, 0.08, 0.6),
				Color3.fromRGB(60, 60, 64),
				M.Metal
			)
			for i = 0, 2 do
				decor(
					model,
					"Snack",
					at(at0, -1 + i * 0.65, 2.68 + row * 0.95, 1.05),
					Vector3.new(0.45, 0.45, 0.3),
					Color3.fromHSV(((row * 3 + i) * 0.13) % 1, 0.65, 0.95),
					M.SmoothPlastic
				)
			end
		end
		decor(
			model,
			"Keypad",
			at(at0, 1.15, 4.2, 1.32),
			Vector3.new(0.6, 1.4, 0.08),
			Color3.fromRGB(40, 40, 44),
			M.Metal
		)
		decor(model, "Tray", at(at0, -0.35, 1.2, 1.32), Vector3.new(2, 0.6, 0.08), Color3.fromRGB(20, 20, 22), M.Metal)
		decor(model, "Marquee", at(at0, 0, 6.3, 1.32), Vector3.new(2.8, 0.5, 0.06), theme.lamp, M.Neon).CastShadow =
			false
	end, { variant = variant })
end

function Props.waterCooler(parent: Instance, cf: CFrame)
	Assets.place(parent, "waterCooler", cf, function(slot: Model, at0: CFrame)
		local model = Kit.model(slot, "WaterCooler")
		decor(
			model,
			"Body",
			at0 * CFrame.new(0, 1.7, 0),
			Vector3.new(1.3, 3.4, 1.3),
			Color3.fromRGB(236, 238, 240),
			M.SmoothPlastic
		).CastShadow =
			true
		decor(
			model,
			"Taps",
			at(at0, 0, 2.6, 0.7),
			Vector3.new(0.7, 0.3, 0.12),
			Color3.fromRGB(60, 120, 220),
			M.SmoothPlastic
		)
		local bottle = Kit.cylinder(model, {
			name = "Bottle",
			cf = at0 * CFrame.new(0, 4.05, 0) * CFrame.Angles(0, 0, math.pi / 2),
			size = Vector3.new(1.3, 1.1, 1.1),
			color = Color3.fromRGB(120, 180, 240),
			material = M.Glass,
		})
		bottle.Transparency = 0.35
	end)
end

function Props.trashBin(parent: Instance, cf: CFrame, theme: Theme)
	Assets.place(parent, "trashBin", cf, function(slot: Model, at0: CFrame)
		local model = Kit.model(slot, "TrashBin")
		Kit.cylinder(model, {
			name = "Bin",
			cf = at0 * CFrame.new(0, 1.1, 0) * CFrame.Angles(0, 0, math.pi / 2),
			size = Vector3.new(2.2, 1.4, 1.4),
			color = Color3.fromRGB(40, 70, 50),
			material = M.Metal,
			shadow = true,
		})
		Kit.cylinder(model, {
			name = "Rim",
			cf = at0 * CFrame.new(0, 2.22, 0) * CFrame.Angles(0, 0, math.pi / 2),
			size = Vector3.new(0.12, 1.5, 1.5),
			color = theme.brass,
			material = M.Foil,
		})
	end)
end

function Props.roomServiceCart(parent: Instance, cf: CFrame, theme: Theme, variant: number?)
	Assets.place(parent, "roomServiceCart", cf, function(slot: Model, at0: CFrame)
		local model = Kit.model(slot, "ServiceCart")
		for _, y in { 1.1, 2.9 } do
			decor(model, "Tier", at0 * CFrame.new(0, y, 0), Vector3.new(3.2, 0.14, 1.9), theme.wainscot, M.Wood).CastShadow =
				true
		end
		for _, x in { -1.45, 1.45 } do
			for _, z in { -0.8, 0.8 } do
				decor(model, "Post", at0 * CFrame.new(x, 1.5, z), Vector3.new(0.12, 3, 0.12), theme.brass, M.Foil)
			end
		end
		decor(
			model,
			"Cloth",
			at0 * CFrame.new(0, 2.6, 0),
			Vector3.new(3.3, 0.6, 2),
			Color3.fromRGB(246, 242, 232),
			M.Fabric
		)
		Kit.ellipsoid(model, {
			name = "Cloche",
			cf = at0 * CFrame.new(0.4, 3.25, 0),
			size = Vector3.new(1.4, 0.9, 1.4),
			color = Color3.fromRGB(214, 218, 224),
			material = M.Foil,
		})
	end, { variant = variant })
end

function Props.suitcaseStack(parent: Instance, cf: CFrame, variant: number?)
	Assets.place(parent, "suitcaseStack", cf, function(slot: Model, at0: CFrame)
		local model = Kit.model(slot, "SuitcaseStack")
		local y = 0
		local leather = { Color3.fromRGB(120, 72, 44), Color3.fromRGB(80, 50, 36), Color3.fromRGB(150, 100, 60) }
		for i, spec in { Vector3.new(2.4, 1.2, 1.8), Vector3.new(2, 1, 1.6), Vector3.new(1.6, 0.9, 1.3) } do
			local case = decor(
				model,
				"Case",
				at0 * CFrame.new(0, y + spec.Y / 2, 0) * CFrame.Angles(0, (i - 2) * 0.15, 0),
				spec,
				leather[i],
				M.Leather
			)
			case.CastShadow = true
			y += spec.Y
		end
	end, { variant = variant })
end

function Props.trafficCone(parent: Instance, cf: CFrame)
	Assets.place(parent, "trafficCone", cf, function(slot: Model, at0: CFrame)
		local model = Kit.model(slot, "Cone")
		decor(
			model,
			"Base",
			at0 * CFrame.new(0, 0.08, 0),
			Vector3.new(1.2, 0.16, 1.2),
			Color3.fromRGB(30, 30, 30),
			M.Rubber
		)
		for i, spec in { { 0.45, 1.0, 0.9 }, { 1.0, 0.75, 0.6 }, { 1.5, 0.5, 0.45 } } do
			Kit.cylinder(model, {
				name = "Cone" .. i,
				cf = at0 * CFrame.new(0, spec[1], 0) * CFrame.Angles(0, 0, math.pi / 2),
				size = Vector3.new(spec[3], spec[2], spec[2]),
				color = if i == 2 then Color3.fromRGB(245, 245, 245) else Color3.fromRGB(255, 110, 30),
				material = M.SmoothPlastic,
			})
		end
	end)
end

function Props.signBoard(parent: Instance, cf: CFrame, theme: Theme, text: string, width: number, height: number)
	local board = decor(parent, "SignBoard", at(cf, 0, 0, 0.1), Vector3.new(width, height, 0.2), theme.wainscot, M.Wood)
	decor(parent, "SignTrim", at(cf, 0, 0, 0.05), Vector3.new(width + 0.3, height + 0.3, 0.1), theme.brass, M.Foil)
	Kit.surfaceText(board, {
		face = Enum.NormalId.Front,
		text = text,
		color = theme.sign,
		font = FONT_SERIF,
		lightInfluence = 0.3,
	})
	return board
end

return Props
