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
local Assets = require(script.Parent.Assets)
local Surfaces = require(script.Parent.Palette)
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

-- A private generator drawn once from `rng`, so a room's other random details are the same whether a slot
-- ends up holding its real model or its fallback.
local function subRng(rng: () -> number): () -> number
	local state = math.floor(rng() * 2147483645) + 1
	return function(): number
		state = (state * 16807) % 2147483647
		return state / 2147483647
	end
end

-- Room-space frames for asset slots: standing on the floor facing the doorway, or flat on a wall facing in.
local function facingDoor(roomCF: CFrame, x: number, y: number, d: number): CFrame
	return rp(roomCF, x, y, d) * CFrame.Angles(0, math.pi, 0)
end

local function onSideWall(roomCF: CFrame, side: number, y: number, d: number): CFrame
	-- Inner wall faces are at x = +-7; side -1 = left wall (facing +x), 1 = right wall (facing -x).
	return rp(roomCF, side * 7, y, d) * CFrame.Angles(0, side * math.pi / 2, 0)
end

-- An invisible collision box (real models never collide; their proxies do).
local function collider(parent: Instance, cf: CFrame, size: Vector3)
	Kit.part(parent, { name = "Collider", cf = cf, size = size, transparency = 1, solid = true, shadow = false })
end

-- Shared shell ---------------------------------------------------------------------------------------

