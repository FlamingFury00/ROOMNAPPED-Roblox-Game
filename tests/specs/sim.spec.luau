--[[
	End-to-end server simulations: the shipped server runs inside the headless engine (tests/harness/Sim)
	with scripted bots playing real expeditions through the real remotes.
]]
local Sim = require("../harness/Sim")

return function(ctx)
	local Spec = ctx.Spec
	local describe, it, expect = Spec.describe, Spec.it, Spec.expect
	local V3 = ctx.roblox.Vector3

	local function boot()
		local sim = Sim.new(ctx.placePath)
		sim:startServer()
		sim:run(0.3)
		return sim
	end

	local function assertClean(sim)
		if #sim.errors > 0 then
			error("simulation errors:\n" .. table.concat(sim.errors, "\n----\n"))
		end
	end

	local function phase(sim, bot)
		return sim:state(bot, "global", "run.phase")
	end

	local function near(sim, bot, point, radius)
		return function()
			local p = sim:position(bot)
			return p ~= nil and V3.new(p.X - point.X, 0, p.Z - point.Z).Magnitude <= (radius or 1.5)
		end
	end

	local function tileIndexAt(level, position)
		local best, bestDistance = 1, math.huge
		for i, tile in level.tiles do
			local d = (tile.cf.Position - position).Magnitude
			if d < bestDistance then
				best, bestDistance = i, d
			end
		end
		return best
	end

	-- Waypoints along tile centres from the bot's current tile to tile `toIndex` (raised to root height).
	local function route(sim, bot, level, toIndex)
		local from = tileIndexAt(level, sim:position(bot))
		local points = {}
		local step = if toIndex >= from then 1 else -1
		for i = from, toIndex, step do
			table.insert(points, level.tiles[i].cf.Position + V3.new(0, 3, 0))
		end
		return points
	end

	local function joinAndLaunch(sim, names)
		local bots = {}
		for i, name in names do
			local bot = sim:addBot(name, 1000 + i)
			sim:snapshot(bot)
			table.insert(bots, bot)
		end
		sim:run(0.6)
		for _, bot in bots do
			expect(sim:state(bot, "me", "profile.status")).toBe("Ready")
			sim:send(bot, "ClientReady", "keyboard", "en-us")
			sim:send(bot, "SetReady", true)
		end
		local launched = sim:runUntil(function()
			return phase(sim, bots[1]) == "Explore"
		end, 30)
		assertClean(sim)
		expect(launched).toBe(true)
		return bots
	end

	describe("Simulated expedition (S02/S12/S13/S14/S22/S24)", function()
		it("completes the tutorial solo: deploy Freezer, cross the ice, capture, escape, bank and save", function()
			local sim = boot()
			local bot = joinAndLaunch(sim, { "Alice" })[1]
			-- Baseline: lobby + this player's character, before the level existed.
			local baseline = sim:instanceCount() - #sim.workspace.Expedition:GetDescendants() - 1
			local level = sim:state(bot, "global", "level")
			expect(level.layoutId).toBe("L0")
			expect(sim:state(bot, "global", "run.tutorial")).toBe(true)

			-- Walk to the Freezer socket and unfold it.
			local s1 = level.sockets.S1.interactPoint
			local socketTile = tileIndexAt(level, s1)
			local path = route(sim, bot, level, socketTile)
			table.insert(path, s1)
			sim:walk(bot, path)
			expect(sim:runUntil(near(sim, bot, s1), 15)).toBe(true)
			sim:send(bot, "SelectSlot", 1)
			sim:send(bot, "RequestDeploy", "S1", 1)
			sim:run(0.3)
			assertClean(sim)
			expect(sim:state(bot, "global", "sockets.S1.room")).toBe("Freezer")
			sim:run(1.5)
			expect(sim:state(bot, "global", "zones.B1.phase")).toBe("Ice")

			-- Cross the frozen basin to the target room.
			local target = level.target.capturePoint
			local targetTile = tileIndexAt(level, target)
			local toTarget = route(sim, bot, level, targetTile)
			table.insert(toTarget, target)
			sim:walk(bot, toTarget)
			expect(sim:runUntil(near(sim, bot, target), 25)).toBe(true)
			expect(sim:state(bot, "global", "roster.1001.hearts")).toBe(3)
			expect(sim:state(bot, "global", "run.combos") ~= nil).toBe(true)

			-- Capture with a server-verified hold.
			sim:send(bot, "HoldBegin", "capture", "target")
			sim:run(3.05)
			sim:send(bot, "HoldEnd", "capture", "target", true)
			sim:run(0.2)
			assertClean(sim)
			expect(phase(sim, bot)).toBe("Capture")
			expect(sim:state(bot, "global", "cargo.state")).toBe("Carried")
			expect(sim:state(bot, "global", "cargo.carrier")).toBe("1001")
			expect(sim:runUntil(function()
				return phase(sim, bot) == "Escape"
			end, 4)).toBe(true)
			expect(sim:state(bot, "global", "run.escapeEndsAt") ~= nil).toBe(true)

			-- Run back to the extraction elevator.
			local back = route(sim, bot, level, 1)
			table.insert(back, level.exit.cf.Position)
			sim:walk(bot, back)
			expect(sim:runUntil(function()
				return phase(sim, bot) == "Results"
			end, 40)).toBe(true)
			assertClean(sim)
			expect(sim:state(bot, "global", "run.outcome")).toBe("Success")
			expect(sim:runUntil(function()
				return sim:state(bot, "me", "results.saving") == "Saved"
			end, 10)).toBe(true)
			expect(sim:state(bot, "me", "profile.rooms.Laundry")).toBe(true)
			expect(sim:state(bot, "me", "profile.tutorialDone")).toBe(true)
			expect(sim:state(bot, "me", "results.plan.blueprint")).toBe("Laundry")
			local credits = sim:state(bot, "me", "profile.credits")
			expect(credits > 0).toBe(true)

			-- Back to a clean Prep.
			sim:send(bot, "ResultsAction", "lobby")
			expect(sim:runUntil(function()
				return phase(sim, bot) == "Prep"
			end, 40)).toBe(true)
			sim:run(1)
			assertClean(sim)
			expect(sim:state(bot, "global", "level")).toBe(nil)
			-- No instance growth once the level is gone (S27).
			expect(sim:instanceCount() <= baseline + 5).toBe(true)
		end)

		it("fails safely when the caretaker catches a solo player who stands still (S16)", function()
			local sim = boot()
			local bot = joinAndLaunch(sim, { "Bob" })[1]
			local level = sim:state(bot, "global", "level")
			local creditsBefore = sim:state(bot, "me", "profile.credits")
			-- Reach the target via the ledge-free route: debug-teleport straight to the target.
			sim:send(bot, "Debug", "tp", "target")
			sim:run(0.3)
			sim:send(bot, "HoldBegin", "capture", "target")
			sim:run(3.05)
			sim:send(bot, "HoldEnd", "capture", "target", true)
			sim:run(0.3)
			expect(phase(sim, bot)).toBe("Capture")
			-- Stand still and let the escape window expire or the caretaker win.
			expect(sim:runUntil(function()
				return phase(sim, bot) == "Results"
			end, 140)).toBe(true)
			assertClean(sim)
			local outcome = sim:state(bot, "global", "run.outcome")
			expect(outcome == "Wiped" or outcome == "TimeUp").toBe(true)
			sim:run(3)
			expect(sim:state(bot, "me", "results.plan")).toBe(nil)
			expect(sim:state(bot, "me", "profile.rooms.Laundry")).toBe(nil)
			expect(sim:state(bot, "me", "profile.credits")).toBe(creditsBefore)
			local _ = level
		end)

		it("rejects spoofed or invalid requests without breaking the run (S20)", function()
			local sim = boot()
			local bot = joinAndLaunch(sim, { "Cara" })[1]
			-- Deploy from the elevator, far from S1.
			sim:send(bot, "RequestDeploy", "S1", 1)
			sim:run(0.2)
			expect(sim:state(bot, "global", "sockets.S1")).toBe(nil)
			expect(sim:inboxHas(bot, "Toast", "deploy.reason.OutOfRange")).toBe(true)
			-- Malformed payloads are dropped by the schema.
			sim:send(bot, "RequestDeploy", 42, "x")
			sim:send(bot, "RequestDeploy", "S1", 1.5)
			sim:send(bot, "HoldBegin", "capture")
			-- Capture from far away is rejected; an early HoldEnd never captures.
			sim:send(bot, "HoldBegin", "capture", "target")
			sim:run(0.2)
			expect(sim:inboxHas(bot, "Effect", "holdRejected")).toBe(true)
			sim:send(bot, "Debug", "tp", "target")
			sim:run(0.3)
			sim:send(bot, "HoldBegin", "capture", "target")
			sim:run(1)
			sim:send(bot, "HoldEnd", "capture", "target", true)
			sim:run(0.3)
			expect(phase(sim, bot)).toBe("Explore")
			-- Unknown sockets and non-roster interactions are ignored.
			sim:send(bot, "RequestDeploy", "NOPE", 1)
			sim:send(bot, "Interact", "lever", "L99")
			sim:run(0.3)
			assertClean(sim)
			expect(phase(sim, bot)).toBe("Explore")
		end)

		it("keeps a two-player run going when one player disconnects; orphaned rooms fold (S19)", function()
			local sim = boot()
			local bots = joinAndLaunch(sim, { "Dee", "Eve" })
			local a, b = bots[1], bots[2]
			local level = sim:state(a, "global", "level")
			expect(sim:state(a, "global", "run.solo")).toBe(false)
			local s1 = level.sockets.S1.interactPoint
			local path = route(sim, a, level, tileIndexAt(level, s1))
			table.insert(path, s1)
			sim:walk(a, path)
			expect(sim:runUntil(near(sim, a, s1), 15)).toBe(true)
			sim:send(a, "RequestDeploy", "S1", 1)
			sim:run(1)
			expect(sim:state(b, "global", "sockets.S1.room")).toBe("Freezer")
			sim:removeBot(a)
			sim:run(0.2)
			expect(sim:state(b, "global", "roster.1001.status")).toBe("Disconnected")
			expect(sim:runUntil(function()
				return sim:state(b, "global", "sockets.S1") == nil
			end, 5)).toBe(true)
			expect(phase(sim, b)).toBe("Explore")
			assertClean(sim)
		end)

		it("cycles ten runs without growing the instance count (S27)", function()
			local sim = boot()
			local bot = sim:addBot("Finn", 2001)
			sim:snapshot(bot)
			sim:run(0.6)
			sim:send(bot, "Debug", "give", "all")
			sim:run(0.2)
			local baseline = sim:instanceCount()
			for i = 1, 10 do
				sim:send(bot, "SetReady", true)
				expect(sim:runUntil(function()
					return phase(sim, bot) == "Explore"
				end, 30)).toBe(true)
				sim:send(bot, "Debug", "phase", if i % 2 == 0 then "win" else "fail")
				expect(sim:runUntil(function()
					return phase(sim, bot) == "Results"
				end, 5)).toBe(true)
				sim:send(bot, "ResultsAction", "lobby")
				expect(sim:runUntil(function()
					return phase(sim, bot) == "Prep"
				end, 40)).toBe(true)
				sim:run(0.5)
			end
			assertClean(sim)
			expect(sim:instanceCount() <= baseline + 5).toBe(true)
		end)
	end)
end
