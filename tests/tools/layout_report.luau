--[[
	Layout authoring report: builds layouts headlessly and prints validation errors, an ASCII map of the
	grid (route + room/alcove footprints), sockets with their links and wind lanes, launches, crates,
	keys and levers. Used while authoring Content/Layouts.

	Usage (from the repo root, after tools/build.sh build/test.rbxl):
	  lune run tests/tools/layout_report.luau build/test.rbxl [layoutId ...]
]]

local process = require("@lune/process")

local Env = require("../harness/Env")

local placePath = process.args[1] or "build/test.rbxl"
local wanted = {}
for i = 2, #process.args do
	wanted[process.args[i]] = true
end

local loaded = Env.load(placePath)
local function module(path: string)
	return loaded.require(Env.find(loaded.game, path))
end

local Layouts = module("ReplicatedStorage.Shared.Content.Layouts")
local LevelBuilder = module("ReplicatedStorage.Shared.World.LevelBuilder")

local KIND_CHAR = {
	Elevator = "E",
	Hall = "H",
	Turn = "+",
	Basin = "B",
	Gap = "G",
	Fire = "F",
	Puddle = "P",
	Carts = "C",
	Target = "X",
}

local function asciiMap(runtime)
	local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
	local cells = {}
	for key, what in runtime.cells do
		local gx, gz = string.match(key, "^(-?%d+),(-?%d+)$")
		local x, z = tonumber(gx), tonumber(gz)
		minX, maxX = math.min(minX, x), math.max(maxX, x)
		minZ, maxZ = math.min(minZ, z), math.max(maxZ, z)
		local ch = "?"
		if what == "tile" then
			ch = "#"
		elseif string.sub(what, 1, 4) == "room" then
			ch = "r"
		elseif string.sub(what, 1, 6) == "alcove" then
			ch = "a"
		elseif what == "elevator" then
			ch = "e"
		elseif what == "target room" then
			ch = "x"
		end
		cells[x .. "," .. z] = ch
	end
	for _, tile in runtime.tiles do
		cells[tile.gx .. "," .. tile.gz] = KIND_CHAR[tile.kind] or "#"
	end
	local lines = {}
	-- Rows = gz descending, columns = gx descending (so +X reads to the left like a top-down view from +Y
	-- with -Z up would; orientation only matters for readability).
	for z = maxZ, minZ, -1 do
		local row = {}
		for x = maxX, minX, -1 do
			table.insert(row, cells[x .. "," .. z] or ".")
		end
		table.insert(lines, string.format("%4d  %s", z, table.concat(row, " ")))
	end
	return table.concat(lines, "\n")
end

local ids = {}
for id in Layouts do
	if next(wanted) == nil or wanted[id] then
		table.insert(ids, id)
	end
end
table.sort(ids)

for _, id in ids do
	local layout = Layouts[id]
	local result = LevelBuilder.build(layout)
	local rt = result.runtime
	print(string.rep("=", 78))
	print(
		string.format(
			"%s  theme=%s  tiles=%d  parts=%d  errors=%d",
			id,
			layout.theme,
			#rt.tiles,
			rt.partCount,
			#rt.errors
		)
	)
	for _, e in rt.errors do
		print("  ERROR: " .. e)
	end
	print(asciiMap(rt))
	local sockets = {}
	for sid in rt.sockets do
		table.insert(sockets, sid)
	end
	table.sort(sockets)
	for _, sid in sockets do
		local s = rt.sockets[sid]
		local lanes = {}
		for dir, laneId in s.lanes do
			local lane = rt.lanes[laneId]
			table.insert(
				lanes,
				string.format("%s(len %.0f, slides %s)", dir, lane.size.Z, table.concat(lane.slides, "+"))
			)
		end
		table.sort(lanes)
		local links = s.links
		print(
			string.format(
				"  socket %-4s tile %2d %s  cold=[%s] water=%s vine=%s magnet=[%s]  lanes: %s",
				sid,
				s.tile,
				s.side,
				table.concat(links.cold or {}, ","),
				tostring(links.water),
				tostring(links.vine),
				table.concat(links.magnet or {}, ","),
				table.concat(lanes, " ")
			)
		)
	end
	for lid, launch in rt.launches do
		print(string.format("  launch %s basin=%s landing=%s", lid, tostring(launch.basin), tostring(launch.landing)))
	end
	for cid, crate in rt.crates do
		print(
			string.format(
				"  crate %s metal=%s rail=%.1f start=%.1f slot=%s plates=[%s] tile=%d",
				cid,
				tostring(crate.metal),
				crate.railLength,
				crate.startOffset,
				if crate.slotOffset then string.format("%.1f", crate.slotOffset) else "-",
				table.concat(crate.plates, ","),
				crate.tile
			)
		)
	end
	for kid, key in rt.keys do
		print(string.format("  key %s alcove=%s", kid, tostring(key.alcove)))
	end
	for lid, lever in rt.levers do
		print(string.format("  lever %s tile=%d", lid, lever.tile))
	end
	for cid, cart in rt.carts do
		print(string.format("  carts %s tile=%d speed=%s", cid, cart.tile, tostring(cart.speed)))
	end
	print(
		string.format(
			"  caretaker dormant=%s spawn=%s patrol=%s..%s  ledges=%d pits=%d",
			tostring(rt.caretaker.dormant),
			rt.caretaker.spawnNode,
			tostring(rt.caretaker.patrol[1]),
			tostring(rt.caretaker.patrol[#rt.caretaker.patrol]),
			#rt.ledges,
			#rt.pits
		)
	)
end
