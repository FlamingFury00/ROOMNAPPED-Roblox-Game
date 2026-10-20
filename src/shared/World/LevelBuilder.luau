--!strict
--[[
	LevelBuilder: assembles a layout (LayoutTypes.LayoutDef) into hotel geometry plus the Runtime
	description every server system consumes (S10 level assembly, A01 modular kit, R11 geometry contract).

	The build is deterministic for a given layout (seeded decoration), contains no gameplay logic and
	validates the layout as it goes: anything that would break the contract (overlapping footprints, a
	socket on a pit, a dangling link...) is reported in runtime.errors, and the test suite fails on it.

	Server-owned gameplay parts:
	  RN_Zone           zone marker parts (attributes ZoneId, ZoneKind)
	  RN_IceCollider    ice walkway for a basin (CanCollide toggled by the effect service)
	  RN_VineCollider   vine bridge collider
	  RN_GateCollider   alcove gate bars
	  RN_Door           sliding/opening doors animated by clients (attributes Open, OpenOffset)
	  RN_Crate          crate colliders moved by the server, smoothed by clients
]]

local Geometry = require(script.Parent.Geometry)
local Kit = require(script.Parent.Kit)
local Props = require(script.Parent.Props)
local Palette = require(script.Parent.Palette)
local LayoutTypes = require(script.Parent.LayoutTypes)
local RoomPrefabs = require(script.Parent.RoomPrefabs)
local MathUtil = require(script.Parent.Parent.Util.MathUtil)

type LayoutDef = LayoutTypes.LayoutDef
type ModuleDef = LayoutTypes.ModuleDef
type TileInfo = LayoutTypes.TileInfo
type Runtime = LayoutTypes.Runtime
type Box = LayoutTypes.Box
type Theme = Palette.Theme

local LevelBuilder = {}

local T = Geometry.Tile
local HALF = Geometry.Half
local INNER = Geometry.Inner
local CEIL = Geometry.Ceiling
local PIT = Geometry.Pit
local M = Enum.Material

local HEADINGS: { [number]: Vector3 } = {
	[0] = Vector3.new(0, 0, 1),
	[1] = Vector3.new(-1, 0, 0),
	[2] = Vector3.new(0, 0, -1),
	[3] = Vector3.new(1, 0, 0),
}

local PIT_KINDS: { [string]: boolean } = { Basin = true, Gap = true }
local SINGLE_TILE: { [string]: boolean } = {
	Elevator = true,
	Turn = true,
	Target = true,
	Fire = true,
	Puddle = true,
	Carts = true,
}

type Ctx = {
	layout: LayoutDef,
	theme: Theme,
	rng: () -> number,
	model: Model,
	structure: Folder,
	decor: Folder,
	zones: Folder,
	interact: Folder,
	movers: Folder,
	runtime: Runtime,
	errors: { string },
	roomNumber: number,
	shadowLights: number,
	moduleTiles: { [number]: { number } },
	features: { [number]: { L: string?, R: string? } }, -- tile index -> wall feature per side
	zoneIds: { [string]: string },
	crateRuns: { [number]: boolean }, -- runs with an off-centre crate rail (kept free of floor props)
}

-- Coordinate helpers -----------------------------------------------------------------------------

-- Typed fallbacks for optional authoring lists/maps (keeps the type checker precise).
local function crates(mod: ModuleDef): { LayoutTypes.CrateDef }
	return mod.crates or {}
end
local function plates(mod: ModuleDef): { LayoutTypes.PlateDef }
	return mod.plates or {}
end
local function keysOf(mod: ModuleDef): { LayoutTypes.KeyDef }
	return mod.keys or {}
end
local function levers(mod: ModuleDef): { LayoutTypes.LeverDef }
	return mod.levers or {}
end
local function alcoves(mod: ModuleDef): { LayoutTypes.AlcoveDef }
	return mod.alcoves or {}
end
local function socketsOf(mod: ModuleDef): { [number]: { L: string?, R: string? } }
	return mod.sockets or {}
end
local function strings(t: { string }?): { string }
	return t or {}
end

local function tcf(cf: CFrame, x: number, y: number, a: number): CFrame
	return cf * CFrame.new(x, y, -a)
end

local function tpt(cf: CFrame, x: number, y: number, a: number): Vector3
	return cf * Vector3.new(x, y, -a)
end

local function box(cf: CFrame, x: number, y: number, a: number, sx: number, sy: number, sa: number): Box
	return { cf = tcf(cf, x, y, a), size = Vector3.new(sx, sy, sa) }
end

local function err(ctx: Ctx, message: string)
	table.insert(ctx.errors, message)
end

local function sideSign(side: string): number
	return if side == "R" then 1 else -1
end

local function cellKey(gx: number, gz: number): string
	return gx .. "," .. gz
end

local function moduleLength(mod: ModuleDef): number
	if SINGLE_TILE[mod.kind] then
		return 1
	end
	return math.max(1, math.floor(mod.len or 1))
end

-- Interval subtraction: returns the parts of [lo, hi] not covered by `holes` (each {a0, a1}).
local function subtract(lo: number, hi: number, holes: { { number } }): { { number } }
	local segments = { { lo, hi } }
	for _, hole in holes do
		local nextSegments = {}
		for _, seg in segments do
			if hole[2] <= seg[1] or hole[1] >= seg[2] then
				table.insert(nextSegments, seg)
			else
				if hole[1] > seg[1] then
					table.insert(nextSegments, { seg[1], hole[1] })
				end
				if hole[2] < seg[2] then
					table.insert(nextSegments, { hole[2], seg[2] })
				end
			end
		end
		segments = nextSegments
	end
	local out = {}
	for _, seg in segments do
		if seg[2] - seg[1] > 0.05 then
			table.insert(out, seg)
		end
	end
	return out
end

-- Walls ------------------------------------------------------------------------------------------

export type Opening = { from: number, to: number, height: number }

--[[
	Build one straight wall in tile space.
	axis = "x": side wall at x = pos running along a in [from, to]
	axis = "a": end wall at a = pos running along x in [from, to]
	bottom: lowest y of the wall (pits extend walls downwards)
]]
local function wall(
	ctx: Ctx,
	cf: CFrame,
	axis: string,
	pos: number,
	from: number,
	to: number,
	openings: { Opening },
	bottom: number?
)
	local theme = ctx.theme
	local yb = bottom or 0
	local inward = -math.sign(pos) -- direction from the wall towards the corridor centre
	local innerFace = pos + inward * 0.5
	local holes = {}
	for _, o in openings do
		table.insert(holes, { o.from, o.to })
	end

	-- A layer spans from `outer` to `inner`, measured from the wall's inner face (positive = into the
	-- corridor). The structural wall is (-1, 0); decor layers protrude into the corridor.
	local function place(
		u0: number,
		u1: number,
		y0: number,
		y1: number,
		outer: number,
		inner: number,
		color: Color3,
		material: Enum.Material,
		isSolid: boolean,
		name: string
	)
		local len = u1 - u0
		if len <= 0.01 or y1 - y0 <= 0.01 then
			return
		end
		local mid = (u0 + u1) / 2
		local thickness = inner - outer
		local centre = innerFace + inward * ((outer + inner) / 2)
		local size, partCF
		if axis == "x" then
			size = Vector3.new(thickness, y1 - y0, len)
			partCF = tcf(cf, centre, (y0 + y1) / 2, mid)
		else
			size = Vector3.new(len, y1 - y0, thickness)
			partCF = tcf(cf, mid, (y0 + y1) / 2, centre)
		end
		if isSolid then
			Kit.solid(ctx.structure, name, partCF, size, color, material)
		else
			Kit.decor(ctx.decor, name, partCF, size, color, material)
		end
	end

	for _, seg in subtract(from, to, holes) do
		if yb < 0 then
			place(seg[1], seg[2], yb, 0, -1, 0, theme.pitWall, theme.pitMaterial, true, "PitWall")
		end
		place(seg[1], seg[2], 0, CEIL, -1, 0, theme.wall, theme.wallMaterial, true, "Wall")
		place(seg[1], seg[2], 0, 4.2, 0, 0.25, theme.wainscot, theme.wainscotMaterial, false, "Wainscot")
		place(seg[1], seg[2], 4.2, 4.55, 0, 0.42, theme.trim, theme.trimMaterial, false, "ChairRail")
		place(
			seg[1],
			seg[2],
			0,
			0.75,
			0,
			0.36,
			theme.wainscot:Lerp(Color3.new(0, 0, 0), 0.25),
			theme.wainscotMaterial,
			false,
			"Baseboard"
		)
		place(seg[1], seg[2], CEIL - 0.7, CEIL, 0, 0.5, theme.trim, theme.trimMaterial, false, "Crown")
	end
	for _, o in openings do
		if o.height < CEIL then
			place(o.from, o.to, o.height, CEIL, -1, 0, theme.wall, theme.wallMaterial, true, "Lintel")
			place(o.from, o.to, CEIL - 0.7, CEIL, 0, 0.5, theme.trim, theme.trimMaterial, false, "Crown")
		end
		if yb < 0 then
			place(o.from, o.to, yb, 0, -1, 0, theme.pitWall, theme.pitMaterial, true, "PitWall")
		end
	end
end

-- Floors & ceilings --------------------------------------------------------------------------------

local function floorTile(ctx: Ctx, cf: CFrame, a0: number, a1: number, carpet: boolean)
	local theme = ctx.theme
	local len = a1 - a0
	local mid = (a0 + a1) / 2
	Kit.solid(ctx.structure, "Floor", tcf(cf, 0, -0.5, mid), Vector3.new(T, 1, len), theme.floor, theme.floorMaterial)
	if carpet then
		Kit.decor(
			ctx.decor,
			"Carpet",
			tcf(cf, 0, 0.04, mid),
			Vector3.new(9, 0.08, len),
			theme.carpet,
			theme.carpetMaterial
		)
		for _, x in { -4.7, 4.7 } do
			Kit.decor(
				ctx.decor,
				"CarpetBorder",
				tcf(cf, x, 0.05, mid),
				Vector3.new(0.45, 0.1, len),
				theme.carpetBorder,
				theme.carpetMaterial
			)
		end
	end
end

local function ceilingTile(ctx: Ctx, cf: CFrame, a0: number, a1: number)
	local len = a1 - a0
	Kit.solid(
		ctx.structure,
		"Ceiling",
		tcf(cf, 0, CEIL + 0.5, (a0 + a1) / 2),
		Vector3.new(T, 1, len),
		ctx.theme.ceiling,
		ctx.theme.ceilingMaterial
	)
end

local function lampAt(ctx: Ctx, cf: CFrame, a: number)
	local shadows = false
	if ctx.shadowLights < 10 and ctx.rng() < 0.6 then
		shadows = true
		ctx.shadowLights += 1
	end
	Props.ceilingLamp(ctx.decor, tcf(cf, 0, CEIL, a), ctx.theme, shadows)
end

-- Route walking -------------------------------------------------------------------------------------

