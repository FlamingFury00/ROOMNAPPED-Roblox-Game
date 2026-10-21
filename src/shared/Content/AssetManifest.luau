--!strict
--[[
	AssetManifest: the curated free Creator Store models the hotel is dressed with (A01, A10).

	Every entry names one prop key the world builders ask for (World/Assets) and the Creator Store models
	that may fill it. The server loads them at startup with AssetService:LoadAssetAsync, keeps no scripts,
	sounds, physics or GUIs, turns each model so its front faces -Z, scales it uniformly into `size` and
	publishes the result as a template (AssetLibraryService). A key whose models all fail keeps its procedural
	fallback, so the manifest can never break a level.

	  ids      model ids, one template per id that loads (variants are picked deterministically per slot)
	  mount    "floor" | "wall" | "ceiling" | "centre" (where the template's pivot sits, see World/Assets)
	  size     target bounds in studs: X width, Y height, Z depth (front to back)
	  fit      "contain" (fit inside size), "height" or "width" (match that dimension; the others follow) or
	           "stretch" (height exact, width and depth each fitted within a third of it: tops things stand on)
	  facing   "auto": the model's front is where its Seat faces or, without one, the side its Creator Store
	           thumbnail shows (the thumbnail camera sits on the side the model's pivot looks towards, so a
	           thumbnail that shows the front means the pivot faces front); "any": round props, no turn;
	           "wide": no front, the longer side runs along X (rugs)
	  turns    extra yaw in degrees for single ids whose thumbnail shows a side (the side on the right of the
	           thumbnail is the pivot's left, so a wall plate on the right means a turn of +90)
	  lights   keep the model's own lights (default off: builders place the hotel's lights themselves)
	  shadows  false for light fittings, so a fixture never shades its own light
	  credit   creator names, recorded in docs/CONTENT_OWNERSHIP.md

	Provenance: every id is a free Creator Store asset with no audio, picked by hand from contact sheets made
	with tools/assets/scout.py; docs/CONTENT_OWNERSHIP.md lists names, creators and checks.
]]

export type Entry = {
	ids: { number },
	mount: "floor" | "wall" | "ceiling" | "centre",
	size: Vector3,
	fit: "contain" | "height" | "width" | "stretch",
	facing: "auto" | "any" | "wide",
	turns: { [number]: number }?,
	lights: boolean?,
	particles: boolean?,
	shadows: boolean?,
	credit: string?,
}

local V = Vector3.new

local entries: { [string]: Entry } = {
	-- Seating ------------------------------------------------------------------------------------------------
	armchair = {
		ids = { 1253590181, 138623098643136 }, -- oxblood leather wingback; green velvet Louis XV fauteuil
		mount = "floor",
		size = V(3.2, 4.2, 3.4),
		fit = "contain",
		facing = "auto",
		credit = "rysida (cozy leather chair); pipepedro9 / Parkour Games Fans (Green Chair)",
	},
	sofa = {
		ids = { 80597511587533, 11290198233 }, -- red tufted velvet camelback; brown leather Victorian couch
		mount = "floor",
		size = V(7.4, 3.8, 3.4),
		fit = "contain",
		facing = "auto",
		credit = "FouDDy (Luxury Sofa); BlkMatt (Couch (Old Sofa))",
	},
	bench = {
		ids = { 83282298311815, 16017612847 }, -- grey tufted bench on brass legs; white tufted bench
		mount = "floor",
		size = V(4.6, 2.2, 1.9),
		fit = "contain",
		facing = "auto",
		credit = "MACKIEJ56 (Kiester Bench); DEV_MohamedTarek (Bench_White)",
	},

	-- Tables ---------------------------------------------------------------------------------------------------
	sideTable = {
		-- Exactly table height (Props.sideTable puts a lamp or a vase on top at 2.7 studs).
		ids = { 11930694315, 8544032055 }, -- mahogany two-drawer table; round tilt-top on a tripod
		mount = "floor",
		size = V(2.6, 2.7, 2.6),
		fit = "height",
		facing = "auto",
		credit = "BRA1122555 (#antique #furniture); DerRuecken (small_table_wood)",
	},
	coffeeTable = {
		ids = { 9589128284 }, -- marble top on carved scroll legs
		mount = "floor",
		size = V(5, 1.7, 3),
		fit = "contain",
		facing = "auto",
		credit = "turohabaneero (Coffee Table)",
	},

	-- Clocks, mirrors, racks -------------------------------------------------------------------------------------
	grandfatherClock = {
		ids = { 13534278784, 18985183180 }, -- mahogany longcase with brass dial; slim dark longcase
		mount = "floor",
		size = V(2.6, 7.8, 1.8),
		fit = "height",
		facing = "auto",
		credit = "zzz_1551 (Old Clock); Solvyra (Grandfather Clock)",
	},
	wallClock = {
		ids = { 125444652358924, 72312535411205 }, -- round Roman-numeral clock; pendulum wall clock
		mount = "wall",
		size = V(2.2, 2.6, 0.8),
		fit = "contain",
		facing = "auto",
		credit = "chatillo201017 (Mantle Antique Wall Clock, Pendulum Wall Clock)",
	},
	mirror = {
		ids = { 16017770957 }, -- black baroque scroll frame
		mount = "wall",
		size = V(3.4, 4.6, 0.8),
		fit = "contain",
		facing = "auto",
		credit = "DEV_MohamedTarek (Ornate Mirror)",
	},
	keyRack = {
		ids = { 4826812656 }, -- wooden key cabinet with a big brass key
		mount = "wall",
		size = V(8, 5, 1.2),
		fit = "contain",
		facing = "auto",
		credit = "LIAS FAN GROUP (Keybox)",
	},

	-- Light fittings (the builders add the light rigs) -----------------------------------------------------------
	wallSconce = {
		-- Both thumbnails are side views with the wall plate on the right: the front is the pivot's right.
		ids = { 2416484976, 8803156531 }, -- twin amber tulip sconce; iron bracket lantern
		mount = "wall",
		size = V(1.8, 2.2, 1.4),
		fit = "contain",
		facing = "auto",
		turns = { [2416484976] = 90, [8803156531] = 90 },
		shadows = false,
		credit = "Festivereinhard2 (Old Wall Lamp); Cholin178 (Wall lantern)",
	},
	ceilingLamp = {
		ids = { 475636989 }, -- iron flush mount with a glass bowl
		mount = "ceiling",
		size = V(2.6, 1.4, 2.6),
		fit = "contain",
		facing = "any",
		shadows = false,
		credit = "wakydawg119 (Ceiling Light)",
	},
	chandelier = {
		ids = { 17370166704, 10627959279 }, -- two-tier brass candle chandelier; brass scrollwork with shades
		mount = "ceiling",
		size = V(5.6, 5.2, 5.6),
		fit = "contain",
		facing = "any",
		shadows = false,
		credit = "GT_oli (ChandelierPBR); OffByByte (Chandelier)",
	},
	floorLamp = {
		ids = { 16276432775 }, -- turned brass column, cream shade
		mount = "floor",
		size = V(1.8, 6.4, 1.8),
		fit = "height",
		facing = "any",
		shadows = false,
		credit = "MissMariaAntoinette (Lamp)",
	},
	tableLamp = {
		ids = { 8763605702, 15020876796 }, -- Tiffany-style stained glass; brass banker's lamp
		mount = "floor",
		size = V(1.6, 2, 1.6),
		fit = "contain",
		facing = "auto",
		shadows = false,
		credit = "Cholin178 (Table Lamp); Thetijdmjd (A Banker's Favorite Lamp)",
	},

	-- Plants and flowers ---------------------------------------------------------------------------------------
	bigPlant = {
		ids = { 8704290264, 10758068779, 8569543269 }, -- kentia palm; palm in a classical urn; spiral topiary
		mount = "floor",
		size = V(4, 6.2, 4),
		fit = "height",
		facing = "any",
		credit = "d_ytme (Potted Plant); PuggleyCake (Potted Plant); BN895 (Indoor Tree)",
	},
	smallPlant = {
		ids = { 87801222295603, 8259072716, 14924964084 }, -- fern planter box; fern in marble bowl; snake plant
		mount = "floor",
		size = V(3, 4.4, 3),
		fit = "height",
		facing = "any",
		credit = "CancelGrav (Plant Tree); noe_bsc (Plant Decoration); Milliankah (SolariumPottedPlant_E)",
	},
	flowerVase = {
		ids = { 2060720336, 14924836767, 13558787444 }, -- roses in a marble urn; lavender bowl; hydrangea urn
		mount = "floor",
		size = V(1.4, 2, 1.4),
		fit = "contain",
		facing = "any",
		credit = "UnixeI (Flower Vase); Milliankah (Vase_w_Flowers_LG); exoopss (hydrangea urn)",
	},

	-- Hotel service ------------------------------------------------------------------------------------------------
	receptionDesk = {
		-- The bell and a lamp stand on it at 4.25 studs (LobbyBuilder).
		ids = { 2653577393 }, -- carved counter with roundel panels (customer side front)
		mount = "floor",
		size = V(14, 4.25, 3.6),
		fit = "stretch",
		facing = "auto",
		credit = "Gypherviz (Bar Counter)",
	},
	deskBell = {
		ids = { 4948213579 }, -- silver dome bell with plunger
		mount = "floor",
		size = V(0.9, 0.8, 0.9),
		fit = "contain",
		facing = "any",
		credit = "ACRG22 (Little tiny bell)",
	},
	luggageCart = {
		ids = { 11498050741, 15040967563 }, -- bronze birdcage cart; gold double-arch cart
		mount = "floor",
		size = V(4.6, 6.2, 2.6),
		fit = "contain",
		facing = "auto",
		credit = "Straysnack (Luggage_Cart); taleshka666 (gold luggage cart)",
	},
	umbrellaStand = {
		ids = { 140669320531443 }, -- brass rack on marble with umbrellas and a cane
		mount = "floor",
		size = V(1.8, 3.4, 1.2),
		fit = "contain",
		facing = "auto",
		credit = "Blaye1100 (Umbrella Holder)",
	},
	statue = {
		ids = { 15603344661, 85011138302601 }, -- stone angel; bronze classical figure on a plinth
		mount = "floor",
		size = V(3.4, 6.6, 3.4),
		fit = "height",
		facing = "auto",
		credit = "dbbooq (realistic angel statue); OB3Y_Y (Asklepios_LG)",
	},
	rug = {
		ids = { 11829259774 }, -- red and blue Persian rug
		mount = "floor",
		size = V(14, 0.6, 12),
		fit = "contain",
		facing = "wide",
		credit = "caductis (Realistic Rug)",
	},

	-- Corridor extras ----------------------------------------------------------------------------------------
	vendingMachine = {
		ids = { 13660630957, 10551751004 }, -- wood-panelled glass-front machine; old snack machine (no logos)
		mount = "floor",
		size = V(3.4, 7, 2.8),
		fit = "contain",
		facing = "auto",
		credit = "craploltrevorIII (old vending machine); pizzafriday17 (Broken Vending machine)",
	},
	waterCooler = {
		ids = { 10904549519 }, -- white cooler with a blue bottle
		mount = "floor",
		size = V(1.6, 5, 1.6),
		fit = "contain",
		facing = "auto",
		credit = "Ligij (Water Dispenser Mesh PBR)",
	},
	trashBin = {
		ids = { 11426062981, 11508587471 }, -- slatted bins with chrome bands
		mount = "floor",
		size = V(1.6, 2.4, 1.6),
		fit = "contain",
		facing = "any",
		credit = "MR_MohamedTarek (Trash Bin); RTopix (Trash Can)",
	},
	roomServiceCart = {
		ids = { 990979342, 3861786118 }, -- two-tier antique tea table; wooden tea trolley
		mount = "floor",
		size = V(3.4, 3.2, 2.2),
		fit = "contain",
		facing = "auto",
		credit = "SurfaceGlue (Antique table); lakerguy2016 (wooden tea trolley)",
	},
	suitcaseStack = {
		ids = { 4903900210, 4593529461 }, -- stacked vintage cases with a doctor's bag; worn leather cases
		mount = "floor",
		size = V(2.6, 4.2, 2.2),
		fit = "contain",
		facing = "auto",
		credit = "EndlessSwagger (Bellboy's Heavy Suitcases); visionpsyche7 (Luggage)",
	},
	trafficCone = {
		ids = { 8952512774, 8615958435 },
		mount = "floor",
		size = V(1.2, 2.2, 1.2),
		fit = "contain",
		facing = "any",
		credit = "TheDiamondjordan (Traffic Cone); Zynkuru (Traffic Cone)",
	},
	goldenKey = {
		-- The key pickup (the client spins it; ZoneVisuals keeps its glow and sparkles).
		ids = { 4022890583 }, -- giant golden skeleton key
		mount = "centre",
		size = V(2.4, 2.4, 2.4),
		fit = "contain",
		facing = "any",
		credit = "EndlessSwagger (Giant Golden Skeleton Key)",
	},

	-- Rooms ------------------------------------------------------------------------------------------------------
	uprightFreezer = {
		ids = { 134950797159239 }, -- mint 1950s fridge
		mount = "floor",
		size = V(2.8, 6.2, 2.6),
		fit = "contain",
		facing = "auto",
		credit = "jamesback1949 (Vintage fridge)",
	},
	deskFan = {
		ids = { 2293770895 }, -- white oscillating desk fan
		mount = "floor",
		size = V(1.6, 2, 1.4),
		fit = "contain",
		facing = "auto",
		credit = "BonnieGamez101 (Electric Fan)",
	},
	cardboardBoxes = {
		ids = { 5128298696, 110825748556023 },
		mount = "floor",
		size = V(3.2, 3.2, 3),
		fit = "contain",
		facing = "any",
		credit = "Xitral (Cardboard Boxes Mesh); nyaalchemi (CardBoard_Boxes)",
	},
	ventDuct = {
		ids = { 8431921736 }, -- air duct section, long side along X
		mount = "ceiling",
		size = V(6, 1.6, 1.8),
		fit = "contain",
		facing = "wide",
		credit = "nate2the2great (Air Duct Section)",
	},
	laundryBasket = {
		ids = { 6132018569, 7992808754 }, -- wicker basket; plastic laundry basket
		mount = "floor",
		size = V(2.6, 2.2, 2.2),
		fit = "contain",
		facing = "any",
		credit = "Glowziing (basket); cruelescent (Laundry Basket)",
	},
	ironingBoard = {
		ids = { 14650194703 },
		mount = "floor",
		size = V(5, 3.2, 1.6),
		fit = "contain",
		facing = "wide",
		credit = "IzzyEpic29 (Ironing Board)",
	},
	detergentShelf = {
		ids = { 12342086399 }, -- shop shelf of coloured bottles and boxes (no brands)
		mount = "floor",
		size = V(4, 6, 1.6),
		fit = "contain",
		facing = "auto",
		credit = "lovegirl8560 (ShopInterior_Shelf_01)",
	},
	towelStack = {
		ids = { 433396067 }, -- folded white towels
		mount = "floor",
		size = V(1.8, 1.2, 1.4),
		fit = "contain",
		facing = "any",
		credit = "WrathOfTheElvhen (Stack of Towels)",
	},
	pottedFern = {
		ids = { 138705818090140, 84496050289038 },
		mount = "floor",
		size = V(2.2, 2.6, 2.2),
		fit = "height",
		facing = "any",
		credit = "WaysonPhD (COGIC Flower (5)); gabrielTST129 (Matero)",
	},
	flowerPots = {
		ids = { 7371169545 },
		mount = "floor",
		size = V(2.4, 1.6, 2),
		fit = "contain",
		facing = "any",
		credit = "StoneSymmetry (Flower Pots)",
	},
	cactus = {
		ids = { 4112655360, 5950578308 },
		mount = "floor",
		size = V(1.8, 2.2, 1.8),
		fit = "height",
		facing = "any",
		credit = "bearduckmonkey (Cactus Plant); Procybit (Cactus in the pot)",
	},
	smallTree = {
		ids = { 3486483490, 8927567782 }, -- topiary in a white pot; leafy plant
		mount = "floor",
		size = V(2.4, 4.2, 2.4),
		fit = "height",
		facing = "any",
		credit = "fred11468 (Potted plant); wesfilms (Plant)",
	},
	hangingPlant = {
		ids = { 8130406239, 13414398302 },
		mount = "ceiling",
		size = V(2, 3.6, 2),
		fit = "contain",
		facing = "any",
		credit = "EerieBun (fixed hanging plant); Crimson924 (Potted_Ivy_A)",
	},
	wateringCan = {
		ids = { 14003540414 },
		mount = "floor",
		size = V(1.6, 1.4, 1),
		fit = "contain",
		facing = "auto",
		credit = "zzz_1551 (Watering Can)",
	},
	vines = {
		ids = { 16155518562, 16078553656 }, -- ivy spreading over a wall
		mount = "wall",
		size = V(5, 6, 1.2),
		fit = "contain",
		facing = "auto",
		credit = "xGalaxinex (Ivy Veins); anolivys (Vines)",
	},
	scrapPile = {
		ids = { 4740013617, 4570032694 },
		mount = "floor",
		size = V(4, 2.4, 3.4),
		fit = "contain",
		facing = "any",
		credit = "Be4Vaporeon (Scrap Pile 2); Blabbering_Goat (scrap metal)",
	},
	metalBarrel = {
		ids = { 14452389275, 13304723548 },
		mount = "floor",
		size = V(1.9, 2.8, 1.9),
		fit = "contain",
		facing = "any",
		credit = "JSCHRISP (Barrel Metal); 2BeeSupreme (Rusty Barrel)",
	},
	gears = {
		ids = { 188960284 },
		mount = "wall",
		size = V(4, 3.4, 1.2),
		fit = "contain",
		facing = "auto",
		credit = "connorhperkins (Gears)",
	},
	toolbox = {
		ids = { 14452594483, 11464827472 },
		mount = "floor",
		size = V(2, 1.2, 1),
		fit = "contain",
		facing = "auto",
		credit = "JSCHRISP (Rusty Toolbox); Filpaaaaa (Toolbox)",
	},
	electromagnet = {
		ids = { 8630369951 }, -- crane magnet on chains (kept above head height)
		mount = "ceiling",
		size = V(3.2, 4.2, 3.2),
		fit = "contain",
		facing = "any",
		credit = "daon2000 (Crane Magnet)",
	},

	-- Safety ---------------------------------------------------------------------------------------------------
	fireExtinguisher = {
		ids = { 14003556037, 5307188544 }, -- worn red extinguisher; plain red extinguisher
		mount = "floor",
		size = V(1.1, 2.6, 1.1),
		fit = "contain",
		facing = "auto",
		credit = "zzz_1551 (Extinguisher); acxirv (Fire extinguisher)",
	},
	wetFloorSign = {
		ids = { 95220285653886, 16945975184 }, -- folding yellow signs (pictogram only, no text)
		mount = "floor",
		size = V(1.6, 2.8, 1.4),
		fit = "contain",
		facing = "auto",
		credit = "At0_mik (Free Wet Floor Sign - Procedural Floors); skrigliets (Wet Floor Sign)",
	},
}

local AssetManifest = {}

AssetManifest.entries = entries

function AssetManifest.get(key: string): Entry?
	return entries[key]
end

-- What players see first (the lobby, then every corridor) loads first; the rest follows alphabetically.
local FIRST: { string } = {
	"receptionDesk",
	"chandelier",
	"wallSconce",
	"sofa",
	"armchair",
	"grandfatherClock",
	"statue",
	"rug",
	"coffeeTable",
	"floorLamp",
	"tableLamp",
	"keyRack",
	"deskBell",
	"bigPlant",
	"luggageCart",
	"ceilingLamp",
	"sideTable",
	"bench",
	"smallPlant",
	"flowerVase",
}

-- Keys in loading order (the server loads them in this order, a few at a time).
function AssetManifest.keys(): { string }
	local keys = {}
	for key in entries do
		if not table.find(FIRST, key) then
			table.insert(keys, key)
		end
	end
	table.sort(keys)
	local ordered = {}
	for _, key in FIRST do
		if entries[key] then
			table.insert(ordered, key)
		end
	end
	for _, key in keys do
		table.insert(ordered, key)
	end
	return ordered
end

-- Every model id in the manifest (for the content record and the tests).
function AssetManifest.allIds(): { number }
	local ids = {}
	for _, key in AssetManifest.keys() do
		for _, id in entries[key].ids do
			table.insert(ids, id)
		end
	end
	return ids
end

return AssetManifest
