--!strict
--[[
	RoomPrefabs: the functional rooms (A02) and suitcases (A04), built procedurally from a skin palette.

	Contract (R11): every room shares the same shell, socket origin, reserved bounds, effect outlet and
	occupancy zone (see World/Geometry). A room is recognisable at phone scale by one large signature prop
	(freezer chest + icicles, giant fan, washing machines, planters, horseshoe magnet) and its colour.

	The returned model contains:
	  Shell       solid floor / walls / ceiling (collision proxy)
	  Props       decoration (mostly non-colliding)
	  Outlet      invisible part at the doorway, tagged RN_RoomOutlet, used by client effects
	  Spinner     (Fan only) blade assembly the client rotates
]]

local Kit = require(script.Parent.Kit)
local Geometry = require(script.Parent.Geometry)
local SkinDefs = require(script.Parent.Parent.Config.SkinDefs)
local RoomDefs = require(script.Parent.Parent.Config.RoomDefs)
local MathUtil = require(script.Parent.Parent.Util.MathUtil)

type Palette = SkinDefs.Palette

local RoomPrefabs = {}

local M = Enum.Material
local decor = Kit.decor
local solid = Kit.solid
local R = Geometry.Room

local FONT_SIGN = Font.new("rbxasset://fonts/families/FredokaOne.json", Enum.FontWeight.Bold)

local function rp(roomCF: CFrame, x: number, y: number, d: number): CFrame
	return Geometry.roomCFrame(roomCF, x, y, d)
end

local function darker(c: Color3, t: number): Color3
	return c:Lerp(Color3.new(0, 0, 0), t)
end

local function lighter(c: Color3, t: number): Color3
	return c:Lerp(Color3.new(1, 1, 1), t)
end

-- Shared shell ---------------------------------------------------------------------------------------

local function buildShell(model: Model, roomCF: CFrame, palette: Palette, accentColor: Color3)
	local shell = Kit.folder(model, "Shell")
	local w, d, h = R.Width, R.Depth, R.Height
	solid(shell, "Floor", rp(roomCF, 0, -0.5, d / 2), Vector3.new(w, 1, d), palette.floor, palette.floorMaterial)
	solid(
		shell,
		"Ceiling",
		rp(roomCF, 0, h + 0.5, d / 2),
		Vector3.new(w, 1, d),
		darker(palette.wall, 0.15),
		palette.wallMaterial
	)
	solid(
		shell,
		"WallL",
		rp(roomCF, -w / 2 + 0.5, h / 2, d / 2),
		Vector3.new(1, h, d),
		palette.wall,
		palette.wallMaterial
	)
	solid(
		shell,
		"WallR",
		rp(roomCF, w / 2 - 0.5, h / 2, d / 2),
		Vector3.new(1, h, d),
		palette.wall,
		palette.wallMaterial
	)
	solid(shell, "WallBack", rp(roomCF, 0, h / 2, d - 0.5), Vector3.new(w, h, 1), palette.wall, palette.wallMaterial)
	-- Trim lines that read as "this is a room" even when the props are culled on low graphics.
	local props = model:FindFirstChild("Props") or Kit.folder(model, "Props")
	decor(
		props,
		"BaseTrim",
		rp(roomCF, 0, 0.3, d - 1.05),
		Vector3.new(w - 2, 0.6, 0.12),
		palette.trim,
		palette.trimMaterial
	)
	decor(
		props,
		"BaseTrimL",
		rp(roomCF, -w / 2 + 1.05, 0.3, d / 2),
		Vector3.new(0.12, 0.6, d - 2),
		palette.trim,
		palette.trimMaterial
	)
	decor(
		props,
		"BaseTrimR",
		rp(roomCF, w / 2 - 1.05, 0.3, d / 2),
		Vector3.new(0.12, 0.6, d - 2),
		palette.trim,
		palette.trimMaterial
	)
	decor(
		props,
		"CeilingTrim",
		rp(roomCF, 0, h - 0.3, d - 1.05),
		Vector3.new(w - 2, 0.4, 0.12),
		palette.trim,
		palette.trimMaterial
	)
	-- Doorway frame glow in the room colour (the effect outlet marker).
	local frameColor = accentColor
	decor(props, "OutletFrameL", rp(roomCF, -4.3, 5, 0.35), Vector3.new(0.35, 10, 0.5), frameColor, M.Neon)
	decor(props, "OutletFrameR", rp(roomCF, 4.3, 5, 0.35), Vector3.new(0.35, 10, 0.5), frameColor, M.Neon)
	decor(props, "OutletFrameTop", rp(roomCF, 0, 10.2, 0.35), Vector3.new(8.95, 0.35, 0.5), frameColor, M.Neon)
	-- Interior light.
	local lamp = Kit.part(props, {
		name = "RoomLight",
		cf = rp(roomCF, 0, h - 0.15, d / 2),
		size = Vector3.new(6, 0.2, 4),
		color = palette.light,
		material = M.Neon,
		transparency = 0.1,
	})
	lamp:AddTag("RN_Lamp")
	-- No shadows: up to four rooms can be out at once on top of the corridor lamps.
	Kit.pointLight(lamp, palette.light, palette.lightBrightness, 20, false)
	local outlet = Kit.part(model, {
		name = "Outlet",
		cf = rp(roomCF, 0, R.OutletHeight, 0.5),
		size = Vector3.new(8, 10, 1),
		transparency = 1,
	})
	outlet:AddTag("RN_RoomOutlet")
	return props :: Folder
