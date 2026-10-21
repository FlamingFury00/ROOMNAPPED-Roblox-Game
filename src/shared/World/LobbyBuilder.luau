--!strict
--[[
	LobbyBuilder: the grand hotel lobby (S25, A08) - one hall, no large town.

	Layout (lobby local space, +Z = toward the departure elevators):
	  * spawn in the middle of a marble hall under two chandeliers, a coffered ceiling and gallery walls
	  * reception desk on the left with the key rack behind it, the luggage rack (collection & loadout) on
	    the right, a lounge of sofas and armchairs on a rug, palms, clocks and luggage carts
	  * mission board and the departure elevator straight ahead; stepping into the elevator car (or pressing
	    PLAY) readies the player

	Furniture comes from the asset library (World/Assets) with procedural fallbacks; colliders are simple
	invisible boxes so every model is free to be detailed.
]]

local Geometry = require(script.Parent.Geometry)
local Kit = require(script.Parent.Kit)
local Props = require(script.Parent.Props)
local Palette = require(script.Parent.Palette)
local Assets = require(script.Parent.Assets)
local RoomPrefabs = require(script.Parent.RoomPrefabs)
local RoomDefs = require(script.Parent.Parent.Config.RoomDefs)
local MathUtil = require(script.Parent.Parent.Util.MathUtil)

type Box = { cf: CFrame, size: Vector3 }

export type LobbyRuntime = {
	spawn: CFrame,
	arrival: { CFrame },
	readyZone: Box,
	elevatorCar: Box,
	missionBoard: BasePart,
	collectionStation: BasePart,
	bounds: { min: Vector3, max: Vector3 },
}

local LobbyBuilder = {}

local M = Enum.Material
local W, D, H = 72, 60, 22 -- hall width (x), depth (z), height

local FONT_TITLE = Font.new("rbxasset://fonts/families/LuckiestGuy.json", Enum.FontWeight.Regular)
local FONT_SERIF = Font.new("rbxasset://fonts/families/Fondamento.json", Enum.FontWeight.Bold)

