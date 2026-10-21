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
	end)

	local _ = Geometry
end
