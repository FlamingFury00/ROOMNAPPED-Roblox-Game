--[[
	Full-stack play tests: the shipped server AND the shipped client run together in the headless engine
	(tests/harness/Sim + ClientSim). A bot's client presses real keys through the client's input bindings,
	the client sends real remotes, the server answers, and every controller, visual and HUD module runs its
	real code paths. Any error anywhere fails the test.
]]
local Sim = require("../harness/Sim")
local ClientSim = require("../harness/ClientSim")

return function(ctx)
	local Spec = ctx.Spec
	local describe, it, expect = Spec.describe, Spec.it, Spec.expect
	local V3 = ctx.roblox.Vector3

	local function assertClean(sim)
		local problems = {}
		for _, e in sim.errors do
			table.insert(problems, e)
		end
		for _, w in sim.warnings do
			if string.find(w, "failed", 1, true) or string.find(w, "error", 1, true) then
				table.insert(problems, "[warning] " .. w)
			end
		end
		if #problems > 0 then
			error("errors during play:\n" .. table.concat(problems, "\n----\n"))
		end
	end

	local function boot()
		local sim = Sim.new(ctx.placePath)
		sim:startServer()
		sim:run(0.3)
		local bot = sim:addBot("Alice", 1001)
		sim:snapshot(bot)
		local client = ClientSim.attach(sim, bot)
		client:start()
		sim:run(1)
		return sim, bot, client
	end

	local function phase(sim, bot)
		return sim:state(bot, "global", "run.phase")
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

	local function route(sim, bot, level, toIndex)
		local from = tileIndexAt(level, sim:position(bot))
		local points = {}
		local step = if toIndex >= from then 1 else -1
		for i = from, toIndex, step do
			table.insert(points, level.tiles[i].cf.Position + V3.new(0, 3, 0))
		end
		return points
	end

	local function near(sim, bot, point, radius)
		return function()
			local p = sim:position(bot)
			return p ~= nil and V3.new(p.X - point.X, 0, p.Z - point.Z).Magnitude <= (radius or 1.5)
		end
	end

	describe("Client + server play (full stack)", function()
		it("boots the client in the lobby without errors", function()
			local sim, _, client = boot()
			assertClean(sim)
			expect(client:find("RN_Hud") ~= nil).toBe(true)
			expect(client:find("RN_Menus") ~= nil).toBe(true)
		end)

		it("plays the whole tutorial through the client's own input, HUD and visuals", function()
			local sim, bot, client = boot()
			-- Lobby: press PLAY on the HUD.
			local play = client:find("PlayButton")
			expect(play ~= nil).toBe(true)
			client:click(play)
			sim:run(0.2)
			expect(sim:state(bot, "global", "players.1001.ready")).toBe(true)
			expect(sim:runUntil(function()
				return phase(sim, bot) == "Explore"
			end, 30)).toBe(true)
			sim:run(1)
			assertClean(sim)
			local level = sim:state(bot, "global", "level")
			expect(sim.workspace:FindFirstChild("RN_ZoneVisuals") ~= nil).toBe(true)
			expect(sim.workspace:FindFirstChild("Caretaker") ~= nil).toBe(true)

			-- Walk to the Freezer door, pull out slot 1 and unfold it with the context action.
			local s1 = level.sockets.S1.interactPoint
			local path = route(sim, bot, level, tileIndexAt(level, s1))
			table.insert(path, s1)
			sim:walk(bot, path)
			expect(sim:runUntil(near(sim, bot, s1), 15)).toBe(true)
			client:tap("RN_Slot1")
			sim:run(0.3)
			expect(bot.player.Character:FindFirstChild("HeldSuitcase") ~= nil).toBe(true)
			local placement = client:module("Controllers.PlacementController").candidate()
			expect(placement ~= nil).toBe(true)
			expect(placement.socketId).toBe("S1")
			expect(placement.valid).toBe(true)
			client:tap("RN_Use")
			sim:run(0.4)
			assertClean(sim)
			expect(sim:state(bot, "global", "sockets.S1.room")).toBe("Freezer")
			sim:run(2)
			expect(sim:state(bot, "global", "zones.B1.phase")).toBe("Ice")
			local ice = sim.workspace.Expedition:FindFirstChild("Ice_B1", true)
			expect(ice ~= nil and ice.Transparency < 0.5).toBe(true)

			-- Cross to the target room and hold the context action until the ring fills.
			local target = level.target.capturePoint
			local toTarget = route(sim, bot, level, tileIndexAt(level, target))
			table.insert(toTarget, target)
			sim:walk(bot, toTarget)
			expect(sim:runUntil(near(sim, bot, target), 25)).toBe(true)
			sim:run(0.3)
			local action = client:module("Controllers.InteractionController").current()
			expect(action ~= nil and action.kind).toBe("capture")
			client:press("RN_Use")
			sim:run(3.4)
			client:release("RN_Use")
			sim:run(0.3)
			assertClean(sim)
			expect(phase(sim, bot) == "Capture" or phase(sim, bot) == "Escape").toBe(true)
			expect(sim:state(bot, "global", "cargo.carrier")).toBe("1001")

			-- Escape to the elevator.
			local back = route(sim, bot, level, 1)
			table.insert(back, level.exit.cf.Position)
			sim:walk(bot, back)
			expect(sim:runUntil(function()
				return phase(sim, bot) == "Results"
			end, 45)).toBe(true)
			sim:run(4)
			assertClean(sim)
			expect(sim:state(bot, "global", "run.outcome")).toBe("Success")
			local UIRoot = client:module("UI.UIRoot")
			expect(UIRoot.isOpen("Results")).toBe(true)
		end)
	end)
end