local function walkRoute(ctx: Ctx, origin: CFrame)
	local layout = ctx.layout
	local runtime = ctx.runtime
	local gx, gz, heading = 0, 0, 0
	local run, runStartIndex = 1, 1
	local previousHeading = 0
	for moduleIndex, mod in layout.modules do
		ctx.moduleTiles[moduleIndex] = {}
		local len = moduleLength(mod)
		for offset = 1, len do
			local index = #runtime.tiles + 1
			if index > 1 and heading ~= previousHeading then
				run += 1
				runStartIndex = index
			end
			previousHeading = heading
			local key = cellKey(gx, gz)
			if runtime.cells[key] then
				err(ctx, string.format("route overlaps itself at cell %s (module %d)", key, moduleIndex))
			end
			runtime.cells[key] = "tile"
			local centre = origin * Vector3.new(gx * T, 0, gz * T)
			local cf = CFrame.lookAt(centre, centre + HEADINGS[heading])
			local tile: TileInfo = {
				index = index,
				gx = gx,
				gz = gz,
				heading = heading,
				cf = cf,
				kind = mod.kind,
				module = moduleIndex,
				offset = offset,
				run = run,
				runAlong = (index - runStartIndex) * T,
				hazard = mod.id,
				safe = not PIT_KINDS[mod.kind],
			}
			table.insert(runtime.tiles, tile)
			table.insert(ctx.moduleTiles[moduleIndex], index)
			if mod.kind == "Turn" then
				heading = (heading + (if mod.dir == "R" then 1 else -1)) % 4
			end
			local step = HEADINGS[heading]
			gx += math.round(step.X)
			gz += math.round(step.Z)
		end
	end
end

-- The cell beside / behind / ahead of a tile.
local function neighbourCell(tile: TileInfo, lateral: number, along: number): string
	local look = HEADINGS[tile.heading]
	local right = HEADINGS[(tile.heading + 1) % 4]
	local gx = tile.gx + math.round(look.X) * along + math.round(right.X) * lateral
	local gz = tile.gz + math.round(look.Z) * along + math.round(right.Z) * lateral
	return cellKey(gx, gz)
end

local function claimCell(ctx: Ctx, key: string, what: string)
	local existing = ctx.runtime.cells[key]
	if existing then
		err(ctx, string.format("%s footprint overlaps %s at cell %s", what, existing, key))
	else
		ctx.runtime.cells[key] = what
	end
end

