--[[
	Chaos soak (S19, S20, S27, R06, R13, A12).

	A squad of three bots plays every mission while doing what a careless, curious or malicious player could
	do: deploys and recalls at any socket with any slot and direction, holds that start and stop at random,
	levers, pings, cargo drops, lobby requests in the middle of a run, malformed payloads, leaving the run and
	dropping out and rejoining. A late joiner hammers the same requests from the lobby. Invariants are checked
	every second:

	  * no server error, ever;
	  * at most two rooms per player and four per team, and every room belongs to a member of the squad;
	  * at most one suitcase, carried only by an active member of the squad;
	  * hearts stay within 0..max, the phase is always a known one and outsiders never join the roster;
	  * the run always ends, the server returns to a clean Prep, the instance count returns to its baseline and
	    the next run launches normally.

	The squad leader runs the real client, so every HUD, menu, visual and controller module lives through the
	same chaos (RN_CHAOS_NO_CLIENT=1 runs the server alone, faster). Each mission uses a fixed seed, so a failure
	reproduces exactly. RN_CHAOS_SEEDS=n soaks n seeds per mission; RN_SKIP_CHAOS=1 skips the soak in quick
	local iterations (CI runs it in its own job).
]]
local process = require("@lune/process")
local serde = require("@lune/serde")

local Sim = require("../harness/Sim")
local ClientSim = require("../harness/ClientSim")