end

-- Freezer --------------------------------------------------------------------------------------------

local function buildFreezer(_model: Model, roomCF: CFrame, palette: Palette, props: Folder, rng: () -> number)
	-- Chest freezer (signature prop) against the back wall.
	solid(props, "Chest", rp(roomCF, 0, 1.6, 11.6), Vector3.new(7.5, 3.2, 3.2), palette.prop, M.SmoothPlastic)
	decor(
		props,
		"ChestLid",
		rp(roomCF, 0, 3.35, 11.6),
		Vector3.new(7.7, 0.3, 3.4),
		lighter(palette.prop, 0.3),
		M.SmoothPlastic
	)
	decor(props, "ChestHandle", rp(roomCF, 0, 2.7, 9.95), Vector3.new(2.4, 0.3, 0.2), palette.trim, M.Metal)
	local label =
		decor(props, "ChestLabel", rp(roomCF, 0, 1.6, 9.98), Vector3.new(3, 1, 0.05), palette.trim, M.SmoothPlastic)
	Kit.surfaceText(label, { face = Enum.NormalId.Back, text = "ICE", color = Color3.new(1, 1, 1), font = FONT_SIGN })
	-- Steel shelves with ice blocks on both sides.
	for _, side in { -1, 1 } do
		local x = side * 6.3
		for level = 0, 2 do
			local y = 2.4 + level * 3.2
			decor(props, "Shelf", rp(roomCF, x, y, 6.5), Vector3.new(2.2, 0.25, 9), palette.trim, M.Metal)
			for i = 0, 2 do
				if rng() < 0.75 then
					local size = 1 + rng() * 0.7
					decor(
						props,
						"IceBlock",
						rp(roomCF, x + (rng() - 0.5) * 0.6, y + 0.15 + size / 2, 3.5 + i * 3),
						Vector3.new(size, size, size),
						palette.accent,
						palette.accentMaterial
					).Transparency =
						0.15
				end
			end
		end
		for _, depth in { 2.1, 10.9 } do
			solid(
				props,
				"ShelfPost",
				rp(roomCF, x - side * 1, 5, depth),
				Vector3.new(0.3, 10, 0.3),
				darker(palette.trim, 0.3),
				M.Metal
			)
		end
	end
	-- Icicles along the ceiling.
	for _ = 1, 14 do
		local x = -6 + rng() * 12
		local depth = 1.5 + rng() * 11
		local len = 0.8 + rng() * 1.8
		Kit.wedge(props, {
			name = "Icicle",
			cf = rp(roomCF, x, R.Height - len / 2, depth) * CFrame.Angles(math.pi, rng() * math.pi, 0),
			size = Vector3.new(0.35, len, 0.35),
			color = palette.accent,
			material = M.Ice,
			transparency = 0.2,
		})
	end
	-- Frost patches on the floor.
	for _ = 1, 5 do
		decor(
			props,
			"Frost",
			rp(roomCF, -5 + rng() * 10, 0.03, 2 + rng() * 10),
			Vector3.new(2 + rng() * 2.5, 0.06, 1.5 + rng() * 2),
			palette.accent,
			M.Glacier
		).Transparency =
			0.3
	end
	if palette.style == "icecream" then
		-- Giant ice cream cones.
		for _, x in { -3.5, 3.5 } do
			Kit.wedge(props, {
				name = "Cone",
				cf = rp(roomCF, x, 1.8, 7.5) * CFrame.Angles(math.pi, 0, 0),
				size = Vector3.new(1.6, 3.6, 1.6),
				color = Color3.fromRGB(226, 170, 96),
				material = M.Cardboard,
			})
			Kit.ball(props, {
				name = "Scoop",
				cf = rp(roomCF, x, 4.1, 7.5),
				size = Vector3.new(2.4, 2.2, 2.4),
				color = if x < 0 then Color3.fromRGB(255, 160, 190) else Color3.fromRGB(170, 240, 200),
				material = M.SmoothPlastic,
			})
		end
	elseif palette.style == "lodge" then
		-- Crossed skis and a snowman.
		for _, tilt in { -0.35, 0.35 } do
			decor(
				props,
				"Ski",
				rp(roomCF, 0, 9, 12.9) * CFrame.Angles(0, 0, tilt),
				Vector3.new(0.5, 7, 0.15),
				palette.trim,
				M.Wood
			)
		end
		for i, size in { 2.6, 2, 1.4 } do
			Kit.ball(props, {
				name = "Snowman",
				cf = rp(roomCF, 4.5, 0.9 + (i - 1) * 1.9, 4),
				size = Vector3.new(size, size, size),
				color = Color3.fromRGB(250, 252, 255),
				material = M.Snow,
			})
		end
	elseif palette.style == "aurora" then
		for i = 1, 6 do
			local x = -6 + i * 2
			Kit.wedge(props, {
				name = "Crystal",
				cf = rp(roomCF, x, 1.2, 9.2 - (i % 2) * 1.5) * CFrame.Angles(0, i, 0),
				size = Vector3.new(0.9, 2.4 + (i % 3), 0.9),
				color = if i % 2 == 0 then palette.trim else palette.accent,
				material = M.Neon,
				transparency = 0.25,
			})
		end
	end
