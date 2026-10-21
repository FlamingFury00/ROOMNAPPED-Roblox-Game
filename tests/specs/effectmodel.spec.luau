return function(ctx)
	local Spec = ctx.Spec
	local describe, it, expect = Spec.describe, Spec.it, Spec.expect
	local EffectModel = ctx.module("ReplicatedStorage.Shared.Logic.EffectModel")
	local GameConfig = ctx.module("ReplicatedStorage.Shared.Config.GameConfig")
	local T = GameConfig.Effects

	local function defs()
		return {
			basins = {
				B1 = { id = "B1", baseWet = true, deep = true },
				B2 = { id = "B2", baseWet = false, deep = true },
				P1 = { id = "P1", baseWet = true, deep = false, power = "PW1" },
				F1pool = { id = "F1pool", baseWet = false, deep = false },
			},
			fires = { F1 = { id = "F1", pools = { "F1pool" } } },
			vines = { V1 = { id = "V1", waterBasin = "B2" } },
			powers = { PW1 = { id = "PW1", default = true, levers = { "L1" } } },
			gates = { G1 = { id = "G1", signals = { "float:B2" } } },
			links = {
				S1 = { cold = { "B1", "B2", "P1" }, water = "B2" },
				S2 = { water = "B2", cold = { "V1" } },
				S3 = { water = "F1pool" },
				S4 = { vine = "V1" },
				S5 = { water = "V1" },
			},
		}
	end

	local function run(model, seconds)
		local steps = math.ceil(seconds / 0.05)
		for _ = 1, steps do
			model:step(0.05)
		end
	end

	describe("EffectModel basins", function()
		it("freezes a flooded basin into solid ice and melts it back", function()
			local m = EffectModel.new(defs(), T)
			expect(m:basinPhase("B1")).toBe("Water")
			expect(m:basinSolid("B1")).toBe(false)
			m:setSources({ S1 = "cold" })
			run(m, T.FreezeSeconds + 0.1)
			expect(m:basinPhase("B1")).toBe("Ice")
			expect(m:basinSolid("B1")).toBe(true)
			m:setSources({})
			run(m, T.IceExitGraceSeconds + T.MeltSeconds + 0.2)
			expect(m:basinPhase("B1")).toBe("Water")
			expect(m:basinSolid("B1")).toBe(false)
		end)

		it("holds ice while occupied after the freezer is recalled (R07 safe exit)", function()
			local m = EffectModel.new(defs(), T)
			m:setSources({ S1 = "cold" })
			run(m, 1)
			m:setOccupied("B1", true)
			m:setSources({})
			run(m, 10)
			expect(m:basinPhase("B1")).toBe("Thawing")
			expect(m:basinSolid("B1")).toBe(true)
			m:setOccupied("B1", false)
			run(m, T.IceExitGraceSeconds * 0.5)
			expect(m:basinSolid("B1")).toBe(true)
			-- Stepping back on during the melt re-arms the hold.
			run(m, T.IceExitGraceSeconds + 0.2)
			expect(m:basinPhase("B1")).toBe("Melting")
			m:setOccupied("B1", true)
			m:step(0.05)
			expect(m:basinPhase("B1")).toBe("Thawing")
			expect(m:basinSolid("B1")).toBe(true)
		end)

		it("cold on a dry basin does nothing; water + cold bridges it", function()
			local m = EffectModel.new(defs(), T)
			m:setSources({ S2 = "cold" }) -- S2 cold links only V1
			run(m, 3)
			expect(m:basinPhase("B2")).toBe("Dry")
			m:setSources({ S1 = "cold" })
			run(m, 3)
			expect(m:basinPhase("B2")).toBe("Dry")
			m:setSources({ S1 = "cold", S2 = "water" })
			run(m, T.FillSeconds + T.FreezeSeconds + 0.3)
			expect(m:basinPhase("B2")).toBe("Ice")
			expect(m:basinSolid("B2")).toBe(true)
		end)

		it("is order independent for any deploy/recall order with the same final set (R07/R13)", function()
			local ops = {
				{ "S1", "cold" },
				{ "S2", "water" },
				{ "S3", "water" },
				{ "S4", "vine" },
			}
			local function permutations(list)
				local out = {}
				local function permute(arr, n)
					if n == 1 then
						table.insert(out, table.clone(arr))
						return
					end
					for i = 1, n do
						arr[i], arr[n] = arr[n], arr[i]
						permute(arr, n - 1)
						arr[i], arr[n] = arr[n], arr[i]
					end
				end
				permute(table.clone(list), #list)
				return out
			end
			local reference = nil
			for _, order in permutations(ops) do
				local m = EffectModel.new(defs(), T)
				local active = {}
				for _, op in order do
					active[op[1]] = op[2]
					m:setSources(active)
					run(m, 0.35) -- deliberately interrupt transitions mid-way
				end
				-- Recall and redeploy the freezer mid-stream to stress cleanup.
				active.S1 = nil
				m:setSources(active)
				run(m, 0.2)
				active.S1 = "cold"
				m:setSources(active)
				run(m, 20)
				local result = {}
				for _, id in m:allZoneIds() do
					local s = m:snapshotZone(id)
					result[id] = (s.phase or "") .. "|" .. tostring(s.open) .. "|" .. tostring(s.electrified)
				end
				if reference == nil then
					reference = result
				else
					expect(result).toEqual(reference)
				end
			end
			expect(reference.B2).toBe("Ice|nil|false")
			expect(reference.F1).toBe("Out|nil|nil")
		end)
	end)

	describe("EffectModel fire", function()
		it("water puts fire out and re-ignition shows a warning first (R09)", function()
			local m = EffectModel.new(defs(), T)
			expect(m:fireLit("F1")).toBe(true)
			m:setSources({ S3 = "water" })
			run(m, T.FillSeconds + 0.1)
			expect(m:firePhase("F1")).toBe("Out")
			m:setSources({})
			run(m, T.DrainSeconds * 0.5 + 0.1)
			-- Pool has drained below half: the fire warns before it burns.
			expect(m:firePhase("F1")).toBe("Warning")
			expect(m:fireLit("F1")).toBe(false)
			run(m, T.FireWarningSeconds + T.DrainSeconds)
			expect(m:firePhase("F1")).toBe("Burning")
		end)
	end)

	describe("EffectModel electricity", function()
		it("powered water is electrified, frozen water is safe and the lever cuts power (R10)", function()
			local m = EffectModel.new(defs(), T)
			m:step(0.05)
			expect(m:basinElectrified("P1")).toBe(true)
			m:setSources({ S1 = "cold" })
			run(m, T.FreezeSeconds + 0.1)
			expect(m:basinElectrified("P1")).toBe(false)
			m:setSources({})
			run(m, T.IceExitGraceSeconds + T.MeltSeconds + 0.2)
			expect(m:basinElectrified("P1")).toBe(true)
			m:setLever("L1", true)
			m:step(0.05)
			expect(m:powerOn("PW1")).toBe(false)
			expect(m:basinElectrified("P1")).toBe(false)
		end)
	end)

	describe("EffectModel vines and gates", function()
		it("vines need a greenhouse and water; cold pauses; retraction waits for occupants (R04)", function()
			local m = EffectModel.new(defs(), T)
			m:setSources({ S4 = "vine" })
			run(m, T.VineGrowSeconds + 1)
			expect(m:vineProgress("V1")).toBe(0)
			m:setSources({ S4 = "vine", S5 = "water" })
			run(m, T.VineGrowSeconds * 0.5)
			local half = m:vineProgress("V1")
			expect(half > 0.3 and half < 0.7).toBe(true)
			m:setSources({ S4 = "vine", S5 = "water", S2 = "cold" })
			run(m, 2)
			expect(m:vineProgress("V1")).toBeNear(half, 0.02)
			m:setSources({ S4 = "vine", S5 = "water" })
			run(m, T.VineGrowSeconds)
			expect(m:vineSolid("V1")).toBe(true)
			m:setOccupied("V1", true)
			m:setSources({})
			run(m, 5)
			expect(m:vineSolid("V1")).toBe(true)
			m:setOccupied("V1", false)
			run(m, T.VineRetractSeconds + 0.2)
			expect(m:vineProgress("V1")).toBe(0)
		end)

		it("a vine fed by a frozen basin goes dormant instead of growing", function()
			local m = EffectModel.new(defs(), T)
			-- B2 floods (S2 Laundry), then S1 freezes it; the Greenhouse at S4 would grow V1 from B2's water.
			m:setSources({ S2 = "water" })
			run(m, T.FillSeconds + 0.5)
			m:setSources({ S1 = "cold", S2 = "water", S4 = "vine" })
			run(m, T.FreezeSeconds + 0.5)
			expect(m:basinSolid("B2")).toBe(true)
			-- It drank while the water was still freezing; once the basin is solid it neither grows nor drops.
			local frozenAt = m:vineProgress("V1")
			expect(frozenAt < 1).toBe(true)
			run(m, T.VineGrowSeconds + 0.5)
			expect(m:vineProgress("V1")).toBe(frozenAt)
			expect(m:vineSolid("V1")).toBe(false)
		end)

		it("reports a gate change exactly when it becomes passable and when it blocks again", function()
			local m = EffectModel.new(defs(), T)
			local wasOpen = m:gateOpen("G1")
			local flips, reported = 0, 0
			local function watch(seconds)
				for _ = 1, math.ceil(seconds / 0.05) do
					local changed = m:step(0.05)
					local open = m:gateOpen("G1")
					if open ~= wasOpen then
						flips += 1
						if table.find(changed, "G1") then
							reported += 1
						end
						wasOpen = open
					end
				end
			end
			m:setSources({ S2 = "water" })
			watch(T.FillSeconds + 1.2)
			m:setSources({})
			watch(T.DrainSeconds + 2)
			expect(flips).toBe(2)
			expect(reported).toBe(2)
		end)

		it("float gates open with water and never close on a player", function()
			local m = EffectModel.new(defs(), T)
			m:setSources({ S2 = "water" })
			run(m, T.FillSeconds + 1.2)
			expect(m:gateOpen("G1")).toBe(true)
			m:setOccupied("G1", true)
			m:setSources({})
			run(m, T.DrainSeconds + 2)
			expect(m:gateOpen("G1")).toBe(true)
			m:setOccupied("G1", false)
			run(m, 1.2)
			expect(m:gateOpen("G1")).toBe(false)
		end)
	end)
end
