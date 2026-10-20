--!strict
--[[
	LayoutTypes: authoring format for expedition layouts (S10, S31) and the runtime description the
	LevelBuilder produces for the server services.

	A layout is a linear route of modules. The route starts in the extraction elevator, winds through the
	hotel (Turn modules change heading) and ends at the Target room. Sockets are declared per hall tile and
	their effect links are listed by socket id, which keeps every interaction explicit (S08: tagged zones and
	explicit interactions, no fluid simulation).
]]

export type Side = "L" | "R"
export type WindDir = "Forward" | "Backward" | "Across"

export type SocketDef = {
	cold: { string }?,
	water: string?,
	vine: string?,
	magnet: { string }?,
	wind: { string }?, -- any of "Forward" | "Backward" | "Across"
	protected: boolean?,
}

-- Wall sides inside these lists are plain strings ("L" / "R"): the type solver cannot push the Side singleton
-- type into table literals nested in optional lists, so the builder validates them instead.
export type CrateDef = { id: string, at: number, lateral: number, along: number?, metal: boolean? }
export type PlateDef = { id: string, at: number, lateral: number, along: number? }
export type LeverDef = { id: string, at: number, side: string }
export type KeyDef = { id: string, at: number?, lateral: number?, along: number?, alcove: string? }
export type AlcoveDef = { id: string, at: number, side: string, gate: string, key: string? } -- key waits inside

export type ModuleDef = {
	kind: "Elevator" | "Hall" | "Turn" | "Basin" | "Gap" | "Fire" | "Puddle" | "Carts" | "Target",
	len: number?,
	dir: Side?,
	id: string?,
	wet: boolean?,
	ledge: Side?,
	beam: Side?,
	slot: string?,
	launch: boolean?,
	vine: string?,
	waterFrom: string?,
	power: string?,
	room: string?,
	sockets: { [number]: { L: string?, R: string? } }?,
	doors: boolean?,
	crates: { CrateDef }?,
	plates: { PlateDef }?,
	levers: { LeverDef }?,
	keys: { KeyDef }?,
	alcoves: { AlcoveDef }?,
	cartSpeed: number?,
	note: string?,
}

