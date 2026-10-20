--[[
	Export procedural geometry for offline visual QA.

	Usage: lune run tools/preview/export.luau <place.rbxl> <what> <out.json> [roomId skinId]
	  what = layout id (e.g. L0), "lobby", or "room" (with roomId and skinId)
	Writes every BasePart (class, shape, CFrame components, size, colour, material, transparency) plus
	light positions, so tools/preview/render.py can rasterise views of the level.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local Env = require("../../tests/harness/Env")

local placePath = process.args[1] or "build/test.rbxl"
local what = process.args[2] or "L0"
local outPath = process.args[3] or "tools/preview/out/scene.json"

local loaded = Env.load(placePath)
local function module(path: string)
	return loaded.require(Env.find(loaded.game, path))
end

local root
local extra = {}
if what == "lobby" then
	local LobbyBuilder = module("ReplicatedStorage.Shared.World.LobbyBuilder")
	local result = LobbyBuilder.build()
	root = result.model
	extra.spawn = { result.runtime.spawn.Position.X, result.runtime.spawn.Position.Y, result.runtime.spawn.Position.Z }
elseif what == "room" then
	local RoomPrefabs = module("ReplicatedStorage.Shared.World.RoomPrefabs")
	local roblox = require("@lune/roblox")
	root = RoomPrefabs.build(process.args[4] or "Freezer", process.args[5], roblox.CFrame.new(0, 0, 0), "preview")
else
	local Layouts = module("ReplicatedStorage.Shared.Content.Layouts")
	local LevelBuilder = module("ReplicatedStorage.Shared.World.LevelBuilder")
	local layout = Layouts[what]
	assert(layout, "unknown layout " .. what)
	local result = LevelBuilder.build(layout)
	root = result.model
	local tiles = {}
	for _, tile in result.runtime.tiles do
		local cf = tile.cf
		table.insert(tiles, {
			kind = tile.kind,
			pos = { cf.Position.X, cf.Position.Y, cf.Position.Z },
			look = { cf.LookVector.X, cf.LookVector.Y, cf.LookVector.Z },
		})
	end
	extra.tiles = tiles
	extra.errors = result.runtime.errors
	extra.partCount = result.runtime.partCount
end

local parts = {}
local lights = {}
for _, d in root:GetDescendants() do
	if d:IsA("BasePart") then
		local cf = d.CFrame
		local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cf:GetComponents()
		local shape = "Block"
		if d.ClassName == "WedgePart" then
			shape = "Wedge"
		elseif d.ClassName == "CornerWedgePart" then
			shape = "CornerWedge"
		elseif d.ClassName == "Part" then
			shape = d.Shape.Name
		end
		table.insert(parts, {
			n = d.Name,
			s = shape,
			cf = { x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 },
			sz = { d.Size.X, d.Size.Y, d.Size.Z },
			c = { d.Color.R, d.Color.G, d.Color.B },
			m = d.Material.Name,
			t = d.Transparency,
		})
	elseif d:IsA("Light") then
		local parent = d.Parent
		if parent and parent:IsA("BasePart") then
			local p = parent.CFrame.Position
			table.insert(lights, {
				p = { p.X, p.Y, p.Z },
				c = { d.Color.R, d.Color.G, d.Color.B },
				r = (d :: any).Range,
				b = d.Brightness,
			})
		end
	end
end
extra.parts = parts
extra.lights = lights
fs.writeFile(outPath, serde.encode("json", extra))
print(string.format("exported %d parts, %d lights -> %s", #parts, #lights, outPath))
