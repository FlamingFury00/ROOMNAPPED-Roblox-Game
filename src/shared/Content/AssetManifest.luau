--!strict
--[[
	AssetManifest: the curated free Creator Store models the hotel is dressed with (A01, A10).

	Every entry names one prop key the world builders ask for (World/Assets) and the Creator Store models
	that may fill it. The server loads them at startup with AssetService:LoadAssetAsync, keeps no scripts,
	sounds, physics or GUIs, turns each model so its front faces -Z, scales it uniformly into `size` and
	publishes the result as a template (AssetLibraryService). A key whose models all fail keeps its procedural
	fallback, so the manifest can never break a level.

	  ids     model ids, one template per id that loads (variants are picked deterministically per slot)
	  mount   "floor" | "wall" | "ceiling" (where the template's pivot sits, see World/Assets)
	  size    target bounds in studs: X width, Y height, Z depth (front to back)
	  fit     "contain" (fit inside size), "height" or "width" (match that dimension; the others follow)
	  facing  "auto" (detect the front, Roblox models usually face +Z), "any" (round props: no turn) or a
	          fixed turn in degrees applied after loading
	  lights  keep the model's own lights (default off: builders place the hotel's lights themselves)
	  credit  creator name, recorded in docs/CONTENT_OWNERSHIP.md

	Provenance: every id is a free Creator Store asset found with tools/assets/scout.py; see
	docs/CONTENT_OWNERSHIP.md for names, creators and checks.
]]

export type Entry = {
	ids: { number },
	mount: "floor" | "wall" | "ceiling",
	size: Vector3,
	fit: "contain" | "height" | "width",
	facing: "auto" | "any" | number,
	lights: boolean?,
	particles: boolean?,
	shadows: boolean?,
	credit: string?,
}

local V = Vector3.new

local entries: { [string]: Entry } = {}

local AssetManifest = {}

AssetManifest.entries = entries

function AssetManifest.get(key: string): Entry?
	return entries[key]
end

-- Keys in a stable order (loading order: lobby and corridor first).
function AssetManifest.keys(): { string }
	local keys = {}
	for key in entries do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end

local _ = V

return AssetManifest