-- Authored solutions: scripted solo playthroughs (documentation + the solvability spec in
-- tests/specs/layouts.spec.luau, which replays them step by step against the real effect model, wind lanes,
-- crate rails, plates, gates and the route's reachability).
export type CrossingMethod =
	"ice" -- a Freezer froze the flooded basin / pool
	| "ledge" -- slow safe ledge along a basin or gap
	| "beam" -- slow safe beam across a gap
	| "walkway" -- heat-shielded walkway past a fire
	| "launch" -- ice + wind launch over a gap (outward only)
	| "crate" -- a pushed / pulled crate sits in the gap slot as stepping stones
	| "vine" -- a grown vine bridge
	| "douse" -- water put the fire out
	| "power" -- the zone is not electrified (switch off, or frozen)
	| "pin" -- a Fan blowing across the track pins the cart at the far side
	| "slow" -- cold slows the cart right down
	| "timing" -- dodge the running cart

export type SolutionStep = {
	deploy: string?, -- socket id (with `room`, and `dir` for directional rooms)
	room: string?,
	dir: string?,
	recall: string?, -- room id to fold back (recall works from anywhere)
	pull: string?, -- lever id
	cross: string?, -- obstacle id (Basin / Gap / Fire / powered Puddle / Carts module id)
	by: CrossingMethod?,
	capture: boolean?, -- steal the target room (must be standing at the target)
	escape: boolean?, -- reach the elevator with the suitcase
}

export type Solution = {
	name: string,
	loadout: { string }, -- the solo player's two equipped rooms
	steps: { SolutionStep },
	combos: { string }?, -- combos the playthrough performs (verified)
	keys: { string }?, -- keys the playthrough collects (verified)
}

export type LayoutDef = {
	id: string,
	nameKey: string,
	theme: string,
	seed: number,
	modules: { ModuleDef },
	sockets: { [string]: SocketDef },
	powers: { [string]: { default: boolean, levers: { string } } }?,
	gates: { [string]: { signals: { string }, mode: ("any" | "all")? } }?,
	caretaker: { dormant: boolean?, patrolFrom: number?, patrolTo: number?, spawn: number? }?,
	tutorial: boolean?,
	roomNumberBase: number?,
	solutions: { Solution }, -- empty for the tutorial
}

-- Runtime ------------------------------------------------------------------------------------------

export type TileInfo = {
	index: number,
	gx: number,
	gz: number,
	heading: number,
	cf: CFrame,
	kind: string,
	module: number,
	offset: number, -- 1-based tile offset within its module
	run: number,
	runAlong: number, -- along-distance of the tile centre from the start of its run
	hazard: string?,
	safe: boolean,
}

export type Box = { cf: CFrame, size: Vector3 }

export type SocketRuntime = {
	id: string,
	tile: number,
	side: Side,
	doorCF: CFrame, -- inner wall face, LookVector into the corridor
	roomCF: CFrame, -- room frame (outer wall face, LookVector into the room)
	interactPoint: Vector3,
	links: SocketDef,
	lanes: { [string]: string }, -- WindDir -> lane id
	defaultDir: WindDir?,
	coldFields: { Box },
	previewZones: { string },
	protected: boolean,
}

export type LaneRuntime = {
	id: string,
	socket: string,
	dir: WindDir,
	cf: CFrame,
	size: Vector3,
	vector: Vector3,
	slides: { string }, -- launch pad ids boosted by this lane
}

export type LaunchRuntime = {
	id: string,
	trigger: Box,
	landing: Vector3,
	direction: Vector3,
	basin: string?, -- the ice basin feeding the ramp (wind boost applies on it)
	slide: Box, -- region where the wind boost accelerates sliding players
}

export type BasinRuntime = {
	id: string,
	deep: boolean,
	surface: Box, -- water surface / ice top region
	pit: Box?, -- fall region (deep basins)
	occupancy: Box, -- standing-on-ice region
	damage: Box?, -- electrified region (shallow)
	power: string?,
	tiles: { number },
	fire: string?, -- fire this pool belongs to
}

export type FireRuntime = { id: string, pool: string, volume: Box, tile: number }
export type VineRuntime = { id: string, bridge: Box, tile: number, waterBasin: string? }
export type GateRuntime = { id: string, box: Box, alcove: string? }
export type CrateRuntime = {
	id: string,
	metal: boolean,
	railCF: CFrame, -- centre of the rail, X axis = movement axis
	railLength: number,
	startOffset: number, -- crate start position along the rail (relative to centre)
	slotOffset: number?, -- along-rail offset where the crate drops into a slot
	slotCF: CFrame?, -- final resting CFrame inside the slot
	plates: { string },
	tile: number,
}
export type PlateRuntime = { id: string, cf: CFrame, radius: number, tile: number }
export type LeverRuntime = { id: string, cf: CFrame, tile: number }
export type KeyRuntime = { id: string, position: Vector3, alcove: string? }
export type CartRuntime = { id: string, tileCF: CFrame, range: number, speed: number, size: Vector3, tile: number }
export type PitRuntime = { box: Box, zone: string?, kind: string }

export type Runtime = {
	layoutId: string,
	theme: string,
	origin: CFrame,
	tiles: { TileInfo },
	cells: { [string]: string }, -- "gx,gz" -> what occupies the cell
	sockets: { [string]: SocketRuntime },
	socketOrder: { string },
	basins: { [string]: BasinRuntime },
	fires: { [string]: FireRuntime },
	vines: { [string]: VineRuntime },
	gates: { [string]: GateRuntime },
	lanes: { [string]: LaneRuntime },
	launches: { [string]: LaunchRuntime },
	crates: { [string]: CrateRuntime },
	plates: { [string]: PlateRuntime },
	levers: { [string]: LeverRuntime },
	keys: { [string]: KeyRuntime },
	carts: { [string]: CartRuntime },
	ledges: { Box },
	pits: { PitRuntime },
	safeFloors: { Box },
	slots: { [string]: { gap: string, cf: CFrame, run: number, centre: Vector3 } },
	spawns: { CFrame },
	exit: Box,
	target: { room: string, doorCF: CFrame, roomCF: CFrame, capturePoint: Vector3, tile: number },
	nav: { nodes: { { id: string, position: Vector3 } }, edges: { { string } } },
	caretaker: { dormant: boolean, spawnNode: string, patrol: { string }, escapeSpawnNode: string },
	bounds: { min: Vector3, max: Vector3 },
	effectDefs: any,
	errors: { string },
	partCount: number,
}

return {}
