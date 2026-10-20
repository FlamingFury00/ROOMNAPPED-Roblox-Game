--!strict
--[[
	LobbyBuilder: the small elevator lobby (S25, A08) - no large town.

	Layout (lobby local space, +Z = toward the departure elevators):
	  * spawn in the middle of a marble hall with chandeliers
	  * reception desk on the left, luggage rack (collection & loadout) on the right
	  * mission board and the departure elevator straight ahead; stepping into the elevator car (or
	    pressing PLAY) readies the player
]]

local Geometry = require(script.Parent.Geometry)
local Kit = require(script.Parent.Kit)
local Props = require(script.Parent.Props)
local Palette = require(script.Parent.Palette)
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

	-- Floor: marble checkerboard with a carpet runner to the elevators.
	Kit.solid(structure, "Floor", at(0, -0.5, 0), Vector3.new(W, 1, D), theme.floor, M.Marble)
	for ix = -4, 3 do
		for iz = -3, 2 do
			if (ix + iz) % 2 == 0 then
				Kit.decor(
					decor,
					"Tile",
					at(ix * 9 + 4.5, 0.02, iz * 10 + 5),
					Vector3.new(9, 0.04, 10),
					Color3.fromRGB(60, 40, 48),
					M.Marble
				)
			end
		end
	end
	Props.rug(decor, at(0, 0.04, 6), Vector2.new(12, 44), theme.carpet, theme.carpetBorder)
	Kit.solid(structure, "Ceiling", at(0, H + 0.5, 0), Vector3.new(W, 1, D), theme.ceiling, M.Plaster)
	-- Coffered ceiling beams.
	for i = -3, 3 do
		Kit.decor(decor, "Beam", at(i * 10, H - 0.6, 0), Vector3.new(1.2, 1.2, D), theme.trim, M.Foil)
	end

	-- Walls with wainscot and trim.
	local function wallPiece(name: string, cf: CFrame, size: Vector3)
		Kit.solid(structure, name, cf, size, theme.wall, theme.wallMaterial)
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
	end
	local function wainscot(cf: CFrame, length: number, axis: string)
		local size = if axis == "x" then Vector3.new(length, 4.5, 0.3) else Vector3.new(0.3, 4.5, length)
		Kit.decor(decor, "Wainscot", cf * CFrame.new(0, 2.25, 0), size, theme.wainscot, theme.wainscotMaterial)
		local rail = if axis == "x" then Vector3.new(length, 0.35, 0.5) else Vector3.new(0.5, 0.35, length)
		Kit.decor(decor, "Rail", cf * CFrame.new(0, 4.6, 0), rail, theme.trim, theme.trimMaterial)
	end
	wainscot(at(0, 0, -D / 2 + 0.15), W, "x")
	wainscot(at(-W / 2 + 0.15, 0, 0), D, "z")
	wainscot(at(W / 2 - 0.15, 0, 0), D, "z")

	-- Marble pillars with gold capitals.
	for _, x in { -24, 24 } do
		for _, z in { -14, 6, 22 } do
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
			Kit.post(decor, {
				name = "Capital",
				cf = at(x, H - 1, z),
				height = 1.4,
				diameter = 3.8,
				color = theme.trim,
				material = M.Foil,
			})
			Kit.post(decor, {
				name = "Plinth",
				cf = at(x, 0.7, z),
				height = 1.4,
				diameter = 3.8,
				color = theme.trim,
				material = M.Foil,
			})
		end
	end

	-- Chandeliers.
	Props.chandelier(decor, at(0, H, -6), theme, 1.6)
	Props.chandelier(decor, at(0, H, 14), theme, 1.3)
	for _, x in { -30, 30 } do
		for _, z in { -20, 0, 20 } do
			local p = at(x + (if x < 0 then -5.6 else 5.6), 9, z)
			local inward = (at(0, 9, z).Position - p.Position).Unit
			Props.wallSconce(decor, CFrame.lookAt(p.Position, p.Position + inward), theme, true)
		end
	end

	-- Night windows on the back wall.
	for _, x in { -22, 0, 22 } do
		local frame = at(x, 11, -D / 2 + 0.2)
		Kit.decor(decor, "WindowFrame", frame, Vector3.new(9, 12, 0.3), theme.trim, M.Foil)
		local glass = Kit.part(decor, {
			name = "NightSky",
			cf = frame * CFrame.new(0, 0, 0.2),
			size = Vector3.new(8, 11, 0.1),
			color = Color3.fromRGB(28, 36, 80),
			material = M.Neon,
			transparency = 0.15,
		})
		glass:AddTag("RN_Lamp")
		Kit.decor(decor, "Mullion", frame * CFrame.new(0, 0, 0.3), Vector3.new(0.3, 11, 0.12), theme.trim, M.Foil)
		Kit.decor(decor, "Transom", frame * CFrame.new(0, 2, 0.3), Vector3.new(8, 0.3, 0.12), theme.trim, M.Foil)
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
		Kit.solid(structure, "CarWallL", at(x - 4.5, 5.5, cz), Vector3.new(1, 11, carDepth), theme.trim, M.Foil)
		Kit.solid(structure, "CarWallR", at(x + 4.5, 5.5, cz), Vector3.new(1, 11, carDepth), theme.trim, M.Foil)
		Kit.solid(structure, "CarBack", at(x, 5.5, cz + carDepth / 2 + 0.5), Vector3.new(10, 11, 1), theme.trim, M.Foil)
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
		end
		local indicator = Kit.decor(
			decor,
			"Indicator",
			at(x, 10.9, D / 2 - 0.2),
			Vector3.new(4, 1, 0.2),
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

	-- Reception desk (left).
	local deskCF = facing(-22, 0, 8, 0, 8)
	Kit.solid(
		structure,
		"Desk",
		deskCF * CFrame.new(0, 2, 0),
		Vector3.new(16, 4, 3.4),
		Color3.fromRGB(96, 56, 36),
		M.Wood
	)
	Kit.decor(
		decor,
		"DeskTop",
		deskCF * CFrame.new(0, 4.1, 0),
		Vector3.new(16.6, 0.3, 3.8),
		Color3.fromRGB(236, 228, 214),
		M.Marble
	)
	Kit.decor(decor, "DeskTrim", deskCF * CFrame.new(0, 1, -1.75), Vector3.new(16.2, 0.4, 0.1), theme.trim, M.Foil)
	local bell = Kit.ball(decor, {
		name = "Bell",
		cf = deskCF * CFrame.new(2, 4.6, -0.4),
		size = Vector3.new(0.9, 0.7, 0.9),
		color = theme.brass,
		material = M.Foil,
	})
	bell:AddTag("RN_DeskBell")
	local sign =
		Kit.decor(decor, "ReceptionSign", deskCF * CFrame.new(0, 3, -1.8), Vector3.new(7, 1.2, 0.1), theme.trim, M.Foil)
	Kit.surfaceText(
		sign,
		{ face = Enum.NormalId.Front, text = "RECEPTION", color = Color3.fromRGB(50, 26, 20), font = FONT_SERIF }
	)
	-- Key rack behind the desk (on the left wall).
	local rack = facing(-W / 2 + 0.6, 8, 8, 0, 8)
	Kit.decor(decor, "KeyRack", rack, Vector3.new(14, 6, 0.4), Color3.fromRGB(80, 48, 30), M.Wood)
	for i = 0, 11 do
		local col, row = i % 6, math.floor(i / 6)
		Kit.decor(
			decor,
			"Key",
			rack * CFrame.new(-5.5 + col * 2.2, 1 - row * 2.4, -0.4),
			Vector3.new(0.3, 1.2, 0.1),
			theme.brass,
			M.Foil
		)
	end
	Props.painting(decor, facing(-W / 2 + 0.3, 14.5, 8, 0, 8), theme, rng, 8, 5)

	-- Luggage rack / collection station (right).
	local rackCF = facing(24, 0, -4, 0, -4)
	Kit.solid(
		structure,
		"LuggageRack",
		rackCF * CFrame.new(0, 4, 1),
		Vector3.new(16, 8, 2.4),
		Color3.fromRGB(90, 56, 36),
		M.Wood
	)
	for level = 0, 1 do
		Kit.decor(
			decor,
			"Shelf",
			rackCF * CFrame.new(0, 2.4 + level * 3.2, -0.3),
			Vector3.new(15.6, 0.3, 2.4),
			theme.trim,
			M.Foil
		)
	end
	local station = Kit.part(interact, {
		name = "CollectionStation",
		cf = rackCF * CFrame.new(0, 3, -2.2),
		size = Vector3.new(14, 6, 2),
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

	-- Lounge: couches, coffee table and plants.
	for _, z in { -12, -2 } do
		Props.bench(decor, facing(-6 - 6, 0, z, 0, z) * CFrame.new(0, 0, 0), theme)
	end
	Kit.decor(decor, "CoffeeTable", at(-18, 1.3, -7), Vector3.new(5, 0.4, 3), Color3.fromRGB(70, 42, 28), M.Wood)
	Kit.part(
		structure,
		{ name = "LoungeCollider", cf = at(-18, 1, -7), size = Vector3.new(5, 2, 3), transparency = 1, solid = true }
	)
	for _, p in { { -32, -26 }, { 32, -26 }, { -32, 26 }, { 32, 26 }, { -16, 26 }, { 16, 26 } } do
		Props.plant(decor, facing(p[1], 0, p[2], 0, 0), theme, rng, 1.5)
		Kit.part(structure, {
			name = "PlantCollider",
			cf = at(p[1], 1.5, p[2]),
			size = Vector3.new(2.6, 3, 2.6),
			transparency = 1,
			solid = true,
		})
	end
	Props.luggageCart(decor, facing(14, 0, 18, 0, 18), theme, rng)
	Kit.part(
		structure,
		{ name = "CartCollider", cf = at(14, 3, 18), size = Vector3.new(4.6, 6, 2.4), transparency = 1, solid = true }
	)

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

	local arrival = {}
	for _, offset in { { -2, 0 }, { 2, 0 }, { -2, 3.5 }, { 2, 3.5 } } do
		local p = at(-10 + offset[1], 3, D / 2 + 4 + offset[2]).Position
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
