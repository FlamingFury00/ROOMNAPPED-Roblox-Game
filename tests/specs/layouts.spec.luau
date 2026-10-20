--[[
	Layout solvability (S10, S11, S18, S31, R07-R10).

	Every layout ships authored `solutions`: how a squad (by default one solo player) crosses every obstacle on
	the way to the target AND back to the elevator. This spec replays each crossing against the real builder
	runtime and the real EffectModel - water/cold/vine/power states, wind lanes, crate rails, slots, plates and
	gates - so a layout edit that silently breaks a solution fails the build.

	Guarantees checked per layout:
	  * every obstacle is crossable in both directions by every solution (launches are out-only);
	  * a solution exists that needs only the starter rooms (Freezer + Fan) for a solo player;
	  * at least two genuinely different solutions exist (S31);
	  * room usage respects loadouts, one instance per slot and the per-player / team caps (R06);
	  * mission challenges are achievable (combos actually happen, keys behind gates actually open);
	  * the escape route fits the escape window with room to spare for timeLeft challenges.
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
	local SLOW_METHODS = { ledge = true, beam = true, walkway = true }
	local KEY_RADIUS = 4.2

	local builtCache = {}
	local function build(layout)
		local cached = builtCache[layout.id]
		if not cached then
			cached = LevelBuilder.build(layout)
			builtCache[layout.id] = cached
		end
		return cached.runtime
	end

	local function parseRoom(spec: string): (string, string?)
		local room, dir = string.match(spec, "^(%a+):(%a+)$")
		if room then
			return room, dir
		end
		return spec, nil
	end

	local function moduleById(layout, id)
		for index, mod in layout.modules do
			if mod.id == id then
				return mod, index
			end
		end
		return nil, nil
	end

	-- Obstacles: every pit, fire, powered puddle and cart track on the route.
	local function obstacles(layout): { string }
		local out = {}
		for _, mod in layout.modules do
			local kind = mod.kind
			if kind == "Basin" or kind == "Gap" or kind == "Fire" or kind == "Carts" then
				assert(mod.id, "obstacle module without id in " .. layout.id)
				table.insert(out, mod.id)
			elseif kind == "Puddle" and mod.power then
				assert(mod.id, "powered puddle without id in " .. layout.id)
				table.insert(out, mod.id)
			end
		end
		return out
	end

	local function fail(layout, solution, crossing, message)
		error(
			string.format(
				"%s / %s / %s(%s): %s",
				layout.id,
				solution.name,
				tostring(crossing and crossing.zone),
				tostring(crossing and crossing.by),
				message
			)
		)
	end

	-- Crates ------------------------------------------------------------------------------------------------

	-- Mirrors HazardService.crateTargetVelocity: wind along parallel lanes, magnets toward their door.
	local function crateVelocity(rt, crateId, rooms, position)
		local crate = rt.crates[crateId]
		local axis = crate.railCF.XVector
		local wind = 0
		for socketId, spec in rooms do
			local room, dir = parseRoom(spec)
			if room == "Fan" then
				local socket = rt.sockets[socketId]
				local laneId = socket.lanes[dir or socket.defaultDir]
				local lane = laneId and rt.lanes[laneId]
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
			for socketId, spec in rooms do
				local room = parseRoom(spec)
				local socket = rt.sockets[socketId]
				if room == "Magnet" and socket.links.magnet and table.find(socket.links.magnet, crateId) then
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

	-- Moves a crate along its rail under `rooms` for up to 60 s. Returns (slotted, final position).
	local function simulateCrate(rt, crateId, rooms)
		local crate = rt.crates[crateId]
		local half = crate.railLength / 2
		local offset = crate.startOffset
		local dt = 0.05
		for _ = 1, 1200 do
			local position = (crate.railCF * CF.new(offset, 0, 0)).Position
			local velocity = crateVelocity(rt, crateId, rooms, position)
			if math.abs(velocity) < 1e-3 then
				break
			end
			local nextOffset = math.clamp(offset + velocity * dt, -half, half)
			local slot = crate.slotOffset
			if
				slot
				and (
					(offset < slot and nextOffset >= slot)
					or (offset > slot and nextOffset <= slot)
					or math.abs(nextOffset - slot) < 0.05
				)
			then
				return true, crate.slotCF.Position
			end
			if nextOffset == offset then
				break
			end
			offset = nextOffset
		end
		return false, (crate.railCF * CF.new(offset, 0, 0)).Position
	end

	local function pressedPlates(rt, rooms)
		local pressed = {}
		for crateId in rt.crates do
			local slotted, position = simulateCrate(rt, crateId, rooms)
			if not slotted then
				for plateId, plate in rt.plates do
					local d = V3.new(position.X - plate.cf.Position.X, 0, position.Z - plate.cf.Position.Z).Magnitude
					if d <= plate.radius then
						pressed[plateId] = true
					end
				end
			end
		end
		return pressed
	end

	-- Effect state ---------------------------------------------------------------------------------------------

	local function settle(rt, rooms, levers)
		local model = EffectModel.new(rt.effectDefs, GameConfig.Effects, 0)
		local sources = {}
		for socketId, spec in rooms do
			local room = parseRoom(spec)
			sources[socketId] = RoomDefs.byId[room].effect
		end
		model:setSources(sources)
		for _, lever in levers do
			model:setLever(lever, true)
		end
		for plateId in pressedPlates(rt, rooms) do
			model:setPlate(plateId, true)
		end
		for _ = 1, 300 do
			model:step(0.1)
		end
		return model
	end

	-- Crossing checks -------------------------------------------------------------------------------------------

	local function activeFanLane(rt, rooms, wantDir)
		local lanes = {}
		for socketId, spec in rooms do
			local room, dir = parseRoom(spec)
			if room == "Fan" then
				local socket = rt.sockets[socketId]
				local d = dir or socket.defaultDir
				if wantDir == nil or d == wantDir then
					local laneId = socket.lanes[d]
					if laneId then
						table.insert(lanes, rt.lanes[laneId])
					end
				end
			end
		end
		return lanes
	end

	local function checkCrossing(layout, rt, solution, crossing)
		local mod, index = moduleById(layout, crossing.zone)
		if not mod then
			fail(layout, solution, crossing, "unknown zone")
		end
		local rooms = crossing.rooms or {}
		local levers = crossing.levers or {}
		-- Rooms must exist in the loadout, sit in real sockets and respect slots and caps.
		local used = {}
		local count = 0
		for socketId, spec in rooms do
			local room, dir = parseRoom(spec)
			local socket = rt.sockets[socketId]
			if not socket then
				fail(layout, solution, crossing, "unknown socket " .. socketId)
			end
			if not RoomDefs.byId[room] then
				fail(layout, solution, crossing, "unknown room " .. room)
			end
			if dir and not socket.lanes[dir] then
				fail(layout, solution, crossing, "socket " .. socketId .. " has no " .. dir .. " lane")
			end
			used[room] = (used[room] or 0) + 1
			count += 1
		end
		local owned = {}
		for _, room in solution.loadout do
			owned[room] = (owned[room] or 0) + 1
		end
		for room, n in used do
			if (owned[room] or 0) < n then
				fail(
					layout,
					solution,
					crossing,
					"needs " .. n .. "x " .. room .. " but the loadout has " .. (owned[room] or 0)
				)
			end
		end
		local players = math.max(1, math.ceil(#solution.loadout / GameConfig.Loadout.Slots))
		if count > math.min(players * GameConfig.Deploy.ActivePerPlayer, GameConfig.Deploy.ActivePerTeam) then
			fail(layout, solution, crossing, "too many active rooms")
		end
		for _, lever in levers do
			if not rt.levers[lever] then
				fail(layout, solution, crossing, "unknown lever " .. lever)
			end
		end

		local by = crossing.by
		local model = settle(rt, rooms, levers)
		local zone = crossing.zone
		if by == "ice" then
			if not model:basinSolid(zone) then
				fail(
					layout,
					solution,
					crossing,
					"basin is not frozen (phase " .. tostring(model:basinPhase(zone)) .. ")"
				)
			end
		elseif by == "ledge" then
			if not mod.ledge or (mod.kind ~= "Basin" and mod.kind ~= "Gap") then
				fail(layout, solution, crossing, "no ledge on this pit")
			end
		elseif by == "beam" then
			if not mod.beam or mod.kind ~= "Gap" then
				fail(layout, solution, crossing, "no beam on this gap")
			end
		elseif by == "walkway" then
			if not mod.ledge or mod.kind ~= "Fire" then
				fail(layout, solution, crossing, "no walkway on this fire")
			end
		elseif by == "douse" then
			if model:firePhase(zone) ~= "Out" then
				fail(layout, solution, crossing, "fire still " .. tostring(model:firePhase(zone)))
			end
		elseif by == "power" or by == "walk" then
			local basinId = if mod.kind == "Fire" then zone .. "_pool" else zone
			if model:basinElectrified(basinId) then
				fail(layout, solution, crossing, "zone is still electrified")
			end
			if mod.kind == "Basin" and by == "walk" then
				fail(layout, solution, crossing, "deep basins cannot be walked")
			end
		elseif by == "launch" then
			if crossing.way ~= "out" then
				fail(layout, solution, crossing, 'launches only work outward; mark way = "out"')
			end
			local launchId = zone .. "_launch"
			local launch = rt.launches[launchId]
			if not launch then
				fail(layout, solution, crossing, "gap has no launch ramp")
			end
			if not model:basinSolid(launch.basin) then
				fail(layout, solution, crossing, "feeding basin " .. tostring(launch.basin) .. " is not frozen")
			end
			local boosted = false
			for _, lane in activeFanLane(rt, rooms, nil) do
				if table.find(lane.slides, launchId) then
					boosted = true
				end
			end
			if not boosted then
				fail(layout, solution, crossing, "no active Fan lane boosts this launch")
			end
		elseif by == "crate" then
			if mod.kind ~= "Gap" or not mod.slot then
				fail(layout, solution, crossing, "gap has no crate slot")
			end
			local slotted = simulateCrate(rt, mod.slot, rooms)
			if not slotted then
				fail(layout, solution, crossing, "crate " .. mod.slot .. " never reaches its slot")
			end
		elseif by == "vine" then
			if not model:vineSolid(zone) then
				fail(layout, solution, crossing, "vine is not grown")
			end
		elseif by == "pin" then
			local cart = rt.carts[zone]
			local pinned = false
			for _, lane in activeFanLane(rt, rooms, "Across") do
				if MathUtil.pointInBox(lane.cf, lane.size, cart.tileCF.Position + V3.new(0, 3, 0), 0.5) then
					pinned = true
				end
			end
			if not pinned then
				fail(layout, solution, crossing, "no Fan blows across this track")
			end
		elseif by == "slow" then
			local cold = false
			for socketId, spec in rooms do
				local room = parseRoom(spec)
				local links = rt.sockets[socketId].links.cold
				if room == "Freezer" and links and table.find(links, zone) then
					cold = true
				end
			end
			if not cold then
				fail(layout, solution, crossing, "no Freezer chills this track")
			end
		elseif by == "timing" then
			if mod.kind ~= "Carts" then
				fail(layout, solution, crossing, "only cart tracks can be timed")
			end
		else
			fail(layout, solution, crossing, "unknown method")
		end
		local _ = index
	end

	-- Keys ---------------------------------------------------------------------------------------------------

	local function keyReachable(layout, rt, solution, plan)
		local key = rt.keys[plan.id]
		if not key then
			error(layout.id .. " / " .. solution.name .. ": unknown key " .. plan.id)
		end
		if key.alcove then
			local gateId
			for id, gate in rt.gates do
				if gate.alcove == key.alcove then
					gateId = id
				end
			end
			assert(gateId, "alcove without gate " .. key.alcove)
			local model = settle(rt, plan.rooms or {}, plan.levers or {})
			if not model:gateOpen(gateId) then
				error(
					string.format("%s / %s: gate %s stays shut for key %s", layout.id, solution.name, gateId, plan.id)
				)
			end
			return
		end
		-- Floor keys must be within reach of a walkable surface (a floor tile, ledge, beam or walkway).
		for _, tile in rt.tiles do
			if tile.safe and MathUtil.pointInBoxXZ(tile.cf, V3.new(14, 1, 16), key.position, KEY_RADIUS - 1) then
				return
			end
		end
		for _, b in rt.ledges do
			local closest = MathUtil.closestPointInBox(b.cf, b.size, key.position)
			if (closest - key.position).Magnitude <= KEY_RADIUS - 0.5 then
				return
			end
		end
		error(string.format("%s / %s: key %s floats out of reach", layout.id, solution.name, plan.id))
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

			it(id .. " ships a starter-only solo solution and a different alternative", function()
				local solutions = layout.solutions or {}
				expect(#solutions >= 2).toBe(true)
				local starter = false
				for _, solution in solutions do
					local ok = #solution.loadout <= GameConfig.Loadout.Slots
					for _, room in solution.loadout do
						if not STARTERS[room] then
							ok = false
						end
					end
					if ok then
						starter = true
					end
				end
				if not starter then
					error(id .. " has no solution that uses only Freezer + Fan")
				end
				-- Different: some obstacle is crossed by a different method in another solution.
				local methods = {}
				for i, solution in solutions do
					methods[i] = {}
					for _, crossing in solution.crossings do
						methods[i][crossing.zone .. (crossing.way or "")] = crossing.by
					end
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

			it(id .. " solutions cross every obstacle out and back", function()
				local rt = build(layout)
				for _, solution in layout.solutions or {} do
					local covered = { out = {}, back = {} }
					for _, crossing in solution.crossings do
						checkCrossing(layout, rt, solution, crossing)
						if crossing.way ~= "back" then
							covered.out[crossing.zone] = true
						end
						if crossing.way ~= "out" then
							covered.back[crossing.zone] = true
						end
					end
					for _, zone in obstacles(layout) do
						if not covered.out[zone] then
							error(string.format("%s / %s: no way OUT across %s", id, solution.name, zone))
						end
						if not covered.back[zone] then
							error(string.format("%s / %s: no way BACK across %s", id, solution.name, zone))
						end
					end
				end
			end)

			it(id .. " mission challenges are achievable", function()
				local rt = build(layout)
				local allKeys = {}
				for keyId in rt.keys do
					table.insert(allKeys, keyId)
				end
				for _, challenge in mission.challenges do
					if challenge.kind == "combo" then
						local proved = false
						for _, solution in layout.solutions or {} do
							if solution.combos and table.find(solution.combos, challenge.combo) then
								local need = ({
									extinguish = "douse",
									ice_launch = "launch",
									crate_bridge = "crate",
									vine_bridge = "vine",
									power_off = "power",
								})[challenge.combo]
								for _, crossing in solution.crossings do
									if crossing.by == need then
										if need ~= "power" or (crossing.levers and #crossing.levers > 0) then
											proved = true
										end
									end
								end
							end
						end
						if not proved then
							error(id .. ": no solution performs the " .. tostring(challenge.combo) .. " combo")
						end
					elseif challenge.kind == "allKeys" then
						expect(#allKeys > 0).toBe(true)
						local proved = false
						for _, solution in layout.solutions or {} do
							local starterOnly = true
							for _, room in solution.loadout do
								if not STARTERS[room] then
									starterOnly = false
								end
							end
							local got = {}
							for _, plan in solution.keys or {} do
								keyReachable(layout, rt, solution, plan)
								got[plan.id] = true
							end
							local all = true
							for _, keyId in allKeys do
								if not got[keyId] then
									all = false
								end
							end
							if all and starterOnly then
								proved = true
							end
						end
						if not proved then
							error(id .. ": no starter solution collects every key")
						end
					elseif challenge.kind == "timeLeft" then
						-- Escape estimate: carrier speed over the whole route plus slow bypasses.
						local carrier = GameConfig.Movement.WalkSpeed * GameConfig.Cargo.CarrierSpeedMultiplier
						local seconds = #rt.tiles * 16 / carrier + 2 * #obstacles(layout)
						local budget = GameConfig.Escape.WindowSeconds - (challenge.value or 0) - 10
						if seconds > budget then
							error(
								string.format(
									"%s: escape estimate %.0fs leaves no room for %ds",
									id,
									seconds,
									challenge.value
								)
							)
						end
					end
				end
				-- Every key in the layout is reachable in at least one solution.
				for _, keyId in allKeys do
					local reachable = false
					for _, solution in layout.solutions or {} do
						for _, plan in solution.keys or {} do
							if plan.id == keyId then
								reachable = true
							end
						end
					end
					if not reachable then
						error(id .. ": key " .. keyId .. " is not collected by any solution")
					end
				end
			end)

			it(id .. " escape fits the window and slow bypasses stay optional-fast", function()
				local rt = build(layout)
				local carrier = GameConfig.Movement.WalkSpeed * GameConfig.Cargo.CarrierSpeedMultiplier
				for _, solution in layout.solutions or {} do
					local seconds = #rt.tiles * 16 / carrier
					for _, crossing in solution.crossings do
						if crossing.way ~= "out" and SLOW_METHODS[crossing.by] then
							seconds += 16 / (carrier * GameConfig.Movement.LedgeSpeedMultiplier) - 16 / carrier
						end
					end
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
