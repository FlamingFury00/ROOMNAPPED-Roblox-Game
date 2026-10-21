--!strict
--[[
	Palette: visual themes for hotel wings. Layouts pick a theme; the kit reads every colour and material
	from it so a wing can be re-skinned without touching geometry.
]]

export type Theme = {
	id: string,
	floor: Color3,
	floorMaterial: Enum.Material,
	carpet: Color3,
	carpetMaterial: Enum.Material,
	carpetBorder: Color3,
	wall: Color3,
	wallMaterial: Enum.Material,
	wainscot: Color3,
	wainscotMaterial: Enum.Material,
	trim: Color3,
	trimMaterial: Enum.Material,
	ceiling: Color3,
	ceilingMaterial: Enum.Material,
	door: Color3,
	doorMaterial: Enum.Material,
	doorFrame: Color3,
	brass: Color3,
	lamp: Color3,
	lampBrightness: number,
	pitWall: Color3,
	pitMaterial: Enum.Material,
	pitFloor: Color3,
	sign: Color3,
	plant: Color3,
	pot: Color3,
	fog: Color3,
	ambient: Color3,
	-- Patterned surfaces (MaterialVariants in MaterialService, see Palette.dress).
	surfaces: { [SurfaceKind]: Surface }?,
}

export type SurfaceKind = "wall" | "carpet" | "floor" | "ceiling"

-- A MaterialVariant from src/MaterialService: its base material (parts must use it for the variant to
-- show) and the colour the part takes (it multiplies the texture: white shows it as painted).
export type Surface = { variant: string, material: Enum.Material, tint: Color3 }

local M = Enum.Material
local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

local function surface(variant: string, material: Enum.Material, tint: Color3?): Surface
	return { variant = variant, material = material, tint = tint or Color3.new(1, 1, 1) }
end

-- The MaterialVariants the place file defines (src/MaterialService/<name>.model.json) and their base
-- materials; tests check the two agree.
local VARIANTS: { [string]: Enum.Material } = {
	RN_WallDamaskRed = M.Fabric,
	RN_WallDamaskGreen = M.Fabric,
	RN_WallDamaskNavy = M.Fabric,
	RN_WallDamaskMint = M.Fabric,
	RN_WallStripes = M.Fabric,
	RN_WallTiles = M.CeramicTiles,
	RN_WallBrick = M.Brick,
	RN_WallMossBrick = M.Brick,
	RN_CarpetLattice = M.Carpet,
	RN_CarpetMedallion = M.Carpet,
	RN_CarpetMoss = M.Carpet,
	RN_FloorParquet = M.WoodPlanks,
	RN_FloorHerringbone = M.WoodPlanks,
	RN_FloorMarbleWhite = M.Marble,
	RN_FloorMarbleBlack = M.Marble,
	RN_FloorChecker = M.CeramicTiles,
	RN_Concrete = M.Concrete,
	RN_RustMetal = M.Metal,
	RN_Ice = M.Ice,
	RN_GoldDeco = M.Foil,
}

