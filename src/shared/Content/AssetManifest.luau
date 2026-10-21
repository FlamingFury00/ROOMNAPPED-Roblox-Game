--!strict
--[[
	AssetManifest: the curated free Creator Store models the hotel is dressed with (A01, A10).

	Every entry names one prop key the world builders ask for (World/Assets) and the Creator Store models
	that may fill it. The server loads them at startup with AssetService:LoadAssetAsync, keeps no scripts,
	sounds, physics or GUIs, turns each model so its front faces -Z, scales it uniformly into `size` and
	publishes the result as a template (AssetLibraryService). A key whose models all fail keeps its procedural
	fallback, so the manifest can never break a level.

	  ids      model ids, one template per id that loads (variants are picked deterministically per slot)
	  mount    "floor" | "wall" | "ceiling" (where the template's pivot sits, see World/Assets)
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
	mount: "floor" | "wall" | "ceiling",
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

-- Keys in a stable order (the server loads them in this order, a few at a time).
function AssetManifest.keys(): { string }
	local keys = {}
	for key in entries do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
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
