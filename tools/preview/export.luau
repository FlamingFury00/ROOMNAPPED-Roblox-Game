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

local roblox = require("@lune/roblox")
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
	extra.theme = "lobby"
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
	local Palette = module("ReplicatedStorage.Shared.World.Palette")
	local theme = Palette.get(layout.theme or "classic")
	extra.theme = theme.id
	extra.ambient = { theme.ambient.R, theme.ambient.G, theme.ambient.B }
	extra.fog = { theme.fog.R, theme.fog.G, theme.fog.B }
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
local slots = {}
local function components(cf: any): { number }
	local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cf:GetComponents()
	return { x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 }
end
for _, d in root:GetDescendants() do
	if d:IsA("BasePart") then
		local shape = "Block"
		if d.ClassName == "WedgePart" then
			shape = "Wedge"
		elseif d.ClassName == "CornerWedgePart" then
			shape = "CornerWedge"
		elseif d.ClassName == "Part" then
			shape = d.Shape.Name
		end
		local mesh = d:FindFirstChildOfClass("SpecialMesh")
		if mesh and mesh.MeshType == roblox.Enum.MeshType.Sphere then
			shape = "Ellipsoid"
		end
		-- Textures and decals on the part's faces (image id, face, tiling, tint).
		local textures = {}
		for _, child in d:GetChildren() do
			if child:IsA("Decal") then
				local entry: { [string]: any } = {
					id = child.Texture,
					f = child.Face.Name,
					c = { child.Color3.R, child.Color3.G, child.Color3.B },
					t = child.Transparency,
				}
				if child:IsA("Texture") then
					entry.u = child.StudsPerTileU
					entry.v = child.StudsPerTileV
					entry.ou = child.OffsetStudsU
					entry.ov = child.OffsetStudsV
				end
				table.insert(textures, entry)
			end
		end
		local mv = ""
		local okVariant, variant = pcall(function()
			return d.MaterialVariant
		end)
		if okVariant and type(variant) == "string" then
			mv = variant
		end
		table.insert(parts, {
			n = d.Name,
			s = shape,
			cf = components(d.CFrame),
			sz = { d.Size.X, d.Size.Y, d.Size.Z },
			c = { d.Color.R, d.Color.G, d.Color.B },
			m = d.Material.Name,
			mv = mv,
			t = d.Transparency,
			r = d.Reflectance,
			cs = d.CastShadow,
			tex = if #textures > 0 then textures else nil,
		})
	elseif d:IsA("Light") then
		local parent = d.Parent
		if parent and parent:IsA("BasePart") then
			local p = parent.CFrame.Position
			local entry: { [string]: any } = {
				k = d.ClassName,
				p = { p.X, p.Y, p.Z },
				cf = components(parent.CFrame),
				sz = { parent.Size.X, parent.Size.Y, parent.Size.Z },
				c = { d.Color.R, d.Color.G, d.Color.B },
				r = (d :: any).Range,
				b = d.Brightness,
				sh = d.Shadows,
				on = d.Enabled,
			}
			if d:IsA("SpotLight") or d:IsA("SurfaceLight") then
				entry.a = (d :: any).Angle
				entry.f = (d :: any).Face.Name
			end
			table.insert(lights, entry)
		end
	elseif d:IsA("Model") and d:GetAttribute("AssetKey") then
		local cf = d:GetAttribute("SlotCF")
		table.insert(slots, {
			key = d:GetAttribute("AssetKey"),
			cf = if typeof(cf) == "CFrame" then components(cf) else nil,
		})
	end
end
-- MaterialVariants (from their Rojo files): the viewer draws their colour maps from asset thumbnails.
local variants = {}
local variantDir = "src/MaterialService"
if fs.isDir(variantDir) then
	for _, file in fs.readDir(variantDir) do
		local name = string.match(file, "^(.+)%.model%.json$")
		if name then
			local ok, decoded = pcall(serde.decode, "json", fs.readFile(variantDir .. "/" .. file))
			local props = ok and decoded.properties
			local image = props and string.match(tostring(props.ColorMap or ""), "(%d+)")
			if image then
				variants[name] = { image = image, studs = props.StudsPerTile or 8 }
			end
		end
	end
end

extra.parts = parts
extra.lights = lights
extra.slots = slots
extra.variants = variants
fs.writeFile(outPath, serde.encode("json", extra))
print(string.format("exported %d parts, %d lights, %d asset slots -> %s", #parts, #lights, #slots, outPath))
