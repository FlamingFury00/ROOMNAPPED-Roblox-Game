return function(ctx)
	local Spec = ctx.Spec
	local describe, it, expect = Spec.describe, Spec.it, Spec.expect

	local Layouts = ctx.module("ReplicatedStorage.Shared.Content.Layouts")
	local LevelBuilder = ctx.module("ReplicatedStorage.Shared.World.LevelBuilder")
	local RoomPrefabs = ctx.module("ReplicatedStorage.Shared.World.RoomPrefabs")
	local RoomDefs = ctx.module("ReplicatedStorage.Shared.Config.RoomDefs")
	local SkinDefs = ctx.module("ReplicatedStorage.Shared.Config.SkinDefs")
	local Missions = ctx.module("ReplicatedStorage.Shared.Config.MissionDefs")
	local EffectModel = ctx.module("ReplicatedStorage.Shared.Logic.EffectModel")
	local GameConfig = ctx.module("ReplicatedStorage.Shared.Config.GameConfig")
	local Geometry = ctx.module("ReplicatedStorage.Shared.World.Geometry")
	local CF = ctx.roblox.CFrame
	local Vector3 = ctx.roblox.Vector3

	describe("Layouts build cleanly (S10/S31/R11)", function()
		local ids = {}
		for id in Layouts do
			table.insert(ids, id)
		end
		table.sort(ids)
		for _, id in ids do
			it(id .. " builds without validation errors", function()
				local result = LevelBuilder.build(Layouts[id])
				if #result.runtime.errors > 0 then
					error(table.concat(result.runtime.errors, "\n"))
				end
				local rt = result.runtime
				expect(#rt.spawns).toBe(4)
				expect(rt.target ~= nil).toBe(true)
				expect(rt.partCount < 4500).toBe(true)
				-- Effect definitions are valid inputs for the effect engine.
				local model = EffectModel.new(rt.effectDefs, GameConfig.Effects)
				model:step(0.1)
				-- Every socket has at least one wind lane.
				for socketId, socket in rt.sockets do
					local n = 0
					for _ in socket.lanes do
						n += 1
					end
					if n == 0 then
						error("socket " .. socketId .. " has no wind lane")
					end
				end
			end)
		end
		it("every mission references an existing layout", function()
			for _, mission in Missions.list do
				expect(Layouts[mission.layoutId] ~= nil).toBe(true)
			end
		end)
	end)

	describe("Room prefabs (A02/R11)", function()
		it("builds every room with every skin inside the reserved bounds", function()
			local roomCF = CF.new(0, 0, 0)
			for _, def in RoomDefs.ordered do
				for _, skin in SkinDefs.byRoom[def.id] do
					local model = RoomPrefabs.build(def.id, skin.id, roomCF, "test")
					local outlet = model:FindFirstChild("Outlet")
					expect(outlet ~= nil).toBe(true)
					for _, d in model:GetDescendants() do
						if d:IsA("BasePart") then
							local p = d.CFrame.Position
							-- Room space: x in [-8, 8], y in [-1, 15], depth (−z) in [0, 14] (+margin).
							if math.abs(p.X) > 8.6 or p.Y < -1.2 or p.Y > 15.2 or -p.Z < -0.6 or -p.Z > 14.6 then
								error(
									string.format(
										"%s/%s part %s out of bounds at %s",
										def.id,
										skin.id,
										d.Name,
										tostring(p)
									)
								)
							end
						end
					end
				end
			end
		end)
		it("builds suitcases for every suitcase skin", function()
			for _, skin in SkinDefs.suitcases do
				local model = RoomPrefabs.suitcase(skin.id, 1)
				expect(model.PrimaryPart ~= nil).toBe(true)
			end
		end)
	end)

	describe("Surfaces and real models (A01/A10)", function()
		local Palette = ctx.module("ReplicatedStorage.Shared.World.Palette")
		local AssetManifest = ctx.module("ReplicatedStorage.Shared.Content.AssetManifest")
		local LobbyBuilder = ctx.module("ReplicatedStorage.Shared.World.LobbyBuilder")

		it("every palette surface is a MaterialVariant in the place with the same base material", function()
			local service = ctx.game:FindFirstChildOfClass("MaterialService")
			if not service then
				error("the place has no MaterialService")
			end
			for name, material in Palette.VARIANTS do
				local variant = service:FindFirstChild(name)
				if not (variant and variant.ClassName == "MaterialVariant") then
					error("missing MaterialVariant " .. name)
				end
				if variant.BaseMaterial ~= material then
					error(name .. " has base material " .. tostring(variant.BaseMaterial))
				end
			end
			for id, theme in Palette.themes do
				for kind, surface in theme.surfaces or {} do
					if Palette.VARIANTS[surface.variant] ~= surface.material then
						error(id .. "." .. kind .. " uses " .. surface.variant .. " on the wrong base material")
					end
				end
			end
		end)

		it("every manifest entry is well formed", function()
			for _, key in AssetManifest.keys() do
				local entry = AssetManifest.get(key)
				if #entry.ids == 0 then
					error(key .. " has no ids")
				end
				local size = entry.size
				if size.X <= 0 or size.Y <= 0 or size.Z <= 0 then
					error(key .. " has an empty size")
				end
				for id in entry.turns or {} do
					if not table.find(entry.ids, id) then
						error(key .. " turns an id it does not list: " .. tostring(id))
					end
				end
			end
		end)

		it("every prop slot the builders make names a manifest key", function()
			local models = { LobbyBuilder.build().model }
			for _, id in { "L1", "L4", "L6" } do
				if Layouts[id] then
					table.insert(models, LevelBuilder.build(Layouts[id]).model)
				end
			end
			for _, def in RoomDefs.ordered do
				for _, skin in SkinDefs.byRoom[def.id] do
					table.insert(models, RoomPrefabs.build(def.id, skin.id, CF.new(), "slots"))
				end
			end
			local seen = 0
			for _, model in models do
				for _, d in model:GetDescendants() do
					local key = d:GetAttribute("AssetKey")
					if key ~= nil then
						seen += 1
						if not AssetManifest.get(key) then
							error("slot for unknown prop key " .. tostring(key))
						end
					end
				end
			end
			expect(seen > 0).toBe(true)
		end)

		it("takes a curated model into a slot and gives the built-in prop back when switched off", function()
			local Assets = ctx.module("ReplicatedStorage.Shared.World.Assets")
			local Instance = ctx.roblox.Instance
			local storage = ctx.game:GetService("ReplicatedStorage")
			local library = storage:FindFirstChild(Assets.FOLDER) or Instance.new("Folder")
			library.Name = Assets.FOLDER
			library.Parent = storage
			local world = Instance.new("Folder")
			world.Parent = ctx.game:GetService("Workspace")
			local built = 0
			local slot = Assets.place(world, "bench", CF.new(5, 0, 5), function(into, cf)
				built += 1
				local part = Instance.new("Part")
				part.Name = "Fallback"
				part.CFrame = cf
				part.Parent = into
			end)
			expect(slot:GetAttribute("Asset")).toBe(false)
			expect(slot:FindFirstChild("Fallback") ~= nil).toBe(true)
			-- The model arrives: the slot takes it, in place.
			local holder = Instance.new("Folder")
			holder.Name = "bench"
			local template = Instance.new("Model")
			template.Name = "01"
			local real = Instance.new("Part")
			real.Name = "Real"
			real.Parent = template
			template.Parent = holder
			holder.Parent = library
			expect(Assets.upgrade("bench")).toBe(1)
			expect(slot:GetAttribute("Asset")).toBe(true)
			expect(slot:FindFirstChild("Fallback")).toBe(nil)
			local placed = slot:FindFirstChildWhichIsA("Model")
			expect(placed and placed:FindFirstChild("Real") ~= nil).toBe(true)
			expect(((placed :: any).Real.CFrame.Position - Vector3.new(5, 0, 5)).Magnitude < 1e-3).toBe(true)
			-- The library is switched off: the template goes and the built-in prop comes back.
			holder:Destroy()
			expect(Assets.revert("bench")).toBe(1)
			expect(slot:GetAttribute("Asset")).toBe(false)
			expect(slot:FindFirstChild("Fallback") ~= nil).toBe(true)
			expect(slot:FindFirstChildWhichIsA("Model")).toBe(nil)
			expect(built).toBe(2)
			-- Nothing to put back twice.
			expect(Assets.revert("bench")).toBe(0)
			world:Destroy()
		end)

		it("cleans a loaded model into one flat, inert model without invisible parts", function()
			local Library = ctx.module("ServerScriptService.Server.Services.AssetLibraryService")
			local Instance = ctx.roblox.Instance
			local function part(name: string, parent: any, transparency: number?): any
				local p = Instance.new("Part")
				p.Name = name
				p.Transparency = transparency or 0
				p.Parent = parent
				return p
			end
			local loaded = Instance.new("Model")
			local root = Instance.new("Model")
			root.Parent = loaded
			local body = part("Body", root)
			Instance.new("Script").Parent = body
			Instance.new("Sound").Parent = body
			local hitbox = part("Hitbox", root, 1)
			part("Nested", hitbox) -- visible, inside the invisible hitbox
			local label = part("Label", root, 1)
			Instance.new("Decal").Parent = label
			local entry = { ids = { 1 }, mount = "floor", size = Vector3.one, fit = "contain", facing = "any" }
			local model = Library.clean(loaded, entry, "test")
			expect(model ~= nil).toBe(true)
			local kept = {}
			for _, child in (model :: any):GetChildren() do
				kept[child.Name] = child
			end
			expect(kept.Body ~= nil).toBe(true)
			expect(kept.Nested ~= nil).toBe(true)
			expect(kept.Label ~= nil).toBe(true)
			expect(kept.Hitbox).toBe(nil)
			expect(kept.Body.Anchored).toBe(true)
			expect(kept.Body.CanCollide).toBe(false)
			expect(kept.Body.CanQuery).toBe(false)
			expect(#kept.Body:GetChildren()).toBe(0)
			-- Nothing visible at all: no template.
			local ghost = Instance.new("Model")
			part("Ghost", ghost, 1)
			expect(Library.clean(ghost, entry, "test")).toBe(nil)
		end)
	end)

	local _ = Geometry
end
