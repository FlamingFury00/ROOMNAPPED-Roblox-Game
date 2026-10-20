return function(ctx)
	local Spec = ctx.Spec
	local describe, it, expect = Spec.describe, Spec.it, Spec.expect

	local Signal = ctx.module("ReplicatedStorage.Shared.Util.Signal")
	local Trove = ctx.module("ReplicatedStorage.Shared.Util.Trove")
	local RateLimiter = ctx.module("ReplicatedStorage.Shared.Util.RateLimiter")
	local Tables = ctx.module("ReplicatedStorage.Shared.Util.Tables")
	local MathUtil = ctx.module("ReplicatedStorage.Shared.Util.MathUtil")

	describe("Signal", function()
		it("fires listeners with arguments", function()
			local s = Signal.new()
			local got = {}
			s:Connect(function(a, b)
				table.insert(got, a + b)
			end)
			s:Fire(2, 3)
			expect(got[1]).toBe(5)
		end)
		it("disconnects and once", function()
			local s = Signal.new()
			local count = 0
			local c = s:Connect(function()
				count += 1
			end)
			s:Once(function()
				count += 10
			end)
			s:Fire()
			s:Fire()
			c:Disconnect()
			s:Fire()
			expect(count).toBe(12)
			expect(c.Connected).toBe(false)
		end)
		it("tolerates disconnect during dispatch", function()
			local s = Signal.new()
			local count = 0
			local c1
			c1 = s:Connect(function()
				c1:Disconnect()
				count += 1
			end)
			s:Connect(function()
				count += 1
			end)
			s:Fire()
			s:Fire()
			expect(count).toBe(3)
		end)
	end)

	describe("Trove", function()
		it("cleans functions, connections and nested troves in reverse order", function()
			local order = {}
			local t = Trove.new()
			t:Add(function()
				table.insert(order, "a")
			end)
			local child = t:Extend()
			child:Add(function()
				table.insert(order, "child")
			end)
			t:Add(function()
				table.insert(order, "b")
			end)
			local s = Signal.new()
			local hits = 0
			t:Connect(s, function()
				hits += 1
			end)
			s:Fire()
			t:Clean()
			s:Fire()
			expect(hits).toBe(1)
			expect(order).toEqual({ "b", "child", "a" })
		end)
		it("destroys instances", function()
			local t = Trove.new()
			local folder = ctx.roblox.Instance.new("Folder")
			local part = ctx.roblox.Instance.new("Part")
			part.Parent = folder
			t:Add(part)
			t:Clean()
			expect(#folder:GetChildren()).toBe(0)
		end)
	end)

	describe("RateLimiter", function()
		it("allows a burst then refills over time", function()
			local now = 0
			local rl = RateLimiter.new(3, 1, function()
				return now
			end)
			expect(rl:Allow("p")).toBe(true)
			expect(rl:Allow("p")).toBe(true)
			expect(rl:Allow("p")).toBe(true)
			expect(rl:Allow("p")).toBe(false)
			now = 1.01
			expect(rl:Allow("p")).toBe(true)
			expect(rl:Allow("p")).toBe(false)
			expect(rl:Allow("other")).toBe(true)
		end)
	end)

	describe("Tables", function()
		it("reconciles defaults without clobbering values", function()
			local data = { credits = 5, settings = { music = 0.2 }, bad = "x" }
			Tables.reconcile(data, { credits = 0, settings = { music = 1, sfx = 1 }, bad = 3, owned = { a = true } })
			expect(data.credits).toBe(5)
			expect(data.settings.music).toBe(0.2)
			expect(data.settings.sfx).toBe(1)
			expect(data.bad).toBe(3)
			expect(data.owned.a).toBe(true)
		end)
		it("deep copies", function()
			local a = { x = { y = 1 } }
			local b = Tables.deepCopy(a)
			b.x.y = 2
			expect(a.x.y).toBe(1)
		end)
	end)

	describe("MathUtil", function()
		it("tests oriented boxes", function()
			local V3, CF = ctx.roblox.Vector3, ctx.roblox.CFrame
			local cf = CF.new(10, 0, 0) * CF.Angles(0, math.pi / 2, 0)
			expect(MathUtil.pointInBox(cf, V3.new(2, 2, 10), V3.new(14, 0, 0))).toBe(true)
			expect(MathUtil.pointInBox(cf, V3.new(2, 2, 10), V3.new(10, 0, 3))).toBe(false)
		end)
		it("produces deterministic random sequences", function()
			local a, b = MathUtil.rng(42), MathUtil.rng(42)
			for _ = 1, 10 do
				expect(a()).toBe(b())
			end
			local r = MathUtil.rng(7)()
			expect(r >= 0 and r < 1).toBe(true)
		end)
		it("hashes strings stably", function()
			expect(MathUtil.hash("B1")).toBe(MathUtil.hash("B1"))
			expect(MathUtil.hash("B1") ~= MathUtil.hash("B2")).toBe(true)
		end)
	end)
end
