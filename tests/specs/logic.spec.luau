return function(ctx)
	local Spec = ctx.Spec
	local describe, it, expect = Spec.describe, Spec.it, Spec.expect
	local V3 = ctx.roblox.Vector3

	local GameConfig = ctx.module("ReplicatedStorage.Shared.Config.GameConfig")
	local DeployRules = ctx.module("ReplicatedStorage.Shared.Logic.DeployRules")
	local RunMachine = ctx.module("ReplicatedStorage.Shared.Logic.RunMachine")
	local HealthModel = ctx.module("ReplicatedStorage.Shared.Logic.HealthModel")
	local ProfileSchema = ctx.module("ReplicatedStorage.Shared.Logic.ProfileSchema")
	local RewardRules = ctx.module("ReplicatedStorage.Shared.Logic.RewardRules")
	local NavGraph = ctx.module("ReplicatedStorage.Shared.Logic.NavGraph")
	local Missions = ctx.module("ReplicatedStorage.Shared.Config.MissionDefs")
	local Skins = ctx.module("ReplicatedStorage.Shared.Config.SkinDefs")
	local Rooms = ctx.module("ReplicatedStorage.Shared.Config.RoomDefs")
	local Net = ctx.module("ReplicatedStorage.Shared.Net.Net")

	local function deployState()
		return {
			phase = "Explore",
			sockets = {},
			validSockets = { S1 = true, S2 = true, S3 = true, S4 = true, S5 = true },
			disabledRooms = {},
			perPlayerCap = GameConfig.Deploy.ActivePerPlayer,
			teamCap = GameConfig.Deploy.ActivePerTeam,
		}
	end
	local function playerView(userId)
		return {
			userId = userId,
			inRoster = true,
			active = true,
			loadout = { "Freezer", "Fan" },
			deployed = {},
			distanceToSocket = 5,
			range = GameConfig.Deploy.Range,
			cooldownRemaining = 0,
		}
	end
	local function claim(state, player, slot, socketId)
		local ok, reason = DeployRules.canDeploy(state, player, slot, socketId)
		if ok then
			state.sockets[socketId] = { owner = player.userId, slot = slot, room = player.loadout[slot] }
			player.deployed[slot] = socketId
		end
		return ok, reason
	end

	describe("DeployRules (R06/S06)", function()
		it("lets a solo player deploy both slots", function()
			local state, p = deployState(), playerView(1)
			expect(claim(state, p, 1, "S1")).toBe(true)
			expect(claim(state, p, 2, "S2")).toBe(true)
		end)
		it("rejects a second claim on the same socket", function()
			local state, a, b = deployState(), playerView(1), playerView(2)
			expect(claim(state, a, 1, "S1")).toBe(true)
			local ok, reason = claim(state, b, 1, "S1")
			expect(ok).toBe(false)
			expect(reason).toBe("SocketOccupied")
		end)
		it("enforces one instance per slot and the per-player cap", function()
			local state, p = deployState(), playerView(1)
			claim(state, p, 1, "S1")
			local ok, reason = claim(state, p, 1, "S2")
			expect(ok).toBe(false)
			expect(reason).toBe("SlotAlreadyDeployed")
		end)
		it("enforces the team cap of four", function()
			local state = deployState()
			local a, b, c = playerView(1), playerView(2), playerView(3)
			claim(state, a, 1, "S1")
			claim(state, a, 2, "S2")
			claim(state, b, 1, "S3")
			claim(state, b, 2, "S4")
			local ok, reason = claim(state, c, 1, "S5")
			expect(ok).toBe(false)
			expect(reason).toBe("TeamCap")
		end)
		it("blocks out-of-range, downed, wrong phase and non-roster players", function()
			local state, p = deployState(), playerView(1)
			p.distanceToSocket = 50
			expect(select(2, DeployRules.canDeploy(state, p, 1, "S1"))).toBe("OutOfRange")
			p.distanceToSocket = 3
			p.active = false
			expect(select(2, DeployRules.canDeploy(state, p, 1, "S1"))).toBe("NotActive")
			p.active = true
			state.phase = "Prep"
			expect(select(2, DeployRules.canDeploy(state, p, 1, "S1"))).toBe("WrongPhase")
			state.phase = "Explore"
			p.inRoster = false
			expect(select(2, DeployRules.canDeploy(state, p, 1, "S1"))).toBe("NotInRun")
			p.inRoster = true
			expect(select(2, DeployRules.canDeploy(state, p, 3, "S1"))).toBe("InvalidSlot")
			expect(select(2, DeployRules.canDeploy(state, p, 1, "NOPE"))).toBe("UnknownSocket")
		end)
		it("refuses to recall an occupied room and explains why", function()
			local state, p = deployState(), playerView(1)
			claim(state, p, 1, "S1")
			local ok, reason = DeployRules.canRecall(state, p, 1, 1)
			expect(ok).toBe(false)
			expect(reason).toBe("Occupied")
			expect(DeployRules.canRecall(state, p, 1, 0)).toBe(true)
			expect(select(2, DeployRules.canRecall(state, p, 2, 0))).toBe("NotDeployed")
		end)
	end)

	describe("RunMachine (S02)", function()
		it("follows the full loop and always returns to Prep", function()
			local m = RunMachine.new(0)
			expect(m:transition("Explore", 1)).toBe(false)
			expect(m:transition("Launching", 1)).toBe(true)
			expect(m:transition("Explore", 2)).toBe(true)
			expect(m:inRun()).toBe(true)
			expect(m:transition("Capture", 3)).toBe(true)
			expect(m:transition("Escape", 4)).toBe(true)
			expect(m:transition("Results", 5, "Success")).toBe(true)
			expect(m.outcome).toBe("Success")
			expect(m:transition("Explore", 6)).toBe(false)
			expect(m:transition("Prep", 6)).toBe(true)
			expect(m.outcome).toBe(nil)
			expect(m:inRun()).toBe(false)
		end)
		it("allows failure exits from every in-run phase", function()
			for _, phase in { "Launching", "Explore", "Capture", "Escape" } do
				expect(RunMachine.allowed(phase, "Results")).toBe(true)
			end
			expect(RunMachine.allowed("Prep", "Results")).toBe(false)
		end)
	end)

	describe("HealthModel (S16)", function()
		local cfg = HealthModel.configFrom(GameConfig)
		it("applies damage grace", function()
			local s = HealthModel.new(cfg, false, 0)
			expect(HealthModel.damage(cfg, s, 1, 1)).toBe("Hurt")
			expect(HealthModel.damage(cfg, s, 1, 1 + cfg.DamageGraceSeconds - 0.01)).toBe("Ignored")
			expect(s.hearts).toBe(2)
			expect(HealthModel.damage(cfg, s, 1, 1 + cfg.DamageGraceSeconds + 0.01)).toBe("Hurt")
			expect(s.hearts).toBe(1)
		end)
		it("downs at zero hearts, can be revived, and expires into elimination", function()
			local s = HealthModel.new(cfg, false, 0)
			s.hearts = 1
			expect(HealthModel.damage(cfg, s, 1, 10)).toBe("Downed")
			expect(s.status).toBe("Downed")
			expect(HealthModel.revive(cfg, s, 12)).toBe(true)
			expect(s.status).toBe("Active")
			expect(s.hearts).toBe(cfg.ReviveHearts)
			s.hearts = 1
			HealthModel.damage(cfg, s, 1, 20)
			local events = HealthModel.update(cfg, s, 20 + cfg.DownedWindowSeconds + 0.01)
			expect(events[1]).toBe("Eliminated")
			expect(HealthModel.revive(cfg, s, 50)).toBe(false)
		end)
		it("gives solo players exactly one self-recovery", function()
			local s = HealthModel.new(cfg, true, 0)
			s.hearts = 1
			expect(HealthModel.damage(cfg, s, 1, 5)).toBe("Recovering")
			expect(HealthModel.isTeamWiped({ s })).toBe(false)
			local events = HealthModel.update(cfg, s, 5 + cfg.SoloRecoveryDelaySeconds + 0.01)
			expect(events[1]).toBe("SelfRecovered")
			expect(s.hearts).toBe(cfg.SelfRecoveryHearts)
			s.hearts = 1
			expect(HealthModel.damage(cfg, s, 1, 100)).toBe("Downed")
			expect(HealthModel.isTeamWiped({ s })).toBe(true)
		end)
		it("only counts downed players as recoverable while a teammate is active", function()
			local a, b = HealthModel.new(cfg, false, 0), HealthModel.new(cfg, false, 0)
			a.hearts = 1
			HealthModel.damage(cfg, a, 1, 1)
			expect(HealthModel.isTeamWiped({ a, b })).toBe(false)
			b.hearts = 1
			HealthModel.damage(cfg, b, 1, 2)
			expect(HealthModel.isTeamWiped({ a, b })).toBe(true)
		end)
		it("regenerates hearts after a quiet period", function()
			local s = HealthModel.new(cfg, false, 0)
			HealthModel.damage(cfg, s, 1, 1)
			expect(#HealthModel.update(cfg, s, 1 + cfg.RegenDelaySeconds - 0.1)).toBe(0)
			expect(HealthModel.update(cfg, s, 1 + cfg.RegenDelaySeconds + 0.1)[1]).toBe("Regen")
			expect(s.hearts).toBe(3)
		end)
	end)

	local function content()
		return {
			isRoomKnown = function(id)
				return Rooms.byId[id] ~= nil
			end,
			isRoomEnabled = function()
				return true
			end,
			starterRooms = { "Freezer", "Fan" },
			defaultSkins = Skins.defaultForRoom,
			defaultSuitcase = Skins.defaultSuitcase,
			skinTarget = function(id)
				local skin = Skins.byId[id]
				if not skin then
					return nil
				end
				return if skin.kind == "suitcase" then "suitcase" else skin.room
			end,
		}
	end

	describe("ProfileSchema (S21)", function()
		it("creates a valid default profile", function()
			local p = ProfileSchema.default(100, { "Freezer", "Fan" }, Skins.defaultForRoom, Skins.defaultSuitcase)
			expect(p.rooms.Freezer).toBe(true)
			expect(p.rooms.Laundry).toBe(nil)
			expect(p.loadout).toEqual({ "Freezer", "Fan" })
			expect(p.skins.equipped.Freezer).toBe("freezer_classic")
			expect(p.skins.equipped.suitcase).toBe("case_leather")
		end)
		it("migrates v1 data and repairs bad loadouts without losing progress", function()
			local old = {
				schema = 1,
				ownedRooms = { "Freezer", "Fan", "Laundry" },
				credits = 55,
				loadout = { "Laundry", "Laundry", "Magnet" },
			}
			local migrated = ProfileSchema.migrate(old)
			expect(migrated.schema).toBe(ProfileSchema.CURRENT)
			local template = ProfileSchema.default(0, { "Freezer", "Fan" }, Skins.defaultForRoom, Skins.defaultSuitcase)
			local clean = ProfileSchema.sanitize(migrated, template, content())
			expect(clean.rooms.Laundry).toBe(true)
			expect(clean.credits).toBe(55)
			expect(clean.loadout[1]).toBe("Laundry")
			expect(clean.loadout[2]).toBe("Freezer")
			expect(#clean.loadout).toBe(2)
		end)
		it("migrates the v3 onboarding high-water mark to per-step bits", function()
			local old = ProfileSchema.default(0, { "Freezer", "Fan" }, Skins.defaultForRoom, Skins.defaultSuitcase)
			old.schema = 3
			old.flags.onboardingSteps = nil
			(old.flags :: any).onboardingFunnel = 3
			local migrated = ProfileSchema.migrate(old)
			expect(migrated.schema).toBe(ProfileSchema.CURRENT)
			expect(migrated.flags.onboardingSteps).toBe(7) -- steps 1, 2 and 3
			expect(migrated.flags.onboardingFunnel).toBe(nil)
		end)
		it("adds empty mission mastery to v4 data and keeps only id = true entries", function()
			local old = ProfileSchema.default(0, { "Freezer", "Fan" }, Skins.defaultForRoom, Skins.defaultSuitcase)
			old.schema = 4
			old.stats.challengesDone = nil :: any
			old.stats.allKeys = nil :: any
			old.stats.cleared.M1 = 3
			local migrated = ProfileSchema.migrate(old)
			expect(migrated.schema).toBe(5)
			expect(next(migrated.stats.challengesDone)).toBe(nil)
			expect(next(migrated.stats.allKeys)).toBe(nil)
			expect(migrated.stats.cleared.M1).toBe(3)
			migrated.stats.challengesDone = { M1_douse = true, junk = 5, [7] = true } :: any
			local clean = ProfileSchema.sanitize(
				migrated,
				ProfileSchema.default(0, { "Freezer", "Fan" }, Skins.defaultForRoom, Skins.defaultSuitcase),
				content()
			)
			expect(clean.stats.challengesDone.M1_douse).toBe(true)
			expect((clean.stats.challengesDone :: any).junk).toBe(nil)
			expect((clean.stats.challengesDone :: any)[7]).toBe(nil)
		end)
		it("refuses data written by a newer schema", function()
			expect(ProfileSchema.migrate({ schema = 99 })).toBe(nil)
		end)
		it("fixes equipped skins that are not owned", function()
			local p = ProfileSchema.default(0, { "Freezer", "Fan" }, Skins.defaultForRoom, Skins.defaultSuitcase)
			p.skins.equipped.Freezer = "freezer_aurora"
			p.skins.equipped.suitcase = "fan_retro"
			local clean = ProfileSchema.sanitize(
				p,
				ProfileSchema.default(0, { "Freezer", "Fan" }, Skins.defaultForRoom, Skins.defaultSuitcase),
				content()
			)
			expect(clean.skins.equipped.Freezer).toBe("freezer_classic")
			expect(clean.skins.equipped.suitcase).toBe("case_leather")
		end)
		it("cleans client settings", function()
			local base = ProfileSchema.defaultSettings()
			local out = ProfileSchema.cleanSettings({ music = 5, hints = false, evil = "x", sfx = 0 / 0 }, base)
			expect(out.music).toBe(1)
			expect(out.hints).toBe(false)
			expect(out.evil).toBe(nil)
			expect(out.sfx).toBe(base.sfx)
		end)
	end)

	describe("RewardRules (S14/S22/S23/R12)", function()
		local cfg = GameConfig.Rewards
		local function profile()
			return ProfileSchema.default(0, { "Freezer", "Fan" }, Skins.defaultForRoom, Skins.defaultSuitcase)
		end
		local function summary(runId, success)
			return {
				runId = runId,
				missionId = "M1",
				success = success,
				timeLeft = 50,
				keysCollected = 2,
				keysTotal = 3,
				anyDowns = false,
				combos = { extinguish = true },
				durationSeconds = 300,
			}
		end
		it("grants the blueprint first, then the targeted skin, then duplicate credits", function()
			local p = profile()
			local mission = Missions.byId.M1
			local plan = RewardRules.compute(p, mission, summary("r1", true), cfg)
			expect(plan.blueprint).toBe("Laundry")
			expect(RewardRules.apply(p, plan, summary("r1", true), 1, 64)).toBe(true)
			expect(p.rooms.Laundry).toBe(true)
			local plan2 = RewardRules.compute(p, mission, summary("r2", true), cfg)
			expect(plan2.skin).toBe("laundry_royal")
			RewardRules.apply(p, plan2, summary("r2", true), 2, 64)
			local plan3 = RewardRules.compute(p, mission, summary("r3", true), cfg)
			expect(plan3.duplicate).toBe(true)
			expect(plan3.blueprint).toBe(nil)
			expect(plan3.skin).toBe(nil)
		end)
		it("never rewards a failed run", function()
			expect(RewardRules.compute(profile(), Missions.byId.M1, summary("r1", false), cfg)).toBe(nil)
		end)
		it("never grants the same run twice", function()
			local p = profile()
			local s = summary("dup", true)
			local plan = RewardRules.compute(p, Missions.byId.M1, s, cfg)
			expect(RewardRules.apply(p, plan, s, 1, 64)).toBe(true)
			local credits = p.credits
			expect(RewardRules.apply(p, plan, s, 2, 64)).toBe(false)
			expect(p.credits).toBe(credits)
			expect(p.stats.extractions).toBe(1)
		end)
		it("pays challenges, keys and first clear", function()
			local p = profile()
			local plan = RewardRules.compute(p, Missions.byId.M1, summary("r", true), cfg)
			expect(plan.challenges.M1_douse).toBe(true)
			expect(plan.challenges.M1_keys).toBe(nil)
			expect(plan.firstClear).toBe(true)
			expect(plan.credits).toBe(cfg.ExtractionCredits + 2 * cfg.KeyCredits + cfg.FirstClearBonusCredits + 25)
		end)
		it("records mission mastery: challenges stay done, all keys in one run", function()
			local p = profile()
			local s = summary("m1", true)
			RewardRules.apply(p, RewardRules.compute(p, Missions.byId.M1, s, cfg) :: any, s, 1, 64)
			expect(p.stats.challengesDone.M1_douse).toBe(true)
			expect(p.stats.allKeys.M1).toBe(nil) -- two keys of three
			local all = summary("m2", true)
			all.keysCollected = 3
			all.combos = {}
			RewardRules.apply(p, RewardRules.compute(p, Missions.byId.M1, all, cfg) :: any, all, 2, 64)
			expect(p.stats.allKeys.M1).toBe(true)
			expect(p.stats.challengesDone.M1_douse).toBe(true) -- not undone by a run that missed it
		end)
		it("previews the reward before starting", function()
			local p = profile()
			expect(RewardRules.preview(p, Missions.byId.M1, cfg).kind).toBe("blueprint")
			p.rooms.Laundry = true
			expect(RewardRules.preview(p, Missions.byId.M1, cfg).item).toBe("laundry_royal")
		end)
	end)

	describe("NavGraph", function()
		it("finds shortest paths and re-plans around disabled edges", function()
			local g = NavGraph.new()
			g:addNode("a", V3.new(0, 0, 0))
			g:addNode("b", V3.new(10, 0, 0))
			g:addNode("c", V3.new(20, 0, 0))
			g:addNode("d", V3.new(10, 0, 10))
			g:addEdge("a", "b")
			g:addEdge("b", "c")
			g:addEdge("a", "d")
			g:addEdge("d", "c")
			expect(g:path("a", "c")).toEqual({ "a", "b", "c" })
			g:setEdgeEnabled("a", "b", false)
			expect(g:path("a", "c")).toEqual({ "a", "d", "c" })
			g:setNodeEnabled("d", false)
			expect(g:path("a", "c")).toBe(nil)
			expect(g:nearest(V3.new(19, 0, 1))).toBe("c")
		end)
	end)

	describe("Net schema validation (S20)", function()
		it("rejects malformed payloads", function()
			expect(Net.validate({ "string", "integer", "string?" }, "S1", 1)).toBe(true)
			expect(Net.validate({ "string", "integer", "string?" }, "S1", 1.5)).toBe(false)
			expect(Net.validate({ "string", "integer" }, "S1", 1, "extra")).toBe(false)
			expect(Net.validate({ "string" }, string.rep("x", 65))).toBe(false)
			expect(Net.validate({ "number" }, 0 / 0)).toBe(false)
			expect(Net.validate({ "number" }, math.huge)).toBe(false)
			expect(Net.validate({ "Vector3" }, V3.new(1, 2, 3))).toBe(true)
			expect(Net.validate({ "Vector3" }, V3.new(0 / 0, 0, 0))).toBe(false)
			expect(Net.validate({ "boolean" }, "true")).toBe(false)
			expect(Net.validate({ "table" }, {})).toBe(true)
			expect(Net.validate({}, nil)).toBe(true)
		end)
	end)
end