end

-- Fan ------------------------------------------------------------------------------------------------

local function buildFan(model: Model, roomCF: CFrame, palette: Palette, props: Folder, rng: () -> number)
	local center = rp(roomCF, 0, 6.5, 12.6)
	-- Housing ring.
	Kit.cylinder(props, {
		name = "Housing",
		cf = center * CFrame.Angles(0, math.pi / 2, 0),
		size = Vector3.new(1.4, 11.5, 11.5),
		color = palette.prop,
		material = M.Metal,
		shadow = true,
	})
	Kit.cylinder(props, {
		name = "HousingInner",
		cf = center * CFrame.new(0, 0, 0.1) * CFrame.Angles(0, math.pi / 2, 0),
		size = Vector3.new(1.45, 10.4, 10.4),
		color = darker(palette.accent, 0.2),
		material = M.Metal,
	})
	-- Spinner: hub + 4 blades. The client spins this model around the hub's local Z axis.
	local spinner = Kit.model(model, "Spinner")
	local hub = Kit.cylinder(spinner, {
		name = "Hub",
		cf = center * CFrame.new(0, 0, 0.9) * CFrame.Angles(0, math.pi / 2, 0),
		size = Vector3.new(1.2, 2.2, 2.2),
		color = palette.trim,
		material = M.Metal,
	})
	spinner.PrimaryPart = hub
	for i = 0, 3 do
		local angle = i * math.pi / 2
		local blade = decor(
			spinner,
			"Blade",
			center
				* CFrame.new(0, 0, 0.85)
				* CFrame.Angles(0, 0, angle)
				* CFrame.new(0, 2.6, 0)
				* CFrame.Angles(0, 0.35, 0),
			Vector3.new(1.8, 4.4, 0.2),
			palette.prop,
			M.Metal
		)
		blade.CastShadow = true
	end
	-- Safety grille bars.
	for i = -2, 2 do
		decor(
			props,
			"Grille",
			center * CFrame.new(i * 2, 0, 1.6),
			Vector3.new(0.15, 10.5, 0.15),
			darker(palette.prop, 0.3),
			M.Metal
		)
	end
	-- Hazard stripes on the floor in front of the fan.
	for i = -3, 3 do
		decor(
			props,
			"Stripe",
			rp(roomCF, i * 2, 0.04, 10.6) * CFrame.Angles(0, 0.6, 0),
			Vector3.new(0.7, 0.08, 2.6),
			if i % 2 == 0 then palette.trim else palette.accent,
			M.SmoothPlastic
		)
	end
	-- Side vents and a pile of blown papers.
	for _, side in { -1, 1 } do
		for i = 0, 2 do
			decor(
				props,
				"Vent",
				rp(roomCF, side * 6.95, 3 + i * 3.4, 5),
				Vector3.new(0.1, 2, 4),
				darker(palette.wall, 0.4),
				M.DiamondPlate
			)
		end
	end
	for _ = 1, 10 do
		decor(
			props,
			"Paper",
			rp(roomCF, -5 + rng() * 10, 0.05 + rng() * 0.3, 2 + rng() * 6)
				* CFrame.Angles(0, rng() * 3, (rng() - 0.5) * 0.4),
			Vector3.new(0.9, 0.04, 1.2),
			Color3.fromRGB(245, 245, 235),
			M.SmoothPlastic
		)
	end
	if palette.style == "tropical" then
		for _, x in { -5.5, 5.5 } do
			decor(props, "PalmTrunk", rp(roomCF, x, 3.5, 10), Vector3.new(0.8, 7, 0.8), palette.prop, M.Wood)
			for k = 0, 4 do
				decor(
					props,
					"Frond",
					rp(roomCF, x, 7.2, 10) * CFrame.Angles(0, k * 1.25, 0.9) * CFrame.new(0, 1.6, 0),
					Vector3.new(0.9, 3.4, 0.1),
					palette.trim,
					M.LeafyGrass
				)
			end
		end
	elseif palette.style == "retro" then
		local sign = decor(props, "Diner", rp(roomCF, 0, 12.4, 12.85), Vector3.new(6, 1.2, 0.2), palette.accent, M.Neon)
		Kit.surfaceText(sign, {
			face = Enum.NormalId.Back,
			text = "COOL BREEZE",
			color = Color3.new(1, 1, 1),
			font = FONT_SIGN,
			lightInfluence = 0,
		})
	elseif palette.style == "storm" then
		for i = 1, 3 do
			decor(
				props,
				"Bolt",
				rp(roomCF, -5 + i * 2.5, 11.5, 12.85) * CFrame.Angles(0, 0, 0.5 * (i % 2 * 2 - 1)),
				Vector3.new(0.3, 2.4, 0.1),
				palette.accent,
				M.Neon
			)
		end
	end
