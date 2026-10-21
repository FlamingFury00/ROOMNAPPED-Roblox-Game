--[[
	Authored playthroughs on the simulated server (S10, S31, S20).

	For every mission layout, a bot plays the layout's first starter-only solution (Freezer + Fan) through the
	real remotes while the shipped server runs the expedition: real deploy range checks, real effect timings,
	server-moved crates, cart timelines, fire / shock / fall damage and capture validation. The bot walks the
	lanes a player would use (ledges, beams, SAFE WAY walkways, ice, the safe side of a pinned cart), waits for
	gaps between carts, hops across slotted crates and is thrown to the landing by a launch (client-side
	physics the simulation cannot run). The caretaker is switched off so the route itself is what is tested.

	Passing means: the run ends in Success, the suitcase is banked, and the bot never took a hit or fell.

	These runs take a few minutes; set RN_SKIP_LAYOUT_SIMS=1 to skip them in quick local iterations (CI always
	runs them).
]]
local process = require("@lune/process")

local Sim = require("../harness/Sim")
local ClientSim = require("../harness/ClientSim")

return function(ctx)
	local Spec = ctx.Spec
	local describe, it, expect = Spec.describe, Spec.it, Spec.expect
	local V3 = ctx.roblox.Vector3

	local Layouts = ctx.module("ReplicatedStorage.Shared.Content.Layouts")
	local Missions = ctx.module("ReplicatedStorage.Shared.Config.MissionDefs")
	local CartTimeline = ctx.module("ReplicatedStorage.Shared.Logic.CartTimeline")
	local Geometry = ctx.module("ReplicatedStorage.Shared.World.Geometry")

	local SINGLE = { Elevator = true, Turn = true, Target = true, Fire = true, Puddle = true, Carts = true }
	local HALF = Geometry.Half
	local INNER = Geometry.Inner
	local CART_BAND = 2.7 -- half depth of the cart danger band along the route (server: size.Z / 2 + 0.9)

	local function isObstacle(mod): boolean
		return mod.kind == "Basin"
			or mod.kind == "Gap"
			or mod.kind == "Fire"
			or mod.kind == "Carts"
			or (mod.kind == "Puddle" and mod.power ~= nil)
	end

	local function sideSign(side: string?): number
		return if side == "R" then 1 elseif side == "L" then -1 else 0
	end

	local function starterSolution(layout)
		for _, solution in layout.solutions or {} do
			local ok = true
			for _, room in solution.loadout do
				if room ~= "Freezer" and room ~= "Fan" then
					ok = false
				end
			end
			if ok then
				return solution
			end
		end
		return nil
	end

	local function playLayout(layout, mission)
		local solution = starterSolution(layout)
		assert(solution, layout.id .. " has no starter solution")

		local sim = Sim.new(ctx.placePath)
		sim:startServer()
		sim:run(0.3)
		local bot = sim:addBot("Pat", 3001)
		local key = "3001"
		sim:snapshot(bot)
		-- The shipped client rides along: every visual, HUD and movement module runs against this level.
		if process.env.RN_LAYOUT_SIMS_NO_CLIENT ~= "1" then
			ClientSim.attach(sim, bot):start()
		end
		sim:run(0.6)
		sim:send(bot, "ClientReady", "keyboard", "en-us")
		sim:send(bot, "Debug", "give", "all")
		sim:send(bot, "Debug", "caretaker", "off")
		sim:run(0.3)
		sim:send(bot, "SetLoadout", solution.loadout[1], solution.loadout[2])
		sim:send(bot, "SelectMission", mission.id)
		sim:run(0.3)
		expect(sim:state(bot, "global", "lobby.mission")).toBe(mission.id)
		sim:send(bot, "SetReady", true)
		expect(sim:runUntil(function()
			return sim:state(bot, "global", "run.phase") == "Explore"
		end, 30)).toBe(true)
		local level = sim:state(bot, "global", "level")
		expect(level.layoutId).toBe(layout.id)

		local function fail(message: string)
			local errors = if #sim.errors > 0 then "\n" .. table.concat(sim.errors, "\n----\n") else ""
			error(layout.id .. " / " .. solution.name .. ": " .. message .. errors)
		end

		-- Tile bookkeeping (mirrors LevelBuilder's module lengths).
		local moduleTiles, tileModule = {}, {}
		local index = 0
		local moduleIndexOf = {}
		for m, mod in layout.modules do
			local len = if SINGLE[mod.kind] then 1 else math.max(1, math.floor(mod.len or 1))
			moduleTiles[m] = {}
			for _ = 1, len do
				index += 1
				table.insert(moduleTiles[m], index)
				tileModule[index] = m
			end
			if mod.id then
				moduleIndexOf[mod.id] = m
			end
		end
		expect(index).toBe(#level.tiles)
		local function obstacleTile(t: number): boolean
			return isObstacle(layout.modules[tileModule[t]])
		end
		local function tilePoint(t: number, x: number, z: number)
			-- Tile-local point at root height (z is LOCAL: +z = behind the tile, toward lower tile indices).
			return level.tiles[t].cf * V3.new(x, 3, z)
		end
		local function slotOf(room: string): number
			for i, r in solution.loadout do
				if r == room then
					return i
				end
			end
			fail("room " .. room .. " not in loadout")
			return 0
		end

		local cur = 1
		local function walk(points, timeout: number?)
			sim:walk(bot, points)
			if not sim:runUntil(function()
				return #bot.path == 0
			end, timeout or 60) then
				fail("bot stopped walking near " .. tostring(sim:position(bot)))
			end
		end

		-- Walk along tile centres to tile `target`, never stepping onto an obstacle tile on the way.
		local function walkToTile(target: number)
			if target == cur then
				walk({ tilePoint(cur, 0, 0) })
				return
			end
			local step = if target > cur then 1 else -1
			local points = {}
			for t = cur + step, target, step do
				if obstacleTile(t) then
					fail("route from tile " .. cur .. " to " .. target .. " crosses obstacle tile " .. t)
				end
				table.insert(points, tilePoint(t, 0, 0))
			end
			walk(points)
			cur = target
		end

		-- Stand near a wall feature on tile t (on the tile itself, or at its edge when it is an obstacle).
		local function approach(t: number, lateral: number)
			if obstacleTile(t) then
				local before = cur < t
				local neighbour = if before then t - 1 else t + 1
				walkToTile(neighbour)
				walk({ tilePoint(t, lateral, if before then HALF - 1 else -(HALF - 1)) })
			else
				walkToTile(t)
				walk({ tilePoint(t, lateral, 0) })
			end
		end

		local function lateralOf(t: number, position): number
			return level.tiles[t].cf:PointToObjectSpace(position).X
		end

		local function socketTile(socketId: string): number
			local socket = level.sockets[socketId]
			local best, bestDistance = 1, math.huge
			for t, tile in level.tiles do
				local d = (tile.cf.Position - socket.interactPoint).Magnitude
				if d < bestDistance then
					best, bestDistance = t, d
				end
			end
			return best
		end

		local function hurt(): boolean
			for _, message in bot.inbox do
				local args = message.args
				if message.name == "Effect" and type(args[2]) == "table" and args[2].userId == key then
					if args[1] == "hit" or args[1] == "fall" or args[1] == "splash" then
						return true
					end
				end
			end
			return false
		end

		local function serverNow(): number
			return sim.time + 1000
		end

		-- Wait at the edge of a cart band until the cart is safely on the far side of lane `lateral`.
		local function waitForCart(cartId: string, lateral: number)
			local cart = level.carts[cartId]
			local ok = sim:runUntil(function()
				local timeline = sim:state(bot, "global", "carts." .. cartId)
				if not timeline then
					return false
				end
				local now = serverNow()
				local x = CartTimeline.offset(timeline, cart.range, cart.speed, now)
				local away = if lateral < 0 then x > lateral + 5 else x < lateral - 5
				if timeline.pinned ~= 0 then
					return away
				end
				local positive = CartTimeline.movingPositive(timeline, cart.range, cart.speed, now)
				return away and (if lateral < 0 then positive else not positive)
			end, 30)
			if not ok then
				fail("cart " .. cartId .. " never left the lane")
			end
		end

		local function cross(step)
			local m = moduleIndexOf[step.cross]
			local mod = layout.modules[m]
			local tiles = moduleTiles[m]
			local first, last = tiles[1], tiles[#tiles]
			local out = cur < first
			local entryTile = if out then first else last
			local exitTile = if out then last else first
			local beyond = if out then last + 1 else first - 1
			local s = sideSign(mod.ledge or mod.beam)
			local by = step.by
			local lateral = 0
			if by == "ledge" or by == "walkway" then
				lateral = s * (INNER - 1.5)
			elseif by == "beam" then
				lateral = s * (INNER - Geometry.Beam.Width / 2)
			elseif by == "ice" then
				lateral = -sideSign(mod.ledge) * 1.5
			elseif by == "pin" then
				for socketId, socket in level.sockets do
					if socketTile(socketId) == first then
						local socketState = sim:state(bot, "global", "sockets." .. socketId)
						if socketState and socketState.room == "Fan" and socketState.dir == "Across" then
							lateral = math.sign(lateralOf(first, socket.interactPoint)) * 6
						end
					end
				end
				if lateral == 0 then
					fail("no Fan pins " .. step.cross)
				end
			elseif by == "slow" or by == "timing" then
				lateral = -6
			end
			local entryZ = if out then HALF + 1.5 else -(HALF + 1.5)
			local exitZ = -entryZ
			-- Stand on our side of the obstacle, lined up with the lane. When the previous obstacle ends right
			-- here, the bot is already standing on the boundary between the two.
			local approachTile = if out then first - 1 else last + 1
			if not obstacleTile(approachTile) then
				walkToTile(approachTile)
			end
			if by == "slow" or by == "timing" or by == "pin" then
				local bandZ = if out then CART_BAND + 1 else -(CART_BAND + 1)
				walk({ tilePoint(entryTile, lateral, bandZ) })
				if by ~= "pin" then
					waitForCart(step.cross, lateral)
				end
				walk({ tilePoint(exitTile, lateral, -bandZ), tilePoint(exitTile, lateral, exitZ) })
			elseif by == "crate" then
				if sim:state(bot, "global", "crates." .. mod.slot .. ".slotted") ~= true then
					fail("crate " .. mod.slot .. " is not in the slot of " .. step.cross)
				end
				walk({ tilePoint(entryTile, 0, entryZ) })
				-- Two short hops over the slotted crate.
				sim:teleportBot(bot, tilePoint(exitTile, 0, exitZ))
				sim:run(0.3)
			elseif by == "launch" then
				local launch = level.launches[step.cross .. "_launch"]
				if sim:state(bot, "global", "zones." .. launch.basin .. ".phase") ~= "Ice" then
					fail("the launch basin is not frozen")
				end
				walk({ tilePoint(entryTile, 0, entryZ) })
				sim:teleportBot(bot, launch.landing)
				sim:run(0.3)
			else
				walk({ tilePoint(entryTile, lateral, entryZ), tilePoint(exitTile, lateral, exitZ) })
			end
			if obstacleTile(beyond) then
				-- Another obstacle starts right here: stay on the boundary, logically still at this obstacle's end.
				cur = if out then last else first
			else
				walk({ tilePoint(beyond, 0, 0) })
				cur = beyond
			end
			if hurt() then
				fail("hurt while crossing " .. step.cross .. " by " .. tostring(by))
			end
		end

		for _, step in solution.steps do
			if step.deploy then
				local t = socketTile(step.deploy)
				local socket = level.sockets[step.deploy]
				approach(t, math.sign(lateralOf(t, socket.interactPoint)) * 4)
				local slot = slotOf(step.room)
				sim:send(bot, "SelectSlot", slot)
				sim:send(bot, "RequestDeploy", step.deploy, slot, step.dir)
				sim:run(0.4)
				local placed = sim:state(bot, "global", "sockets." .. step.deploy)
				if not placed or placed.room ~= step.room then
					fail("could not unfold " .. step.room .. " at " .. step.deploy)
				end
				sim:run(5)
			elseif step.recall then
				sim:send(bot, "RequestRecall", slotOf(step.recall))
				sim:run(1.5)
			elseif step.pull then
				local lever = level.levers[step.pull]
				local t = 1
				local bestDistance = math.huge
				for i, tile in level.tiles do
					local d = (tile.cf.Position - lever.cf.Position).Magnitude
					if d < bestDistance then
						t, bestDistance = i, d
					end
				end
				approach(t, math.sign(lateralOf(t, lever.cf.Position)) * 4)
				sim:send(bot, "Interact", "lever", step.pull)
				sim:run(0.5)
				if sim:state(bot, "global", "levers." .. step.pull) ~= true then
					fail("lever " .. step.pull .. " did not flip")
				end
				sim:run(2)
			elseif step.cross then
				cross(step)
			elseif step.capture then
				walkToTile(#level.tiles)
				walk({ level.target.capturePoint })
				sim:send(bot, "HoldBegin", "capture", "target")
				sim:run(3.05)
				sim:send(bot, "HoldEnd", "capture", "target", true)
				if
					not sim:runUntil(function()
						return sim:state(bot, "global", "run.phase") == "Escape"
					end, 5)
				then
					fail("capture did not start the escape")
				end
			elseif step.escape then
				walkToTile(1)
				walk({ level.exit.cf.Position })
				if
					not sim:runUntil(function()
						return sim:state(bot, "global", "run.phase") == "Results"
					end, 10)
				then
					fail("reaching the elevator did not end the run")
				end
			end
		end
		sim:run(4) -- results screen, return to the lobby
		local clientWarnings = {}
		for _, w in sim.warnings do
			if string.find(w, "[Client]", 1, true) then
				table.insert(clientWarnings, w)
			end
		end
		if #sim.errors > 0 or #clientWarnings > 0 then
			fail(
				"server or client errors"
					.. (if #clientWarnings > 0 then "\n" .. table.concat(clientWarnings, "\n") else "")
			)
		end
		expect(sim:state(bot, "global", "run.outcome")).toBe("Success")
		expect(hurt()).toBe(false)
	end

	describe("Authored playthroughs on the simulated server (S10/S31)", function()
		if process.env.RN_SKIP_LAYOUT_SIMS == "1" then
			return
		end
		for _, mission in Missions.list do
			local layout = Layouts[mission.layoutId]
			if layout and not mission.tutorial then
				it(layout.id .. " starter playthrough succeeds without a scratch", function()
					playLayout(layout, mission)
				end)
			end
		end
	end)
end