local themes: { [string]: Theme } = {
	classic = {
		id = "classic",
		floor = rgb(110, 74, 50),
		floorMaterial = M.WoodPlanks,
		carpet = rgb(132, 26, 40),
		carpetMaterial = M.Carpet,
		carpetBorder = rgb(212, 168, 76),
		wall = rgb(46, 86, 82),
		wallMaterial = M.Fabric,
		wainscot = rgb(84, 52, 36),
		wainscotMaterial = M.Wood,
		trim = rgb(226, 212, 186),
		trimMaterial = M.SmoothPlastic,
		ceiling = rgb(214, 202, 182),
		ceilingMaterial = M.Plaster,
		door = rgb(92, 54, 34),
		doorMaterial = M.Wood,
		doorFrame = rgb(226, 212, 186),
		brass = rgb(214, 174, 88),
		lamp = rgb(255, 198, 136),
		lampBrightness = 1.35,
		pitWall = rgb(70, 58, 50),
		pitMaterial = M.Brick,
		pitFloor = rgb(30, 26, 26),
		sign = rgb(255, 232, 170),
		plant = rgb(70, 140, 70),
		pot = rgb(170, 90, 60),
		fog = rgb(20, 14, 18),
		ambient = rgb(26, 20, 26),
		surfaces = {
			wall = surface("RN_WallDamaskGreen", M.Fabric, rgb(214, 226, 214)),
			carpet = surface("RN_CarpetLattice", M.Carpet),
			floor = surface("RN_FloorParquet", M.WoodPlanks),
		},
	},
	laundry = {
		id = "laundry",
		floor = rgb(220, 226, 232),
		floorMaterial = M.CeramicTiles,
		carpet = rgb(60, 120, 200),
		carpetMaterial = M.Carpet,
		carpetBorder = rgb(250, 250, 250),
		wall = rgb(176, 214, 232),
		wallMaterial = M.Plaster,
		wainscot = rgb(244, 246, 250),
		wainscotMaterial = M.SmoothPlastic,
		trim = rgb(70, 130, 210),
		trimMaterial = M.SmoothPlastic,
		ceiling = rgb(236, 240, 244),
		ceilingMaterial = M.Plaster,
		door = rgb(240, 244, 248),
		doorMaterial = M.SmoothPlastic,
		doorFrame = rgb(70, 130, 210),
		brass = rgb(190, 200, 214),
		lamp = rgb(220, 238, 255),
		lampBrightness = 1.3,
		pitWall = rgb(150, 176, 196),
		pitMaterial = M.Concrete,
		pitFloor = rgb(40, 50, 60),
		sign = rgb(255, 255, 255),
		plant = rgb(80, 170, 120),
		pot = rgb(236, 236, 236),
		fog = rgb(14, 20, 28),
		ambient = rgb(22, 26, 34),
		surfaces = {
			wall = surface("RN_WallTiles", M.CeramicTiles, rgb(206, 230, 246)),
			floor = surface("RN_FloorChecker", M.CeramicTiles),
		},
	},
	boiler = {
		id = "boiler",
		floor = rgb(80, 78, 76),
		floorMaterial = M.DiamondPlate,
		carpet = rgb(60, 56, 54),
		carpetMaterial = M.DiamondPlate,
		carpetBorder = rgb(240, 170, 40),
		wall = rgb(122, 58, 46),
		wallMaterial = M.Brick,
		wainscot = rgb(70, 66, 64),
		wainscotMaterial = M.Metal,
		trim = rgb(176, 120, 64),
		trimMaterial = M.Metal,
		ceiling = rgb(62, 58, 56),
		ceilingMaterial = M.Concrete,
		door = rgb(90, 96, 104),
		doorMaterial = M.DiamondPlate,
		doorFrame = rgb(176, 120, 64),
		brass = rgb(200, 140, 70),
		lamp = rgb(255, 170, 90),
		lampBrightness = 1.4,
		pitWall = rgb(60, 50, 46),
		pitMaterial = M.Brick,
		pitFloor = rgb(24, 20, 20),
		sign = rgb(255, 210, 120),
		plant = rgb(90, 120, 70),
		pot = rgb(100, 90, 80),
		fog = rgb(26, 14, 10),
		ambient = rgb(32, 20, 16),
		surfaces = {
			wall = surface("RN_WallBrick", M.Brick, rgb(236, 226, 220)),
			ceiling = surface("RN_Concrete", M.Concrete, rgb(150, 144, 140)),
		},
	},
	greenhouse = {
		id = "greenhouse",
		floor = rgb(136, 98, 62),
		floorMaterial = M.WoodPlanks,
		carpet = rgb(74, 120, 64),
		carpetMaterial = M.Carpet,
		carpetBorder = rgb(236, 216, 150),
		wall = rgb(150, 178, 128),
		wallMaterial = M.Plaster,
		wainscot = rgb(108, 78, 50),
		wainscotMaterial = M.WoodPlanks,
		trim = rgb(242, 236, 214),
		trimMaterial = M.SmoothPlastic,
		ceiling = rgb(222, 230, 210),
		ceilingMaterial = M.Plaster,
		door = rgb(120, 86, 54),
		doorMaterial = M.Wood,
		doorFrame = rgb(242, 236, 214),
		brass = rgb(206, 180, 100),
		lamp = rgb(255, 236, 180),
		lampBrightness = 1.4,
		pitWall = rgb(90, 76, 56),
		pitMaterial = M.Ground,
		pitFloor = rgb(34, 30, 22),
		sign = rgb(250, 240, 200),
		plant = rgb(80, 160, 70),
		pot = rgb(180, 100, 60),
		fog = rgb(14, 20, 12),
		ambient = rgb(22, 28, 20),
		surfaces = {
			wall = surface("RN_WallMossBrick", M.Brick),
			carpet = surface("RN_CarpetMoss", M.Carpet),
			floor = surface("RN_FloorHerringbone", M.WoodPlanks),
		},
	},
	frost = {
		id = "frost",
		floor = rgb(200, 216, 230),
		floorMaterial = M.Marble,
		carpet = rgb(62, 112, 168),
		carpetMaterial = M.Carpet,
		carpetBorder = rgb(222, 238, 252),
		wall = rgb(140, 176, 206),
		wallMaterial = M.Fabric,
		wainscot = rgb(226, 236, 246),
		wainscotMaterial = M.Marble,
		trim = rgb(242, 248, 255),
		trimMaterial = M.SmoothPlastic,
		ceiling = rgb(222, 234, 246),
		ceilingMaterial = M.Plaster,
		door = rgb(96, 130, 166),
		doorMaterial = M.Wood,
		doorFrame = rgb(236, 244, 252),
		brass = rgb(194, 210, 228),
		lamp = rgb(212, 232, 255),
		lampBrightness = 1.3,
		pitWall = rgb(118, 138, 160),
		pitMaterial = M.Slate,
		pitFloor = rgb(36, 46, 62),
		sign = rgb(232, 246, 255),
		plant = rgb(66, 128, 112),
		pot = rgb(196, 214, 232),
		fog = rgb(16, 22, 34),
		ambient = rgb(24, 30, 44),
		surfaces = {
			wall = surface("RN_WallDamaskMint", M.Fabric, rgb(196, 222, 248)),
			floor = surface("RN_FloorMarbleWhite", M.Marble, rgb(218, 232, 246)),
		},
	},
	vault = {
		id = "vault",
		floor = rgb(30, 30, 36),
		floorMaterial = M.Marble,
		carpet = rgb(40, 46, 86),
		carpetMaterial = M.Carpet,
		carpetBorder = rgb(222, 184, 90),
		wall = rgb(36, 42, 70),
		wallMaterial = M.Fabric,
		wainscot = rgb(24, 26, 34),
		wainscotMaterial = M.Marble,
		trim = rgb(222, 184, 90),
		trimMaterial = M.Foil,
		ceiling = rgb(30, 32, 44),
		ceilingMaterial = M.SmoothPlastic,
		door = rgb(120, 126, 140),
		doorMaterial = M.Metal,
		doorFrame = rgb(222, 184, 90),
		brass = rgb(232, 194, 96),
		lamp = rgb(200, 216, 255),
		lampBrightness = 1.35,
		pitWall = rgb(40, 40, 50),
		pitMaterial = M.Slate,
		pitFloor = rgb(14, 14, 20),
		sign = rgb(255, 230, 150),
		plant = rgb(60, 130, 90),
		pot = rgb(222, 184, 90),
		fog = rgb(10, 12, 22),
		ambient = rgb(18, 20, 30),
		surfaces = {
			wall = surface("RN_WallDamaskNavy", M.Fabric),
			carpet = surface("RN_CarpetMedallion", M.Carpet),
			floor = surface("RN_FloorMarbleBlack", M.Marble),
		},
	},
	lobby = {
		id = "lobby",
		floor = rgb(232, 224, 210),
		floorMaterial = M.Marble,
		carpet = rgb(132, 26, 40),
		carpetMaterial = M.Carpet,
		carpetBorder = rgb(212, 168, 76),
		wall = rgb(70, 40, 52),
		wallMaterial = M.Fabric,
		wainscot = rgb(84, 52, 36),
		wainscotMaterial = M.Wood,
		trim = rgb(226, 196, 120),
		trimMaterial = M.Foil,
		ceiling = rgb(222, 210, 190),
		ceilingMaterial = M.Plaster,
		door = rgb(92, 54, 34),
		doorMaterial = M.Wood,
		doorFrame = rgb(226, 196, 120),
		brass = rgb(220, 180, 92),
		lamp = rgb(255, 210, 150),
		lampBrightness = 1.5,
		pitWall = rgb(70, 58, 50),
		pitMaterial = M.Brick,
		pitFloor = rgb(30, 26, 26),
		sign = rgb(255, 232, 170),
		plant = rgb(70, 140, 70),
		pot = rgb(200, 160, 80),
		fog = rgb(24, 16, 20),
		ambient = rgb(40, 30, 34),
		surfaces = {
			wall = surface("RN_WallDamaskRed", M.Fabric, rgb(236, 226, 226)),
			carpet = surface("RN_CarpetLattice", M.Carpet),
			floor = surface("RN_FloorMarbleWhite", M.Marble),
		},
	},
}

local Palette = {}

Palette.VARIANTS = VARIANTS

function Palette.get(id: string): Theme
	return themes[id] or themes.classic
end

-- Dress a structural part with the theme's patterned surface of that kind (wallpaper, carpet, parquet ...),
-- if the theme has one; the part keeps its plain colour and material otherwise.
function Palette.dress(part: BasePart, theme: Theme, kind: SurfaceKind)
	local s = theme.surfaces and theme.surfaces[kind]
	if s then
		Palette.apply(part, s.variant, s.tint)
	end
end

-- Put a part on one of the place's MaterialVariants (with its base material) tinted `tint`.
function Palette.apply(part: BasePart, variant: string, tint: Color3?)
	local material = VARIANTS[variant]
	if material then
		part.Material = material
		part.MaterialVariant = variant
		part.Color = tint or Color3.new(1, 1, 1)
	end
end

Palette.themes = themes

return Palette