end

-- Laundry --------------------------------------------------------------------------------------------

local function washer(props: Folder, cf: CFrame, palette: Palette, rng: () -> number)
	solid(props, "Washer", cf * CFrame.new(0, 1.75, 0), Vector3.new(3.4, 3.5, 3.2), palette.prop, M.SmoothPlastic)
	decor(
		props,
		"Panel",
		cf * CFrame.new(0, 3.3, -1.62),
		Vector3.new(3.2, 0.5, 0.05),
		darker(palette.prop, 0.12),
		M.SmoothPlastic
	)
	for i = -1, 1 do
		Kit.ball(props, {
			name = "Dial",
			cf = cf * CFrame.new(i * 0.6, 3.3, -1.66),
			size = Vector3.new(0.3, 0.3, 0.12),
			color = palette.trim,
			material = M.Metal,
		})
	end
	Kit.cylinder(props, {
		name = "DoorRing",
		cf = cf * CFrame.new(0, 1.6, -1.62) * CFrame.Angles(0, math.pi / 2, 0),
		size = Vector3.new(0.15, 2.4, 2.4),
		color = palette.trim,
		material = M.Metal,
	})
	local glass = Kit.cylinder(props, {
		name = "DoorGlass",
		cf = cf * CFrame.new(0, 1.6, -1.66) * CFrame.Angles(0, math.pi / 2, 0),
		size = Vector3.new(0.12, 1.9, 1.9),
		color = Color3.fromRGB(90, 140, 200),
		material = M.Glass,
		transparency = 0.2,
	})
	glass:AddTag("RN_WasherGlass")
	-- Colourful clothes tumbling behind the glass.
	Kit.ball(props, {
		name = "Clothes",
		cf = cf * CFrame.new(0, 1.5, -1.3),
		size = Vector3.new(1.4, 1.2, 0.5),
		color = Color3.fromHSV(rng(), 0.6, 0.9),
		material = M.Fabric,
	})
