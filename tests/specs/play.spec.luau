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
	local V2 = ctx.roblox.Vector2

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

	-- Canvas rect of an offset-positioned HUD element, honouring its anchor point and touch scale.
	local function canvasRect(inst: any): { x0: number, y0: number, x1: number, y1: number }
		local scaleObject = inst:FindFirstChild("TouchScale")
		local s = if scaleObject then scaleObject.Scale else 1
		local w, h = inst.Size.X.Offset * s, inst.Size.Y.Offset * s
		local x, y = inst.Position.X.Offset, inst.Position.Y.Offset
		local ax, ay = inst.AnchorPoint.X, inst.AnchorPoint.Y
		return { x0 = x - ax * w, y0 = y - ay * h, x1 = x + (1 - ax) * w, y1 = y + (1 - ay) * h }
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

	-- Two players in the tutorial; the client rides along with the first one.
	local function bootSquad()
		local sim = Sim.new(ctx.placePath)
		sim:startServer()
		sim:run(0.3)
		local a = sim:addBot("Alice", 1001)
		local b = sim:addBot("Bob", 1002)
		sim:snapshot(a)
		sim:snapshot(b)
		local client = ClientSim.attach(sim, a)
		client:start()
		sim:run(1)
		sim:send(a, "SetReady", true)
		sim:send(b, "SetReady", true)
		expect(sim:runUntil(function()
			return phase(sim, a) == "Explore"
		end, 30)).toBe(true)
		sim:run(1)
		return sim, a, b, client
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

		it("plays on a touch phone: slot buttons, the touch action button and a clear layout", function()
			local sim = Sim.new(ctx.placePath)
			sim:startServer()
			sim:run(0.3)
			local bot = sim:addBot("Alice", 1001)
			sim:snapshot(bot)
			local safeArea = V2.new(750, 311)
			local client =
				ClientSim.attach(sim, bot, { device = "touch", viewport = V2.new(844, 390), safeArea = safeArea })
			client:start()
			sim:run(1)
			client:click(client:find("PlayButton"))
			expect(sim:runUntil(function()
				return phase(sim, bot) == "Explore"
			end, 30)).toBe(true)
			sim:run(1)
			local touch = client:find("TouchActions")
			expect(touch ~= nil and touch.Visible).toBe(true)

			-- The room slots joined the cluster around Roblox's jump button: nothing in it covers the jump button
			-- or the thumbstick zone, and it stays below the top band and on screen.
			local TouchZones = client:module("UI.TouchZones")
			local Quickbar = client:module("UI.Run.Quickbar")
			local zones = TouchZones.get(client:find("RN_Hud"))
			expect(zones.active).toBe(true)
			expect(client:find("Quickbar").Visible).toBe(false)
			local action = touch:FindFirstChild("Action")
			for _, name in { "Action", "Slot1", "Slot2", "Ping" } do
				local piece = touch:FindFirstChild(name)
				expect(piece ~= nil).toBe(true)
				local r = canvasRect(piece)
				expect(TouchZones.intersects(r, zones.stick)).toBe(false)
				expect(TouchZones.intersects(r, zones.jump)).toBe(false)
				expect(r.y0 >= Quickbar.TOP_RESERVE).toBe(true)
				expect(r.x0 >= 0 and r.x1 <= zones.canvas.X and r.y1 <= zones.canvas.Y).toBe(true)
			end

			-- Tap the Freezer slot at the door, then press and release the action button.
			local level = sim:state(bot, "global", "level")
			local s1 = level.sockets.S1.interactPoint
			local path = route(sim, bot, level, tileIndexAt(level, s1))
			table.insert(path, s1)
			sim:walk(bot, path)
			expect(sim:runUntil(near(sim, bot, s1), 15)).toBe(true)
			client:click(client:find("Slot1"))
			sim:run(0.3)
			expect(client:module("Controllers.PlacementController").selectedSlot()).toBe(1)
			client:touchDown(action)
			sim:run(0.1)
			client:touchUp(action)
			sim:run(0.5)
			assertClean(sim)
			expect(sim:state(bot, "global", "sockets.S1.room")).toBe("Freezer")
		end)

		it("lays the lobby out around the touch controls on a phone", function()
			local sim = Sim.new(ctx.placePath)
			sim:startServer()
			sim:run(0.3)
			local bot = sim:addBot("Alice", 1001)
			sim:snapshot(bot)
			local client = ClientSim.attach(
				sim,
				bot,
				{ device = "touch", viewport = V2.new(844, 390), safeArea = V2.new(750, 311) }
			)
			client:start()
			sim:run(1)
			local TouchZones = client:module("UI.TouchZones")
			local zones = TouchZones.get(client:find("RN_Hud"))
			-- The squad turns into the avatar strip at the top; the mission card and PLAY sit between the
			-- thumbstick zone and the jump button.
			expect(client:find("Squad").Visible).toBe(false)
			expect(client:find("SquadStrip").Visible).toBe(true)
			for _, name in { "MissionCard", "Play" } do
				local r = canvasRect(client:find(name))
				expect(TouchZones.intersects(r, zones.stick)).toBe(false)
				expect(TouchZones.intersects(r, zones.jump)).toBe(false)
				expect(r.x0 >= 0 and r.y0 >= 0 and r.x1 <= zones.canvas.X and r.y1 <= zones.canvas.Y).toBe(true)
			end
			client:click(client:find("PlayButton"))
			sim:run(0.5)
			expect(sim:state(bot, "global", "players.1001.ready")).toBe(true)
			assertClean(sim)
		end)

		it("revives a downed teammate with the context hold", function()
			local sim, a, b, client = bootSquad()
			sim:send(b, "Debug", "down")
			sim:run(0.3)
			expect(sim:state(a, "global", "roster.1002.status")).toBe("Downed")
			-- Walk Alice next to Bob.
			local bobPosition = sim:position(b)
			sim:walk(a, { bobPosition + V3.new(2, 0, 0) })
			expect(sim:runUntil(near(sim, a, bobPosition + V3.new(2, 0, 0)), 10)).toBe(true)
			sim:run(0.2)
			local action = client:module("Controllers.InteractionController").current()
			expect(action ~= nil and action.kind).toBe("revive")
			client:press("RN_Use")
			sim:run(3.3)
			client:release("RN_Use")
			sim:run(0.3)
			assertClean(sim)
			expect(sim:state(a, "global", "roster.1002.status")).toBe("Active")
		end)

		it("locks movement while downed, shows the downed card and recovers when revived", function()
			local sim, a, b, client = bootSquad()
			sim:send(a, "Debug", "down")
			sim:run(0.5)
			expect(sim:state(a, "global", "roster.1001.status")).toBe("Downed")
			local humanoid = a.player.Character:FindFirstChildOfClass("Humanoid")
			expect(humanoid.WalkSpeed).toBe(0)
			expect(humanoid.Sit).toBe(true)
			local downedCard = client:find("Downed")
			expect(downedCard ~= nil and downedCard.Visible).toBe(true)
			-- Bob revives Alice through the server.
			sim:walk(b, { sim:position(a) + V3.new(2, 0, 0) })
			sim:run(3)
			sim:send(b, "HoldBegin", "revive", "1001")
			sim:run(3.05)
			sim:send(b, "HoldEnd", "revive", "1001", true)
			sim:run(0.5)
			assertClean(sim)
			expect(sim:state(a, "global", "roster.1001.status")).toBe("Active")
			expect(humanoid.WalkSpeed > 0).toBe(true)
			expect(humanoid.Sit).toBe(false)
			expect(downedCard.Visible).toBe(false)
		end)

		it("spectates a teammate after the downed window runs out", function()
			local sim, a, b, client = bootSquad()
			sim:send(a, "Debug", "down")
			sim:run(21.5)
			assertClean(sim)
			expect(sim:state(a, "global", "roster.1001.status")).toBe("Eliminated")
			local Spectate = client:module("Controllers.SpectateController")
			expect(Spectate.isSpectating()).toBe(true)
			expect(Spectate.target()).toBe("1002")
			local bobHumanoid = b.player.Character:FindFirstChildOfClass("Humanoid")
			expect(client.camera.CameraSubject == bobHumanoid).toBe(true)
			-- The spectator bar replaces the quickbar.
			expect(client:find("Spectate").Visible).toBe(true)
			expect(client:find("Quickbar").Visible).toBe(false)
		end)

		it("pings, turns a fan before unfolding it and recalls it", function()
			local sim, a, _, client = bootSquad()
			local level = sim:state(a, "global", "level")
			-- Ping where we look.
			client:tap("RN_Ping")
			sim:run(0.3)
			expect(client:find("RN_Ping") ~= nil).toBe(true)
			-- Walk to S1 (it accepts wind as well as cold), pull out the Fan (slot 2) and turn it.
			local s1 = level.sockets.S1.interactPoint
			local path = route(sim, a, level, tileIndexAt(level, s1))
			table.insert(path, s1)
			sim:walk(a, path)
			expect(sim:runUntil(near(sim, a, s1), 30)).toBe(true)
			client:tap("RN_Slot2")
			sim:run(0.2)
			local Placement = client:module("Controllers.PlacementController")
			local before = Placement.candidate()
			expect(before ~= nil and before.socketId).toBe("S1")
			client:tap("RN_Rotate")
			sim:run(0.2)
			local after = Placement.candidate()
			expect(after.dir ~= before.dir).toBe(true)
			client:tap("RN_Use")
			sim:run(0.5)
			expect(sim:state(a, "global", "sockets.S1.room")).toBe("Fan")
			expect(sim:state(a, "global", "sockets.S1.dir")).toBe(after.dir)
			-- Select the unfolded slot again: the action becomes Recall, from anywhere.
			sim:run(1)
			client:tap("RN_Slot2")
			sim:run(0.2)
			local recall = Placement.candidate()
			expect(recall ~= nil and recall.kind).toBe("recall")
			client:tap("RN_Use")
			sim:run(1.5)
			assertClean(sim)
			expect(sim:state(a, "global", "sockets.S1")).toBe(nil)
		end)
	end)
end