return function(ctx)
	local Spec = ctx.Spec
	local describe, it, expect = Spec.describe, Spec.it, Spec.expect
	local V3 = ctx.roblox.Vector3

	local Missions = ctx.module("ReplicatedStorage.Shared.Config.MissionDefs")
	local RoomDefs = ctx.module("ReplicatedStorage.Shared.Config.RoomDefs")
	local SkinDefs = ctx.module("ReplicatedStorage.Shared.Config.SkinDefs")
	local GameConfig = ctx.module("ReplicatedStorage.Shared.Config.GameConfig")

	local PHASES = { Prep = true, Launching = true, Explore = true, Capture = true, Escape = true, Results = true }
	local IN_RUN = { Launching = true, Explore = true, Capture = true, Escape = true }
	local CHAOS_SECONDS = 45
	local STEP = 0.2

	local roomIds = {}
	for _, room in RoomDefs.ordered do
		table.insert(roomIds, room.id)
	end
	local skinIds = {}
	for _, skin in SkinDefs.list do
		table.insert(skinIds, skin.id)
	end

	-- Park-Miller generator: deterministic and independent of any math.random use inside the game.
	local function newRandom(seed: number)
		local state = seed % 2147483647
		if state <= 0 then
			state += 2147483646
		end
		local random = {}
		function random.unit(): number
			state = (state * 16807) % 2147483647
			return (state - 1) / 2147483646
		end
		function random.int(n: number): number
			return math.floor(random.unit() * n) + 1
		end
		function random.pick(list: { any }): any
			return list[random.int(#list)]
		end
		function random.chance(p: number): boolean
			return random.unit() < p
		end
		return random
	end

	local function keysOf(map: any): { string }
		local out = {}
		if type(map) == "table" then
			for key in map do
				table.insert(out, tostring(key))
			end
		end
		table.sort(out)
		return out
	end

	local function tileIndexAt(level, position): number
		local best, bestDistance = 1, math.huge
		for i, tile in level.tiles do
			local d = (tile.cf.Position - position).Magnitude
			if d < bestDistance then
				best, bestDistance = i, d
			end
		end
		return best
	end

	local function soak(mission, seed: number)
		local random = newRandom(seed)
		local sim = Sim.new(ctx.placePath)
		sim:startServer()
		sim:run(0.3)

		local squad = {}
		local log: { string } = {}
		local clock = 0
		local function note(text: string)
			table.insert(log, string.format("%6.1f %s", clock, text))
			if #log > 40 then
				table.remove(log, 1)
			end
		end
		local function describeLobby(): string
			local inbox = {}
			if squad[1] then
				for i = math.max(1, #squad[1].inbox - 6), #squad[1].inbox do
					local message = squad[1].inbox[i]
					table.insert(inbox, { message.name, tostring(message.args[1]), tostring(message.args[2]) })
				end
			end
			local ok, text = pcall(serde.encode, "json", {
				inbox = inbox,
				phase = sim:state(squad[1], "global", "run.phase"),
				lobby = sim:state(squad[1], "global", "lobby"),
				players = sim:state(squad[1], "global", "players"),
			})
			return if ok then text else "?"
		end
		local function fail(message: string)
			local errors = if #sim.errors > 0 then "\nserver errors:\n" .. table.concat(sim.errors, "\n----\n") else ""
			errors ..= "\nstate: " .. describeLobby()
			error(
				string.format(
					"%s seed %d at %.1fs: %s%s\nlast actions:\n%s",
					mission.id,
					seed,
					clock,
					message,
					errors,
					table.concat(log, "\n")
				)
			)
		end

		-- The squad: A leads and stays for the whole soak; B may leave the run; C drops out and rejoins.
		for i, name in { "Ava", "Bo", "Cy" } do
			local bot = sim:addBot(name, 5000 + i)
			sim:snapshot(bot)
			squad[i] = bot
		end
		local a = squad[1]
		if process.env.RN_CHAOS_NO_CLIENT ~= "1" then
			ClientSim.attach(sim, a):start()
		end
		local squadKeys = { ["5001"] = true, ["5002"] = true, ["5003"] = true }
		sim:run(0.6)
		for _, bot in squad do
			sim:send(bot, "ClientReady", "keyboard", "en-us")
			sim:send(bot, "Debug", "give", "all")
			local first = random.pick(roomIds)
			local second = random.pick(roomIds)
			while second == first do
				second = random.pick(roomIds)
			end
			sim:send(bot, "SetLoadout", first, second)
		end
		sim:run(0.3)
		sim:send(a, "SelectMission", mission.id)
		sim:run(0.2)
		if sim:state(a, "global", "lobby.mission") ~= mission.id then
			fail("could not select the mission")
		end

		local function charactersCount(): number
			local count = 0
			for _, player in sim.players do
				if player.Character then
					count += #player.Character:GetDescendants() + 1
				end
			end
			return count
		end
		local baseline = sim:instanceCount() - charactersCount()
		local before: { [any]: boolean } = {}
		for _, inst in sim.workspace:GetDescendants() do
			before[inst] = true
		end

		for _, bot in squad do
			sim:send(bot, "SetReady", true)
		end
		if not sim:runUntil(function()
			return sim:state(a, "global", "run.phase") == "Explore"
		end, 30) then
			fail("the run never launched")
		end
		local level = sim:state(a, "global", "level")
		local socketIds = keysOf(level.sockets)
		local leverIds = keysOf(level.levers)
		local keyIds = keysOf(level.keys)

		-- Interesting places to walk to.
		local points = { level.target.capturePoint, level.exit.cf.Position }
		for _, id in socketIds do
			table.insert(points, level.sockets[id].interactPoint)
		end
		for _, id in leverIds do
			table.insert(points, level.levers[id].cf.Position)
		end
		for _, id in keyIds do
			table.insert(points, level.keys[id])
		end
		for _ = 1, 6 do
			table.insert(points, random.pick(level.tiles).cf.Position)
		end

		local function walkTo(bot, point)
			local position = sim:position(bot)
			if not position then
				return
			end
			local from = tileIndexAt(level, position)
			local to = tileIndexAt(level, point)
			local path = {}
			local step = if to >= from then 1 else -1
			for i = from, to, step do
				table.insert(path, level.tiles[i].cf.Position + V3.new(0, 3, 0))
			end
			table.insert(path, point + V3.new(0, 3, 0))
			sim:walk(bot, path)
		end

		local function anyKey(): string
			return random.pick({ "5001", "5002", "5003", "5004", "0", "abc" })
		end

		-- One random request. `bot` may be in the run, waiting in the lobby or spectating.
		local function act(bot)
			local roll = random.unit()
			local who = bot.name
			if roll < 0.18 then
				walkTo(bot, random.pick(points))
				note(who .. " walks")
			elseif roll < 0.32 then
				local socket = if random.chance(0.85) then random.pick(socketIds) else "S99"
				local slot = random.pick({ 1, 2, 1, 2, 0, 3 })
				local dir = random.pick({ "none", "forward", "across", "sideways" })
				dir = if dir == "none" then nil else dir
				sim:send(bot, "RequestDeploy", socket, slot, dir)
				note(string.format("%s deploy %s slot %d %s", who, socket, slot, tostring(dir)))
			elseif roll < 0.4 then
				local slot = random.pick({ 1, 2, 0, 9 })
				sim:send(bot, "RequestRecall", slot)
				note(who .. " recall " .. slot)
			elseif roll < 0.46 then
				local slot = random.pick({ 0, 1, 2, 7 })
				sim:send(bot, "SelectSlot", slot)
				note(who .. " select " .. slot)
			elseif roll < 0.58 then
				local kind = random.pick({ "capture", "revive", "cargo", "lever", "teleport" })
				local target = if kind == "capture"
					then "target"
					elseif kind == "revive" then anyKey()
					elseif kind == "lever" and #leverIds > 0 then random.pick(leverIds)
					else random.pick({ "cargo", "nope", "target" })
				if random.chance(0.6) then
					sim:send(bot, "HoldBegin", kind, target)
					note(who .. " holdBegin " .. kind .. " " .. target)
				else
					sim:send(bot, "HoldEnd", kind, target, random.chance(0.5))
					note(who .. " holdEnd " .. kind .. " " .. target)
				end
			elseif roll < 0.64 then
				local kind = random.pick({ "lever", "cargo", "key", "crate", "plate" })
				local target = if kind == "lever" and #leverIds > 0
					then random.pick(leverIds)
					elseif kind == "key" and #keyIds > 0 then random.pick(keyIds)
					else "X1"
				sim:send(bot, "Interact", kind, target)
				note(who .. " interact " .. kind .. " " .. target)
			elseif roll < 0.68 then
				sim:send(bot, "DropCargo")
				note(who .. " drop cargo")
			elseif roll < 0.74 then
				local origin = sim:position(bot) or V3.zero
				local position = if random.chance(0.8)
					then origin + V3.new(random.unit() * 20 - 10, 0, random.unit() * 20 - 10)
					else origin + V3.new(5000, 0, 0)
				local kind = random.pick({ "help", "here", "room", "danger", "spam" })
				sim:send(bot, "Ping", kind, position, if kind == "room" then random.pick(socketIds) else nil)
				note(who .. " ping " .. kind)
			elseif roll < 0.84 then
				-- Lobby requests at the wrong time (or the right one, for the late joiner).
				local which = random.int(8)
				if which == 1 then
					sim:send(bot, "SetLoadout", random.pick(roomIds), random.pick(roomIds))
				elseif which == 2 then
					sim:send(bot, "SelectMission", random.pick(Missions.list).id)
				elseif which == 3 then
					sim:send(bot, "SetReady", random.chance(0.5))
				elseif which == 4 then
					sim:send(bot, "BuySkin", random.pick(skinIds))
				elseif which == 5 then
					sim:send(bot, "EquipSkin", random.pick({ "suitcase", random.pick(roomIds) }), random.pick(skinIds))
				elseif which == 6 then
					sim:send(bot, "SaveSettings", { master = random.unit(), reducedMotion = random.chance(0.5) })
				elseif which == 7 then
					local tag = random.pick({ "none", "fun", "confusing", "x" })
					sim:send(bot, "Feedback", random.int(5), if tag == "none" then nil else tag)
				else
					sim:send(bot, "ResultsAction", random.pick({ "lobby", "replay", "bogus" }))
				end
				note(who .. " lobby request " .. which)
			elseif roll < 0.92 then
				-- Malformed payloads: the schema must drop every one of them.
				local which = random.int(6)
				if which == 1 then
					sim:send(bot, "RequestDeploy", 42, "x")
				elseif which == 2 then
					sim:send(bot, "Ping", "help", "not a vector")
				elseif which == 3 then
					sim:send(bot, "HoldBegin", nil, nil)
				elseif which == 4 then
					sim:send(bot, "SaveSettings", "string")
				elseif which == 5 then
					sim:send(bot, "RequestRecall", 1.5)
				else
					sim:send(bot, "SelectSlot", 0 / 0)
				end
				note(who .. " malformed " .. which)
			elseif roll < 0.96 then
				sim:send(bot, "RequestUnstuck")
				note(who .. " unstuck")
			else
				-- Stand still for a moment (lets holds complete and the Caretaker catch up).
				sim:walk(bot, {})
				note(who .. " idles")
			end
		end

		local function phase(): string?
			return sim:state(a, "global", "run.phase")
		end

		local late: any = nil
		local lateRunId: any = nil -- the run that was playing when the late joiner arrived
		local function check()
			if #sim.errors > 0 then
				fail("server or client error")
			end
			for _, warning in sim.warnings do
				if string.find(warning, "[Client]", 1, true) then
					fail("client warning: " .. warning)
				end
			end
			local p = phase()
			if not PHASES[p] then
				fail("unknown phase " .. tostring(p))
			end
			local roster = sim:state(a, "global", "roster") or {}
			local runId = sim:state(a, "global", "run.id")
			for key, entry in roster do
				-- The late joiner may take part in a later run (a random PLAY AGAIN), never in the one they found.
				local lateKey = late ~= nil and key == tostring(late.player.UserId)
				if not squadKeys[key] and not (lateKey and runId ~= lateRunId) then
					fail("outsider " .. key .. " joined the roster of run " .. tostring(runId))
				end
				local hearts = entry.hearts
				if type(hearts) == "number" and (hearts < 0 or hearts > (entry.max or 3)) then
					fail("hearts out of range for " .. key .. ": " .. hearts)
				end
			end
			local perOwner: { [string]: number } = {}
			local total = 0
			for socketId, record in sim:state(a, "global", "sockets") or {} do
				total += 1
				local owner = tostring(record.owner)
				perOwner[owner] = (perOwner[owner] or 0) + 1
				if roster[owner] == nil then
					fail("room in " .. socketId .. " belongs to " .. owner .. ", who is not in the squad")
				end
			end
			if total > GameConfig.Deploy.ActivePerTeam then
				fail("team room cap exceeded: " .. total)
			end
			for owner, count in perOwner do
				if count > GameConfig.Deploy.ActivePerPlayer then
					fail(owner .. " has " .. count .. " rooms")
				end
			end
			local cargo = sim:state(a, "global", "cargo")
			if type(cargo) == "table" and cargo.state == "Carried" then
				local carrier = roster[tostring(cargo.carrier)]
				if not carrier then
					fail("suitcase carried by " .. tostring(cargo.carrier) .. ", who is not in the squad")
				elseif carrier.status ~= nil and carrier.status ~= "Active" then
					fail("suitcase carried by a " .. tostring(carrier.status) .. " player")
				end
			end
			if late and runId == lateRunId and roster[tostring(late.player.UserId)] then
				fail("the late joiner was let into the run in progress")
			end
		end

		-- The soak.
		local connected = { squad[1], squad[2], squad[3] }
		local leftRun = false
		local nextCheck = 1
		while clock < CHAOS_SECONDS do
			if late == nil and clock >= 8 then
				lateRunId = sim:state(a, "global", "run.id")
				late = sim:addBot("Dee", 5004)
				sim:snapshot(late)
				sim:send(late, "ClientReady", "touch", "en-us")
				table.insert(connected, late)
				note("Dee joins mid-run")
			end
			if squad[3] and clock >= 15 and table.find(connected, squad[3]) and not squad[3].rejoined then
				sim:removeBot(squad[3])
				table.remove(connected, table.find(connected, squad[3]) :: number)
				note("Cy drops out")
			end
			if clock >= 25 and not squad[3].rejoined then
				local again = sim:addBot("Cy", 5003)
				again.rejoined = true
				sim:snapshot(again)
				sim:send(again, "ClientReady", "gamepad", "en-us")
				squad[3] = again
				table.insert(connected, again)
				note("Cy rejoins")
			end
			if not leftRun and clock >= 32 and random.chance(0.5) then
				sim:send(squad[2], "LeaveRun")
				leftRun = true
				note("Bo leaves the run")
			end
			for _, bot in connected do
				if random.chance(0.55) then
					act(bot)
				end
			end
			sim:run(STEP)
			clock += STEP
			if clock >= nextCheck then
				nextCheck += 1
				check()
			end
		end

		-- Wind down: everyone stops, nobody is ready, whatever is running ends and the squad returns to the lobby.
		-- (Stopping matters: walking out of the elevator un-readies a player, by design.)
		local function settle(): boolean
			for _, bot in connected do
				sim:walk(bot, {})
			end
			local waited = 0
			while waited < 150 do
				local p = phase()
				for _, bot in connected do
					sim:send(bot, "SetReady", false)
				end
				if p == "Prep" then
					sim:run(1)
					waited += 1
					local lobby = sim:state(a, "global", "lobby") or {}
					if phase() == "Prep" and lobby.countdownEndsAt == nil then
						return true
					end
				else
					if IN_RUN[p] and p ~= "Launching" then
						sim:send(a, "Debug", "phase", "fail")
					elseif p == "Results" then
						for _, bot in connected do
							sim:send(bot, "ResultsAction", "lobby")
						end
					end
					sim:run(0.5)
					waited += 0.5
				end
				clock += 0.5
				check()
			end
			return false
		end
		note("settling")
		if not settle() then
			fail("the server never returned to a quiet Prep (phase " .. tostring(phase()) .. ")")
		end
		check()
		if sim:state(a, "global", "level") ~= nil then
			fail("the level is still published in Prep")
		end
		if next(sim:state(a, "global", "sockets") or {}) ~= nil then
			fail("rooms are still deployed in Prep")
		end
		-- One-shot sounds clean up when they end or, failing that, after a 30 s safety net (sounds never "end"
		-- in the headless engine): let that pass so only real leftovers count.
		sim:run(31)
		local leftovers = sim:instanceCount() - charactersCount()
		if leftovers > baseline + 5 then
			local added = {}
			for _, inst in sim.workspace:GetDescendants() do
				local character = inst:FindFirstAncestorOfClass("Model")
				local isCharacter = false
				while character do
					if character:FindFirstChildOfClass("Humanoid") then
						isCharacter = true
						break
					end
					character = character.Parent and character.Parent:FindFirstAncestorOfClass("Model")
				end
				if not before[inst] and not isCharacter and #added < 30 then
					table.insert(added, inst:GetFullName() .. " (" .. inst.ClassName .. ")")
				end
			end
			fail(
				string.format("instance count grew from %d to %d:\n%s", baseline, leftovers, table.concat(added, "\n"))
			)
		end

		-- The next run launches and ends normally (after the lobby rate limits refill).
		sim:run(4)
		for _, bot in connected do
			sim:send(bot, "SetReady", true)
		end
		if not sim:runUntil(function()
			return phase() == "Explore"
		end, 40) then
			fail("the next run never launched")
		end
		sim:send(a, "Debug", "phase", "win")
		if not sim:runUntil(function()
			return phase() == "Results"
		end, 10) then
			fail("the next run did not end")
		end
		check()
		expect(#sim.errors).toBe(0)
	end

	describe("Chaos soak (S19/S20/S27/R06/R13)", function()
		if process.env.RN_SKIP_CHAOS == "1" then
			return
		end
		local seeds = math.max(1, tonumber(process.env.RN_CHAOS_SEEDS) or 1)
		for index, mission in Missions.list do
			for s = 1, seeds do
				local seed = 7919 * index + 104729 * (s - 1)
				it(string.format("%s survives a random squad (seed %d)", mission.id, seed), function()
					soak(mission, seed)
				end)
			end
		end
	end)
end