end

local function buildLaundry(_model: Model, roomCF: CFrame, palette: Palette, props: Folder, rng: () -> number)
	for i = -1, 1 do
		washer(props, rp(roomCF, i * 3.8, 0, 11.9) * CFrame.Angles(0, math.pi, 0), palette, rng)
	end
	-- Dryer stack on the left wall.
	for level = 0, 1 do
		washer(props, rp(roomCF, -5.9, level * 3.6, 6) * CFrame.Angles(0, -math.pi / 2, 0), palette, rng)
	end
	-- Clothesline with shirts across the room.
	decor(props, "Line", rp(roomCF, 0, 10.5, 6.5), Vector3.new(14, 0.08, 0.08), palette.trim, M.Fabric)
	for i = 1, 6 do
		local x = -6 + i * 1.8
		local color = Color3.fromHSV((i * 0.17 + rng() * 0.1) % 1, 0.55, 0.95)
		decor(
			props,
			"Shirt",
			rp(roomCF, x, 9.4, 6.5) * CFrame.Angles(0, 0, (rng() - 0.5) * 0.2),
			Vector3.new(1.4, 2, 0.08),
			color,
			M.Fabric
		)
		decor(props, "Sleeves", rp(roomCF, x, 10.1, 6.5), Vector3.new(2.1, 0.6, 0.07), color, M.Fabric)
	end
	-- Laundry basket and detergent bottles.
	solid(props, "Basket", rp(roomCF, 5, 1, 5), Vector3.new(2.6, 2, 2), Color3.fromRGB(200, 170, 120), M.Fabric)
	Kit.ball(props, {
		name = "BasketPile",
		cf = rp(roomCF, 5, 2.1, 5),
		size = Vector3.new(2.4, 1, 1.8),
		color = Color3.fromRGB(250, 250, 255),
		material = M.Fabric,
	})
	for i = 0, 2 do
		decor(
			props,
			"Detergent",
			rp(roomCF, 6.6, 1 + 0, 9 + i * 0.9),
			Vector3.new(0.7, 2, 0.7),
			Color3.fromHSV(0.55 + i * 0.12, 0.7, 0.9),
			M.SmoothPlastic
		)
	end
	-- Suds on the floor.
	for _ = 1, 8 do
		local size = 0.6 + rng() * 1.2
		Kit.ball(props, {
			name = "Suds",
			cf = rp(roomCF, -5 + rng() * 10, size * 0.3, 2 + rng() * 7),
			size = Vector3.new(size, size * 0.6, size),
			color = Color3.fromRGB(250, 252, 255),
			material = M.SmoothPlastic,
			transparency = 0.1,
		})
	end
	if palette.style == "royal" then
		local crest = decor(props, "Crest", rp(roomCF, 0, 9.8, 12.85), Vector3.new(4, 2.2, 0.2), palette.trim, M.Foil)
		Kit.surfaceText(
			crest,
			{ face = Enum.NormalId.Back, text = "ROYAL LINEN", color = darker(palette.wall, 0.4), font = FONT_SIGN }
		)
	elseif palette.style == "bubble" then
		for _ = 1, 10 do
			local size = 0.8 + rng() * 1.6
			Kit.ball(props, {
				name = "Bubble",
				cf = rp(roomCF, -6 + rng() * 12, 4 + rng() * 8, 2 + rng() * 10),
				size = Vector3.new(size, size, size),
				color = Color3.fromRGB(220, 240, 255),
				material = M.Glass,
				transparency = 0.45,
			})
		end
	elseif palette.style == "seaside" then
		Kit.cylinder(props, {
			name = "Lifebuoy",
			cf = rp(roomCF, 6.2, 8, 9) * CFrame.Angles(0, 0, 0),
			size = Vector3.new(0.6, 3, 3),
			color = palette.accent,
			material = M.SmoothPlastic,
		})
	end
end

-- Greenhouse -----------------------------------------------------------------------------------------