local function buildShell(model: Model, roomCF: CFrame, palette: Palette, accentColor: Color3)
	local shell = Kit.folder(model, "Shell")
	local w, d, h = R.Width, R.Depth, R.Height
	local floor =
		solid(shell, "Floor", rp(roomCF, 0, -0.5, d / 2), Vector3.new(w, 1, d), palette.floor, palette.floorMaterial)
	if palette.floorSurface then
		Surfaces.apply(floor, palette.floorSurface, palette.floorTint)
	end
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
	if palette.wallSurface then
		for _, name in { "WallL", "WallR", "WallBack" } do
			local wall = shell:FindFirstChild(name)
			if wall and wall:IsA("BasePart") then
				Surfaces.apply(wall, palette.wallSurface, palette.wallTint)
			end
		end
	end
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
	-- Steel shelves with ice blocks on both sides, and an old upright freezer in each back corner.
	for _, side in { -1, 1 } do
		local x = side * 6.3
		for level = 0, 2 do
			local y = 2.4 + level * 3.2
			decor(props, "Shelf", rp(roomCF, x, y, 5.8), Vector3.new(2.2, 0.25, 7.6), palette.trim, M.Metal)
			for i = 0, 2 do
				if rng() < 0.75 then
					local size = 1 + rng() * 0.7
					decor(
						props,
						"IceBlock",
						rp(roomCF, x + (rng() - 0.5) * 0.6, y + 0.15 + size / 2, 3.4 + i * 2.6),
						Vector3.new(size, size, size),
						palette.accent,
						palette.accentMaterial
					).Transparency =
						0.15
				end
			end
		end
		local fridge = facingDoor(roomCF, side * 5.7, 0, 11.75)
		Assets.place(props, "uprightFreezer", fridge, function(slot: Model, cf: CFrame)
			decor(slot, "Cabinet", cf * CFrame.new(0, 3, 0), Vector3.new(2.6, 6, 2.4), palette.prop, M.SmoothPlastic).CastShadow =
				true
			decor(
				slot,
				"DoorLine",
				cf * CFrame.new(0, 4.3, -1.21),
				Vector3.new(2.5, 0.08, 0.04),
				darker(palette.prop, 0.3),
				M.Metal
			)
			decor(slot, "Handle", cf * CFrame.new(0.95, 3.2, -1.3), Vector3.new(0.14, 1.4, 0.14), palette.trim, M.Metal)
			decor(
				slot,
				"Grille",
				cf * CFrame.new(0, 0.35, -1.21),
				Vector3.new(2.2, 0.4, 0.04),
				darker(palette.prop, 0.45),
				M.Metal
			)
		end, { variant = if side < 0 then 1 else 2 })
		collider(props, fridge * CFrame.new(0, 3, 0), Vector3.new(2.6, 6, 2.4))
		for _, depth in { 2.1, 9.5 } do
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
	-- Boxes by the side walls: a neat stack exactly 3.2 high with a desk fan on top on the left, a pile on the
	-- right (the curated piles have no flat top to stand a fan on); air ducts along the ceiling. Both keep
	-- clear of the walls and their base trim (inner faces at x = +-7) however the boxes are turned.
	local cardboard = Color3.fromRGB(186, 146, 98)
	local stack = facingDoor(roomCF, -5.4, 0, 9)
	local stackRng = subRng(rng)
	local stackTop = 0
	for i, height in { 1.1, 1.1, 1 } do
		local turn = if i == 1 then 0 else (stackRng() - 0.5) * 0.4
		decor(
			props,
			"Box",
			stack * CFrame.new((stackRng() - 0.5) * 0.3, stackTop + height / 2, 0) * CFrame.Angles(0, turn, 0),
			Vector3.new(2.6 - i * 0.3, height, 2.2 - i * 0.2),
			cardboard,
			M.Cardboard
		).CastShadow =
			true
		stackTop += height
	end
	collider(props, stack * CFrame.new(0, stackTop / 2, 0), Vector3.new(2.4, stackTop, 2.2))
	local pile = facingDoor(roomCF, 5.4, 0, 9)
	local pileRng = subRng(rng)
	Assets.place(props, "cardboardBoxes", pile, function(slot: Model, cf: CFrame)
		local y = 0
		for i = 1, 2 + math.floor(pileRng() * 2) do
			local size = Vector3.new(2.6 - i * 0.3, 1.1, 2.2 - i * 0.2)
			decor(
				slot,
				"Box",
				cf
					* CFrame.new((pileRng() - 0.5) * 0.2, y + size.Y / 2, 0)
					* CFrame.Angles(0, (pileRng() - 0.5) * 0.3, 0),
				size,
				cardboard,
				M.Cardboard
			).CastShadow =
				true
			y += size.Y
		end
	end, { variant = if rng() < 0.5 then 1 else 2 })
	collider(props, pile * CFrame.new(0, 1.5, 0), Vector3.new(2.4, 3, 3.6))
	for _, side in { -1, 1 } do
		Assets.place(
			props,
			"ventDuct",
			rp(roomCF, side * 5.8, R.Height, 5.5) * CFrame.Angles(0, math.pi / 2, 0),
			function(slot: Model, cf: CFrame)
				decor(
					slot,
					"Duct",
					cf * CFrame.new(0, -0.75, 0),
					Vector3.new(6, 1.4, 1.6),
					darker(palette.prop, 0.1),
					M.Metal
				)
				for _, x in { -2.9, 0, 2.9 } do
					decor(
						slot,
						"Flange",
						cf * CFrame.new(x, -0.75, 0),
						Vector3.new(0.2, 1.6, 1.8),
						darker(palette.prop, 0.3),
						M.Metal
					)
				end
			end
		)
	end
	Assets.place(
		props,
		"deskFan",
		facingDoor(roomCF, -5.4, stackTop, 9) * CFrame.Angles(0, 0.5, 0),
		function(slot: Model, cf: CFrame)
			Kit.cylinder(slot, {
				name = "FanBase",
				cf = cf * CFrame.new(0, 0.1, 0) * CFrame.Angles(0, 0, math.pi / 2),
				size = Vector3.new(0.2, 1, 1),
				color = palette.trim,
				material = M.Metal,
			})
			decor(slot, "FanNeck", cf * CFrame.new(0, 0.7, 0), Vector3.new(0.15, 1.1, 0.15), palette.trim, M.Metal)
			Kit.cylinder(slot, {
				name = "FanCage",
				cf = cf * CFrame.new(0, 1.4, -0.1) * CFrame.Angles(0, math.pi / 2, 0),
				size = Vector3.new(0.4, 1.3, 1.3),
				color = lighter(palette.trim, 0.3),
				material = M.Metal,
			})
		end
	)
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
		-- Potted palms against the side walls in front of the vents (clear of the boxes, the fan and the walls).
		for i, x in { -4.8, 4.8 } do
			Assets.place(props, "bigPlant", facingDoor(roomCF, x, 0, 4.2), function(slot: Model, cf: CFrame)
				Kit.cylinder(slot, {
					name = "Pot",
					cf = cf * CFrame.new(0, 0.7, 0) * CFrame.Angles(0, 0, math.pi / 2),
					size = Vector3.new(1.4, 1.7, 1.7),
					color = darker(palette.prop, 0.25),
					material = M.Concrete,
				})
				Kit.cylinder(slot, {
					name = "Trunk",
					cf = cf * CFrame.new(0, 3, 0) * CFrame.Angles(0, 0, math.pi / 2),
					size = Vector3.new(3.4, 0.45, 0.45),
					color = palette.prop,
					material = M.Wood,
				})
				for k = 0, 5 do
					decor(
						slot,
						"Frond",
						cf * CFrame.new(0, 4.6, 0) * CFrame.Angles(0, k * math.pi / 3 + i, 0.85) * CFrame.new(0, 1.2, 0),
						Vector3.new(0.7, 2.5, 0.08),
						palette.trim,
						M.LeafyGrass
					)
				end
			end, { variant = i, scale = 0.85 })
			collider(props, rp(roomCF, x, 1, 4.2), Vector3.new(1.7, 2, 1.7))
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
	-- Laundry basket, a shelf of detergents on the right wall, an ironing board and towels on the dryers.
	local basket = facingDoor(roomCF, 4.4, 0, 3.6)
	Assets.place(props, "laundryBasket", basket, function(slot: Model, cf: CFrame)
		decor(slot, "Basket", cf * CFrame.new(0, 1, 0), Vector3.new(2.6, 2, 2), Color3.fromRGB(200, 170, 120), M.Fabric).CastShadow =
			true
		Kit.ellipsoid(slot, {
			name = "BasketPile",
			cf = cf * CFrame.new(0, 2.1, 0),
			size = Vector3.new(2.4, 1, 1.8),
			color = Color3.fromRGB(250, 250, 255),
			material = M.Fabric,
		})
	end)
	collider(props, basket * CFrame.new(0, 1.1, 0), Vector3.new(2.6, 2.2, 2.2))
	local shelf = onSideWall(roomCF, 1, 0, 8.6)
	Assets.place(props, "detergentShelf", shelf * CFrame.new(0, 0, -0.8), function(slot: Model, cf: CFrame)
		decor(slot, "ShelfBack", cf * CFrame.new(0, 3, 0.7), Vector3.new(4, 6, 0.2), darker(palette.trim, 0.2), M.Metal)
		for level = 0, 2 do
			local y = 0.6 + level * 2
			decor(slot, "ShelfBoard", cf * CFrame.new(0, y, 0), Vector3.new(4, 0.15, 1.5), palette.trim, M.Metal)
			for i = 0, 3 do
				decor(
					slot,
					"Detergent",
					cf * CFrame.new(-1.4 + i * 0.95, y + 0.75, 0),
					Vector3.new(0.6, 1.4, 0.6),
					Color3.fromHSV((0.55 + i * 0.12 + level * 0.3) % 1, 0.7, 0.9),
					M.SmoothPlastic
				)
			end
		end
	end)
	collider(props, shelf * CFrame.new(0, 3, -0.8), Vector3.new(4, 6, 1.6))
	Assets.place(props, "ironingBoard", facingDoor(roomCF, -4.6, 0, 2.4), function(slot: Model, cf: CFrame)
		Kit.ellipsoid(slot, {
			name = "Board",
			cf = cf * CFrame.new(0, 3, 0),
			size = Vector3.new(4.6, 0.2, 1.4),
			color = palette.accent,
			material = M.Fabric,
		})
		for _, tilt in { -0.45, 0.45 } do
			decor(
				slot,
				"Leg",
				cf * CFrame.new(0, 1.5, 0) * CFrame.Angles(0, 0, tilt),
				Vector3.new(0.12, 3.2, 0.12),
				palette.trim,
				M.Metal
			)
		end
	end)
	Assets.place(
		props,
		"towelStack",
		rp(roomCF, -5.9, 7.1, 6) * CFrame.Angles(0, -math.pi / 2, 0),
		function(slot: Model, cf: CFrame)
			for i = 0, 2 do
				decor(
					slot,
					"Towel",
					cf * CFrame.new(0, 0.2 + i * 0.36, 0),
					Vector3.new(1.6, 0.34, 1.2),
					if i % 2 == 0 then Color3.fromRGB(250, 250, 250) else palette.accent,
					M.Fabric
				)
			end
		end
	)
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
			local plantRng = subRng(rng)
			local kinds = { "pottedFern", "flowerPots", "smallTree", "cactus" }
			local kind = kinds[((i + (if side < 0 then 0 else 2)) % #kinds) + 1]
			Assets.place(
				props,
				kind,
				base * CFrame.Angles(0, plantRng() * math.pi * 2, 0),
				function(slot: Model, cf: CFrame)
					local height = 1.5 + plantRng() * 2.5
					decor(
						slot,
						"Stem",
						cf * CFrame.new(0, height / 2, 0),
						Vector3.new(0.2, height, 0.2),
						darker(palette.accent, 0.3),
						M.Grass
					)
					for k = 0, 3 do
						decor(
							slot,
							"Leaf",
							cf
								* CFrame.new(0, height * (0.4 + k * 0.18), 0)
								* CFrame.Angles(0, k * 1.6 + plantRng(), 0.8)
								* CFrame.new(0, 0.6, 0),
							Vector3.new(0.8, 1.3, 0.08),
							palette.accent,
							M.LeafyGrass
						)
					end
					if plantRng() < 0.4 then
						Kit.ball(slot, {
							name = "Bloom",
							cf = cf * CFrame.new(0, height + 0.3, 0),
							size = Vector3.new(0.9, 0.9, 0.9),
							color = if palette.style == "mushroom"
								then Color3.fromRGB(230, 80, 80)
								else Color3.fromRGB(255, 210, 60),
							material = M.SmoothPlastic,
						})
					end
				end,
				{ variant = i + (if side < 0 then 1 else 3) }
			)
		end
		-- Ivy climbing the wall above the bed.
		Assets.place(props, "vines", onSideWall(roomCF, side, 8.4, 7.5), function(slot: Model, cf: CFrame)
			for k = 0, 7 do
				decor(
					slot,
					"Ivy",
					cf
						* CFrame.new(-2 + (k % 4) * 1.3, -1.5 + math.floor(k / 4) * 2.4, -0.06)
						* CFrame.Angles(0, 0, k * 0.7),
					Vector3.new(1.1, 1.1, 0.06),
					darker(palette.accent, 0.15),
					M.LeafyGrass
				)
			end
		end, { variant = if side < 0 then 1 else 2 })
	end
	-- Hanging baskets under the glass roof.
	for k, spot in { Vector3.new(-2.6, 0, 4.5), Vector3.new(2.6, 0, 8.5) } do
		Assets.place(props, "hangingPlant", rp(roomCF, spot.X, R.Height, spot.Z), function(slot: Model, cf: CFrame)
			decor(slot, "Chain", cf * CFrame.new(0, -1, 0), Vector3.new(0.08, 2, 0.08), palette.trim, M.Metal)
			Kit.cylinder(slot, {
				name = "Basket",
				cf = cf * CFrame.new(0, -2.4, 0) * CFrame.Angles(0, 0, math.pi / 2),
				size = Vector3.new(0.8, 1.4, 1.4),
				color = Color3.fromRGB(150, 110, 70),
				material = M.WoodPlanks,
			})
			for j = 0, 4 do
				decor(
					slot,
					"Trail",
					cf * CFrame.Angles(0, j * 1.25, 0) * CFrame.new(0.6, -3.1, 0),
					Vector3.new(0.3, 1.2, 0.06),
					palette.accent,
					M.LeafyGrass
				)
			end
		end, { variant = k })
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
	Assets.place(
		props,
		"wateringCan",
		facingDoor(roomCF, 3.4, 0, 1.6) * CFrame.Angles(0, 0.6, 0),
		function(slot: Model, cf: CFrame)
			decor(
				slot,
				"WateringCan",
				cf * CFrame.new(0, 0.7, 0),
				Vector3.new(1.4, 1.4, 0.9),
				Color3.fromRGB(80, 150, 200),
				M.Metal
			)
		end
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
	-- Scrap heaps, oil drums, a toolbox, gears on the walls and a crane magnet hanging over it all. (The lab's
	-- bench stands where the second heap would.)
	local heaps = { Vector3.new(-4.6, 0, 6.2), Vector3.new(4.4, 0, 3.6) }
	if palette.style == "lab" then
		table.remove(heaps, 2)
	end
	for k, spot in heaps do
		local scrapRng = subRng(rng)
		Assets.place(
			props,
			"scrapPile",
			facingDoor(roomCF, spot.X, 0, spot.Z) * CFrame.Angles(0, k * 1.3, 0),
			function(slot: Model, cf: CFrame)
				for _ = 1, 5 do
					local size = Vector3.new(0.5 + scrapRng() * 1.5, 0.3 + scrapRng() * 0.8, 0.5 + scrapRng() * 1.2)
					decor(
						slot,
						"Scrap",
						cf
							* CFrame.new((scrapRng() - 0.5) * 3, size.Y / 2, (scrapRng() - 0.5) * 2.4)
							* CFrame.Angles(0, scrapRng() * 3, 0),
						size,
						palette.prop:Lerp(Color3.new(0.3, 0.3, 0.3), scrapRng() * 0.5),
						M.CorrodedMetal
					)
				end
			end,
			{ variant = k }
		)
	end
	for _, side in { -1, 1 } do
		Assets.place(props, "metalBarrel", facingDoor(roomCF, side * 6, 0, 12.2), function(slot: Model, cf: CFrame)
			Kit.cylinder(slot, {
				name = "Drum",
				cf = cf * CFrame.new(0, 1.4, 0) * CFrame.Angles(0, 0, math.pi / 2),
				size = Vector3.new(2.8, 1.8, 1.8),
				color = darker(palette.accent, 0.2),
				material = M.Metal,
				shadow = true,
			})
			for _, y in { 0.5, 1.4, 2.3 } do
				Kit.cylinder(slot, {
					name = "Hoop",
					cf = cf * CFrame.new(0, y, 0) * CFrame.Angles(0, 0, math.pi / 2),
					size = Vector3.new(0.12, 1.86, 1.86),
					color = darker(palette.accent, 0.45),
					material = M.Metal,
				})
			end
		end, { variant = if side < 0 then 1 else 2 })
		collider(props, rp(roomCF, side * 6, 1.4, 12.2), Vector3.new(1.9, 2.8, 1.9))
		Assets.place(props, "gears", onSideWall(roomCF, side, 8.6, 7.5), function(slot: Model, cf: CFrame)
			for k, spec in { { -1, 0.4, 2 }, { 0.9, -0.5, 1.5 }, { 0.6, 1.2, 1 } } do
				Kit.cylinder(slot, {
					name = "Gear" .. k,
					cf = cf * CFrame.new(spec[1], spec[2], -0.15 - k * 0.05) * CFrame.Angles(0, math.pi / 2, 0),
					size = Vector3.new(0.25, spec[3], spec[3]),
					color = if k == 2 then palette.trim else palette.prop,
					material = M.Metal,
				})
			end
		end, { variant = if side < 0 then 1 else 2 })
	end
	Assets.place(
		props,
		"toolbox",
		facingDoor(roomCF, -1.6, 0, 2.6) * CFrame.Angles(0, -0.4, 0),
		function(slot: Model, cf: CFrame)
			decor(
				slot,
				"Toolbox",
				cf * CFrame.new(0, 0.5, 0),
				Vector3.new(1.8, 1, 0.9),
				Color3.fromRGB(190, 40, 40),
				M.Metal
			)
			decor(
				slot,
				"Grip",
				cf * CFrame.new(0, 1.15, 0),
				Vector3.new(1, 0.15, 0.15),
				Color3.fromRGB(30, 30, 30),
				M.Metal
			)
		end
	)
	Assets.place(props, "electromagnet", rp(roomCF, 0, R.Height, 7.5), function(slot: Model, cf: CFrame)
		decor(
			slot,
			"Cable",
			cf * CFrame.new(0, -1.5, 0),
			Vector3.new(0.18, 3, 0.18),
			Color3.fromRGB(40, 40, 44),
			M.Metal
		)
		Kit.cylinder(slot, {
			name = "Disc",
			cf = cf * CFrame.new(0, -3.4, 0) * CFrame.Angles(0, 0, math.pi / 2),
			size = Vector3.new(0.9, 3.2, 3.2),
			color = palette.trim,
			material = M.Metal,
		})
	end)
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
	elseif palette.style == "medal" or palette.style == "legend" then
		-- A medal on the lid (a diamond on a ribbon); the legend case adds a glowing rim.
		piece("Ribbon", CFrame.new(0, -1.25 * s, -0.53 * s), Vector3.new(0.34, 0.9, 0.04), palette.trim, M.Fabric)
		piece(
			"Medal",
			CFrame.new(0, -1.85 * s, -0.55 * s) * CFrame.Angles(0, 0, math.pi / 4),
			Vector3.new(0.55, 0.55, 0.06),
			palette.accent,
			palette.accentMaterial
		)
		if palette.style == "legend" then
			piece("Glow", CFrame.new(0, -2.95 * s, 0), Vector3.new(2.6, 0.08, 0.9), palette.trim, M.Neon)
			piece("Crown", CFrame.new(0, -0.5 * s, 0), Vector3.new(2.6, 0.08, 0.9), palette.trim, M.Neon)
		end
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