-- Wall architecture (a taller version of the corridor's): heights above the floor.
local WAINSCOT = 5.2
local PICTURE_RAIL = 16.4
local FRIEZE = { bottom = 19.4, top = 20.4 }
local COVE_TOP = 21.6

function LobbyBuilder.build(origin: Vector3?): { model: Model, runtime: LobbyRuntime }
	local theme = Palette.get("lobby")
	local rng = MathUtil.rng(4242)
	local base = CFrame.new(origin or Geometry.LobbyOrigin)
	local model = Kit.model(nil, "Lobby")
	local structure = Kit.folder(model, "Structure")
	local decor = Kit.folder(model, "Decor")
	local interact = Kit.folder(model, "Interact")
	local movers = Kit.folder(model, "Movers")

	local function at(x: number, y: number, z: number): CFrame
		return base * CFrame.new(x, y, z)
	end
	local function facing(x: number, y: number, z: number, tx: number, tz: number): CFrame
		local p = (base * CFrame.new(x, y, z)).Position
		local t = (base * CFrame.new(tx, y, tz)).Position
		return CFrame.lookAt(p, t)
	end
	local function piece(name: string, cf: CFrame, size: Vector3, color: Color3, material: Enum.Material?): Part
		local part = Kit.decor(decor, name, cf, size, color, material)
		part.CastShadow = false
		return part
	end
	local function collider(name: string, cf: CFrame, size: Vector3)
		Kit.part(structure, { name = name, cf = cf, size = size, transparency = 1, solid = true, shadow = false })
	end

	-- Floor: marble checkerboard framed by an inlay band, a compass rose under the chandelier and a carpet
	-- runner to the elevators.
	Palette.dress(
		Kit.solid(structure, "Floor", at(0, -0.5, 0), Vector3.new(W, 1, D), theme.floor, M.Marble),
		theme,
		"floor"
	)
	local dark = Color3.fromRGB(60, 40, 48)
	for ix = -4, 3 do
		for iz = -3, 2 do
			if (ix + iz) % 2 == 0 then
				local tile =
					piece("Tile", at(ix * 9 + 4.5, 0.02, iz * 10 + 5), Vector3.new(9, 0.04, 10), dark, M.Marble)
				Palette.apply(tile, "RN_FloorMarbleBlack", Color3.fromRGB(200, 190, 196))
			end
		end
	end
	for _, side in { -1, 1 } do
		piece("InlayX", at(0, 0.05, side * (D / 2 - 2.6)), Vector3.new(W - 4.4, 0.06, 0.8), theme.trim, M.Foil)
		piece("InlayZ", at(side * (W / 2 - 2.6), 0.05, 0), Vector3.new(0.8, 0.06, D - 4.4), theme.trim, M.Foil)
	end
	local rose: { { diameter: number, color: Color3 } } = {
		{ diameter = 11, color = theme.trim },
		{ diameter = 9.6, color = dark },
		{ diameter = 6.4, color = theme.floor },
		{ diameter = 2.2, color = theme.trim },
	}
	for ring, spec in rose do
		Kit.cylinder(decor, {
			name = "Rose" .. ring,
			cf = at(0, 0.06 + ring * 0.01, -6) * CFrame.Angles(0, 0, math.pi / 2),
			size = Vector3.new(0.06, spec.diameter, spec.diameter),
			color = spec.color,
			material = M.Marble,
		})
	end
	Palette.dress(
		Props.rug(decor, at(0, 0.1, 13), Vector2.new(10, 26), theme.carpet, theme.carpetBorder),
		theme,
		"carpet"
	)

	-- Ceiling: plaster with a coffered grid.
	Kit.solid(structure, "Ceiling", at(0, H + 0.5, 0), Vector3.new(W, 1, D), theme.ceiling, M.Plaster)
	for i = -3, 3 do
		piece("BeamZ", at(i * 12, H - 0.7, 0), Vector3.new(1.2, 1.4, D), theme.trim, M.Foil)
	end
	for i = -2, 2 do
		piece("BeamX", at(0, H - 0.55, i * 12), Vector3.new(W, 1.1, 1), theme.trim:Lerp(theme.ceiling, 0.4), M.Foil)
	end

	-- Walls: structure, then the gallery architecture.
	local function wallPiece(name: string, cf: CFrame, size: Vector3)
		local part = Kit.solid(structure, name, cf, size, theme.wall, theme.wallMaterial)
		Palette.dress(part, theme, "wall")
	end
	wallPiece("WallBack", at(0, H / 2, -D / 2 - 0.5), Vector3.new(W + 2, H, 1))
	wallPiece("WallLeft", at(-W / 2 - 0.5, H / 2, 0), Vector3.new(1, H, D + 2))
	wallPiece("WallRight", at(W / 2 + 0.5, H / 2, 0), Vector3.new(1, H, D + 2))
	-- Front wall with the elevator openings (two cars at x = -10 and x = 10).
	local frontZ = D / 2 + 0.5
	wallPiece("WallFrontL", at(-W / 2 + (W / 2 - 14) / 2, H / 2, frontZ), Vector3.new(W / 2 - 14, H, 1))
	wallPiece("WallFrontR", at(W / 2 - (W / 2 - 14) / 2, H / 2, frontZ), Vector3.new(W / 2 - 14, H, 1))
	wallPiece("WallFrontMid", at(0, H / 2, frontZ), Vector3.new(12, H, 1))
	for _, x in { -10, 10 } do
		wallPiece("ElevatorLintel", at(x, (10 + H) / 2, frontZ), Vector3.new(8, H - 10, 1))
		-- Threshold under the doorway: the hall floor ends at the wall face and the car floor starts behind it.
		Kit.solid(structure, "ElevatorSill", at(x, -0.5, frontZ), Vector3.new(8, 1, 1), theme.trim, M.Foil)
	end

	--[[
		One wall's trim. `frame` sits on the wall's inner face at floor level, centred, X along the wall and
		LookVector into the hall; `gaps` are spans (in frame X) where the lower trim stops.
	]]
	local panelColor = theme.wainscot:Lerp(Color3.new(1, 1, 1), 0.07)
	local baseColor = theme.wainscot:Lerp(Color3.new(0, 0, 0), 0.32)
	local function layer(
		frame: CFrame,
		u0: number,
		u1: number,
		y0: number,
		y1: number,
		d0: number,
		d1: number,
		color: Color3,
		material: Enum.Material,
		name: string
	)
		if u1 - u0 > 0.01 and y1 - y0 > 0.01 then
			piece(
				name,
				frame * CFrame.new((u0 + u1) / 2, (y0 + y1) / 2, -(d0 + d1) / 2),
				Vector3.new(u1 - u0, y1 - y0, d1 - d0),
				color,
				material
			)
		end
	end
	local function trimWall(frame: CFrame, length: number, gaps: { { number } }, pilasters: { number })
		local segments = { { -length / 2, length / 2 } }
		for _, gap in gaps do
			local nextSegments = {}
			for _, seg in segments do
				if gap[2] <= seg[1] or gap[1] >= seg[2] then
					table.insert(nextSegments, seg)
				else
					if gap[1] > seg[1] then
						table.insert(nextSegments, { seg[1], gap[1] })
					end
					if gap[2] < seg[2] then
						table.insert(nextSegments, { gap[2], seg[2] })
					end
				end
			end
			segments = nextSegments
		end
		for _, seg in segments do
			local u0, u1 = seg[1], seg[2]
			layer(frame, u0, u1, 0, WAINSCOT, 0, 0.2, theme.wainscot, theme.wainscotMaterial, "Wainscot")
			local count = math.max(1, math.round((u1 - u0) / 4))
			local pitch = (u1 - u0) / count
			if pitch > 1.6 then
				for i = 0, count - 1 do
					layer(
						frame,
						u0 + i * pitch + 0.4,
						u0 + (i + 1) * pitch - 0.4,
						1.4,
						WAINSCOT - 0.6,
						0.2,
						0.3,
						panelColor,
						theme.wainscotMaterial,
						"WainscotPanel"
					)
				end
			end
			layer(frame, u0, u1, 0, 0.9, 0.2, 0.4, baseColor, theme.wainscotMaterial, "Baseboard")
			layer(frame, u0, u1, 0.9, 1.02, 0.2, 0.44, baseColor, theme.wainscotMaterial, "BaseboardCap")
			layer(frame, u0, u1, WAINSCOT, WAINSCOT + 0.4, 0, 0.44, theme.trim, theme.trimMaterial, "ChairRail")
			layer(
				frame,
				u0,
				u1,
				WAINSCOT + 0.4,
				WAINSCOT + 0.52,
				0,
				0.34,
				theme.trim,
				theme.trimMaterial,
				"ChairRailLip"
			)
		end
		local half = length / 2
		layer(
			frame,
			-half,
			half,
			PICTURE_RAIL,
			PICTURE_RAIL + 0.18,
			0,
			0.12,
			theme.trim,
			theme.trimMaterial,
			"PictureRail"
		)
		layer(frame, -half, half, FRIEZE.bottom, FRIEZE.top, 0, 0.2, theme.trim, theme.trimMaterial, "Crown")
		-- Cove: a wedge flat against the wall and the ceiling.
		local depth = 0.8
		local centre = (frame * CFrame.new(0, (FRIEZE.top + COVE_TOP) / 2, -depth / 2)).Position
		local towardWall = frame.LookVector * -1
		local up = Vector3.new(0, -1, 0)
		local cove = Kit.wedge(decor, {
			name = "CrownCove",
			cf = CFrame.fromMatrix(centre, up:Cross(towardWall), up, towardWall),
			size = Vector3.new(length, COVE_TOP - FRIEZE.top, depth),
			color = theme.trim,
			material = theme.trimMaterial,
		})
		cove.CastShadow = false
		layer(frame, -half, half, COVE_TOP, H, 0, 0.9, theme.trim, theme.trimMaterial, "CrownFillet")
		for _, u in pilasters do
			layer(
				frame,
				u - 0.7,
				u + 0.7,
				WAINSCOT + 0.52,
				FRIEZE.bottom,
				0,
				0.34,
				theme.trim,
				theme.trimMaterial,
				"Pilaster"
			)
			layer(
				frame,
				u - 0.85,
				u + 0.85,
				WAINSCOT + 0.52,
				WAINSCOT + 1.3,
				0,
				0.42,
				theme.trim,
				theme.trimMaterial,
				"PilasterBase"
			)
			layer(
				frame,
				u - 0.9,
				u + 0.9,
				FRIEZE.bottom - 0.6,
				FRIEZE.bottom,
				0,
				0.46,
				theme.trim,
				theme.trimMaterial,
				"PilasterCap"
			)
		end
	end
	local backFrame = facing(0, 0, -D / 2, 0, 0)
	trimWall(backFrame, W, {}, { -30, -11, 11, 30 })
	trimWall(facing(-W / 2, 0, 0, 0, 0), D, {}, { -18, 0, 18 })
	trimWall(facing(W / 2, 0, 0, 0, 0), D, {}, { -18, 0, 18 })
	-- Front wall: trim stops at the two elevator portals (frame X runs toward -x seen from inside).
	trimWall(facing(0, 0, D / 2, 0, 0), W, { { -15, -5 }, { 5, 15 } }, { -26, 26 })

	-- Marble pillars with gold capitals and bases, in line with the side walls' pilasters.
	for _, x in { -24, 24 } do
		for _, z in { -18, 0, 18 } do
			Kit.post(structure, {
				name = "Pillar",
				cf = at(x, H / 2, z),
				height = H,
				diameter = 3,
				color = Color3.fromRGB(236, 228, 214),
				material = M.Marble,
				solid = true,
				shadow = true,
			})
			for _, spec in { { H - 1, 1.4, 3.8 }, { H - 2.1, 0.5, 3.4 }, { 0.7, 1.4, 3.8 }, { 1.65, 0.5, 3.4 } } do
				Kit.post(decor, {
					name = "Capital",
					cf = at(x, spec[1], z),
					height = spec[2],
					diameter = spec[3],
					color = theme.trim,
					material = M.Foil,
				})
			end
		end
	end

	-- Light: two chandeliers, gallery sconces between the pilasters and ceiling lamps in the side coffers.
	Props.chandelier(decor, at(0, H, -6), theme, 1.6)
	Props.chandelier(decor, at(0, H, 14), theme, 1.3)
	for _, side in { -1, 1 } do
		for _, z in { -14.5, -3.5, 3.5, 14.5 } do
			Props.wallSconce(decor, facing(side * (W / 2 - 0.02), 10, z, 0, z), theme, true)
		end
	end
	for _, x in { -30, 30 } do
		for _, z in { -18, -6, 6, 18 } do -- the coffer centres, between the cross beams
			Props.ceilingLamp(decor, at(x, H, z), theme, false)
		end
	end

	-- Night windows on the back wall: curtains, a valance, the moon in the middle one.
	for _, x in { -20.5, 0, 20.5 } do
		local frame = at(x, 11.5, -D / 2 + 0.2)
		piece("WindowFrame", frame, Vector3.new(9, 12, 0.3), theme.trim, M.Foil)
		local glass = Kit.part(decor, {
			name = "NightSky",
			cf = frame * CFrame.new(0, 0, 0.2),
			size = Vector3.new(8, 11, 0.1),
			color = Color3.fromRGB(28, 36, 80),
			material = M.Neon,
			transparency = 0.15,
		})
		glass.CastShadow = false
		glass:AddTag("RN_LobbyWindow")
		piece("Mullion", frame * CFrame.new(0, 0, 0.3), Vector3.new(0.3, 11, 0.12), theme.trim, M.Foil)
		piece("Transom", frame * CFrame.new(0, 2, 0.3), Vector3.new(8, 0.3, 0.12), theme.trim, M.Foil)
		for _, side in { -1, 1 } do
			-- Gathered drapes: three folds each.
			for fold = 0, 2 do
				local drape = piece(
					"Drape",
					frame * CFrame.new(side * (5.2 + fold * 0.45), -0.8, 0.5 + (fold % 2) * 0.15),
					Vector3.new(0.55, 15, 0.35),
					theme.carpet:Lerp(Color3.new(0, 0, 0), fold * 0.08),
					M.Fabric
				)
				drape.CastShadow = true
			end
			local tie = piece(
				"Tieback",
				frame * CFrame.new(side * 5.65, -2.2, 0.8),
				Vector3.new(1.5, 0.3, 0.55),
				theme.trim,
				M.Foil
			)
			tie.CastShadow = false
		end
		piece("Valance", frame * CFrame.new(0, 7.2, 0.6), Vector3.new(13, 1.6, 0.6), theme.carpet, M.Fabric)
		piece("ValanceTrim", frame * CFrame.new(0, 6.35, 0.75), Vector3.new(13, 0.25, 0.4), theme.trim, M.Foil)
		if x == 0 then
			Kit.cylinder(decor, {
				name = "Moon",
				cf = frame * CFrame.new(2, 3, 0.28) * CFrame.Angles(0, math.pi / 2, 0),
				size = Vector3.new(0.05, 2.2, 2.2),
				color = Color3.fromRGB(255, 248, 210),
				material = M.Neon,
			})
		end
	end
	-- A grandfather clock between the windows and portraits above the side walls' lounge.
	for _, x in { -8.2, 8.2 } do
		Assets.place(decor, "grandfatherClock", facing(x, 0, -D / 2 + 1.2, x, 0), function(slot: Model, cf: CFrame)
			Kit.decor(
				slot,
				"Case",
				cf * CFrame.new(0, 3.8, 0),
				Vector3.new(2.2, 7.6, 1.4),
				Color3.fromRGB(70, 40, 26),
				M.Wood
			)
			Kit.cylinder(slot, {
				name = "Dial",
				cf = cf * CFrame.new(0, 6.3, -0.72) * CFrame.Angles(0, math.pi / 2, 0),
				size = Vector3.new(0.06, 1.6, 1.6),
				color = Color3.fromRGB(240, 230, 205),
			})
		end, { variant = if x < 0 then 1 else 2 })
		collider("ClockCollider", at(x, 3.8, -D / 2 + 1.2), Vector3.new(2.4, 7.6, 1.6))
	end

	-- Title sign above the elevators.
	local title = Kit.decor(
		decor,
		"TitleSign",
		at(0, 16.5, D / 2 - 0.4),
		Vector3.new(34, 4.2, 0.4),
		Color3.fromRGB(40, 22, 30),
		M.Wood
	)
	Kit.surfaceText(title, {
		face = Enum.NormalId.Back,
		text = "ROOMNAPPED",
		color = Color3.fromRGB(255, 214, 120),
		font = FONT_TITLE,
		lightInfluence = 0,
		brightness = 1.4,
		strokeColor = Color3.fromRGB(80, 30, 10),
		strokeTransparency = 0.2,
	})
	piece("TitleFrame", at(0, 16.5, D / 2 - 0.25), Vector3.new(35, 5, 0.3), theme.trim, M.Foil)
	local subtitle =
		Kit.decor(decor, "Subtitle", at(0, 13.6, D / 2 - 0.4), Vector3.new(22, 1.4, 0.3), theme.trim, M.Foil)
	Kit.surfaceText(subtitle, {
		face = Enum.NormalId.Back,
		text = "THE GRAND FOLD HOTEL · DEPARTURES",
		color = Color3.fromRGB(50, 26, 20),
		font = FONT_SERIF,
	})

	-- Departure elevators (x = -10 active, x = +10 decorative "out of order").
	local carDepth = 12
	local elevatorCar: Box = { cf = at(-10, 5, D / 2 + 1 + carDepth / 2), size = Vector3.new(7.6, 10, carDepth - 1) }
	for _, x in { -10, 10 } do
		local cz = D / 2 + 1 + carDepth / 2
		Kit.solid(
			structure,
			"CarFloor",
			at(x, -0.5, cz),
			Vector3.new(10, 1, carDepth),
			Color3.fromRGB(60, 40, 30),
			M.Wood
		)
		Kit.decor(decor, "CarRug", at(x, 0.05, cz), Vector3.new(7, 0.1, carDepth - 2), theme.carpet, M.Carpet)
		Kit.solid(structure, "CarCeiling", at(x, 11.5, cz), Vector3.new(10, 1, carDepth), theme.trim, M.Foil)
		local carWalls: { { name: string, cf: CFrame, size: Vector3 } } = {
			{ name = "CarWallL", cf = at(x - 4.5, 5.5, cz), size = Vector3.new(1, 11, carDepth) },
			{ name = "CarWallR", cf = at(x + 4.5, 5.5, cz), size = Vector3.new(1, 11, carDepth) },
			{ name = "CarBack", cf = at(x, 5.5, cz + carDepth / 2 + 0.5), size = Vector3.new(10, 11, 1) },
		}
		for _, spec in carWalls do
			Palette.apply(Kit.solid(structure, spec.name, spec.cf, spec.size, theme.trim, M.Foil), "RN_GoldDeco")
		end
		-- Car interior: wood panels, a mirror, a handrail.
		for _, side in { -1, 1 } do
			for k = 0, 2 do
				piece(
					"CarPanel",
					at(x + side * 3.92, 5.8, cz - 3.6 + k * 3.6),
					Vector3.new(0.12, 6.4, 3),
					Color3.fromRGB(110, 66, 40),
					M.Wood
				)
			end
			piece("CarRail", at(x + side * 3.8, 3.4, cz), Vector3.new(0.3, 0.3, carDepth - 2), theme.brass, M.Foil)
		end
		local mirror = piece(
			"CarMirror",
			at(x, 6, cz + carDepth / 2 - 0.05),
			Vector3.new(6.6, 6.4, 0.1),
			Color3.fromRGB(200, 215, 225),
			M.Glass
		)
		mirror.Reflectance = 0.4
		local light = Kit.part(decor, {
			name = "CarLight",
			cf = at(x, 10.9, cz),
			size = Vector3.new(3.4, 0.15, 3.4),
			color = theme.lamp,
			material = M.Neon,
		})
		light:AddTag("RN_Lamp")
		Kit.pointLight(light, theme.lamp, 1.3, 16, false)
		for _, side in { -1, 1 } do
			local door = Kit.part(movers, {
				name = "LobbyElevatorDoor",
				cf = at(x + side * 2, 4.75, frontZ),
				size = Vector3.new(4, 9.5, 0.3),
				color = theme.brass,
				material = M.Foil,
				solid = true,
				tag = "RN_Door",
				attrs = { Open = x == -10, OpenOffset = Vector3.new(side * 3.8, 0, 0), LobbyElevator = x == -10 },
			})
			door.CanCollide = x ~= -10
			-- Art deco portal around the doors: fluted jambs and a stepped head.
			piece("PortalJamb", at(x + side * 4.6, 5, frontZ - 0.65), Vector3.new(1.2, 10, 0.5), theme.trim, M.Foil)
			piece(
				"PortalFlute",
				at(x + side * 4.6, 5, frontZ - 0.95),
				Vector3.new(0.3, 9.2, 0.15),
				theme.brass:Lerp(Color3.new(0, 0, 0), 0.2),
				M.Foil
			)
		end
		piece("PortalHead", at(x, 10.4, frontZ - 0.7), Vector3.new(10.4, 0.8, 0.6), theme.trim, M.Foil)
		piece("PortalStep", at(x, 11.0, frontZ - 0.6), Vector3.new(8.4, 0.4, 0.4), theme.trim, M.Foil)
		-- Floor dial: a half-moon gauge with a needle (the client swings it during a departure).
		Kit.cylinder(decor, {
			name = "DialFace",
			cf = at(x, 12.2, frontZ - 0.75) * CFrame.Angles(0, math.pi / 2, 0),
			size = Vector3.new(0.12, 2.6, 2.6),
			color = Color3.fromRGB(240, 226, 190),
			material = M.SmoothPlastic,
		})
		local needle = piece(
			"DialNeedle",
			at(x, 12.6, frontZ - 0.85),
			Vector3.new(0.12, 1, 0.06),
			Color3.fromRGB(40, 24, 18),
			M.Metal
		)
		needle:AddTag("RN_LobbyDialNeedle")
		local indicator = Kit.decor(
			decor,
			"Indicator",
			at(x, 13.9, D / 2 - 0.2),
			Vector3.new(4, 0.9, 0.2),
			Color3.fromRGB(20, 14, 10),
			M.Wood
		)
		Kit.surfaceText(indicator, {
			face = Enum.NormalId.Back,
			text = if x == -10 then "▼ EXPEDITION" else "OUT OF ORDER",
			color = if x == -10 then Color3.fromRGB(255, 190, 90) else Color3.fromRGB(200, 70, 70),
			font = Font.new("rbxasset://fonts/families/FredokaOne.json", Enum.FontWeight.Bold),
			lightInfluence = 0,
			brightness = 1.8,
		})
		if x == -10 then
			indicator:AddTag("RN_LobbyIndicator")
		end
	end
	-- Ready zone glow on the active car's floor.
	local readyPad = Kit.part(interact, {
		name = "ReadyPad",
		cf = at(-10, 0.1, D / 2 + 1 + carDepth / 2),
		size = Vector3.new(7, 0.12, carDepth - 2.5),
		color = Color3.fromRGB(255, 196, 90),
		material = M.Neon,
		transparency = 0.6,
		tag = "RN_ReadyPad",
	})
	readyPad.CastShadow = false

	-- Mission board (interactable) between the elevators.
	local board = Kit.part(interact, {
		name = "MissionBoard",
		cf = facing(0, 6.5, D / 2 - 0.6, 0, 0),
		size = Vector3.new(10, 7, 0.4),
		color = Color3.fromRGB(70, 44, 30),
		material = M.Wood,
		query = true,
		tag = "RN_MissionBoard",
	})
	Kit.decor(decor, "BoardFrame", facing(0, 6.5, D / 2 - 0.45, 0, 0), Vector3.new(10.8, 7.8, 0.3), theme.trim, M.Foil)
	local boardGui = Kit.surfaceText(board, {
		face = Enum.NormalId.Front,
		text = "MISSIONS",
		color = Color3.fromRGB(255, 230, 170),
		font = FONT_TITLE,
		lightInfluence = 0.2,
	})
	boardGui.Name = "BoardGui"
	-- Statues guard the departures (outside the palms beside the elevator portals).
	for _, x in { -21, 21 } do
		Assets.place(decor, "statue", facing(x, 0, D / 2 - 3, x, 0), function(slot: Model, cf: CFrame)
			Kit.decor(
				slot,
				"Pedestal",
				cf * CFrame.new(0, 1.9, 0),
				Vector3.new(1.8, 3.8, 1.8),
				Color3.fromRGB(236, 228, 214),
				M.Marble
			)
			Kit.ball(slot, {
				name = "Bust",
				cf = cf * CFrame.new(0, 4.6, 0),
				size = Vector3.new(1.2, 1.5, 1),
				color = Color3.fromRGB(228, 222, 210),
				material = M.Marble,
			})
		end)
		collider("StatueCollider", at(x, 3.3, D / 2 - 3), Vector3.new(2.4, 6.6, 2.4))
	end

	-- Reception (left): the desk between two pillars, the bell and a lamp on it, the key cabinet and the
	-- RECEPTION lettering on the wall behind.
	local deskCF = facing(-24, 0, 9, 0, 9)
	Assets.place(decor, "receptionDesk", deskCF, function(slot: Model, cf: CFrame)
		Kit.decor(slot, "Desk", cf * CFrame.new(0, 2, 0), Vector3.new(14, 4, 3.4), Color3.fromRGB(96, 56, 36), M.Wood)
		Kit.decor(
			slot,
			"DeskTop",
			cf * CFrame.new(0, 4.1, 0),
			Vector3.new(14.6, 0.3, 3.8),
			Color3.fromRGB(236, 228, 214),
			M.Marble
		)
		Kit.decor(slot, "DeskTrim", cf * CFrame.new(0, 1, -1.75), Vector3.new(14.2, 0.4, 0.1), theme.trim, M.Foil)
		for i = -2, 2 do
			Kit.decor(
				slot,
				"DeskPanel",
				cf * CFrame.new(i * 2.6, 2.4, -1.72),
				Vector3.new(1.9, 2.2, 0.06),
				Color3.fromRGB(110, 66, 42),
				M.Wood
			)
		end
	end)
	collider("DeskCollider", deskCF * CFrame.new(0, 2.1, 0), Vector3.new(14, 4.2, 3.4))
	local bell = Assets.place(decor, "deskBell", deskCF * CFrame.new(2, 4.25, -0.4), function(slot: Model, cf: CFrame)
		Kit.ball(slot, {
			name = "Bell",
			cf = cf * CFrame.new(0, 0.35, 0),
			size = Vector3.new(0.9, 0.7, 0.9),
			color = theme.brass,
			material = M.Foil,
		})
	end)
	bell:AddTag("RN_DeskBell")
	Assets.place(decor, "tableLamp", deskCF * CFrame.new(-5, 4.25, 0.3), function(slot: Model, cf: CFrame)
		Kit.decor(slot, "LampBase", cf * CFrame.new(0, 0.5, 0), Vector3.new(0.5, 1, 0.5), theme.brass, M.Foil)
		Kit.cylinder(slot, {
			name = "LampShade",
			cf = cf * CFrame.new(0, 1.3, 0) * CFrame.Angles(0, 0, math.pi / 2),
			size = Vector3.new(0.8, 1.3, 1.3),
			color = Color3.fromRGB(250, 226, 180),
			material = M.Fabric,
		})
	end, { variant = 1 })
	local deskLamp = Kit.part(decor, {
		name = "DeskLampLight",
		cf = deskCF * CFrame.new(-5, 5.6, 0.3),
		size = Vector3.new(0.3, 0.3, 0.3),
		transparency = 1,
	})
	deskLamp:AddTag("RN_Lamp")
	Kit.pointLight(deskLamp, theme.lamp, 0.7, 10, false)
	Assets.place(decor, "keyRack", facing(-W / 2 + 0.02, 9, 9, 0, 9), function(slot: Model, cf: CFrame)
		Kit.decor(
			slot,
			"KeyRack",
			cf * CFrame.new(0, 0, -0.2),
			Vector3.new(8, 5, 0.4),
			Color3.fromRGB(80, 48, 30),
			M.Wood
		)
		for i = 0, 7 do
			local col, row = i % 4, math.floor(i / 4)
			Kit.decor(
				slot,
				"Key",
				cf * CFrame.new(-2.7 + col * 1.8, 1 - row * 2.2, -0.45),
				Vector3.new(0.3, 1.2, 0.1),
				theme.brass,
				M.Foil
			)
		end
	end)
	local lettering = Kit.decor(
		decor,
		"ReceptionSign",
		facing(-W / 2 + 0.1, 14.2, 9, 0, 9),
		Vector3.new(9, 1.6, 0.2),
		theme.trim,
		M.Foil
	)
	Kit.surfaceText(lettering, {
		face = Enum.NormalId.Front,
		text = "RECEPTION",
		color = Color3.fromRGB(50, 26, 20),
		font = FONT_SERIF,
	})

	-- Gallery: a painting in every side-wall bay (the sconces flank them).
	for _, side in { -1, 1 } do
		for _, spec in { { -9, 13.4, 6, 3.6 }, { 24, 12.6, 5, 6.5 }, { -24, 12.6, 5, 6.5 } } do
			local z = spec[1]
			Props.painting(decor, facing(side * (W / 2 - 0.12), spec[2], z, 0, z), theme, rng, spec[3], spec[4])
		end
	end
	Props.painting(decor, facing(W / 2 - 0.12, 13.4, 9, 0, 9), theme, rng, 6, 3.6)

	-- Luggage rack / collection station (right).
	local rackCF = facing(24, 0, 9, 0, 9)
	Kit.solid(
		structure,
		"LuggageRack",
		rackCF * CFrame.new(0, 4, 1),
		Vector3.new(14, 8, 2.4),
		Color3.fromRGB(90, 56, 36),
		M.Wood
	)
	for level = 0, 1 do
		Kit.decor(
			decor,
			"Shelf",
			rackCF * CFrame.new(0, 2.4 + level * 3.2, -0.3),
			Vector3.new(13.6, 0.3, 2.4),
			theme.trim,
			M.Foil
		)
	end
	local station = Kit.part(interact, {
		name = "CollectionStation",
		cf = rackCF * CFrame.new(0, 3, -2.2),
		size = Vector3.new(13, 6, 2),
		transparency = 1,
		query = true,
		tag = "RN_CollectionStation",
	})
	local stationSign = Kit.decor(
		decor,
		"CollectionSign",
		rackCF * CFrame.new(0, 9.4, -0.2),
		Vector3.new(10, 1.6, 0.3),
		Color3.fromRGB(40, 22, 30),
		M.Wood
	)
	Kit.surfaceText(stationSign, {
		face = Enum.NormalId.Front,
		text = "LUGGAGE · ROOM COLLECTION",
		color = Color3.fromRGB(255, 214, 120),
		font = FONT_SERIF,
		lightInfluence = 0.2,
	})
	-- One suitcase per room on the shelves, tinted with the room colour.
	for i, def in RoomDefs.ordered do
		local level = if i <= 3 then 0 else 1
		local slot = if i <= 3 then i else i - 3
		local case = RoomPrefabs.suitcase(nil, 1.1, def.color)
		case:SetAttribute("RoomId", def.id)
		case:AddTag("RN_DisplayCase")
		local target = rackCF
			* CFrame.new(-5 + slot * 3.3 - (if level == 1 then 1.6 else 0), 2.55 + level * 3.2 + 3.1, -0.5)
		local pivot = (case.PrimaryPart :: BasePart).CFrame
		for _, d in case:GetDescendants() do
			if d:IsA("BasePart") then
				d.CFrame = target * pivot:ToObjectSpace(d.CFrame)
			end
		end
		case.Parent = decor
	end

	-- Lounge (left of the runner): a rug with two sofas facing a coffee table, armchairs at the ends, floor
	-- lamps and side tables.
	local loungeX, loungeZ = -14, -12
	Assets.place(decor, "rug", at(loungeX, 0.04, loungeZ), function(slot: Model, cf: CFrame)
		Props.rug(
			slot,
			cf * CFrame.new(0, 0.06, 0),
			Vector2.new(14, 12),
			theme.carpet:Lerp(Color3.new(0, 0, 0), 0.15),
			theme.carpetBorder
		)
	end)
	for _, side in { -1, 1 } do
		local z = loungeZ + side * 4.2
		Assets.place(decor, "sofa", facing(loungeX, 0, z, loungeX, loungeZ), function(slot: Model, cf: CFrame)
			Props.benchFallback(slot, cf, theme)
		end, { variant = if side < 0 then 1 else 2 })
		collider("SofaCollider", at(loungeX, 1.6, z), Vector3.new(7, 3.2, 3))
		Assets.place(
			decor,
			"armchair",
			facing(loungeX + side * 6, 0, loungeZ, loungeX, loungeZ),
			function(slot: Model, cf: CFrame)
				Props.benchFallback(slot, cf * CFrame.new(0, 0, 0), theme)
			end,
			{ variant = if side < 0 then 1 else 2 }
		)
		collider("ArmchairCollider", at(loungeX + side * 6, 1.8, loungeZ), Vector3.new(3.2, 3.6, 3.2))
		Assets.place(
			decor,
			"floorLamp",
			facing(loungeX + side * 6.2, 0, loungeZ + 4.6, loungeX, loungeZ),
			function(slot: Model, cf: CFrame)
				Kit.decor(slot, "Pole", cf * CFrame.new(0, 3, 0), Vector3.new(0.25, 6, 0.25), theme.brass, M.Foil)
				Kit.cylinder(slot, {
					name = "Shade",
					cf = cf * CFrame.new(0, 6.2, 0) * CFrame.Angles(0, 0, math.pi / 2),
					size = Vector3.new(1.2, 1.6, 1.6),
					color = Color3.fromRGB(250, 226, 180),
					material = M.Fabric,
				})
			end,
			{ variant = if side < 0 then 1 else 2 }
		)
		local lampLight = Kit.part(decor, {
			name = "FloorLampLight",
			cf = at(loungeX + side * 6.2, 6, loungeZ + 4.6),
			size = Vector3.new(0.3, 0.3, 0.3),
			transparency = 1,
		})
		lampLight:AddTag("RN_Lamp")
		Kit.pointLight(lampLight, theme.lamp, 0.8, 12, false)
	end
	Assets.place(decor, "coffeeTable", at(loungeX, 0, loungeZ), function(slot: Model, cf: CFrame)
		Kit.decor(
			slot,
			"CoffeeTable",
			cf * CFrame.new(0, 1.3, 0),
			Vector3.new(5, 0.4, 3),
			Color3.fromRGB(70, 42, 28),
			M.Wood
		)
	end)
	collider("LoungeCollider", at(loungeX, 1, loungeZ), Vector3.new(5, 2, 3))
	-- A second seating pair across the hall from the lounge.
	for _, z in { -13, -5 } do
		Assets.place(decor, "armchair", facing(30, 0, z, 0, z), function(slot: Model, cf: CFrame)
			Props.benchFallback(slot, cf, theme)
		end, { variant = if z < -9 then 2 else 1 })
		collider("ArmchairCollider", at(30, 1.8, z), Vector3.new(3.2, 3.6, 3.2))
	end
	Props.sideTable(decor, facing(31, 0, -9, 0, -9), theme, rng)

	-- Palms in the corners and beside the departures.
	for _, p in { { -32, -26 }, { 32, -26 }, { -32, 26 }, { 32, 26 }, { -16, 26 }, { 16, 26 }, { -30, -4 } } do
		Props.plant(decor, facing(p[1], 0, p[2], 0, 0), theme, rng, 1.5)
		collider("PlantCollider", at(p[1], 1.5, p[2]), Vector3.new(2.6, 3, 2.6))
	end
	for _, spec in { { 14, 18 }, { 6, 22 } } do
		Props.luggageCart(decor, facing(spec[1], 0, spec[2], 0, spec[2]), theme, rng)
		collider("CartCollider", facing(spec[1], 3, spec[2], 0, spec[2]), Vector3.new(4.6, 6, 2.4))
	end

	-- Spawn: facing the elevators.
	local spawnCF = facing(0, 3, -16, 0, 30)
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "LobbySpawn"
	spawn.Anchored = true
	spawn.Size = Vector3.new(10, 0.2, 10)
	spawn.CFrame = at(0, 0.1, -16)
	spawn.Transparency = 1
	spawn.CanCollide = false
	spawn.CanQuery = false
	spawn.CanTouch = true
	spawn.Duration = 0
	spawn.Neutral = true
	spawn.Enabled = true
	spawn.Parent = model

	-- Returning squads step out of the departure elevator into the lobby (outside the ready zone).
	local arrival = {}
	for _, offset in { { -2, 0 }, { 2, 0 }, { -2, -3.5 }, { 2, -3.5 } } do
		local p = at(-10 + offset[1], 3, D / 2 - 3 + offset[2]).Position
		table.insert(arrival, CFrame.lookAt(p, at(-10 + offset[1], 3, 0).Position))
	end

	local runtime: LobbyRuntime = {
		spawn = spawnCF,
		arrival = arrival,
		readyZone = elevatorCar,
		elevatorCar = elevatorCar,
		missionBoard = board,
		collectionStation = station,
		bounds = {
			min = (base * CFrame.new(-W / 2, -10, -D / 2)).Position,
			max = (base * CFrame.new(W / 2, H + 5, D / 2 + carDepth + 2)).Position,
		},
	}
	return { model = model, runtime = runtime }
end

return LobbyBuilder