local function buildGreenhouse(_model: Model, roomCF: CFrame, palette: Palette, props: Folder, rng: () -> number)
	-- Glass roof panes over the shell ceiling.
	for i = -1, 1 do
		decor(
			props,
			"RoofPane",
			rp(roomCF, i * 5, R.Height - 0.05, 7),
			Vector3.new(4.6, 0.1, 12.6),
			Color3.fromRGB(210, 240, 230),
			M.Glass
		).Transparency =
			0.5
	end
	-- Raised planter beds along the walls with plants.
	for _, side in { -1, 1 } do
		solid(props, "Planter", rp(roomCF, side * 5.6, 1, 7.5), Vector3.new(3.2, 2, 10), palette.prop, M.WoodPlanks)
		decor(
			props,
			"Soil",
			rp(roomCF, side * 5.6, 2.05, 7.5),
			Vector3.new(2.8, 0.1, 9.6),
			Color3.fromRGB(70, 46, 30),
			M.Ground
		)
		for i = 0, 3 do
			local base = rp(roomCF, side * 5.6, 2.1, 3.5 + i * 2.6)
			local height = 1.5 + rng() * 2.5
			decor(
				props,
				"Stem",
				base * CFrame.new(0, height / 2, 0),
				Vector3.new(0.2, height, 0.2),
				darker(palette.accent, 0.3),
				M.Grass
			)
			for k = 0, 3 do
				decor(
					props,
					"Leaf",
					base
						* CFrame.new(0, height * (0.4 + k * 0.18), 0)
						* CFrame.Angles(0, k * 1.6 + rng(), 0.8)
						* CFrame.new(0, 0.6, 0),
					Vector3.new(0.8, 1.3, 0.08),
					palette.accent,
					M.LeafyGrass
				)
			end
			if rng() < 0.4 then
				Kit.ball(props, {
					name = "Bloom",
					cf = base * CFrame.new(0, height + 0.3, 0),
					size = Vector3.new(0.9, 0.9, 0.9),
					color = if palette.style == "mushroom"
						then Color3.fromRGB(230, 80, 80)
						else Color3.fromRGB(255, 210, 60),
					material = M.SmoothPlastic,
				})
			end
		end
	end
	-- Coiled vine (signature prop) on the back wall.
	for i = 0, 10 do
		local angle = i * 0.7
		Kit.ball(props, {
			name = "VineCoil",
			cf = rp(roomCF, math.cos(angle) * 2.5, 2 + i * 0.75, 12.8 - math.sin(angle) * 0.4),
			size = Vector3.new(1.1, 1.1, 1.1),
			color = palette.accent,
			material = M.LeafyGrass,
		})
	end
	decor(
		props,
		"WateringCan",
		rp(roomCF, 2, 0.7, 3),
		Vector3.new(1.4, 1.4, 0.9),
		Color3.fromRGB(80, 150, 200),
		M.Metal
	)
	if palette.style == "mushroom" then
		for i = 1, 5 do
			local x = -3 + i * 1.2
			decor(
				props,
				"MushStem",
				rp(roomCF, x, 0.9, 10.5),
				Vector3.new(0.5, 1.8, 0.5),
				Color3.fromRGB(240, 230, 210),
				M.SmoothPlastic
			)
			Kit.ball(props, {
				name = "MushCap",
				cf = rp(roomCF, x, 1.9, 10.5),
				size = Vector3.new(1.6, 0.8, 1.6),
				color = palette.trim,
				material = M.Neon,
				transparency = 0.15,
			})
		end
	elseif palette.style == "zen" then
		decor(props, "Lantern", rp(roomCF, -2.5, 1.5, 10.5), Vector3.new(1, 3, 1), palette.trim, M.Slate)
		for _ = 1, 4 do
			Kit.ball(props, {
				name = "Blossom",
				cf = rp(roomCF, 2 + rng() * 2, 7 + rng() * 3, 11 + rng()),
				size = Vector3.new(1.6, 1.2, 1.6),
				color = palette.accent,
				material = M.SmoothPlastic,
			})
		end
	end
end

-- Magnet ---------------------------------------------------------------------------------------------

