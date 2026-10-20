--[[
	Layout solvability (S10, S11, S18, S31, R06-R10).

	Every mission layout ships authored `solutions`: scripted SOLO playthroughs (deploy / recall / pull a lever /
	cross an obstacle / capture / escape). This spec replays each step against the real builder runtime and the
	real rules:
	  * the route is split into regions by its obstacles; a socket or lever can only be used from the region
	    the player stands in (sockets on a floor hazard tile are reachable from both sides);
	  * rooms obey the loadout, one instance per slot and the per-player cap; recall works from anywhere;
	  * water / cold / vine / power states come from the real EffectModel; wind lanes, crate rails, slots,
	    magnets, plates and gates mirror the server's maths; slotted crates stay slotted;
	  * every crossing must be valid in the current state and direction (launches only go outward);
	  * keys are picked up where the player actually walks; alcove keys need their gate open;
	  * combos are detected the way the server awards them.
	Then the mission rules: a starter-only (Freezer + Fan) solution exists, two solutions differ, every
	challenge is achievable and the escape fits the window.
]]

return function(ctx)
	local Spec = ctx.Spec
	local describe, it, expect = Spec.describe, Spec.it, Spec.expect

	local Layouts = ctx.module("ReplicatedStorage.Shared.Content.Layouts")
	local LevelBuilder = ctx.module("ReplicatedStorage.Shared.World.LevelBuilder")
	local EffectModel = ctx.module("ReplicatedStorage.Shared.Logic.EffectModel")
	local GameConfig = ctx.module("ReplicatedStorage.Shared.Config.GameConfig")
	local RoomDefs = ctx.module("ReplicatedStorage.Shared.Config.RoomDefs")
	local Missions = ctx.module("ReplicatedStorage.Shared.Config.MissionDefs")
	local MathUtil = ctx.module("ReplicatedStorage.Shared.Util.MathUtil")
	local CF = ctx.roblox.CFrame
	local V3 = ctx.roblox.Vector3

	local STARTERS = { Freezer = true, Fan = true }
	local SLOW = { ledge = true, beam = true, walkway = true }
	local KEY_RADIUS = 4.2

	-- Route analysis ----------------------------------------------------------------------------------------

	type Analysis = {
		layout: any,
		rt: any,
		obstacles: { string },
		obstacleIndex: { [string]: number },
		tileRegions: { [number]: { number } },
		obstacleTiles: { [string]: { number } },
		keyInfo: { [string]: any },
	}

	local cache: { [string]: Analysis } = {}

	local function tileOf(rt, moduleIndex: number, offset: number): number
		for _, tile in rt.tiles do
			if tile.module == moduleIndex and tile.offset == offset then
				return tile.index
			end
		end
		error("no tile for module " .. moduleIndex .. " offset " .. offset)
	end

	local function analyse(layout): Analysis
		local cached = cache[layout.id]
		if cached then
			return cached
		end
		local rt = LevelBuilder.build(layout).runtime
		local obstacles, obstacleIndex, moduleObstacle = {}, {}, {}
		local regionBefore = {}
		for index, mod in layout.modules do
			regionBefore[index] = #obstacles
			local kind = mod.kind
			if
				kind == "Basin"
				or kind == "Gap"
				or kind == "Fire"
				or kind == "Carts"
				or (kind == "Puddle" and mod.power)
			then
				assert(mod.id, layout.id .. ": obstacle module " .. index .. " needs an id")
				table.insert(obstacles, mod.id)
				obstacleIndex[mod.id] = #obstacles
				moduleObstacle[index] = #obstacles
			end
		end
		local tileRegions, obstacleTiles = {}, {}
		for _, tile in rt.tiles do
			local k = moduleObstacle[tile.module]
			if k then
				tileRegions[tile.index] = { k - 1, k }
				local id = layout.modules[tile.module].id
				obstacleTiles[id] = obstacleTiles[id] or {}
				table.insert(obstacleTiles[id], tile.index)
			else
				tileRegions[tile.index] = { regionBefore[tile.module] }
			end
		end
		-- Keys: where they are and how they can be picked up.
		local keyInfo = {}
		for moduleIndex, mod in layout.modules do
			for _, key in mod.keys or {} do
				local info: any = { id = key.id }
				if key.alcove then
					for alcoveModule, other in layout.modules do
						for _, alcove in other.alcoves or {} do
							if alcove.id == key.alcove then
								info.tile = tileOf(rt, alcoveModule, alcove.at or 1)
								info.gate = alcove.gate
							end
						end
					end
					assert(info.tile, layout.id .. ": key " .. key.id .. " names unknown alcove " .. key.alcove)
				else
					info.tile = tileOf(rt, moduleIndex, key.at or 1)
					local k = moduleObstacle[moduleIndex]
					if k then
						info.obstacle = mod.id
					end
				end
				info.regions = tileRegions[info.tile]
				keyInfo[key.id] = info
			end
		end
		local analysis: Analysis = {
			layout = layout,
			rt = rt,
			obstacles = obstacles,
			obstacleIndex = obstacleIndex,
			tileRegions = tileRegions,
			obstacleTiles = obstacleTiles,
			keyInfo = keyInfo,
		}
		cache[layout.id] = analysis
		return analysis
	end

	-- World rules ------------------------------------------------------------------------------------------------

	type Placed = { room: string, dir: string? }
	type State = {
		region: number,
		rooms: { [string]: Placed },
		levers: { [string]: boolean },
		crates: { [string]: { offset: number, slotted: boolean } },
		keys: { [string]: boolean },
		combos: { [string]: boolean },
		captured: boolean,
		escaped: boolean,
		backSlow: number,
		stepsAfterCapture: number,
	}

	local function laneFor(rt, socketId: string, placed: Placed)
		local socket = rt.sockets[socketId]
		local laneId = socket.lanes[placed.dir or socket.defaultDir]
		return if laneId then rt.lanes[laneId] else nil
	end

	-- Mirrors HazardService.crateTargetVelocity.
	local function crateVelocity(rt, state: State, crateId: string, position): number
		local crate = rt.crates[crateId]
		local axis = crate.railCF.XVector
		local wind = 0
		local socketIds = {}
		for socketId in state.rooms do
			table.insert(socketIds, socketId)
		end
		table.sort(socketIds)
		for _, socketId in socketIds do
			local placed = state.rooms[socketId]
			if placed.room == "Fan" then
				local lane = laneFor(rt, socketId, placed)
				if lane and lane.dir ~= "Across" and MathUtil.pointInBox(lane.cf, lane.size, position, 0.5) then
					local along = lane.vector:Dot(axis)
					if math.abs(along) > 0.9 then
						wind = GameConfig.Wind.CratePushSpeed * math.sign(along)
						break
					end
				end
			end
		end
		local magnet = 0
		if crate.metal then
			for _, socketId in socketIds do
				local placed = state.rooms[socketId]
				local socket = rt.sockets[socketId]
				if placed.room == "Magnet" and socket.links.magnet and table.find(socket.links.magnet, crateId) then
					local toAnchor = (socket.doorCF.Position - position):Dot(axis)
					if math.abs(toAnchor) > 3.2 then
						magnet = GameConfig.Magnet.PullSpeed * math.sign(toAnchor)
					end
					break
				end
			end
		end
		if magnet ~= 0 and wind ~= 0 then
			return math.clamp(wind + magnet, -GameConfig.Magnet.MaxCombinedSpeed, GameConfig.Magnet.MaxCombinedSpeed)
				* 0.5
		end
		return wind + magnet
	end

	local function cratePosition(rt, crateId: string, offset: number)
		return (rt.crates[crateId].railCF * CF.new(offset, 0, 0)).Position
	end

	-- Let every loose crate move for up to a minute under the current rooms.
	local function settleCrates(rt, state: State)
		for crateId, crate in rt.crates do
			local c = state.crates[crateId]
			if not c.slotted then
				local half = crate.railLength / 2
				local dt = 0.05
				for _ = 1, 1200 do
					local velocity = crateVelocity(rt, state, crateId, cratePosition(rt, crateId, c.offset))
					if math.abs(velocity) < 1e-3 then
						break
					end
					local nextOffset = math.clamp(c.offset + velocity * dt, -half, half)
					local slot = crate.slotOffset
					if
						slot
						and (
							(c.offset < slot and nextOffset >= slot)
							or (c.offset > slot and nextOffset <= slot)
							or math.abs(nextOffset - slot) < 0.05
						)
					then
						c.slotted = true
						state.combos.crate_bridge = true
						break
					end
					if nextOffset == c.offset then
						break
					end
					c.offset = nextOffset
				end
			end
		end
	end

	local function pressedPlates(rt, state: State): { [string]: boolean }
		local pressed = {}
		for crateId, c in state.crates do
			if not c.slotted then
				local p = cratePosition(rt, crateId, c.offset)
				for plateId, plate in rt.plates do
					local d = V3.new(p.X - plate.cf.Position.X, 0, p.Z - plate.cf.Position.Z).Magnitude
					if d <= plate.radius then
						pressed[plateId] = true
					end
				end
			end
		end
		return pressed
	end

	local function effects(rt, state: State)
		local model = EffectModel.new(rt.effectDefs, GameConfig.Effects, 0)
		local sources = {}
		for socketId, placed in state.rooms do
			sources[socketId] = RoomDefs.byId[placed.room].effect
		end
		model:setSources(sources)
		for leverId, flipped in state.levers do
			if flipped then
				model:setLever(leverId, true)
			end
		end
		for plateId in pressedPlates(rt, state) do
			model:setPlate(plateId, true)
		end
		for _ = 1, 300 do
			model:step(0.1)
		end
		return model
	end

	local function anyElectrified(rt, model): boolean
		for basinId in rt.basins do
			if model:basinElectrified(basinId) then
				return true
			end
		end
		return false
	end

	-- Combos that follow from a state change (before -> after), mirroring EffectService / HazardService.
	local function noteCombos(rt, state: State, before, after, cause: string)
		for fireId, fire in rt.fires do
			if before:firePhase(fireId) == "Burning" and after:firePhase(fireId) == "Out" then
				if #after:sourcesFor(fire.pool, "water") > 0 then
					state.combos.extinguish = true
				end
			end
		end
		for basinId in rt.basins do
			if
				before:basinElectrified(basinId)
				and not after:basinElectrified(basinId)
				and after:basinSolid(basinId)
			then
				state.combos.frozen_safe = true
			end
		end
		for vineId in rt.vines do
			if not before:vineSolid(vineId) and after:vineSolid(vineId) then
				state.combos.vine_bridge = true
			end
		end
		if cause == "lever" and anyElectrified(rt, before) and not anyElectrified(rt, after) then
			state.combos.power_off = true
		end
	end

	local function noteCartCombos(rt, state: State, socketId: string, placed: Placed)
		for cartId, cart in rt.carts do
			if placed.room == "Fan" then
				local lane = laneFor(rt, socketId, placed)
				if
					lane
					and lane.dir == "Across"
					and MathUtil.pointInBox(lane.cf, lane.size, cart.tileCF.Position + V3.new(0, 3, 0), 0.5)
				then
					state.combos.cart_pin = true
				end
			elseif placed.room == "Freezer" then
				local cold = rt.sockets[socketId].links.cold
				if cold and table.find(cold, cartId) then
					state.combos.cart_freeze = true
				end
			end
		end
	end

	local function contains(list: { number }, value: number): boolean
		return table.find(list, value) ~= nil
	end

	local function nearBox(b, position, radius: number): boolean
		local closest = MathUtil.closestPointInBox(b.cf, b.size, position)
		return (closest - position).Magnitude <= radius
	end

	-- Pick up keys the player can now reach in their region.
	local function collectRegionKeys(a: Analysis, state: State, model)
		for keyId, info in a.keyInfo do
			if not state.keys[keyId] and not info.obstacle and contains(info.regions, state.region) then
				if info.gate then
					if model:gateOpen(info.gate) then
						state.keys[keyId] = true
					end
				else
					state.keys[keyId] = true
				end
			end
		end
	end

	-- Keys hanging over an obstacle are picked up while crossing it on a surface that passes close enough.
	local function collectCrossingKeys(a: Analysis, state: State, zone: string, by: string)
		local rt = a.rt
		for keyId, info in a.keyInfo do
			if not state.keys[keyId] and info.obstacle == zone then
				local position = rt.keys[keyId].position
				local got = false
				local mod
				for _, m in a.layout.modules do
					if m.id == zone then
						mod = m
					end
				end
				if SLOW[by] then
					for _, b in rt.ledges do
						if nearBox(b, position, KEY_RADIUS - 0.5) then
							got = true
						end
					end
				elseif by == "ice" then
					got = nearBox(rt.basins[zone].occupancy, position, KEY_RADIUS - 0.5)
				elseif by == "crate" then
					local slot = rt.crates[mod.slot].slotCF.Position
					got = (slot + V3.new(0, 3.4, 0) - position).Magnitude <= KEY_RADIUS
				elseif by == "vine" then
					got = nearBox(rt.vines[mod.vine].bridge, position, KEY_RADIUS - 0.5)
				elseif by ~= "launch" and (mod.kind == "Fire" or mod.kind == "Puddle" or mod.kind == "Carts") then
					got = true
				end
				if got then
					state.keys[keyId] = true
				end
			end
		end
	end

	-- Playthrough ---------------------------------------------------------------------------------------------

	local function play(a: Analysis, solution): State
		local layout, rt = a.layout, a.rt
		local state: State = {
			region = 0,
			rooms = {},
			levers = {},
			crates = {},
			keys = {},
			combos = {},
			captured = false,
			escaped = false,
			backSlow = 0,
			stepsAfterCapture = 0,
		}
		for crateId, crate in rt.crates do
			state.crates[crateId] = { offset = crate.startOffset, slotted = false }
		end
		local owned: { [string]: number } = {}
		for _, room in solution.loadout do
			owned[room] = (owned[room] or 0) + 1
		end
		if #solution.loadout > GameConfig.Loadout.Slots then
			error(solution.name .. ": a solo loadout holds " .. GameConfig.Loadout.Slots .. " rooms")
		end
		local model = effects(rt, state)
		collectRegionKeys(a, state, model)

		for stepIndex, step in solution.steps do
			local function bad(message: string)
				error(string.format("%s / %s / step %d: %s", layout.id, solution.name, stepIndex, message))
			end
			if state.captured then
				state.stepsAfterCapture += 1
			end
			if step.deploy then
				local socketId = step.deploy
				local room = step.room
				local socket = rt.sockets[socketId]
				if not socket then
					bad("unknown socket " .. socketId)
				end
				if not room or not RoomDefs.byId[room] then
					bad("deploy needs a known room")
				end
				local deployed = 0
				local active = 0
				for _, placed in state.rooms do
					active += 1
					if placed.room == room then
						deployed += 1
					end
				end
				if deployed >= (owned[room :: string] or 0) then
					bad((room :: string) .. " is not in the loadout or already unfolded")
				end
				if active >= GameConfig.Deploy.ActivePerPlayer then
					bad("player cap reached")
				end
				if state.rooms[socketId] then
					bad("socket " .. socketId .. " is occupied")
				end
				if not contains(a.tileRegions[socket.tile], state.region) then
					bad("socket " .. socketId .. " is not reachable from region " .. state.region)
				end
				local def = RoomDefs.byId[room :: string]
				local dir = step.dir
				if def.directional then
					dir = dir or socket.defaultDir
					if not socket.lanes[dir :: string] then
						bad("socket " .. socketId .. " has no " .. tostring(dir) .. " lane")
					end
				elseif dir then
					bad((room :: string) .. " has no direction")
				end
				local placed: Placed = { room = room :: string, dir = dir }
				state.rooms[socketId] = placed
				settleCrates(rt, state)
				if next(pressedPlates(rt, state)) then
					state.combos.crate_plate = true
				end
				local after = effects(rt, state)
				noteCombos(rt, state, model, after, "deploy")
				noteCartCombos(rt, state, socketId, placed)
				model = after
			elseif step.recall then
				local found = nil
				for socketId, placed in state.rooms do
					if placed.room == step.recall then
						found = socketId
					end
				end
				if not found then
					bad("no unfolded " .. step.recall .. " to recall")
				end
				state.rooms[found :: string] = nil
				settleCrates(rt, state)
				if next(pressedPlates(rt, state)) then
					state.combos.crate_plate = true
				end
				local after = effects(rt, state)
				noteCombos(rt, state, model, after, "recall")
				model = after
			elseif step.pull then
				local lever = rt.levers[step.pull]
				if not lever then
					bad("unknown lever " .. step.pull)
				end
				if not contains(a.tileRegions[lever.tile], state.region) then
					bad("lever " .. step.pull .. " is not reachable from region " .. state.region)
				end
				state.levers[step.pull] = not state.levers[step.pull]
				local after = effects(rt, state)
				noteCombos(rt, state, model, after, "lever")
				model = after
			elseif step.cross then
				local zone = step.cross
				local k = a.obstacleIndex[zone]
				if not k then
					bad("unknown obstacle " .. zone)
				end
				local way
				if state.region == k - 1 then
					way = "out"
				elseif state.region == k then
					way = "back"
				else
					bad("obstacle " .. zone .. " is not next to region " .. state.region)
				end
				local mod
				for _, m in layout.modules do
					if m.id == zone then
						mod = m
					end
				end
				local by = step.by
				if by == "ice" then
					if not model:basinSolid(zone) then
						bad(zone .. " is not frozen (" .. tostring(model:basinPhase(zone)) .. ")")
					end
					if mod.kind == "Basin" then
						state.combos.ice_bridge = true
					end
				elseif by == "ledge" then
					if not mod.ledge or (mod.kind ~= "Basin" and mod.kind ~= "Gap") then
						bad(zone .. " has no ledge")
					end
				elseif by == "beam" then
					if not mod.beam or mod.kind ~= "Gap" then
						bad(zone .. " has no beam")
					end
				elseif by == "walkway" then
					if not mod.ledge or mod.kind ~= "Fire" then
						bad(zone .. " has no SAFE WAY walkway")
					end
				elseif by == "douse" then
					if mod.kind ~= "Fire" or model:firePhase(zone) ~= "Out" then
						bad(zone .. " is still " .. tostring(model:firePhase(zone)))
					end
				elseif by == "power" then
					if mod.kind ~= "Puddle" then
						bad("power crossings are for live puddles")
					end
					if model:basinElectrified(zone) then
						bad(zone .. " is still live")
					end
				elseif by == "launch" then
					if way ~= "out" then
						bad("launches only work outward")
					end
					local launchId = zone .. "_launch"
					local launch = rt.launches[launchId]
					if not launch then
						bad(zone .. " has no launch ramp")
					end
					if not model:basinSolid(launch.basin) then
						bad("feeding basin " .. tostring(launch.basin) .. " is not frozen")
					end
					local boosted = false
					for socketId, placed in state.rooms do
						if placed.room == "Fan" then
							local lane = laneFor(rt, socketId, placed)
							if lane and table.find(lane.slides, launchId) then
								boosted = true
							end
						end
					end
					if not boosted then
						bad("no Fan lane boosts the slide into " .. zone)
					end
					state.combos.ice_launch = true
				elseif by == "crate" then
					if mod.kind ~= "Gap" or not mod.slot or not state.crates[mod.slot].slotted then
						bad("no crate sits in the slot of " .. zone)
					end
				elseif by == "vine" then
					if mod.kind ~= "Gap" or not mod.vine or not model:vineSolid(mod.vine) then
						bad("no grown vine bridges " .. zone)
					end
				elseif by == "pin" then
					local cart = rt.carts[zone]
					local pinned = false
					for socketId, placed in state.rooms do
						if placed.room == "Fan" then
							local lane = laneFor(rt, socketId, placed)
							if
								lane
								and lane.dir == "Across"
								and MathUtil.pointInBox(lane.cf, lane.size, cart.tileCF.Position + V3.new(0, 3, 0), 0.5)
							then
								pinned = true
							end
						end
					end
					if not pinned then
						bad("no Fan blows across " .. zone)
					end
				elseif by == "slow" then
					local chilled = false
					for socketId, placed in state.rooms do
						local cold = rt.sockets[socketId].links.cold
						if placed.room == "Freezer" and cold and table.find(cold, zone) then
							chilled = true
						end
					end
					if not chilled then
						bad("no Freezer chills " .. zone)
					end
				elseif by == "timing" then
					if mod.kind ~= "Carts" then
						bad("only cart tracks can be timed")
					end
				else
					bad("unknown method " .. tostring(by))
				end
				if way == "back" and SLOW[by :: string] then
					state.backSlow += 1
				end
				collectCrossingKeys(a, state, zone, by :: string)
				state.region = if way == "out" then k else k - 1
			elseif step.capture then
				if state.region ~= #a.obstacles then
					bad("the target room is not reachable from region " .. state.region)
				end
				state.captured = true
			elseif step.escape then
				if not state.captured then
					bad("escaping without the suitcase")
				end
				if state.region ~= 0 then
					bad("the elevator is not reachable from region " .. state.region)
				end
				state.escaped = true
			else
				bad("empty step")
			end
			collectRegionKeys(a, state, model)
		end
		if not state.escaped then
			error(layout.id .. " / " .. solution.name .. ": the playthrough never escapes")
		end
		for _, combo in solution.combos or {} do
			if not state.combos[combo] then
				error(layout.id .. " / " .. solution.name .. ": documented combo " .. combo .. " never happens")
			end
		end
		for _, keyId in solution.keys or {} do
			if not state.keys[keyId] then
				error(layout.id .. " / " .. solution.name .. ": documented key " .. keyId .. " is never collected")
			end
		end
		return state
	end

	local function starterOnly(solution): boolean
		for _, room in solution.loadout do
			if not STARTERS[room] then
				return false
			end
		end
		return true
	end

	-- Specs ------------------------------------------------------------------------------------------------------

	local missionsByLayout = {}
	for _, mission in Missions.list do
		missionsByLayout[mission.layoutId] = mission
	end

	local ids = {}
	for id in Layouts do
		table.insert(ids, id)
	end
	table.sort(ids)

	describe("Layout solutions (S10/S31/R06-R10)", function()
		for _, id in ids do
			local layout = Layouts[id]
			local mission = missionsByLayout[id]
			if layout.tutorial or not mission then
				continue
			end

			it(id .. " every authored solo playthrough completes", function()
				local a = analyse(layout)
				local solutions = layout.solutions or {}
				expect(#solutions >= 2).toBe(true)
				for _, solution in solutions do
					play(a, solution)
				end
			end)

			it(id .. " has a starter-only solution and a genuinely different alternative", function()
				local a = analyse(layout)
				local solutions = layout.solutions or {}
				local hasStarter = false
				local methods = {}
				for i, solution in solutions do
					if starterOnly(solution) then
						hasStarter = true
					end
					methods[i] = {}
					local region = 0
					for _, step in solution.steps do
						if step.cross then
							local k = a.obstacleIndex[step.cross]
							local way = if region == k - 1 then "out" else "back"
							methods[i][step.cross .. way] = step.by
							region = if way == "out" then k else k - 1
						end
					end
				end
				if not hasStarter then
					error(id .. " has no solution that only needs Freezer + Fan")
				end
				local different = false
				for i = 1, #solutions do
					for j = i + 1, #solutions do
						for key, by in methods[i] do
							if methods[j][key] and methods[j][key] ~= by then
								different = true
							end
						end
					end
				end
				expect(different).toBe(true)
			end)

			it(id .. " mission challenges are achievable", function()
				local a = analyse(layout)
				local results = {}
				for i, solution in layout.solutions or {} do
					results[i] = play(a, solution)
				end
				for _, challenge in mission.challenges do
					if challenge.kind == "combo" then
						local done = false
						for _, state in results do
							if state.combos[challenge.combo] then
								done = true
							end
						end
						if not done then
							error(id .. ": no playthrough performs the " .. tostring(challenge.combo) .. " combo")
						end
					elseif challenge.kind == "allKeys" then
						local done = false
						for i, solution in layout.solutions or {} do
							if starterOnly(solution) then
								local all = true
								for keyId in a.rt.keys do
									if not results[i].keys[keyId] then
										all = false
									end
								end
								if all then
									done = true
								end
							end
						end
						if not done then
							error(id .. ": no starter playthrough collects every key")
						end
					elseif challenge.kind == "timeLeft" then
						local best = math.huge
						local carrier = GameConfig.Movement.WalkSpeed * GameConfig.Cargo.CarrierSpeedMultiplier
						for _, state in results do
							local seconds = #a.rt.tiles * 16 / carrier
								+ state.backSlow * (16 / (carrier * GameConfig.Movement.LedgeSpeedMultiplier) - 16 / carrier)
								+ state.stepsAfterCapture * 1.5
							best = math.min(best, seconds)
						end
						local budget = GameConfig.Escape.WindowSeconds - (challenge.value or 0) - 10
						if best > budget then
							error(
								string.format(
									"%s: best escape ~%.0fs leaves no room for %ss",
									id,
									best,
									tostring(challenge.value)
								)
							)
						end
					end
				end
			end)

			it(id .. " escape fits comfortably in the window for every playthrough", function()
				local a = analyse(layout)
				local carrier = GameConfig.Movement.WalkSpeed * GameConfig.Cargo.CarrierSpeedMultiplier
				for _, solution in layout.solutions or {} do
					local state = play(a, solution)
					local seconds = #a.rt.tiles * 16 / carrier
						+ state.backSlow * (16 / (carrier * GameConfig.Movement.LedgeSpeedMultiplier) - 16 / carrier)
						+ state.stepsAfterCapture * 1.5
					if seconds > GameConfig.Escape.WindowSeconds * 0.6 then
						error(
							string.format(
								"%s / %s: escape takes ~%.0fs of %ds",
								id,
								solution.name,
								seconds,
								GameConfig.Escape.WindowSeconds
							)
						)
					end
				end
			end)
		end
	end)
end
