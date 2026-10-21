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
			-- Check-In is done, so the lobby has moved on to the first real mission (PLAY AGAIN goes there).
			expect(sim:state(bot, "global", "lobby.mission")).toBe("M1")
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
			if outcome == "Wiped" then
				-- The results name what knocked the squad out.
				expect(sim:state(bot, "global", "run.cause")).toBe("caretaker")
			end
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

		it("saves the lost-run notice when a player drops mid-run and rejoins the same server (U20, S21)", function()
			local sim = boot()
			local bots = joinAndLaunch(sim, { "Ivy", "Jon" })
			local a, b = bots[1], bots[2]
			sim:removeBot(a)
			sim:run(0.5)
			expect(sim:state(b, "global", "roster.1001.status")).toBe("Disconnected")
			-- Rejoin on the same server: the new session waits for the old one's release save, then loads it.
			local again = sim:addBot("Ivy", 1001)
			sim:snapshot(again)
			expect(sim:runUntil(function()
				return sim:state(again, "me", "profile.status") == "Ready"
			end, 30)).toBe(true)
			sim:send(again, "ClientReady", "keyboard", "en-us")
			sim:run(0.5)
			expect(sim:inboxHas(again, "Toast", "toast.interruptedRun")).toBe(true)
			assertClean(sim)
		end)

		it("launches one squad of at most four; the fifth player waits for the next run (S17)", function()
			local sim = boot()
			local names = { "Ann", "Ben", "Cal", "Dot", "Eli" }
			local bots = {}
			for i, name in names do
				local bot = sim:addBot(name, 2000 + i)
				sim:snapshot(bot)
				table.insert(bots, bot)
			end
			sim:run(0.6)
			for _, bot in bots do
				sim:send(bot, "ClientReady", "keyboard", "en-us")
				sim:send(bot, "SetReady", true)
				sim:run(0.05)
			end
			expect(sim:state(bots[5], "global", "players.2005.ready")).toBe(false)
			expect(sim:runUntil(function()
				return phase(sim, bots[1]) == "Explore"
			end, 30)).toBe(true)
			local roster = sim:state(bots[1], "global", "roster")
			local count = 0
			for _ in roster do
				count += 1
			end
			expect(count).toBe(4)
			expect(roster["2005"]).toBe(nil)
			assertClean(sim)
		end)

		it("returns to the lobby without relaunching, and PLAY AGAIN relaunches (U18)", function()
			local sim = boot()
			local bot = sim:addBot("Gus", 2101)
			sim:snapshot(bot)
			sim:run(0.6)
			sim:send(bot, "Debug", "give", "all")
			sim:send(bot, "SetReady", true)
			expect(sim:runUntil(function()
				return phase(sim, bot) == "Explore"
			end, 30)).toBe(true)
			sim:send(bot, "Debug", "phase", "win")
			expect(sim:runUntil(function()
				return phase(sim, bot) == "Results"
			end, 5)).toBe(true)
			sim:send(bot, "ResultsAction", "lobby")
			expect(sim:runUntil(function()
				return phase(sim, bot) == "Prep"
			end, 40)).toBe(true)
			-- Back in the lobby: nobody is readied by standing near the elevator, so no new run starts.
			sim:run(8)
			expect(phase(sim, bot)).toBe("Prep")
			expect(sim:state(bot, "global", "players.2101.ready")).toBe(false)
			-- A second run that ends with PLAY AGAIN goes straight back out.
			sim:send(bot, "SetReady", true)
			expect(sim:runUntil(function()
				return phase(sim, bot) == "Explore"
			end, 30)).toBe(true)
			sim:send(bot, "Debug", "phase", "fail")
			expect(sim:runUntil(function()
				return phase(sim, bot) == "Results"
			end, 5)).toBe(true)
			sim:send(bot, "ResultsAction", "replay")
			expect(sim:runUntil(function()
				return phase(sim, bot) == "Explore"
			end, 60)).toBe(true)
			assertClean(sim)
		end)

		it("gives a socket to exactly one of two players who claim it in the same frame (S06)", function()
			local sim = boot()
			local bots = joinAndLaunch(sim, { "Hal", "Ida" })
			local a, b = bots[1], bots[2]
			local level = sim:state(a, "global", "level")
			local s1 = level.sockets.S1.interactPoint
			for i, bot in bots do
				local path = route(sim, bot, level, tileIndexAt(level, s1))
				table.insert(path, s1 + V3.new(i - 1.5, 0, 0))
				sim:walk(bot, path)
			end
			expect(sim:runUntil(function()
				return near(sim, a, s1, 2.5)() and near(sim, b, s1, 2.5)()
			end, 20)).toBe(true)
			sim:send(a, "RequestDeploy", "S1", 1)
			sim:send(b, "RequestDeploy", "S1", 1)
			sim:run(1.5)
			assertClean(sim)
			local socket = sim:state(a, "global", "sockets.S1")
			expect(socket ~= nil).toBe(true)
			expect(socket.owner).toBe("1001")
			expect(sim:inboxHas(b, "Toast", "deploy.reason.SocketOccupied")).toBe(true)
			-- One room, one owner: the loser's slot is still free.
			local count = 0
			for _ in sim:state(a, "global", "sockets") do
				count += 1
			end
			expect(count).toBe(1)
		end)

		it(
			"charges once when a skin is bought with exactly enough credits, however often it is pressed (A12)",
			function()
				local sim = boot()
				local bot = sim:addBot("Jay", 2201)
				sim:snapshot(bot)
				sim:run(0.6)
				local price = ctx.module("ReplicatedStorage.Shared.Config.SkinDefs").byId.freezer_icecream.price
				local credits = sim:state(bot, "me", "profile.credits")
				sim:send(bot, "Debug", "give", "credits", tostring(price - credits))
				sim:run(0.3)
				expect(sim:state(bot, "me", "profile.credits")).toBe(price)
				for _ = 1, 6 do
					sim:send(bot, "BuySkin", "freezer_icecream")
				end
				sim:run(1)
				assertClean(sim)
				expect(sim:state(bot, "me", "profile.credits")).toBe(0)
				expect(sim:state(bot, "me", "profile.skins.owned.freezer_icecream")).toBe(true)
				local bought = 0
				for _, message in bot.inbox do
					if message.name == "Toast" and message.args[2] == "toast.bought" then
						bought += 1
					end
				end
				expect(bought).toBe(1)
				-- Too poor for the next one: refused, balance untouched.
				sim:run(6)
				sim:send(bot, "BuySkin", "fan_tropical")
				sim:run(0.5)
				expect(sim:state(bot, "me", "profile.credits")).toBe(0)
			end
		)

		-- Plays the tutorial to a win with `failures` store requests failing from the moment the run ends, and
		-- records every save state the results panel would show.
		local function winWithFailingStore(name: string, userId: number, failures: number)
			local sim = boot()
			local bot = sim:addBot(name, userId)
			sim:snapshot(bot)
			sim:run(0.6)
			sim:send(bot, "SetReady", true)
			expect(sim:runUntil(function()
				return phase(sim, bot) == "Explore"
			end, 30)).toBe(true)
			sim:send(bot, "Debug", "failsaves", tostring(failures))
			sim:run(0.1)
			sim:send(bot, "Debug", "phase", "win")
			local states = {}
			local savedAt: number? = nil
			local elapsed = 0
			while elapsed < 120 do
				local state = sim:state(bot, "me", "results.saving")
				if state ~= states[#states] then
					table.insert(states, state)
				end
				if state == "Saved" or state == "Error" then
					savedAt = elapsed
					break
				end
				sim:run(0.2)
				elapsed += 0.2
			end
			return sim, bot, states, savedAt
		end

		local function rejoin(sim, bot, name: string, userId: number)
			sim:removeBot(bot)
			sim:run(1)
			local again = sim:addBot(name, userId)
			sim:snapshot(again)
			expect(sim:runUntil(function()
				return sim:state(again, "me", "profile.status") == "Ready"
			end, 30)).toBe(true)
			return again
		end

		it("shows Saving through a store outage and Saved only after the write lands (S22, A12)", function()
			-- Six failures: the first save gives up after five attempts, the retry succeeds on its second.
			local sim, bot, states, savedAt = winWithFailingStore("Kim", 2301, 6)
			assertClean(sim)
			expect(states[#states]).toBe("Saved")
			expect(table.find(states, "Error")).toBe(nil)
			expect(table.find(states, "Saving") ~= nil).toBe(true)
			-- Five attempts with backoff (1 + 2 + 4 + 8 s) had to fail before anything could be confirmed.
			expect((savedAt :: number) >= 15).toBe(true)
			local credits = sim:state(bot, "me", "results.plan.credits")
			expect(credits > 0).toBe(true)
			expect(sim:state(bot, "me", "profile.credits")).toBe(credits)
			-- The write really landed: a fresh session loads the reward, granted exactly once.
			local again = rejoin(sim, bot, "Kim", 2301)
			expect(sim:state(again, "me", "profile.rooms.Laundry")).toBe(true)
			expect(sim:state(again, "me", "profile.credits")).toBe(credits)
			assertClean(sim)
		end)

		it("reports a save that keeps failing, keeps retrying and confirms when it lands (S22, A12)", function()
			local sim, bot, states, _ = winWithFailingStore("Lou", 2302, 100)
			assertClean(sim)
			expect(states[#states]).toBe("Error")
			expect(table.find(states, "Saved")).toBe(nil)
			expect(sim:inboxHas(bot, "Toast", "toast.saveFailed")).toBe(true)
			local credits = sim:state(bot, "me", "results.plan.credits")
			-- The outage ends: the background retry lands, the panel flips to Saved and the player is told.
			sim:send(bot, "Debug", "failsaves", "0")
			expect(sim:runUntil(function()
				return sim:state(bot, "me", "results.saving") == "Saved"
			end, 40)).toBe(true)
			expect(sim:inboxHas(bot, "Toast", "toast.saveRecovered")).toBe(true)
			-- And the next session loads the reward.
			local again = rejoin(sim, bot, "Lou", 2302)
			expect(sim:state(again, "me", "profile.rooms.Laundry")).toBe(true)
			expect(sim:state(again, "me", "profile.credits")).toBe(credits)
			assertClean(sim)
		end)

		it("switches content off live without touching what players own (S32)", function()
			local sim = boot()
			local bot = sim:addBot("Max", 2401)
			sim:snapshot(bot)
			sim:run(0.6)
			sim:send(bot, "Debug", "give", "all")
			sim:run(0.2)
			sim:send(bot, "SelectMission", "M3")
			sim:send(bot, "SetLoadout", "Laundry", "Greenhouse")
			sim:run(0.3)
			expect(sim:state(bot, "global", "lobby.mission")).toBe("M3")
			expect(sim:state(bot, "me", "profile.loadout")[2]).toBe("Greenhouse")

			-- A mission switched off: the selection moves on and it cannot be picked again.
			sim:send(bot, "Debug", "flag", "M3", "off")
			sim:run(0.3)
			expect(sim:state(bot, "global", "flags.disabledMissions.M3")).toBe(true)
			expect(sim:state(bot, "global", "lobby.mission") ~= "M3").toBe(true)
			sim:send(bot, "SelectMission", "M3")
			sim:run(0.3)
			expect(sim:state(bot, "global", "lobby.mission") ~= "M3").toBe(true)
			expect(sim:inboxHas(bot, "Toast", "toast.missionLocked")).toBe(true)

			-- A room switched off leaves the loadout but stays owned, and cannot be equipped again.
			sim:send(bot, "Debug", "flag", "Greenhouse", "off")
			sim:run(0.3)
			local loadout = sim:state(bot, "me", "profile.loadout")
			expect(table.find(loadout, "Greenhouse")).toBe(nil)
			expect(#loadout).toBe(2)
			expect(sim:state(bot, "me", "profile.rooms.Greenhouse")).toBe(true)
			sim:send(bot, "SetLoadout", "Greenhouse", "Fan")
			sim:run(0.3)
			expect(table.find(sim:state(bot, "me", "profile.loadout"), "Greenhouse")).toBe(nil)

			-- The shop switched off: nothing can be bought (a second player who owns no skins yet).
			local shopper = sim:addBot("Ned", 2402)
			sim:snapshot(shopper)
			sim:run(0.6)
			sim:send(shopper, "Debug", "give", "credits", "1000")
			sim:send(bot, "Debug", "flag", "shop", "off")
			sim:run(0.3)
			local credits = sim:state(shopper, "me", "profile.credits")
			sim:send(shopper, "BuySkin", "freezer_icecream")
			sim:run(0.5)
			expect(sim:state(shopper, "me", "profile.credits")).toBe(credits)
			expect(sim:state(shopper, "me", "profile.skins.owned.freezer_icecream")).toBe(nil)

			-- Everything comes back when switched on again.
			sim:send(bot, "Debug", "flag", "M3", "on")
			sim:send(bot, "Debug", "flag", "Greenhouse", "on")
			sim:send(bot, "Debug", "flag", "shop", "on")
			sim:run(0.3)
			sim:send(shopper, "BuySkin", "freezer_icecream")
			sim:run(0.5)
			expect(sim:state(shopper, "me", "profile.skins.owned.freezer_icecream")).toBe(true)
			sim:send(bot, "SelectMission", "M3")
			sim:send(bot, "SetLoadout", "Greenhouse", "Fan")
			sim:run(0.3)
			expect(sim:state(bot, "global", "lobby.mission")).toBe("M3")
			expect(sim:state(bot, "me", "profile.loadout")[1]).toBe("Greenhouse")
			assertClean(sim)
		end)

		it("celebrates a new personal best only when the record is beaten (S31)", function()
			local sim = boot()
			local bot = sim:addBot("Oz", 2501)
			sim:snapshot(bot)
			sim:run(0.6)
			sim:send(bot, "Debug", "give", "all")
			sim:send(bot, "SelectMission", "M1")
			sim:run(0.3)
			local function winAfter(seconds: number)
				sim:send(bot, "SetReady", true)
				expect(sim:runUntil(function()
					return phase(sim, bot) == "Explore"
				end, 30)).toBe(true)
				local runId = sim:state(bot, "global", "run.id")
				sim:run(seconds)
				sim:send(bot, "Debug", "phase", "win")
				expect(sim:runUntil(function()
					return sim:state(bot, "me", "results.runId") == runId
						and sim:state(bot, "me", "results.saving") == "Saved"
				end, 20)).toBe(true)
				local newBest = sim:state(bot, "me", "results.newBest") == true
				sim:send(bot, "ResultsAction", "lobby")
				expect(sim:runUntil(function()
					return phase(sim, bot) == "Prep"
				end, 40)).toBe(true)
				sim:run(1)
				return newBest
			end
			expect(winAfter(8)).toBe(false) -- first clear: no record to beat yet
			expect(winAfter(14)).toBe(false) -- slower
			expect(winAfter(2)).toBe(true) -- faster than the record
			assertClean(sim)
		end)

		it("keeps only well-formed live flag overrides (S32)", function()
			local sim = boot()
			local Flags = sim:module("ServerScriptService.Server.Services.FlagsService")
			local clean, dropped = Flags.cleanOverrides({
				rooms = false,
				missions = { M3 = false, M99 = false, M2 = "no" },
				features = { shop = false, teleport = true },
				adminUserIds = { 5, "x", -1 },
				adminGroup = { id = 7, minRank = 200 },
				junk = 1,
			})
			expect(clean.rooms).toBe(nil)
			expect(clean.missions.M3).toBe(false)
			expect(clean.missions.M99).toBe(nil)
			expect(clean.missions.M2).toBe(nil)
			expect(clean.features.shop).toBe(false)
			expect(clean.features.teleport).toBe(nil)
			expect(#clean.adminUserIds).toBe(1)
			expect(clean.adminGroup.minRank).toBe(200)
			expect(#dropped).toBe(7)
			-- Garbage as a whole is simply "no overrides".
			local none = Flags.cleanOverrides("oops")
			expect(next(none)).toBe(nil)
		end)

		it("never launches a mission that is switched off, even the tutorial (S32)", function()
			local sim = boot()
			local bot = sim:addBot("Pip", 2601)
			sim:snapshot(bot)
			sim:run(0.6)
			sim:send(bot, "Debug", "flag", "M0", "off")
			sim:run(0.3)
			sim:send(bot, "SetReady", true)
			sim:run(20)
			expect(phase(sim, bot)).toBe("Prep")
			expect(sim:inboxHas(bot, "Toast", "toast.missionClosed")).toBe(true)
			expect(sim:state(bot, "global", "players.2601.ready")).toBe(false)
			assertClean(sim)
		end)

		it("lets a run keep a room that is switched off after it launched (S32)", function()
			local sim = boot()
			local bot = joinAndLaunch(sim, { "Quin" })[1]
			sim:send(bot, "Debug", "flag", "Freezer", "off")
			sim:run(0.3)
			expect(sim:state(bot, "global", "flags.disabledRooms.Freezer")).toBe(true)
			local level = sim:state(bot, "global", "level")
			local s1 = level.sockets.S1.interactPoint
			local path = route(sim, bot, level, tileIndexAt(level, s1))
			table.insert(path, s1)
			sim:walk(bot, path)
			expect(sim:runUntil(near(sim, bot, s1), 15)).toBe(true)
			sim:send(bot, "RequestDeploy", "S1", 1)
			sim:run(0.5)
			expect(sim:state(bot, "global", "sockets.S1.room")).toBe("Freezer")
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