local function buildMagnet(_model: Model, roomCF: CFrame, palette: Palette, props: Folder, rng: () -> number)
	-- Giant horseshoe magnet on the back wall: two arms joined by a curved top.
	local base = rp(roomCF, 0, 0, 12.3)
	for _, side in { -1, 1 } do
		solid(
			props,
			"MagnetArm",
			base * CFrame.new(side * 2.6, 3.6, 0),
			Vector3.new(2, 5.5, 2),
			palette.accent,
			M.SmoothPlastic
		)
		decor(
			props,
			"MagnetTip",
			base * CFrame.new(side * 2.6, 0.5, 0),
			Vector3.new(2.05, 1, 2.05),
			palette.prop,
			M.Metal
		)
	end
	for i = 0, 6 do
		local angle = math.pi * i / 6
		decor(
			props,
			"MagnetArc",
			base * CFrame.new(math.cos(angle) * 2.6, 6.4 + math.sin(angle) * 2.6, 0) * CFrame.Angles(0, 0, angle),
			Vector3.new(2, 1.6, 2),
			palette.accent,
			M.SmoothPlastic
		)
	end
	-- Scrap piles and coils.
	for _ = 1, 10 do
		local size = Vector3.new(0.5 + rng() * 1.5, 0.3 + rng() * 0.8, 0.5 + rng() * 1.2)
		decor(
			props,
			"Scrap",
			rp(roomCF, -6 + rng() * 12, size.Y / 2, 3 + rng() * 6) * CFrame.Angles(0, rng() * 3, 0),
			size,
			palette.prop:Lerp(Color3.new(0.3, 0.3, 0.3), rng() * 0.5),
			M.CorrodedMetal
		)
	end
	for _, side in { -1, 1 } do
		Kit.cylinder(props, {
			name = "Coil",
			cf = rp(roomCF, side * 6, 2.5, 10),
			size = Vector3.new(3, 2, 2),
			color = Color3.fromRGB(200, 120, 60),
			material = M.Metal,
		})
	end
	-- Warning stripes.
	for i = -3, 3 do
		decor(
			props,
			"Stripe",
			rp(roomCF, i * 2, 0.04, 9.4) * CFrame.Angles(0, -0.6, 0),
			Vector3.new(0.7, 0.08, 2.6),
			if i % 2 == 0 then palette.trim else Color3.fromRGB(30, 30, 30),
			M.SmoothPlastic
		)
	end
	if palette.style == "arcade" then
		local sign = decor(props, "Arcade", rp(roomCF, 0, 12, 12.85), Vector3.new(7, 1.4, 0.2), palette.trim, M.Neon)
		Kit.surfaceText(sign, {
			face = Enum.NormalId.Back,
			text = "MEGA PULL",
			color = Color3.new(1, 1, 1),
			font = FONT_SIGN,
			lightInfluence = 0,
		})
	elseif palette.style == "lab" then
		for i = 0, 2 do
			decor(
				props,
				"Beaker",
				rp(roomCF, 5.8, 3.6, 4 + i * 1.2),
				Vector3.new(0.6, 1, 0.6),
				Color3.fromHSV(0.3 + i * 0.2, 0.7, 1),
				M.Glass
			).Transparency =
				0.2
		end
		solid(props, "LabBench", rp(roomCF, 5.8, 1.5, 5.2), Vector3.new(2.4, 3, 5), palette.wall, M.SmoothPlastic)
	end
end

local BUILDERS: { [string]: (Model, CFrame, Palette, Folder, () -> number) -> () } = {
	Freezer = buildFreezer,
	Fan = buildFan,
	Laundry = buildLaundry,
	Greenhouse = buildGreenhouse,
	Magnet = buildMagnet,
}

-- Build a room. `roomCF` follows the geometry contract. Returns the room model (not yet parented).
function RoomPrefabs.build(roomId: string, skinId: string?, roomCF: CFrame, seedKey: string?): Model
	local def = RoomDefs.get(roomId)
	assert(def, "Unknown room " .. roomId)
	local skin = if skinId then SkinDefs.get(skinId) else nil
	if not skin or skin.room ~= roomId then
		skin = SkinDefs.get(SkinDefs.defaultFor(roomId))
	end
	local palette = (skin :: SkinDefs.SkinDef).palette
	local model = Kit.model(nil, "Room_" .. roomId)
	model:SetAttribute("RoomId", roomId)
	model:SetAttribute("SkinId", (skin :: SkinDefs.SkinDef).id)
	local rng = MathUtil.rng(MathUtil.hash((seedKey or "") .. roomId .. (skin :: SkinDefs.SkinDef).id))
	local props = buildShell(model, roomCF, palette, def.glow)
	BUILDERS[roomId](model, roomCF, palette, props, rng)
	local floor = model:FindFirstChild("Shell") and (model :: any).Shell:FindFirstChild("Floor")
	if floor then
		model.PrimaryPart = floor
	end
	return model