-- Module frame for multi-tile hazards: centre of the module, oriented with its heading.
local function moduleFrame(ctx: Ctx, moduleIndex: number): (CFrame, number, { number })
	local indices = ctx.moduleTiles[moduleIndex]
	local first = ctx.runtime.tiles[indices[1]]
	local last = ctx.runtime.tiles[indices[#indices]]
	local centre = (first.cf.Position + last.cf.Position) / 2
	local cf = CFrame.lookAt(centre, centre + HEADINGS[first.heading])
	return cf, #indices * T, indices
end

-- Side features ---------------------------------------------------------------------------------------

local function nextRoomNumber(ctx: Ctx): string
	ctx.roomNumber += 1
	return tostring(ctx.roomNumber)
end

local function decorateWall(ctx: Ctx, tile: TileInfo, side: string, hasDoor: boolean)
	local s = sideSign(side)
	local function onWall(a: number, y: number): CFrame
		-- Wall-mounted prop frame: LookVector into the corridor.
		local p = tpt(tile.cf, s * INNER, y, a)
		return CFrame.lookAt(p, p + (tile.cf.Position - tpt(tile.cf, s * INNER, 0, 0)).Unit)
	end
	if hasDoor then
		Props.decorDoor(ctx.decor, onWall(0, 0), ctx.theme, nextRoomNumber(ctx), ctx.rng)
		Props.wallSconce(ctx.decor, onWall(3.6, 6.4), ctx.theme, ctx.rng() < 0.5)
	else
		if ctx.rng() < 0.55 then
			Props.painting(ctx.decor, onWall(0, 7.6), ctx.theme, ctx.rng, 4 + ctx.rng() * 1.5, 3)
		elseif ctx.rng() < 0.5 then
			Props.mirror(ctx.decor, onWall(0, 7.4), ctx.theme)
		else
			Props.wallClock(ctx.decor, onWall(0, 8.5), ctx.theme)
		end
		Props.wallSconce(ctx.decor, onWall(-4.5, 6.4), ctx.theme, true)
		Props.wallSconce(ctx.decor, onWall(4.5, 6.4), ctx.theme, false)
	end
end

local function floorProp(ctx: Ctx, tile: TileInfo, side: string, a: number)
	local s = sideSign(side)
	local roll = ctx.rng()
	local inward = (tile.cf.Position - tpt(tile.cf, s * INNER, 0, 0)).Unit
	local function standing(depth: number): CFrame
		local p = tpt(tile.cf, s * (INNER - depth / 2 - 0.2), 0, a)
		return CFrame.lookAt(p, p + inward)
	end
	local proxySize: Vector3
	local cf: CFrame
	if roll < 0.3 then
		cf = standing(1.8)
		Props.bench(ctx.decor, cf, ctx.theme)
		proxySize = Vector3.new(4.4, 3.6, 1.9)
	elseif roll < 0.55 then
		cf = standing(1.4)
		Props.sideTable(ctx.decor, cf, ctx.theme, ctx.rng)
		proxySize = Vector3.new(2.4, 2.7, 1.4)
	elseif roll < 0.75 then
		cf = standing(2)
		Props.plant(ctx.decor, cf, ctx.theme, ctx.rng)
		proxySize = Vector3.new(1.8, 2, 1.8)
	elseif roll < 0.9 then
		cf = standing(2.4)
		Props.luggageCart(ctx.decor, cf, ctx.theme, ctx.rng)
		proxySize = Vector3.new(4.6, 6, 2.4)
	else
		cf = standing(1)
		Props.umbrellaStand(ctx.decor, cf, ctx.theme)
		proxySize = Vector3.new(1, 2.4, 1)
	end
	-- One invisible collision proxy per floor prop keeps physics cheap (S27).
	Kit.part(ctx.structure, {
		name = "PropCollider",
		cf = cf * CFrame.new(0, proxySize.Y / 2, 0),
		size = proxySize,
		transparency = 1,
		solid = true,
		shadow = false,
	})
end

-- Socket doorway (S06, U05). The socket door slides open when a room is deployed.
local function buildSocket(ctx: Ctx, tile: TileInfo, side: string, socketId: string)
	local runtime = ctx.runtime
	local s = sideSign(side)
	local def = ctx.layout.sockets[socketId]
	if not def then
		err(ctx, "socket " .. socketId .. " has no definition in layout.sockets")
		def = {}
	end
	if runtime.sockets[socketId] then
		err(ctx, "duplicate socket id " .. socketId)
	end
	claimCell(ctx, neighbourCell(tile, s, 0), "room " .. socketId)
	local inward = (tile.cf.Position - tpt(tile.cf, s * INNER, 0, 0)).Unit
	local doorPos = tpt(tile.cf, s * INNER, 0, 0)
	local doorCF = CFrame.lookAt(doorPos, doorPos + inward)
	local roomOrigin = tpt(tile.cf, s * HALF, 0, 0)
	local roomCF = CFrame.lookAt(roomOrigin, roomOrigin - inward)
	local theme = ctx.theme
	local door = Geometry.SocketDoor

	-- Frame and marker.
	local function onDoor(x: number, y: number, z: number): CFrame
		return doorCF * CFrame.new(x, y, -z)
	end
	Kit.decor(
		ctx.decor,
		"SocketFrameL",
		onDoor(-door.Width / 2 - 0.35, door.Height / 2, 0.15),
		Vector3.new(0.7, door.Height + 0.7, 0.4),
		theme.doorFrame,
		theme.trimMaterial
	)
	Kit.decor(
		ctx.decor,
		"SocketFrameR",
		onDoor(door.Width / 2 + 0.35, door.Height / 2, 0.15),
		Vector3.new(0.7, door.Height + 0.7, 0.4),
		theme.doorFrame,
		theme.trimMaterial
	)
	Kit.decor(
		ctx.decor,
		"SocketFrameTop",
		onDoor(0, door.Height + 0.35, 0.15),
		Vector3.new(door.Width + 1.4, 0.7, 0.4),
		theme.doorFrame,
		theme.trimMaterial
	)
	local marker = Kit.part(ctx.interact, {
		name = "SocketMarker_" .. socketId,
		cf = onDoor(0, 0.06, 1.6),
		size = Vector3.new(door.Width, 0.08, 3),
		color = Color3.fromRGB(255, 214, 120),
		material = M.Neon,
		transparency = 0.55,
		attrs = { SocketId = socketId },
		tag = "RN_SocketMarker",
	})
	marker.CastShadow = false
	local plaque = Kit.decor(
		ctx.decor,
		"SocketPlaque",
		onDoor(0, door.Height + 1.25, 0.2),
		Vector3.new(4.2, 0.9, 0.12),
		theme.brass,
		M.Foil
	)
	Kit.surfaceText(plaque, {
		face = Enum.NormalId.Front,
		text = "SUITE " .. socketId,
		color = Color3.fromRGB(40, 28, 20),
		font = Font.new("rbxasset://fonts/families/Fondamento.json", Enum.FontWeight.Bold),
	})
	-- Closed socket door: two panels that slide into the wall when a room is deployed.
	for _, panelSide in { -1, 1 } do
		local closed = onDoor(panelSide * door.Width / 4, door.Height / 2, -0.3)
		local panel = Kit.part(ctx.movers, {
			name = "SocketDoor_" .. socketId,
			cf = closed,
			size = Vector3.new(door.Width / 2, door.Height, 0.35),
			color = theme.door,
			material = theme.doorMaterial,
			solid = true,
			tag = "RN_Door",
			attrs = {
				Open = false,
				OpenOffset = Vector3.new(panelSide * (door.Width / 2 - 0.2), 0, 0),
				SocketId = socketId,
			},
		})
		panel.CastShadow = true
		Kit.decor(
			ctx.decor,
			"SocketDoorGlow",
			onDoor(panelSide * door.Width / 4, 0.05, 0.05),
			Vector3.new(door.Width / 2 - 0.3, 0.1, 0.3),
			theme.lamp,
			M.Neon
		)
	end

	-- Cold fields: the socket tile plus every linked zone region (computed after zones exist).
	runtime.sockets[socketId] = {
		id = socketId,
		tile = tile.index,
		side = side :: any,
		doorCF = doorCF,
		roomCF = roomCF,
		interactPoint = tpt(tile.cf, s * (INNER - 1.5), 3, 0),
		links = def,
		lanes = {},
		defaultDir = nil,
		coldFields = { box(tile.cf, 0, 5, 0, 14, 10, 16) },
		previewZones = {},
		protected = def.protected == true,
	}
	table.insert(runtime.socketOrder, socketId)
	ctx.features[tile.index] = ctx.features[tile.index] or {}
	(ctx.features[tile.index] :: any)[side] = "socket"
end

local function buildLever(ctx: Ctx, tile: TileInfo, side: string, leverId: string)
	local s = sideSign(side)
	local inward = (tile.cf.Position - tpt(tile.cf, s * INNER, 0, 0)).Unit
	local base = tpt(tile.cf, s * INNER, 4.4, 0)
	local cf = CFrame.lookAt(base, base + inward)
	local theme = ctx.theme
	Kit.decor(
		ctx.decor,
		"LeverPlate",
		cf * CFrame.new(0, 0, -0.1),
		Vector3.new(1.6, 2.6, 0.2),
		Color3.fromRGB(60, 62, 70),
		M.DiamondPlate
	)
	local warning = Kit.decor(
		ctx.decor,
		"LeverSign",
		cf * CFrame.new(0, 2.3, -0.12),
		Vector3.new(2.2, 0.8, 0.1),
		Color3.fromRGB(250, 210, 40),
		M.SmoothPlastic
	)
	Kit.surfaceText(warning, {
		face = Enum.NormalId.Front,
		text = "⚡ POWER",
		color = Color3.fromRGB(30, 30, 30),
		font = Font.new("rbxasset://fonts/families/FredokaOne.json", Enum.FontWeight.Bold),
	})
	local handle = Kit.part(ctx.interact, {
		name = "Lever_" .. leverId,
		cf = cf * CFrame.new(0, 0.3, -0.55) * CFrame.Angles(-0.6, 0, 0),
		size = Vector3.new(0.35, 1.8, 0.35),
		color = Color3.fromRGB(220, 40, 40),
		material = M.SmoothPlastic,
		query = true,
		tag = "RN_Lever",
		attrs = { LeverId = leverId, Flipped = false },
	})
	local _ = handle
	local _theme = theme
	ctx.runtime.levers[leverId] = { id = leverId, cf = cf * CFrame.new(0, 0, -1), tile = tile.index }
	ctx.features[tile.index] = ctx.features[tile.index] or {}
	(ctx.features[tile.index] :: any)[side] = "lever"
end

local function buildAlcove(ctx: Ctx, tile: TileInfo, side: string, alcoveId: string, gateId: string)
	local s = sideSign(side)
	claimCell(ctx, neighbourCell(tile, s, 0), "alcove " .. alcoveId)
	local theme = ctx.theme
	local inward = (tile.cf.Position - tpt(tile.cf, s * INNER, 0, 0)).Unit
	local origin = tpt(tile.cf, s * HALF, 0, 0)
	local acf = CFrame.lookAt(origin, origin - inward) -- alcove frame, LookVector into the alcove
	local function ap(x: number, y: number, d: number): CFrame
		return acf * CFrame.new(x, y, -d)
	end
	Kit.solid(ctx.structure, "AlcoveFloor", ap(0, -0.5, 4), Vector3.new(8, 1, 8), theme.floor, theme.floorMaterial)
	Kit.solid(ctx.structure, "AlcoveCeiling", ap(0, 9.5, 4), Vector3.new(8, 1, 8), theme.ceiling, theme.ceilingMaterial)
	Kit.solid(ctx.structure, "AlcoveBack", ap(0, 4.5, 8.5), Vector3.new(8, 9, 1), theme.wall, theme.wallMaterial)
	Kit.solid(ctx.structure, "AlcoveL", ap(-3.5, 4.5, 4), Vector3.new(1, 9, 8), theme.wall, theme.wallMaterial)
	Kit.solid(ctx.structure, "AlcoveR", ap(3.5, 4.5, 4), Vector3.new(1, 9, 8), theme.wall, theme.wallMaterial)
	local vaultLight = Kit.part(ctx.decor, {
		name = "AlcoveLight",
		cf = ap(0, 8.9, 4),
		size = Vector3.new(2, 0.15, 2),
		color = Color3.fromRGB(255, 220, 120),
		material = M.Neon,
	})
	Kit.pointLight(vaultLight, Color3.fromRGB(255, 220, 140), 1.2, 10, false)
	local sign = Kit.decor(ctx.decor, "AlcoveSign", ap(0, 9.2, -1.06), Vector3.new(4.5, 0.9, 0.1), theme.brass, M.Foil)
	Kit.surfaceText(sign, {
		face = Enum.NormalId.Back,
		text = "LOST & FOUND",
		color = Color3.fromRGB(40, 28, 20),
		font = Font.new("rbxasset://fonts/families/Fondamento.json", Enum.FontWeight.Bold),
	})
	-- Gate bars (server collider; clients slide them up when the gate opens).
	local gatePart = Kit.part(ctx.movers, {
		name = "Gate_" .. gateId,
		cf = ap(0, 3.6, -0.5),
		size = Vector3.new(6, 7.2, 0.3),
		color = theme.brass,
		material = M.Metal,
		transparency = 0,
		solid = true,
		tag = "RN_Door",
		attrs = { Open = false, OpenOffset = Vector3.new(0, 7, 0), GateId = gateId },
	})
	gatePart:AddTag("RN_GateCollider")
	ctx.runtime.gates[gateId] = {
		id = gateId,
		box = { cf = ap(0, 4, -0.5), size = Vector3.new(7, 8, 4) },
		alcove = alcoveId,
	}
	ctx.features[tile.index] = ctx.features[tile.index] or {}
	(ctx.features[tile.index] :: any)[side] = "alcove"
	return acf
end

-- Tile builders ------------------------------------------------------------------------------------------

local function sideOpenings(feature: string?): { Opening }
	if feature == "socket" then
		return {
			{
				from = -Geometry.SocketDoor.Width / 2,
				to = Geometry.SocketDoor.Width / 2,
				height = Geometry.SocketDoor.Height,
			},
		}
	elseif feature == "alcove" then
		return { { from = -3, to = 3, height = 8 } }
	end
	return {}
end

-- Floor props must never block a bypass entrance (ledges, beams and fire walkways start right at the edge
-- of the neighbouring hazard tile) or the path of an off-centre crate rail.
local function propBlocksRoute(ctx: Ctx, tile: TileInfo, a: number): boolean
	local neighbour = ctx.runtime.tiles[tile.index + (if a > 0 then 1 else -1)]
	if neighbour and (PIT_KINDS[neighbour.kind] or neighbour.kind == "Fire") then
		return true
	end
	return ctx.crateRuns[tile.run] == true
end

local function buildHallTile(ctx: Ctx, tile: TileInfo, mod: ModuleDef, allowDoors: boolean)
	local feats = ctx.features[tile.index] or {}
	floorTile(ctx, tile.cf, -HALF, HALF, true)
	ceilingTile(ctx, tile.cf, -HALF, HALF)
	lampAt(ctx, tile.cf, 0)
	for _, side in { "L", "R" } do
		local feature = (feats :: any)[side]
		wall(ctx, tile.cf, "x", sideSign(side) * 7.5, -HALF, HALF, sideOpenings(feature))
		if feature == nil then
			local hasDoor = allowDoors and ctx.rng() < 0.7
			decorateWall(ctx, tile, side, hasDoor)
			if mod.kind == "Hall" and not ctx.runtime.tiles[tile.index].hazard and ctx.rng() < 0.32 then
				local a = if ctx.rng() < 0.5 then 5.2 else -5.2
				if not propBlocksRoute(ctx, tile, a) then
					floorProp(ctx, tile, side, a)
				end
			end
		end
	end
	-- Exit signs every other tile, pointing back toward the elevator.
	if tile.index % 2 == 0 then
		local side = if tile.index % 4 == 0 then "R" else "L"
		local feature = (feats :: any)[side]
		if feature == nil or feature == "lever" then
			local s = sideSign(side)
			local inward = (tile.cf.Position - tpt(tile.cf, s * INNER, 0, 0)).Unit
			local p = tpt(tile.cf, s * INNER, 11.3, -5.5)
			Props.exitSign(ctx.decor, CFrame.lookAt(p, p + inward), if side == "R" then "right" else "left")
		end
	end
end

local function buildTurnTile(ctx: Ctx, tile: TileInfo, mod: ModuleDef)
	floorTile(ctx, tile.cf, -HALF, HALF, false)
	Props.rug(ctx.decor, tile.cf, Vector2.new(10, 10), ctx.theme.carpet, ctx.theme.carpetBorder)
	ceilingTile(ctx, tile.cf, -HALF, HALF)
	lampAt(ctx, tile.cf, 0)
	local outerSide = if mod.dir == "R" then "L" else "R"
	wall(ctx, tile.cf, "x", sideSign(outerSide) * 7.5, -HALF, HALF, {})
	wall(ctx, tile.cf, "a", 7.5, -HALF, HALF, {})
	-- Corner dressing: a big plant in the outer corner and a painting on the front wall.
	local s = sideSign(outerSide)
	local corner = tpt(tile.cf, s * 5.2, 0, 5.2)
	Props.plant(
		ctx.decor,
		CFrame.lookAt(corner, tile.cf.Position * Vector3.new(1, 0, 1) + Vector3.new(0, corner.Y, 0)),
		ctx.theme,
		ctx.rng,
		1.3
	)
	Kit.part(ctx.structure, {
		name = "PropCollider",
		cf = CFrame.new(corner + Vector3.new(0, 1.2, 0)),
		size = Vector3.new(2.2, 2.4, 2.2),
		transparency = 1,
		solid = true,
	})
	local front = tpt(tile.cf, -s * 1.5, 7.4, INNER)
	Props.painting(ctx.decor, CFrame.lookAt(front, front - tile.cf.LookVector), ctx.theme, ctx.rng, 5, 3.4)
	local sconce = tpt(tile.cf, s * INNER, 6.4, 0)
	Props.wallSconce(
		ctx.decor,
		CFrame.lookAt(sconce, sconce + (tile.cf.Position - tpt(tile.cf, s * INNER, 0, 0)).Unit),
		ctx.theme,
		true
	)
end

local function buildElevator(ctx: Ctx, tile: TileInfo)
	local theme = ctx.theme
	local E = Geometry.Elevator
	claimCell(ctx, neighbourCell(tile, 0, -1), "elevator")
	floorTile(ctx, tile.cf, -HALF, HALF, true)
	ceilingTile(ctx, tile.cf, -HALF, HALF)
	lampAt(ctx, tile.cf, 2)
	for _, side in { "L", "R" } do
		wall(ctx, tile.cf, "x", sideSign(side) * 7.5, -HALF, HALF, {})
	end
	wall(
		ctx,
		tile.cf,
		"a",
		-7.5,
		-HALF,
		HALF,
		{ { from = -E.DoorWidth / 2, to = E.DoorWidth / 2, height = E.DoorHeight } }
	)
	-- Car shell behind the back wall: a in [-8 - depth, -8].
	local a0, a1 = -HALF - E.Depth, -HALF
	local mid = (a0 + a1) / 2
	local half = E.Width / 2
	Kit.solid(
		ctx.structure,
		"CarFloor",
		tcf(tile.cf, 0, -0.5, mid),
		Vector3.new(E.Width + 2, 1, E.Depth),
		Color3.fromRGB(60, 40, 30),
		M.Wood
	)
	Kit.decor(
		ctx.decor,
		"CarRug",
		tcf(tile.cf, 0, 0.05, mid),
		Vector3.new(E.Width - 2, 0.1, E.Depth - 2),
		theme.carpet,
		M.Carpet
	)
	Kit.solid(
		ctx.structure,
		"CarCeiling",
		tcf(tile.cf, 0, E.Height + 0.5, mid),
		Vector3.new(E.Width + 2, 1, E.Depth),
		theme.brass,
		M.Foil
	)
	Kit.solid(
		ctx.structure,
		"CarWallL",
		tcf(tile.cf, -half - 0.5, E.Height / 2, mid),
		Vector3.new(1, E.Height, E.Depth),
		theme.brass,
		M.Foil
	)
	Kit.solid(
		ctx.structure,
		"CarWallR",
		tcf(tile.cf, half + 0.5, E.Height / 2, mid),
		Vector3.new(1, E.Height, E.Depth),
		theme.brass,
		M.Foil
	)
	Kit.solid(
		ctx.structure,
		"CarBack",
		tcf(tile.cf, 0, E.Height / 2, a0 - 0.5),
		Vector3.new(E.Width + 2, E.Height, 1),
		theme.brass,
		M.Foil
	)
	-- Interior details.
	for _, x in { -half + 0.15, half - 0.15 } do
		Kit.decor(
			ctx.decor,
			"Handrail",
			tcf(tile.cf, x, 3.4, mid),
			Vector3.new(0.3, 0.3, E.Depth - 1.5),
			theme.brass,
			M.Metal
		)
		for k = 0, 2 do
			Kit.decor(
				ctx.decor,
				"WoodPanel",
				tcf(tile.cf, x, 6, a0 + 1.7 + k * 3.2),
				Vector3.new(0.12, 6, 2.6),
				Color3.fromRGB(110, 66, 40),
				M.Wood
			)
		end
	end
	local mirror = Kit.decor(
		ctx.decor,
		"CarMirror",
		tcf(tile.cf, 0, 5.5, a0 + 0.1),
		Vector3.new(E.Width - 3, 6, 0.1),
		Color3.fromRGB(200, 215, 225),
		M.Glass
	)
	mirror.Reflectance = 0.4
	local panel = Kit.decor(
		ctx.decor,
		"ButtonPanel",
		tcf(tile.cf, half - 0.1, 4.6, -HALF - 1.6),
		Vector3.new(0.15, 2.2, 1),
		Color3.fromRGB(40, 36, 30),
		M.Metal
	)
	local _ = panel
	for k = 0, 3 do
		local button = Kit.ball(ctx.decor, {
			name = "Button",
			cf = tcf(tile.cf, half - 0.2, 3.8 + k * 0.5, -HALF - 1.6),
			size = Vector3.new(0.25, 0.25, 0.25),
			color = if k == 3 then Color3.fromRGB(255, 120, 60) else Color3.fromRGB(255, 220, 140),
			material = M.Neon,
		})
		button:AddTag("RN_Lamp")
	end
	local carLight = Kit.part(ctx.decor, {
		name = "CarLight",
		cf = tcf(tile.cf, 0, E.Height - 0.1, mid),
		size = Vector3.new(4, 0.15, 4),
		color = theme.lamp,
		material = M.Neon,
	})
	carLight:AddTag("RN_Lamp")
	Kit.pointLight(carLight, theme.lamp, 1.4, 16, true)
	-- Floor indicator and hotel sign in the corridor.
	local indicatorPos = tpt(tile.cf, 0, E.DoorHeight + 1.5, -INNER)
	local indicator = Kit.decor(
		ctx.decor,
		"FloorIndicator",
		CFrame.lookAt(indicatorPos, indicatorPos + tile.cf.LookVector) * CFrame.new(0, 0, -0.15),
		Vector3.new(3.4, 1.1, 0.2),
		Color3.fromRGB(30, 20, 14),
		M.Wood
	)
	Kit.surfaceText(indicator, {
		face = Enum.NormalId.Front,
		text = "▲ ESCAPE",
		color = Color3.fromRGB(255, 190, 90),
		font = Font.new("rbxasset://fonts/families/FredokaOne.json", Enum.FontWeight.Bold),
		lightInfluence = 0,
		brightness = 2,
	})
	indicator:AddTag("RN_ElevatorIndicator")
	for _, side in { -1, 1 } do
		local p = tpt(tile.cf, side * INNER, 7.6, 0)
		local inward = (tile.cf.Position - tpt(tile.cf, side * INNER, 0, 0)).Unit
		Props.signBoard(ctx.decor, CFrame.lookAt(p, p + inward), theme, "THE GRAND FOLD", 7, 1.6)
		local s2 = tpt(tile.cf, side * INNER, 6.2, 5)
		Props.wallSconce(ctx.decor, CFrame.lookAt(s2, s2 + inward), theme, true)
	end
	-- Sliding car doors (clients animate; server toggles collision).
	for _, side in { -1, 1 } do
		local door = Kit.part(ctx.movers, {
			name = "ElevatorDoor",
			cf = tcf(tile.cf, side * E.DoorWidth / 4, E.DoorHeight / 2, -HALF + 0.3),
			size = Vector3.new(E.DoorWidth / 2, E.DoorHeight, 0.3),
			color = theme.brass,
			material = M.Foil,
			solid = true,
			tag = "RN_Door",
			attrs = { Open = false, OpenOffset = Vector3.new(side * (E.DoorWidth / 2 - 0.2), 0, 0), Elevator = true },
		})
		door.CastShadow = true
		door.CanCollide = false
	end
	local runtime = ctx.runtime
	runtime.exit = box(tile.cf, 0, 4.5, mid, E.Width - 0.8, 9, E.Depth - 0.8)
	runtime.spawns = {}
	for _, spot in { { -2.6, -11.5 }, { 2.6, -11.5 }, { -2.6, -15 }, { 2.6, -15 } } do
		local p = tpt(tile.cf, spot[1], 3.2, spot[2])
		table.insert(runtime.spawns, CFrame.lookAt(p, p + tile.cf.LookVector))
	end
end

local function buildTarget(ctx: Ctx, tile: TileInfo, mod: ModuleDef)
	local theme = ctx.theme
	claimCell(ctx, neighbourCell(tile, 0, 1), "target room")
	floorTile(ctx, tile.cf, -HALF, HALF, true)
	ceilingTile(ctx, tile.cf, -HALF, HALF)
	lampAt(ctx, tile.cf, -2)
	for _, side in { "L", "R" } do
		wall(ctx, tile.cf, "x", sideSign(side) * 7.5, -HALF, HALF, {})
		local s = sideSign(side)
		local p = tpt(tile.cf, s * INNER, 6.4, 3)
		Props.wallSconce(
			ctx.decor,
			CFrame.lookAt(p, p + (tile.cf.Position - tpt(tile.cf, s * INNER, 0, 0)).Unit),
			theme,
			true
		)
	end
	local door = Geometry.SocketDoor
	wall(ctx, tile.cf, "a", 7.5, -HALF, HALF, { { from = -door.Width / 2, to = door.Width / 2, height = door.Height } })
	local roomId = mod.room or "Laundry"
	local origin = tpt(tile.cf, 0, 0, HALF)
	local roomCF = CFrame.lookAt(origin, origin + tile.cf.LookVector)
	local room = RoomPrefabs.build(roomId, nil, roomCF, ctx.layout.id .. "target")
	room.Name = "TargetRoom"
	room:SetAttribute("Target", true)
	room.Parent = ctx.model
	local doorPos = tpt(tile.cf, 0, 0, INNER)
	local doorCF = CFrame.lookAt(doorPos, doorPos - tile.cf.LookVector)
	local sign = Kit.decor(
		ctx.decor,
		"TargetSign",
		doorCF * CFrame.new(0, door.Height + 1.6, -0.25),
		Vector3.new(7, 1.4, 0.2),
		Color3.fromRGB(30, 20, 14),
		M.Wood
	)
	Kit.surfaceText(sign, {
		face = Enum.NormalId.Front,
		text = string.upper(roomId) .. " ROOM",
		color = Color3.fromRGB(255, 220, 140),
		font = Font.new("rbxasset://fonts/families/FredokaOne.json", Enum.FontWeight.Bold),
		lightInfluence = 0,
		brightness = 1.6,
	})
	local marker = Kit.part(ctx.interact, {
		name = "CaptureMarker",
		cf = doorCF * CFrame.new(0, 0.06, -2),
		size = Vector3.new(door.Width, 0.08, 3.4),
		color = Color3.fromRGB(255, 200, 80),
		material = M.Neon,
		transparency = 0.4,
		tag = "RN_CaptureMarker",
	})
	marker.CastShadow = false
	ctx.runtime.target = {
		room = roomId,
		doorCF = doorCF,
		roomCF = roomCF,
		capturePoint = tpt(tile.cf, 0, 3, INNER - 2),
		tile = tile.index,
	}
end

-- Hazard modules ----------------------------------------------------------------------------------------

local function zonePart(ctx: Ctx, name: string, b: Box, zoneId: string, kind: string, extra: { [string]: any }?): Part
	local attrs: { [string]: any } = { ZoneId = zoneId, ZoneKind = kind }
	if extra then
		for k, v in extra do
			attrs[k] = v
		end
	end
	return Kit.part(ctx.zones, {
		name = name,
		cf = b.cf,
		size = b.size,
		transparency = 1,
		tag = "RN_Zone",
		attrs = attrs,
	})
end

local function registerZone(ctx: Ctx, id: string, kind: string)
	if ctx.zoneIds[id] then
		err(ctx, string.format("zone id %s used twice (%s and %s)", id, ctx.zoneIds[id], kind))
	end
	ctx.zoneIds[id] = kind
end

local function pitInterior(mod: ModuleDef): (number, number)
	local x0, x1 = -INNER, INNER
	if mod.ledge == "L" then
		x0 = -INNER + Geometry.Ledge.Width
	elseif mod.ledge == "R" then
		x1 = INNER - Geometry.Ledge.Width
	end
	return x0, x1
end

local function buildPitModule(ctx: Ctx, moduleIndex: number, mod: ModuleDef)
	local theme = ctx.theme
	local cf, length, indices = moduleFrame(ctx, moduleIndex)
	local deep = if mod.kind == "Gap" then PIT.GapDepth else PIT.Depth
	local id = mod.id or ("pit" .. moduleIndex)
	local x0, x1 = pitInterior(mod)
	local pitWidth = x1 - x0
	local pitMid = (x0 + x1) / 2
	local la, lb = -length / 2, length / 2
	local pitA0 = la
	if mod.kind == "Gap" and mod.launch then
		pitA0 = la + 3
	end

	-- Per-tile walls (down into the pit), ceiling and lights.
	for _, index in indices do
		local tile = ctx.runtime.tiles[index]
		for _, side in { "L", "R" } do
			wall(ctx, tile.cf, "x", sideSign(side) * 7.5, -HALF, HALF, {}, -deep - 1)
		end
		ceilingTile(ctx, tile.cf, -HALF, HALF)
		lampAt(ctx, tile.cf, 0)
	end
	-- Pit shell.
	Kit.solid(
		ctx.structure,
		"PitFloor",
		tcf(cf, 0, -deep - 0.5, 0),
		Vector3.new(INNER * 2, 1, length),
		theme.pitFloor,
		theme.pitMaterial
	)
	for _, endA in { la - 0.5, lb + 0.5 } do
		Kit.solid(
			ctx.structure,
			"PitEnd",
			tcf(cf, 0, (-deep - 1) / 2 - 0.5, endA),
			Vector3.new(INNER * 2, deep, 1),
			theme.pitWall,
			theme.pitMaterial
		)
	end
	-- Broken floor fringe at both ends.
	Props.brokenEdge(
		ctx.decor,
		CFrame.lookAt(tpt(cf, pitMid, 0, pitA0), tpt(cf, pitMid, 0, pitA0 + 1)),
		pitWidth,
		theme,
		ctx.rng
	)
	Props.brokenEdge(
		ctx.decor,
		CFrame.lookAt(tpt(cf, pitMid, 0, lb), tpt(cf, pitMid, 0, lb - 1)),
		pitWidth,
		theme,
		ctx.rng
	)

	-- Bypass ledge with a rope railing (safe but slow - S10).
	if mod.ledge then
		local s = sideSign(mod.ledge)
		local lw = Geometry.Ledge.Width
		local lx = s * (INNER - lw / 2)
		Kit.solid(
			ctx.structure,
			"Ledge",
			tcf(cf, lx, -0.5, 0),
			Vector3.new(lw, 1, length),
			theme.floor:Lerp(Color3.new(0, 0, 0), 0.1),
			M.WoodPlanks
		)
		Kit.solid(
			ctx.structure,
			"LedgeSupport",
			tcf(cf, s * (INNER - lw + 0.3), (-deep - 1) / 2 - 0.5, 0),
			Vector3.new(0.6, deep, length),
			theme.pitWall,
			theme.pitMaterial
		)
		local railX = s * (INNER - lw)
		local posts = math.max(2, math.floor(length / 4) + 1)
		for i = 0, posts - 1 do
			local a = la + 0.5 + i * ((length - 1) / (posts - 1))
			Kit.post(ctx.decor, {
				name = "RailPost",
				cf = tcf(cf, railX, 0.8, a),
				height = 1.6,
				diameter = 0.3,
				color = theme.brass,
				material = M.Metal,
			})
		end
		Kit.decor(
			ctx.decor,
			"Rope",
			tcf(cf, railX, 1.45, 0),
			Vector3.new(0.18, 0.18, length - 0.6),
			Color3.fromRGB(150, 30, 40),
			M.Fabric
		)
		Kit.part(ctx.structure, {
			name = "RailCollider",
			cf = tcf(cf, railX, 0.8, 0),
			size = Vector3.new(0.4, 1.6, length),
			transparency = 1,
			solid = true,
		})
		table.insert(ctx.runtime.ledges, box(cf, lx, 2.5, 0, lw, 5, length))
		table.insert(ctx.runtime.safeFloors, box(cf, lx, 2.5, 0, lw, 5, length))
	end

	-- Narrow beam bypass for gaps.
	if mod.beam then
		local s = sideSign(mod.beam)
		local bw = Geometry.Beam.Width
		local bx = s * (INNER - bw / 2)
		Kit.solid(
			ctx.structure,
			"Beam",
			tcf(cf, bx, -0.4, (pitA0 + lb) / 2),
			Vector3.new(bw, 0.8, lb - pitA0),
			Color3.fromRGB(120, 84, 56),
			M.Wood
		)
		table.insert(ctx.runtime.ledges, box(cf, bx, 2.5, (pitA0 + lb) / 2, bw, 5, lb - pitA0))
		table.insert(ctx.runtime.safeFloors, box(cf, bx, 2.5, (pitA0 + lb) / 2, bw, 5, lb - pitA0))
	end

	local pitBox = box(cf, pitMid, -deep / 2, (pitA0 + lb) / 2, pitWidth, deep, lb - pitA0)
	table.insert(ctx.runtime.pits, { box = pitBox, zone = id, kind = mod.kind :: string })

	if mod.kind == "Basin" then
		registerZone(ctx, id, "basin")
		local surface = box(cf, pitMid, PIT.WaterSurface, 0, pitWidth, 0.2, length)
		zonePart(ctx, "BasinSurface_" .. id, surface, id, "basin", { Deep = true, Width = pitWidth, Length = length })
		local ice = Kit.part(ctx.zones, {
			name = "Ice_" .. id,
			cf = tcf(cf, pitMid, PIT.IceTop - PIT.IceThickness / 2, 0),
			size = Vector3.new(pitWidth, PIT.IceThickness, length),
			color = Color3.fromRGB(190, 230, 255),
			material = M.Ice,
			transparency = 1,
			solid = true,
			tag = "RN_IceCollider",
			attrs = { ZoneId = id },
			physics = PhysicalProperties.new(0.9, 0.02, 0.1, 100, 1),
		})
		ice.CanCollide = false
		-- Drain grate at the bottom (visible drain - R03).
		Kit.decor(
			ctx.decor,
			"Drain",
			tcf(cf, pitMid, -deep + 0.05, 0),
			Vector3.new(2.4, 0.1, 2.4),
			Color3.fromRGB(70, 70, 76),
			M.DiamondPlate
		)
		local wet = Props.wetFloorSign
		local signA = la - 1.5
		wet(ctx.decor, CFrame.lookAt(tpt(cf, pitMid + 3, 0, signA), tpt(cf, pitMid + 3, 0, signA - 1)))
		ctx.runtime.basins[id] = {
			id = id,
			deep = true,
			surface = surface,
			pit = pitBox,
			occupancy = box(cf, pitMid, 3, 0, pitWidth + 0.6, 6, length + 0.4),
			damage = box(cf, pitMid, -1.5, 0, pitWidth, 4, length),
			power = mod.power,
			tiles = indices,
		}
	else
		-- Gap: optional crate slot pillar, vine bridge and launch lip.
		if mod.launch then
			Kit.solid(
				ctx.structure,
				"LaunchLip",
				tcf(cf, 0, -0.5, la + 1.5),
				Vector3.new(INNER * 2, 1, 3),
				theme.floor,
				theme.floorMaterial
			)
			local ramp = Kit.part(ctx.structure, {
				name = "LaunchRamp",
				cf = tcf(cf, 0, 0.35, la + 1.6) * CFrame.Angles(math.rad(14), 0, 0),
				size = Vector3.new(INNER * 2 - 1, 0.6, 3.2),
				color = Color3.fromRGB(240, 200, 60),
				material = M.DiamondPlate,
				solid = true,
			})
			ramp:AddTag("RN_LaunchRamp")
			for i = -2, 2 do
				Kit.decor(
					ctx.decor,
					"RampArrow",
					tcf(cf, i * 2.6, 0.75, la + 1.6) * CFrame.Angles(math.rad(14), 0, 0) * CFrame.new(0, 0.32, 0),
					Vector3.new(0.6, 0.06, 1.6),
					Color3.fromRGB(40, 40, 40)
				)
			end
			local launchId = id .. "_launch"
			local lastIndex = indices[#indices]
			local after = ctx.runtime.tiles[lastIndex + 1]
			local landing = if after then tpt(after.cf, 0, 3, 1) else tpt(cf, 0, 3, lb + 4)
			local prevModule = ctx.layout.modules[moduleIndex - 1]
			local basinId = if prevModule and prevModule.kind == "Basin" then prevModule.id else nil
			if not basinId then
				err(ctx, "gap " .. id .. " has launch=true but the module before it is not a Basin")
			end
			ctx.runtime.launches[launchId] = {
				id = launchId,
				trigger = box(cf, 0, 2.5, la + 1.6, INNER * 2, 6, 3.6),
				landing = landing,
				direction = cf.LookVector,
				basin = basinId,
				slide = box(cf, 0, 2.5, la - T * 0.75, INNER * 2, 6, T * 1.5 + 3),
			}
			local feeding = if basinId then ctx.runtime.basins[basinId] else nil
			if feeding then
				-- The wind boost applies over the frozen basin and the ramp itself.
				local occ = feeding.occupancy
				ctx.runtime.launches[launchId].slide = {
					cf = occ.cf * CFrame.new(0, 0, -1.8),
					size = occ.size + Vector3.new(0, 0, 3.6),
				}
			end
		end
		if mod.slot then
			local slotCF = tcf(cf, 0, -Geometry.Crate.Size / 2, 0)
			Kit.solid(
				ctx.structure,
				"SlotPillar",
				tcf(cf, 0, (-deep - Geometry.Crate.Size) / 2, 0),
				Vector3.new(Geometry.Crate.Size, deep - Geometry.Crate.Size, Geometry.Crate.Size),
				theme.pitWall,
				theme.pitMaterial
			)
			local hint = Kit.part(ctx.decor, {
				name = "SlotHint",
				cf = tcf(cf, 0, -Geometry.Crate.Size + 0.05, 0),
				size = Vector3.new(Geometry.Crate.Size - 0.2, 0.1, Geometry.Crate.Size - 0.2),
				color = Color3.fromRGB(255, 200, 60),
				material = M.Neon,
				transparency = 0.35,
			})
			hint:AddTag("RN_SlotHint")
			if ctx.runtime.slots[mod.slot] then
				err(ctx, "crate " .. mod.slot .. " has two slots")
			end
			ctx.runtime.slots[mod.slot] =
				{ gap = id, cf = slotCF, run = ctx.runtime.tiles[indices[1]].run, centre = cf.Position }
		end
		if mod.vine then
			registerZone(ctx, mod.vine, "vine")
			local bridge = box(cf, 0, -0.35, (pitA0 + lb) / 2, 5, 0.7, lb - pitA0 + 1)
			local collider = Kit.part(ctx.zones, {
				name = "Vine_" .. mod.vine,
				cf = bridge.cf,
				size = bridge.size,
				color = Color3.fromRGB(80, 160, 60),
				material = M.LeafyGrass,
				transparency = 1,
				solid = true,
				tag = "RN_VineCollider",
				attrs = { ZoneId = mod.vine },
			})
			collider.CanCollide = false
			zonePart(ctx, "VineZone_" .. mod.vine, bridge, mod.vine, "vine", { Length = lb - pitA0 + 1 })
			-- Low planter bed at the near edge where the vine grows from. It is only a small step high so players
			-- walk straight over it onto the grown bridge.
			local planterA = la - 1.6
			Kit.solid(
				ctx.structure,
				"Planter",
				tcf(cf, 0, 0.3, planterA),
				Vector3.new(5.6, 0.6, 2.4),
				Color3.fromRGB(130, 86, 50),
				M.WoodPlanks
			)
			Kit.decor(
				ctx.decor,
				"PlanterSoil",
				tcf(cf, 0, 0.63, planterA),
				Vector3.new(5.2, 0.06, 2),
				Color3.fromRGB(70, 46, 30),
				M.Ground
			)
			ctx.runtime.vines[mod.vine] = {
				id = mod.vine,
				bridge = bridge,
				tile = indices[1],
				waterBasin = mod.waterFrom,
			}
		end
	end
end

-- Heat-shielded service walkway along one wall of a fire tile: the slow, always-safe bypass (S10/S11) for
-- squads without a water room. The flames stop short of it and a rail plus a glass shield separate it.
local function buildFireWalkway(ctx: Ctx, tile: TileInfo, side: string)
	local theme = ctx.theme
	local s = sideSign(side)
	local lw = Geometry.Ledge.Width
	local walkLength = 12
	local railX = s * (INNER - lw)
	Kit.decor(
		ctx.decor,
		"WalkwayGrating",
		tcf(tile.cf, s * (INNER - lw / 2), 0.07, 0),
		Vector3.new(lw - 0.2, 0.14, T),
		Color3.fromRGB(96, 98, 106),
		M.DiamondPlate
	)
	local posts = 4
	for i = 0, posts - 1 do
		local a = -walkLength / 2 + 0.3 + i * ((walkLength - 0.6) / (posts - 1))
		Kit.post(ctx.decor, {
			name = "RailPost",
			cf = tcf(tile.cf, railX, 0.8, a),
			height = 1.6,
			diameter = 0.3,
			color = theme.brass,
			material = M.Metal,
		})
	end
	Kit.decor(
		ctx.decor,
		"Handrail",
		tcf(tile.cf, railX, 1.6, 0),
		Vector3.new(0.22, 0.22, walkLength - 0.4),
		theme.brass,
		M.Metal
	)
	local shield = Kit.decor(
		ctx.decor,
		"HeatShield",
		tcf(tile.cf, railX, 5.1, 0),
		Vector3.new(0.14, 6.8, walkLength - 1),
		Color3.fromRGB(190, 225, 255),
		M.Glass
	)
	shield.Transparency = 0.65
	Kit.part(ctx.structure, {
		name = "RailCollider",
		cf = tcf(tile.cf, railX, 0.8, 0),
		size = Vector3.new(0.4, 1.6, walkLength),
		transparency = 1,
		solid = true,
	})
	local signPos = tpt(tile.cf, s * (INNER - 0.06), 6.2, -walkLength / 2 - 0.6)
	local inward = (tile.cf.Position - tpt(tile.cf, s * INNER, 0, 0)).Unit
	local sign = Kit.decor(
		ctx.decor,
		"WalkwaySign",
		CFrame.lookAt(signPos, signPos + inward),
		Vector3.new(2.6, 0.9, 0.1),
		Color3.fromRGB(40, 160, 80),
		M.SmoothPlastic
	)
	Kit.surfaceText(sign, {
		face = Enum.NormalId.Front,
		text = "SAFE WAY",
		color = Color3.fromRGB(255, 255, 255),
		font = Font.new("rbxasset://fonts/families/FredokaOne.json", Enum.FontWeight.Bold),
		lightInfluence = 0,
	})
	local lane = box(tile.cf, s * (INNER - lw / 2), 2.5, 0, lw, 5, walkLength)
	table.insert(ctx.runtime.ledges, lane)
end

local function buildFireTile(ctx: Ctx, tile: TileInfo, mod: ModuleDef)
	buildHallTile(ctx, tile, mod, false)
	local id = mod.id or ("F" .. tile.index)
	local poolId = id .. "_pool"
	registerZone(ctx, id, "fire")
	registerZone(ctx, poolId, "basin")
	-- The flames span the corridor unless a service walkway (mod.ledge) reserves one wall.
	local fireLo, fireHi = -INNER, INNER
	local walkSign = if mod.ledge then sideSign(mod.ledge) else 0
	if walkSign > 0 then
		fireHi = INNER - Geometry.Ledge.Width - 1
	elseif walkSign < 0 then
		fireLo = -INNER + Geometry.Ledge.Width + 1
	end
	if walkSign >= 0 then
		Props.debrisPile(ctx.decor, tcf(tile.cf, -4.6, 0, 0), 4, ctx.rng)
	end
	if walkSign <= 0 then
		Props.debrisPile(ctx.decor, tcf(tile.cf, 4.6, 0, 0), 4, ctx.rng)
	end
	-- Scorch marks.
	Kit.decor(
		ctx.decor,
		"Scorch",
		tcf(tile.cf, (fireLo + fireHi) / 2, 0.12, 0),
		Vector3.new(fireHi - fireLo - 1, 0.05, 6),
		Color3.fromRGB(30, 24, 22),
		M.Slate
	)
	local volume = box(tile.cf, (fireLo + fireHi) / 2, 3.5, 0, fireHi - fireLo, 7, 4.5)
	zonePart(ctx, "Fire_" .. id, volume, id, "fire")
	if mod.ledge then
		buildFireWalkway(ctx, tile, mod.ledge)
	end
	local surface = box(tile.cf, 0, 0.1, 0, INNER * 2, 0.2, 12)
	zonePart(
		ctx,
		"Pool_" .. poolId,
		surface,
		poolId,
		"basin",
		{ Deep = false, Width = INNER * 2, Length = 12, FirePool = id }
	)
	local ice = Kit.part(ctx.zones, {
		name = "Ice_" .. poolId,
		cf = tcf(tile.cf, 0, 0.1, 0),
		size = Vector3.new(INNER * 2, 0.2, 12),
		material = M.Ice,
		transparency = 1,
		solid = true,
		tag = "RN_IceCollider",
		attrs = { ZoneId = poolId },
		physics = PhysicalProperties.new(0.9, 0.02, 0.1, 100, 1),
	})
	ice.CanCollide = false
	ctx.runtime.fires[id] = { id = id, pool = poolId, volume = volume, tile = tile.index }
	ctx.runtime.basins[poolId] = {
		id = poolId,
		deep = false,
		surface = surface,
		pit = nil,
		occupancy = box(tile.cf, 0, 3, 0, INNER * 2, 6, 12),
		damage = nil,
		power = nil,
		tiles = { tile.index },
		fire = id,
	}
	ctx.zoneIds[id .. "#pool"] = poolId
end

local function buildPuddleTile(ctx: Ctx, tile: TileInfo, mod: ModuleDef)
	buildHallTile(ctx, tile, mod, false)
	local id = mod.id or ("P" .. tile.index)
	registerZone(ctx, id, "basin")
	local surface = box(tile.cf, 0, 0.1, 0, INNER * 2, 0.2, 12)
	zonePart(
		ctx,
		"Puddle_" .. id,
		surface,
		id,
		"basin",
		{ Deep = false, Width = INNER * 2, Length = 12, Powered = mod.power ~= nil }
	)
	local ice = Kit.part(ctx.zones, {
		name = "Ice_" .. id,
		cf = tcf(tile.cf, 0, 0.1, 0),
		size = Vector3.new(INNER * 2, 0.2, 12),
		material = M.Ice,
		transparency = 1,
		solid = true,
		tag = "RN_IceCollider",
		attrs = { ZoneId = id },
		physics = PhysicalProperties.new(0.9, 0.02, 0.1, 100, 1),
	})
	ice.CanCollide = false
	-- Exposed cable lying into the puddle.
	if mod.power then
		local wallPoint = tpt(tile.cf, INNER - 0.3, 3, -4)
		local floorPoint = tpt(tile.cf, 3, 0.2, -1)
		Props.pipeRun(ctx.decor, wallPoint, floorPoint, 0.35, Color3.fromRGB(30, 30, 30))
		local spark = Kit.part(ctx.decor, {
			name = "CableEnd",
			cf = CFrame.new(floorPoint),
			size = Vector3.new(0.6, 0.6, 0.6),
			color = Color3.fromRGB(150, 220, 255),
			material = M.Neon,
		})
		spark:AddTag("RN_CableSpark")
		spark:SetAttribute("ZoneId", id)
		Kit.decor(
			ctx.decor,
			"JunctionBox",
			CFrame.lookAt(wallPoint, wallPoint - tile.cf.RightVector) * CFrame.new(0, 0, 0.1),
			Vector3.new(1.4, 1.8, 0.5),
			Color3.fromRGB(80, 84, 90),
			M.DiamondPlate
		)
	end
	ctx.runtime.basins[id] = {
		id = id,
		deep = false,
		surface = surface,
		pit = nil,
		occupancy = box(tile.cf, 0, 3, 0, INNER * 2, 6, 12),
		damage = box(tile.cf, 0, 1.6, 0, INNER * 2, 3.4, 12),
		power = mod.power,
		tiles = { tile.index },
	}
end

local function buildCartsTile(ctx: Ctx, tile: TileInfo, mod: ModuleDef)
	buildHallTile(ctx, tile, mod, false)
	local id = mod.id or ("C" .. tile.index)
	for _, a in { -1.3, 1.3 } do
		Kit.decor(
			ctx.decor,
			"Rail",
			tcf(tile.cf, 0, 0.12, a),
			Vector3.new(INNER * 2, 0.2, 0.3),
			Color3.fromRGB(150, 150, 156),
			M.Metal
		)
	end
	for i = -6, 6, 2 do
		Kit.decor(
			ctx.decor,
			"Sleeper",
			tcf(tile.cf, i, 0.06, 0),
			Vector3.new(0.6, 0.12, 3.4),
			Color3.fromRGB(90, 60, 40),
			M.Wood
		)
	end
	for _, side in { -1, 1 } do
		local p = tpt(tile.cf, side * 6.9, 9.5, 0)
		local stripe = Kit.decor(
			ctx.decor,
			"CartWarning",
			CFrame.lookAt(p, p - tile.cf.RightVector * side) * CFrame.new(0, 0, -0.1),
			Vector3.new(3.2, 1, 0.1),
			Color3.fromRGB(250, 210, 40)
		)
		Kit.surfaceText(stripe, {
			face = Enum.NormalId.Front,
			text = "⚠ CARTS",
			color = Color3.fromRGB(30, 30, 30),
			font = Font.new("rbxasset://fonts/families/FredokaOne.json", Enum.FontWeight.Bold),
		})
	end
	registerZone(ctx, id, "cart")
	ctx.runtime.carts[id] = {
		id = id,
		tileCF = tile.cf,
		range = 4.4,
		speed = mod.cartSpeed or 9,
		size = Vector3.new(5, 4.6, 3.6),
		tile = tile.index,
	}
end

-- Crates, plates and keys ---------------------------------------------------------------------------------

local function runTiles(ctx: Ctx, run: number): { TileInfo }
	local out = {}
	for _, tile in ctx.runtime.tiles do
		if tile.run == run then
			table.insert(out, tile)
		end
	end
	return out
end

local function buildCrates(ctx: Ctx)
	local runtime = ctx.runtime
	local slots = runtime.slots
	for moduleIndex, mod in ctx.layout.modules do
		for _, crate in crates(mod) do
			local tileIndex = ctx.moduleTiles[moduleIndex][crate.at or 1]
			local tile = runtime.tiles[tileIndex]
			if not tile then
				err(ctx, "crate " .. crate.id .. " refers to a tile outside its module")
				continue
			end
			local tiles = runTiles(ctx, tile.run)
			local first, last = tiles[1], tiles[#tiles]
			-- Run frame: origin at the first tile centre, along = heading.
			local runCF = CFrame.lookAt(first.cf.Position, first.cf.Position + first.cf.LookVector)
			local startAlong = tile.runAlong + (crate.along or 0)
			local margin = Geometry.Crate.Size / 2 + 0.6
			local lo, hi = -HALF + margin, last.runAlong + HALF - margin
			-- A crate may never be blown into the elevator or the target tile: parked in front of either door it
			-- would block the only exit (S10) or the capture.
			for _, t in tiles do
				if t.kind == "Elevator" then
					lo = math.max(lo, t.runAlong + HALF + margin)
				elseif t.kind == "Target" then
					hi = math.min(hi, t.runAlong - HALF - margin)
				end
			end
			-- Pits on this run cut the rail unless they hold this crate's slot.
			local slot = slots[crate.id]
			local slotAlong: number? = nil
			for _, t in tiles do
				if PIT_KINDS[t.kind] then
					local pitLo, pitHi = t.runAlong - HALF, t.runAlong + HALF
					local isSlot = slot ~= nil and ctx.layout.modules[t.module].slot == crate.id
					if isSlot then
						local centreAlong = runCF:PointToObjectSpace(slot.centre).Z * -1
						slotAlong = centreAlong
						if centreAlong > startAlong then
							hi = math.min(hi, centreAlong)
						else
							lo = math.max(lo, centreAlong)
						end
					elseif pitHi <= startAlong then
						lo = math.max(lo, pitHi + margin)
					elseif pitLo >= startAlong then
						hi = math.min(hi, pitLo - margin)
					end
				elseif t.kind == "Fire" or t.kind == "Puddle" or t.kind == "Carts" then
					-- Floor hazards stop a rolling crate too: it never ends up in flames, live water or a cart track.
					local tileLo, tileHi = t.runAlong - HALF, t.runAlong + HALF
					if tileHi <= startAlong then
						lo = math.max(lo, tileHi + margin)
					elseif tileLo >= startAlong then
						hi = math.min(hi, tileLo - margin)
					else
						err(ctx, "crate " .. crate.id .. " starts on a " .. t.kind .. " tile")
					end
				end
			end
			if slot and slotAlong == nil then
				err(ctx, "crate " .. crate.id .. " slot is not on the crate's run")
			elseif slotAlong and (slotAlong < lo - 0.01 or slotAlong > hi + 0.01) then
				err(ctx, "crate " .. crate.id .. " cannot roll to its slot (a hazard or pit is in the way)")
			end
			if hi - lo < 1 then
				err(ctx, "crate " .. crate.id .. " has no room to move")
			end
			local railMid = (lo + hi) / 2
			local railCF = runCF * CFrame.new(crate.lateral, Geometry.Crate.Size / 2, -railMid)
			-- Rail frame: X axis along the run (rotate so +X = heading).
			railCF = railCF * CFrame.Angles(0, math.pi / 2, 0)
			local startCF = runCF * CFrame.new(crate.lateral, Geometry.Crate.Size / 2, -startAlong)
			local part = Kit.part(ctx.movers, {
				name = "Crate_" .. crate.id,
				cf = startCF,
				size = Vector3.new(Geometry.Crate.Size, Geometry.Crate.Size, Geometry.Crate.Size),
				color = if crate.metal then Color3.fromRGB(150, 156, 166) else Color3.fromRGB(176, 128, 76),
				material = if crate.metal then M.DiamondPlate else M.WoodPlanks,
				solid = true,
				tag = "RN_Crate",
				attrs = { CrateId = crate.id, Metal = crate.metal == true },
			})
			part.CastShadow = true
			Kit.surfaceText(part, {
				face = Enum.NormalId.Front,
				text = if crate.metal then "MAGNETIC" else "FRAGILE",
				color = if crate.metal then Color3.fromRGB(230, 40, 40) else Color3.fromRGB(120, 40, 30),
				font = Font.new("rbxasset://fonts/families/SpecialElite.json", Enum.FontWeight.Bold),
				pixelsPerStud = 20,
			})
			Kit.surfaceText(part, {
				face = Enum.NormalId.Back,
				text = if crate.metal then "MAGNETIC" else "FRAGILE",
				color = if crate.metal then Color3.fromRGB(230, 40, 40) else Color3.fromRGB(120, 40, 30),
				font = Font.new("rbxasset://fonts/families/SpecialElite.json", Enum.FontWeight.Bold),
				pixelsPerStud = 20,
			})
			local plates = {}
			for plateId, plate in runtime.plates do
				local local_ = railCF:PointToObjectSpace(plate.cf.Position)
				if math.abs(local_.Z) < 1.2 and math.abs(local_.X) <= (hi - lo) / 2 + 0.5 then
					table.insert(plates, plateId)
				end
			end
			table.sort(plates)
			runtime.crates[crate.id] = {
				id = crate.id,
				metal = crate.metal == true,
				railCF = railCF,
				railLength = hi - lo,
				startOffset = startAlong - railMid,
				slotOffset = if slotAlong then slotAlong - railMid else nil,
				slotCF = if slot then slot.cf else nil,
				plates = plates,
				tile = tileIndex,
			}
		end
	end
end

local function buildPlates(ctx: Ctx)
	for moduleIndex, mod in ctx.layout.modules do
		for _, plate in plates(mod) do
			local tile = ctx.runtime.tiles[ctx.moduleTiles[moduleIndex][plate.at or 1]]
			if not tile then
				err(ctx, "plate " .. plate.id .. " refers to a tile outside its module")
				continue
			end
			local cf = tcf(tile.cf, plate.lateral, 0, plate.along or 0)
			Kit.decor(
				ctx.decor,
				"PlateBase",
				cf * CFrame.new(0, 0.08, 0),
				Vector3.new(6.2, 0.16, 6.2),
				Color3.fromRGB(60, 60, 66),
				M.DiamondPlate
			)
			local top = Kit.part(ctx.interact, {
				name = "Plate_" .. plate.id,
				cf = cf * CFrame.new(0, 0.22, 0),
				size = Vector3.new(5.4, 0.14, 5.4),
				color = Color3.fromRGB(255, 190, 60),
				material = M.Neon,
				transparency = 0.2,
				tag = "RN_Plate",
				attrs = { PlateId = plate.id, Active = false },
			})
			local _ = top
			ctx.runtime.plates[plate.id] = { id = plate.id, cf = cf, radius = 2.8, tile = tile.index }
		end
	end
end

local function buildKeys(ctx: Ctx, alcoveFrames: { [string]: CFrame })
	for moduleIndex, mod in ctx.layout.modules do
		for _, key in keysOf(mod) do
			local position: Vector3
			if key.alcove then
				local acf = alcoveFrames[key.alcove]
				if not acf then
					err(ctx, "key " .. key.id .. " refers to unknown alcove " .. key.alcove)
					continue
				end
				position = (acf * CFrame.new(0, 2.6, -4.5)).Position
			else
				local tile = ctx.runtime.tiles[ctx.moduleTiles[moduleIndex][key.at or 1]]
				if not tile then
					err(ctx, "key " .. key.id .. " refers to a tile outside its module")
					continue
				end
				position = tpt(tile.cf, key.lateral or 0, 2.6, key.along or 0)
			end
			Kit.part(ctx.interact, {
				name = "Key_" .. key.id,
				cf = CFrame.new(position),
				size = Vector3.new(1, 1, 1),
				transparency = 1,
				tag = "RN_Key",
				attrs = { KeyId = key.id },
			})
			ctx.runtime.keys[key.id] = { id = key.id, position = position, alcove = key.alcove }
		end
	end
end

-- Wind lanes (R02): one per allowed direction per socket, clipped to the straight run.
local function buildLanes(ctx: Ctx)
	local runtime = ctx.runtime
	for _, socketId in runtime.socketOrder do
		local socket = runtime.sockets[socketId]
		local tile = runtime.tiles[socket.tile]
		local dirs: { string } = socket.links.wind or { "Forward", "Backward" }
		local tiles = runTiles(ctx, tile.run)
		local first, last = tiles[1], tiles[#tiles]
		local runCF = CFrame.lookAt(first.cf.Position, first.cf.Position + first.cf.LookVector)
		for _, dir in dirs do
			local laneId = socketId .. ":" .. dir
			local cf, size, vector
			if dir == "Across" then
				local s = sideSign(socket.side)
				vector = tile.cf.RightVector * -s
				cf = tcf(tile.cf, 0, 5, 0)
				size = Vector3.new(INNER * 2, 10, T)
			else
				local fromAlong = tile.runAlong - HALF * 0.25
				local toAlong: number
				if dir == "Forward" then
					toAlong = last.runAlong + HALF
					vector = tile.cf.LookVector
				else
					toAlong = -HALF
					vector = -tile.cf.LookVector
					fromAlong = tile.runAlong + HALF * 0.25
				end
				local lo, hi = math.min(fromAlong, toAlong), math.max(fromAlong, toAlong)
				cf = runCF * CFrame.new(0, 5, -(lo + hi) / 2)
				size = Vector3.new(INNER * 2, 10, hi - lo)
			end
			local slides = {}
			for launchId, launch in runtime.launches do
				if
					MathUtil.pointInBox(cf, size, launch.trigger.cf.Position, 1)
					and vector:Dot(launch.direction) > 0.9
				then
					table.insert(slides, launchId)
				end
			end
			table.sort(slides)
			runtime.lanes[laneId] = {
				id = laneId,
				socket = socketId,
				dir = dir :: any,
				cf = cf,
				size = size,
				vector = vector,
				slides = slides,
			}
			socket.lanes[dir] = laneId
			socket.defaultDir = socket.defaultDir or (dir :: any)
		end
	end
end

-- Nav graph for the caretaker (tile centres + alcoves + target room).
local function buildNav(ctx: Ctx, alcoveFrames: { [string]: CFrame })
	local runtime = ctx.runtime
	local hover = Geometry.Caretaker.HoverY
	for i, tile in runtime.tiles do
		table.insert(runtime.nav.nodes, { id = "t" .. i, position = tile.cf.Position + Vector3.new(0, hover, 0) })
		if i > 1 then
			table.insert(runtime.nav.edges, { "t" .. (i - 1), "t" .. i })
		end
	end
	for gateId, gate in runtime.gates do
		local acf = alcoveFrames[gate.alcove or ""]
		if acf then
			local nodeId = "g" .. gateId
			table.insert(runtime.nav.nodes, { id = nodeId, position = (acf * CFrame.new(0, hover, -4)).Position })
			-- Find the tile the alcove hangs off.
			local nearest, best = 1, math.huge
			for i, tile in runtime.tiles do
				local d = (tile.cf.Position - acf.Position).Magnitude
				if d < best then
					nearest, best = i, d
				end
			end
			table.insert(runtime.nav.edges, { "t" .. nearest, nodeId })
		end
	end
	if runtime.target then
		table.insert(
			runtime.nav.nodes,
			{ id = "target", position = (runtime.target.roomCF * CFrame.new(0, hover, -6)).Position }
		)
		table.insert(runtime.nav.edges, { "t" .. runtime.target.tile, "target" })
	end
end

local function finishCaretaker(ctx: Ctx)
	local runtime = ctx.runtime
	local cfg: { dormant: boolean?, patrolFrom: number?, patrolTo: number?, spawn: number? } = ctx.layout.caretaker
		or {}
	local count = #runtime.tiles
	local spawn = math.clamp(cfg.spawn or math.floor(count * 0.6), 2, count)
	local from = math.clamp(cfg.patrolFrom or math.floor(count * 0.4), 2, count)
	local to = math.clamp(cfg.patrolTo or (count - 1), from, count)
	local patrol = {}
	for i = from, to do
		table.insert(patrol, "t" .. i)
	end
	runtime.caretaker = {
		dormant = cfg.dormant == true,
		spawnNode = "t" .. spawn,
		patrol = patrol,
		escapeSpawnNode = "target",
	}
end

local function computeBounds(ctx: Ctx)
	local runtime = ctx.runtime
	local minV = Vector3.new(math.huge, math.huge, math.huge)
	local maxV = Vector3.new(-math.huge, -math.huge, -math.huge)
	for _, tile in runtime.tiles do
		local p = tile.cf.Position
		minV = minV:Min(p - Vector3.new(T * 2, 40, T * 2))
		maxV = maxV:Max(p + Vector3.new(T * 2, 30, T * 2))
	end
	runtime.bounds = { min = minV, max = maxV }
end

-- Effect model definitions derived from the built zones (consumed by EffectModel.new).
local function buildEffectDefs(ctx: Ctx)
	local runtime = ctx.runtime
	local defs = { basins = {}, fires = {}, vines = {}, powers = {}, gates = {}, links = {} }
	for moduleIndex, mod in ctx.layout.modules do
		if mod.kind == "Basin" and mod.id then
			defs.basins[mod.id] = { id = mod.id, baseWet = mod.wet == true, deep = true, power = mod.power }
		elseif mod.kind == "Puddle" and mod.id then
			defs.basins[mod.id] = { id = mod.id, baseWet = mod.wet ~= false, deep = false, power = mod.power }
		elseif mod.kind == "Fire" then
			local id = mod.id or ("F" .. ctx.moduleTiles[moduleIndex][1])
			defs.basins[id .. "_pool"] = { id = id .. "_pool", baseWet = mod.wet == true, deep = false }
			defs.fires[id] = { id = id, pools = { id .. "_pool" } }
		end
	end
	for vineId, vine in runtime.vines do
		defs.vines[vineId] = { id = vineId, waterBasin = vine.waterBasin }
	end
	local powers: { [string]: { default: boolean, levers: { string } } } = ctx.layout.powers or {}
	for powerId, power in powers do
		defs.powers[powerId] = { id = powerId, default = power.default, levers = power.levers }
		for _, lever in power.levers do
			if not runtime.levers[lever] then
				err(ctx, "power " .. powerId .. " references unknown lever " .. lever)
			end
		end
	end
	local gates: { [string]: { signals: { string }, mode: ("any" | "all")? } } = ctx.layout.gates or {}
	for gateId, gate in gates do
		defs.gates[gateId] = { id = gateId, signals = gate.signals, mode = gate.mode }
		if not runtime.gates[gateId] then
			err(ctx, "gate " .. gateId .. " is defined but no alcove uses it")
		end
		for _, signal in gate.signals do
			local kind, ref = string.match(signal, "^(%a+):(.+)$")
			local ok = (kind == "lever" and runtime.levers[ref :: string] ~= nil)
				or (kind == "plate" and runtime.plates[ref :: string] ~= nil)
				or (kind == "float" and defs.basins[ref :: string] ~= nil)
				or (kind == "power" and defs.powers[ref :: string] ~= nil)
			if not ok then
				err(ctx, "gate " .. gateId .. " has an unresolved signal " .. signal)
			end
		end
	end
	for gateId in runtime.gates do
		if not defs.gates[gateId] then
			err(ctx, "alcove gate " .. gateId .. " has no definition in layout.gates")
		end
	end
	-- Socket links: resolve fire ids to their pools and validate every reference.
	for socketId, socket in runtime.sockets do
		local links = socket.links
		local resolved: any = { cold = {}, water = nil, vine = nil }
		for _, zone in strings(links.cold) do
			local target = if defs.fires[zone] then zone .. "_pool" else zone
			if defs.basins[target] or defs.vines[target] or runtime.carts[target] then
				table.insert(resolved.cold, target)
				table.insert(socket.previewZones, target)
			else
				err(ctx, "socket " .. socketId .. " cold link to unknown zone " .. zone)
			end
		end
		if links.water then
			local zone = links.water :: string
			local target = if defs.fires[zone] then zone .. "_pool" else zone
			if defs.basins[target] or defs.vines[target] then
				resolved.water = target
				table.insert(socket.previewZones, target)
			else
				err(ctx, "socket " .. socketId .. " water link to unknown zone " .. zone)
			end
		end
		if links.vine then
			if defs.vines[links.vine :: string] then
				resolved.vine = links.vine
				table.insert(socket.previewZones, links.vine :: string)
			else
				err(ctx, "socket " .. socketId .. " vine link to unknown vine " .. tostring(links.vine))
			end
		end
		for _, crateId in strings(links.magnet) do
			if not runtime.crates[crateId] then
				err(ctx, "socket " .. socketId .. " magnet link to unknown crate " .. crateId)
			elseif not runtime.crates[crateId].metal then
				err(ctx, "socket " .. socketId .. " magnet link to non-metal crate " .. crateId)
			end
		end
		defs.links[socketId] = resolved
		-- Cold fields cover the linked zones too (caretaker slow-down regions).
		for _, zone in resolved.cold do
			local basin = runtime.basins[zone]
			if basin then
				table.insert(
					socket.coldFields,
					{ cf = basin.occupancy.cf, size = basin.occupancy.size + Vector3.new(2, 4, 2) }
				)
			end
			local cart = runtime.carts[zone]
			if cart then
				table.insert(
					socket.coldFields,
					{ cf = cart.tileCF * CFrame.new(0, 5, 0), size = Vector3.new(14, 10, 16) }
				)
			end
		end
	end
	for id in ctx.layout.sockets do
		if not runtime.sockets[id] then
			err(ctx, "socket definition " .. id .. " is not placed on any hall tile")
		end
	end
	runtime.effectDefs = defs
end

-- Entry point -------------------------------------------------------------------------------------------

export type BuildResult = { model: Model, runtime: Runtime }

function LevelBuilder.build(layout: LayoutDef, origin: Vector3?): BuildResult
	local model = Kit.model(nil, "Level_" .. layout.id)
	local originCF = CFrame.new(origin or Geometry.LevelOrigin)
	local runtime: Runtime = {
		layoutId = layout.id,
		theme = layout.theme,
		origin = originCF,
		tiles = {},
		cells = {},
		sockets = {},
		socketOrder = {},
		basins = {},
		fires = {},
		vines = {},
		gates = {},
		lanes = {},
		launches = {},
		crates = {},
		plates = {},
		levers = {},
		keys = {},
		carts = {},
		ledges = {},
		pits = {},
		safeFloors = {},
		slots = {},
		spawns = {},
		exit = { cf = originCF, size = Vector3.one },
		target = nil :: any,
		nav = { nodes = {}, edges = {} },
		caretaker = nil :: any,
		bounds = { min = Vector3.zero, max = Vector3.zero },
		effectDefs = nil,
		errors = {},
		partCount = 0,
	}
	local ctx: Ctx = {
		layout = layout,
		theme = Palette.get(layout.theme),
		rng = MathUtil.rng(layout.seed),
		model = model,
		structure = Kit.folder(model, "Structure"),
		decor = Kit.folder(model, "Decor"),
		zones = Kit.folder(model, "Zones"),
		interact = Kit.folder(model, "Interact"),
		movers = Kit.folder(model, "Movers"),
		runtime = runtime,
		errors = runtime.errors,
		roomNumber = layout.roomNumberBase or 300,
		shadowLights = 0,
		moduleTiles = {},
		features = {},
		zoneIds = {},
		crateRuns = {},
	}

	if #layout.modules == 0 or layout.modules[1].kind ~= "Elevator" then
		err(ctx, "layout must start with an Elevator module")
	end
	if layout.modules[#layout.modules] == nil or layout.modules[#layout.modules].kind ~= "Target" then
		err(ctx, "layout must end with a Target module")
	end

	walkRoute(ctx, originCF)
	for moduleIndex, mod in layout.modules do
		for _, crate in crates(mod) do
			local tile = runtime.tiles[ctx.moduleTiles[moduleIndex][crate.at or 1]]
			if tile and math.abs(crate.lateral) > 1 then
				ctx.crateRuns[tile.run] = true
			end
		end
	end

	-- Wall features first (sockets, levers, alcoves) so walls get their openings.
	local alcoveFrames: { [string]: CFrame } = {}
	for moduleIndex, mod in layout.modules do
		local tilesOfModule = ctx.moduleTiles[moduleIndex]
		for offset, sides in socketsOf(mod) do
			local tile = runtime.tiles[tilesOfModule[offset]]
			if not tile then
				err(ctx, "socket offset " .. offset .. " outside module " .. moduleIndex)
				continue
			end
			if PIT_KINDS[tile.kind] or tile.kind == "Turn" or tile.kind == "Elevator" or tile.kind == "Target" then
				err(ctx, "sockets are not allowed on " .. tile.kind .. " tiles (module " .. moduleIndex .. ")")
				continue
			end
			if sides.L then
				buildSocket(ctx, tile, "L", sides.L)
			end
			if sides.R then
				buildSocket(ctx, tile, "R", sides.R)
			end
		end
		for _, lever in levers(mod) do
			local tile = runtime.tiles[tilesOfModule[lever.at or 1]]
			if tile and not PIT_KINDS[tile.kind] then
				if ctx.features[tile.index] and (ctx.features[tile.index] :: any)[lever.side] then
					err(ctx, "lever " .. lever.id .. " collides with another wall feature")
				else
					buildLever(ctx, tile, lever.side, lever.id)
				end
			else
				err(ctx, "lever " .. lever.id .. " must be on a floor tile")
			end
		end
		for _, alcove in alcoves(mod) do
			local tile = runtime.tiles[tilesOfModule[alcove.at or 1]]
			if tile and not PIT_KINDS[tile.kind] then
				if ctx.features[tile.index] and (ctx.features[tile.index] :: any)[alcove.side] then
					err(ctx, "alcove " .. alcove.id .. " collides with another wall feature")
				else
					alcoveFrames[alcove.id] = buildAlcove(ctx, tile, alcove.side, alcove.id, alcove.gate)
				end
			else
				err(ctx, "alcove " .. alcove.id .. " must be on a floor tile")
			end
		end
	end

	-- Tiles and modules.
	for moduleIndex, mod in layout.modules do
		if PIT_KINDS[mod.kind] then
			buildPitModule(ctx, moduleIndex, mod)
		else
			for _, index in ctx.moduleTiles[moduleIndex] do
				local tile = runtime.tiles[index]
				if mod.kind == "Elevator" then
					buildElevator(ctx, tile)
				elseif mod.kind == "Turn" then
					buildTurnTile(ctx, tile, mod)
				elseif mod.kind == "Target" then
					buildTarget(ctx, tile, mod)
				elseif mod.kind == "Fire" then
					buildFireTile(ctx, tile, mod)
				elseif mod.kind == "Puddle" then
					buildPuddleTile(ctx, tile, mod)
				elseif mod.kind == "Carts" then
					buildCartsTile(ctx, tile, mod)
				else
					buildHallTile(ctx, tile, mod, mod.doors ~= false)
				end
				if tile.safe then
					table.insert(runtime.safeFloors, box(tile.cf, 0, 2.5, 0, T, 5, T))
				end
			end
		end
	end

	buildPlates(ctx)
	buildCrates(ctx)
	buildKeys(ctx, alcoveFrames)
	buildLanes(ctx)
	buildEffectDefs(ctx)
	buildNav(ctx, alcoveFrames)
	finishCaretaker(ctx)
	computeBounds(ctx)

	local count = 0
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			count += 1
		end
	end
	runtime.partCount = count
	return { model = model, runtime = runtime }
end

-- Compact, remote-serialisable subset of the runtime that clients need for movement and visuals.
function LevelBuilder.clientInfo(runtime: Runtime): { [string]: any }
	local lanes = {}
	for id, lane in runtime.lanes do
		lanes[id] = {
			cf = lane.cf,
			size = lane.size,
			vector = lane.vector,
			slides = lane.slides,
			socket = lane.socket,
			dir = lane.dir,
		}
	end
	local launches = {}
	for id, launch in runtime.launches do
		launches[id] = {
			trigger = launch.trigger,
			landing = launch.landing,
			direction = launch.direction,
			basin = launch.basin,
			slide = launch.slide,
		}
	end
	local sockets = {}
	for id, socket in runtime.sockets do
		sockets[id] = {
			doorCF = socket.doorCF,
			roomCF = socket.roomCF,
			interactPoint = socket.interactPoint,
			lanes = socket.lanes,
			defaultDir = socket.defaultDir,
			previewZones = socket.previewZones,
			links = {
				cold = socket.links.cold,
				water = socket.links.water,
				vine = socket.links.vine,
				magnet = socket.links.magnet,
				wind = socket.links.wind,
			},
		}
	end
	local basins = {}
	for id, basin in runtime.basins do
		basins[id] = { surface = basin.surface, deep = basin.deep, occupancy = basin.occupancy, fire = basin.fire }
	end
	local carts = {}
	for id, cart in runtime.carts do
		carts[id] = { tileCF = cart.tileCF, range = cart.range, speed = cart.speed, size = cart.size }
	end
	local keys = {}
	for id, key in runtime.keys do
		keys[id] = key.position
	end
	local vines = {}
	for id, vine in runtime.vines do
		vines[id] = { bridge = vine.bridge }
	end
	local fires = {}
	for id, fire in runtime.fires do
		fires[id] = { volume = fire.volume, pool = fire.pool }
	end
	local levers = {}
	for id, lever in runtime.levers do
		levers[id] = { cf = lever.cf }
	end
	local tiles = {}
	for i, tile in runtime.tiles do
		tiles[i] = { cf = tile.cf, kind = tile.kind }
	end
	return {
		layoutId = runtime.layoutId,
		theme = runtime.theme,
		lanes = lanes,
		launches = launches,
		ledges = runtime.ledges,
		sockets = sockets,
		basins = basins,
		carts = carts,
		keys = keys,
		vines = vines,
		fires = fires,
		levers = levers,
		exit = runtime.exit,
		target = {
			room = runtime.target.room,
			doorCF = runtime.target.doorCF,
			roomCF = runtime.target.roomCF,
			capturePoint = runtime.target.capturePoint,
		},
		tiles = tiles,
		spawns = runtime.spawns,
	}
end

return LevelBuilder