end

-- Suitcases ------------------------------------------------------------------------------------------

-- Build a suitcase model centred on its handle. `scale` 1 = hand-held size (A04).
function RoomPrefabs.suitcase(skinId: string?, scale: number?, roomColor: Color3?): Model
	local skin = if skinId then SkinDefs.get(skinId) else nil
	if not skin or skin.kind ~= "suitcase" then
		skin = SkinDefs.get(SkinDefs.defaultSuitcase)
	end
	local palette = (skin :: SkinDefs.SkinDef).palette
	local s = scale or 1
	local model = Kit.model(nil, "Suitcase")
	local origin = CFrame.new()
	local function piece(name: string, cf: CFrame, size: Vector3, color: Color3, material: Enum.Material): Part
		local part = Kit.part(model, {
			name = name,
			cf = origin * cf,
			size = size * s,
			color = color,
			material = material,
		})
		part.Massless = true
		-- Only the case's body casts a shadow; the small trims would add shadow work for nothing.
		part.CastShadow = name == "Body"
		return part
	end
	local handle = piece("Handle", CFrame.new(0, 0, 0), Vector3.new(1.1, 0.25, 0.3), palette.prop, M.Leather)
	model.PrimaryPart = handle
	piece("HandleL", CFrame.new(-0.55 * s, -0.25 * s, 0), Vector3.new(0.18, 0.5, 0.3), palette.trim, M.Metal)
	piece("HandleR", CFrame.new(0.55 * s, -0.25 * s, 0), Vector3.new(0.18, 0.5, 0.3), palette.trim, M.Metal)
	local body = piece("Body", CFrame.new(0, -1.7 * s, 0), Vector3.new(2.8, 2.4, 1), palette.wall, palette.wallMaterial)
	piece("Seam", CFrame.new(0, -1.7 * s, 0), Vector3.new(2.85, 2.45, 0.12), palette.floor, palette.floorMaterial)
	for _, x in { -1, 1 } do
		piece("Strap", CFrame.new(x * 0.75 * s, -1.7 * s, 0), Vector3.new(0.3, 2.46, 1.04), palette.floor, M.Leather)
		for _, y in { -0.55, -2.85 } do
			piece(
				"Corner",
				CFrame.new(x * 1.3 * s, y * s, 0),
				Vector3.new(0.35, 0.35, 1.08),
				palette.trim,
				palette.trimMaterial
			)
		end
	end
	piece("Latch", CFrame.new(0, -0.6 * s, -0.52 * s), Vector3.new(0.5, 0.3, 0.08), palette.trim, M.Metal)
	if palette.style == "sticker" then
		for i, color in { Color3.fromRGB(255, 200, 40), Color3.fromRGB(255, 90, 120), Color3.fromRGB(120, 230, 160) } do
			piece(
				"Sticker",
				CFrame.new((i - 2) * 0.7 * s, -1.6 * s + (i % 2) * 0.5 * s, -0.53 * s) * CFrame.Angles(0, 0, i * 0.4),
				Vector3.new(0.5, 0.5, 0.04),
				color,
				M.SmoothPlastic
			)
		end
	elseif palette.style == "polka" then
		for i = 0, 5 do
			piece(
				"Dot",
				CFrame.new((-0.9 + (i % 3) * 0.9) * s, (-1.2 - math.floor(i / 3) * 0.9) * s, -0.53 * s),
				Vector3.new(0.35, 0.35, 0.04),
				palette.accent,
				M.SmoothPlastic
			)
		end
	elseif palette.style == "midnight" or palette.style == "gold" then
		piece("Glow", CFrame.new(0, -2.95 * s, 0), Vector3.new(2.6, 0.08, 0.9), palette.trim, M.Neon)
	end
	if roomColor then
		-- Captured-room cargo: a glowing tag in the room's colour.
		local tag =
			piece("RoomTag", CFrame.new(0.9 * s, -1.1 * s, -0.56 * s), Vector3.new(0.7, 0.9, 0.06), roomColor, M.Neon)
		tag:AddTag("RN_CargoGlow")
	end
	body:SetAttribute("SuitcaseBody", true)
	return model
end

return RoomPrefabs
