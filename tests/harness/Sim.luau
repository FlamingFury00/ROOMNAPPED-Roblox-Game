--[[
	Sim: a headless stand-in for the Roblox engine that runs the real ROOMNAPPED server.

	* Loads the built place with Env and executes ServerScriptService.Server exactly as shipped.
	* Replaces `task`, `os.clock` and server time with a deterministic scheduler so minutes of gameplay run in
	  milliseconds.
	* Shims engine members Lune does not implement (events, remotes, Players, RunService, raycasts...).
	* Bots are fake players with simple characters: they walk toward targets, stand on whatever collidable
	  geometry is below them (or fall), and talk to the server through the real RemoteEvents. Each bot keeps
	  a mirror of its replicated state and an inbox of toasts/effects for assertions.
]]

local roblox = require("@lune/roblox")
local luau = require("@lune/luau")

local Env = require("./Env")

local Sim = {}
Sim.__index = Sim

local current: any = nil -- the active simulation (engine shims dispatch to it)
local shimsReady = false

local V3 = roblox.Vector3
local CF = roblox.CFrame

-- Signals ---------------------------------------------------------------------------------------------

local function newSignal(sim: any)
	local signal = { listeners = {} }
	function signal:Connect(fn)
		local connection = { Connected = true }
		local record = { fn = fn, connection = connection }
		table.insert(signal.listeners, record)
		function connection:Disconnect()
			connection.Connected = false
			local index = table.find(signal.listeners, record)
			if index then
				table.remove(signal.listeners, index)
			end
		end
		return connection
	end
	function signal:Once(fn)
		local connection
		connection = signal:Connect(function(...)
			connection:Disconnect()
			fn(...)
		end)
		return connection
	end
	function signal:Wait()
		local thread = coroutine.running()
		local connection
		connection = signal:Connect(function(...)
			connection:Disconnect()
			sim.task.spawn(thread, ...)
		end)
		return coroutine.yield()
	end
	function signal:Fire(...)
		for _, record in table.clone(signal.listeners) do
			if record.connection.Connected then
				sim.task.spawn(record.fn, ...)
			end
		end
	end
	return signal
end

local function signalFor(inst: any, name: string)
	local sim = current
	local perInstance = sim.signals[inst]
	if not perInstance then
		perInstance = {}
		sim.signals[inst] = perInstance
	end
	local signal = perInstance[name]
	if not signal then
		signal = newSignal(sim)
		perInstance[name] = signal
	end
	return signal
end

-- Scheduler -------------------------------------------------------------------------------------------

local function newScheduler(sim: any)
	local queue = {}
	local seq = 0
	local cancelled = setmetatable({}, { __mode = "k" })

	local function push(at: number, thread: thread, ...)
		seq += 1
		table.insert(queue, { at = at, seq = seq, thread = thread, args = table.pack(...) })
	end

	local function resume(thread: thread, ...)
		if cancelled[thread] or coroutine.status(thread) == "dead" then
			return
		end
		local ok, problem = coroutine.resume(thread, ...)
		if not ok then
			table.insert(sim.errors, debug.traceback(thread, tostring(problem)))
		end
	end

	local task = {}
	function task.spawn(f, ...)
		local thread = if type(f) == "thread" then f else coroutine.create(f)
		resume(thread, ...)
		return thread
	end
	function task.defer(f, ...)
		local thread = if type(f) == "thread" then f else coroutine.create(f)
		push(sim.time, thread, ...)
		return thread
	end
	function task.delay(t, f, ...)
		local thread = if type(f) == "thread" then f else coroutine.create(f)
		push(sim.time + math.max(0, tonumber(t) or 0), thread, ...)
		return thread
	end
	function task.wait(t)
		local thread = coroutine.running()
		local start = sim.time
		push(sim.time + math.max(tonumber(t) or 0, 1 / 60), thread)
		coroutine.yield()
		return sim.time - start
	end
	function task.cancel(thread)
		cancelled[thread] = true
	end
	function task.synchronize() end
	function task.desynchronize() end

	local scheduler = {}
	function scheduler.runUntil(target: number)
		while true do
			local bestIndex = nil
			local best = nil
			for i, item in queue do
				if
					item.at <= target
					and (best == nil or item.at < best.at or (item.at == best.at and item.seq < best.seq))
				then
					best = item
					bestIndex = i
				end
			end
			if not bestIndex then
				break
			end
			table.remove(queue, bestIndex)
			sim.time = math.max(sim.time, best.at)
			resume(best.thread, table.unpack(best.args, 1, best.args.n))
		end
		sim.time = math.max(sim.time, target)
	end
	scheduler.task = task
	return scheduler
end

-- Raycasting ------------------------------------------------------------------------------------------

local function rayOBB(origin: any, direction: any, cf: any, size: any): number?
	local o = cf:PointToObjectSpace(origin)
	local d = cf:VectorToObjectSpace(direction)
	local half = size * 0.5
	local tmin, tmax = -math.huge, math.huge
	for _, axis in { "X", "Y", "Z" } do
		local oa, da, h = o[axis], d[axis], half[axis]
		if math.abs(da) < 1e-9 then
			if oa < -h or oa > h then
				return nil
			end
		else
			local t1 = (-h - oa) / da
			local t2 = (h - oa) / da
			if t1 > t2 then
				t1, t2 = t2, t1
			end
			tmin = math.max(tmin, t1)
			tmax = math.min(tmax, t2)
			if tmin > tmax then
				return nil
			end
		end
	end
	if tmax < 0 then
		return nil
	end
	return math.max(tmin, 0)
end

-- Shims ----------------------------------------------------------------------------------------------------

local function installShims()
	if shimsReady then
		return
	end
	shimsReady = true

	for _, class in { "RemoteEvent", "UnreliableRemoteEvent" } do
		roblox.implementProperty(class, "OnServerEvent", function(inst)
			return signalFor(inst, "OnServerEvent")
		end)
		roblox.implementProperty(class, "OnClientEvent", function(inst)
			return signalFor(inst, "OnClientEvent")
		end)
		roblox.implementMethod(class, "FireClient", function(inst, player, ...)
			current:deliver(player, inst.Name, ...)
		end)
		roblox.implementMethod(class, "FireAllClients", function(inst, ...)
			for _, player in current.players do
				current:deliver(player, inst.Name, ...)
			end
		end)
	end
	roblox.implementProperty("RemoteFunction", "OnServerInvoke", function(inst)
		return current.invokeHandlers[inst]
	end, function(inst, value)
		current.invokeHandlers[inst] = value
	end)
	for _, event in { "PlayerAdded", "PlayerRemoving" } do
		roblox.implementProperty("Players", event, function(inst)
			return signalFor(inst, event)
		end)
	end
	roblox.implementMethod("Players", "GetPlayers", function()
		return table.clone(current.players)
	end)
	roblox.implementMethod("Players", "GetPlayerByUserId", function(_, userId)
		for _, player in current.players do
			if player.UserId == userId then
				return player
			end
		end
		return nil
	end)
	roblox.implementProperty("Player", "CharacterAdded", function(inst)
		return signalFor(inst, "CharacterAdded")
	end)
	roblox.implementMethod("Player", "Kick", function(inst, message)
		current.kicked[inst] = message or true
	end)
	roblox.implementMethod("GroupService", "GetGroupsAsync", function()
		return {}
	end)
	roblox.implementMethod("Player", "LoadCharacterAsync", function(inst)
		current:spawnCharacter(inst)
	end)
	roblox.implementProperty("Humanoid", "Died", function(inst)
		return signalFor(inst, "Died")
	end)
	for _, event in { "DescendantAdded", "ChildAdded", "Destroying", "AncestryChanged" } do
		roblox.implementProperty("Instance", event, function(inst)
			return signalFor(inst, event)
		end)
	end
	for _, event in { "Heartbeat", "Stepped", "RenderStepped", "PreSimulation", "PostSimulation" } do
		roblox.implementProperty("RunService", event, function(inst)
			return signalFor(inst, event)
		end)
	end
	roblox.implementMethod("RunService", "IsServer", function()
		return true
	end)
	roblox.implementMethod("RunService", "IsClient", function()
		return false
	end)
	roblox.implementMethod("RunService", "IsStudio", function()
		return true
	end)
	roblox.implementMethod("RunService", "BindToRenderStep", function() end)
	roblox.implementMethod("RunService", "UnbindFromRenderStep", function() end)
	roblox.implementMethod("Workspace", "GetServerTimeNow", function()
		return current.time + 1000
	end)
	roblox.implementMethod("Workspace", "Raycast", function(_, origin, direction, params)
		return current:raycast(origin, direction, params, false)
	end)
	roblox.implementMethod("PhysicsService", "RegisterCollisionGroup", function() end)
	roblox.implementMethod("PhysicsService", "CollisionGroupSetCollidable", function() end)
	roblox.implementMethod("HttpService", "GenerateGUID", function()
		current.guid += 1
		return string.format("00000000-0000-4000-8000-%012d", current.guid)
	end)
	roblox.implementMethod("DataModel", "BindToClose", function(_, fn)
		table.insert(current.closeHandlers, fn)
	end)
	roblox.implementMethod("DataStoreService", "GetDataStore", function()
		error("DataStores are unavailable in the simulation")
	end)
end

-- Simulation ------------------------------------------------------------------------------------------------

function Sim.new(placePath: string)
	installShims()
	local sim = setmetatable({
		time = 0,
		signals = setmetatable({}, { __mode = "k" }),
		players = {},
		bots = {},
		kicked = {},
		invokeHandlers = {},
		closeHandlers = {},
		errors = {},
		warnings = {},
		guid = 0,
		queryCache = nil,
		collideCache = nil,
		velocities = {},
		falling = {},
	}, Sim)
	current = sim
	sim.scheduler = newScheduler(sim)
	sim.task = sim.scheduler.task

	local fakeOs = table.clone(os)
	fakeOs.clock = function()
		return sim.time
	end
	fakeOs.time = function()
		return 1700000000 + math.floor(sim.time)
	end

	local engineModule = {
		velocity = function(part)
			return sim.velocities[part] or V3.zero
		end,
		floorMaterial = function(humanoid)
			local character = humanoid.Parent
			if character and sim.falling[character] then
				return roblox.Enum.Material.Air
			end
			return roblox.Enum.Material.Plastic
		end,
		stop = function(part)
			sim.velocities[part] = V3.zero
		end,
		placeId = function()
			return 0
		end,
		jobId = function()
			return ""
		end,
	}

	sim.loaded = Env.load(placePath, {
		task = sim.task,
		os = fakeOs,
		tick = fakeOs.clock,
		time = fakeOs.clock,
		wait = sim.task.wait,
		delay = sim.task.delay,
		spawn = sim.task.spawn,
		warn = function(...)
			local parts = {}
			for i = 1, select("#", ...) do
				table.insert(parts, tostring((select(i, ...))))
			end
			table.insert(sim.warnings, table.concat(parts, " "))
		end,
		print = function() end,
		RaycastParams = {
			new = function()
				return { FilterType = roblox.Enum.RaycastFilterType.Exclude, FilterDescendantsInstances = {} }
			end,
		},
	})
	sim.game = sim.loaded.game
	sim.workspace = sim.game:GetService("Workspace")
	sim.Players = sim.game:GetService("Players")
	sim.RunService = sim.game:GetService("RunService")

	-- Swap the engine adapter module for the simulated one.
	local engineScript = Env.find(sim.game, "ReplicatedStorage.Shared.Util.Engine")
	sim.loaded.overrides[engineScript] = engineModule
	sim.require = sim.loaded.require
	return sim
end

function Sim.module(self: any, path: string)
	return self.require(Env.find(self.game, path))
end

-- Run the shipped server bootstrap Script.
function Sim.startServer(self: any)
	local serverScript = Env.find(self.game, "ServerScriptService.Server")
	local env = table.clone(self.loaded.env)
	env.script = serverScript
	env.require = self.require
	local fn = luau.load(serverScript.Source, { debugName = "Server", environment = env, injectGlobals = true })
	self.task.spawn(fn)
end

function Sim.queryParts(self: any)
	if not self.queryCache then
		local list = {}
		for _, d in self.workspace:GetDescendants() do
			if d:IsA("BasePart") then
				table.insert(list, d)
			end
		end
		self.queryCache = list
	end
	return self.queryCache
end

function Sim.raycast(self: any, origin: any, direction: any, params: any, collideOnly: boolean)
	local length = direction.Magnitude
	if length < 1e-6 then
		return nil
	end
	local dir = direction / length
	local filterSet = {}
	local include = false
	if params then
		include = params.FilterType == roblox.Enum.RaycastFilterType.Include
		for _, inst in params.FilterDescendantsInstances or {} do
			filterSet[inst] = true
			for _, d in inst:GetDescendants() do
				filterSet[d] = true
			end
		end
	end
	local bestT, best = length, nil
	for _, part in self:queryParts() do
		if part.Parent ~= nil then
			local usable = if collideOnly then part.CanCollide else part.CanQuery
			if usable then
				local listed = filterSet[part] == true
				if (include and listed) or (not include and not listed) then
					local t = rayOBB(origin, dir, part.CFrame, part.Size)
					if t and t < bestT then
						bestT, best = t, part
					end
				end
			end
		end
	end
	if best then
		return {
			Instance = best,
			Position = origin + dir * bestT,
			Distance = bestT,
			Normal = V3.new(0, 1, 0),
			Material = best.Material,
		}
	end
	return nil
end

-- Players & bots -------------------------------------------------------------------------------------------

function Sim.spawnCharacter(self: any, player: any, at: any?)
	if player.Character then
		player.Character.Parent = nil
	end
	local model = roblox.Instance.new("Model")
	model.Name = player.Name
	local function part(name: string, size: any, offset: any)
		local p = roblox.Instance.new("Part")
		p.Name = name
		p.Size = size
		p.CFrame = CF.new(offset)
		p.Anchored = false
		p.CanQuery = true
		p.Parent = model
		return p
	end
	local root = part("HumanoidRootPart", V3.new(2, 2, 1), V3.new(0, 0, 0))
	part("Head", V3.new(2, 1, 1), V3.new(0, 1.5, 0))
	part("UpperTorso", V3.new(2, 1.6, 1), V3.new(0, 0.2, 0))
	part("RightHand", V3.new(0.6, 0.6, 0.6), V3.new(1.5, -1, 0))
	local humanoid = roblox.Instance.new("Humanoid")
	humanoid.Parent = model
	model.PrimaryPart = root
	local spawnCF = at
	if not spawnCF then
		local spawn = self.workspace:FindFirstChild("LobbySpawn", true)
		spawnCF = if spawn then spawn.CFrame * CF.new(0, 3, 0) else CF.new(0, 3, 0)
	end
	model:PivotTo(spawnCF)
	model.Parent = self.workspace
	player.Character = model
	self.queryCache = nil
	signalFor(player, "CharacterAdded"):Fire(model)
	return model
end

function Sim.addBot(self: any, name: string, userId: number)
	local player = roblox.Instance.new("Player")
	player.Name = name
	player.DisplayName = name
	player.UserId = userId
	player.Parent = self.Players
	table.insert(self.players, player)
	local bot = {
		player = player,
		name = name,
		target = nil,
		speed = 16,
		mirror = {},
		seq = {},
		inbox = {},
		path = {},
	}
	self.bots[player] = bot
	signalFor(self.Players, "PlayerAdded"):Fire(player)
	self:spawnCharacter(player)
	return bot
end

function Sim.removeBot(self: any, bot: any)
	local player = bot.player
	signalFor(self.Players, "PlayerRemoving"):Fire(player)
	local index = table.find(self.players, player)
	if index then
		table.remove(self.players, index)
	end
	self.bots[player] = nil
	if player.Character then
		player.Character.Parent = nil
	end
	player.Parent = nil
	self.queryCache = nil
end

local StatePathModule = nil

function Sim.deliver(self: any, player: any, remoteName: string, ...)
	local bot = self.bots[player]
	if not bot then
		return
	end
	if remoteName == "StatePatch" then
		local channel, seq, patches = ...
		StatePathModule = StatePathModule or self:module("ReplicatedStorage.Shared.Net.StatePath")
		bot.mirror[channel] = bot.mirror[channel] or {}
		for _, patch in patches do
			StatePathModule.apply(bot.mirror[channel], patch)
		end
		bot.seq[channel] = seq
		return
	end
	table.insert(bot.inbox, { name = remoteName, args = table.pack(...), time = self.time })
end

-- Bootstrap a bot's mirror from the snapshot function (what the real client does on join).
function Sim.snapshot(self: any, bot: any)
	local remote = Env.find(self.game, "ReplicatedStorage.RoomnappedRemotes.GetSnapshot")
	local handler = self.invokeHandlers[remote]
	assert(handler, "GetSnapshot handler missing")
	local snapshot = handler(bot.player)
	local Tables = self:module("ReplicatedStorage.Shared.Util.Tables")
	for channel, payload in snapshot do
		bot.mirror[channel] = Tables.deepCopy(payload.data)
	end
end

-- Fire a client->server remote as `bot`.
function Sim.send(self: any, bot: any, remoteName: string, ...)
	local remote = Env.find(self.game, "ReplicatedStorage.RoomnappedRemotes." .. remoteName)
	signalFor(remote, "OnServerEvent"):Fire(bot.player, ...)
end

function Sim.state(self: any, bot: any, channel: string, path: string?): any
	local node = bot.mirror[channel]
	if path then
		for segment in string.gmatch(path, "[^%.]+") do
			if type(node) ~= "table" then
				return nil
			end
			node = node[segment]
		end
	end
	return node
end

function Sim.inboxHas(self: any, bot: any, remoteName: string, first: any?): boolean
	for _, message in bot.inbox do
		if message.name == remoteName and (first == nil or message.args[1] == first or message.args[2] == first) then
			return true
		end
	end
	return false
end

function Sim.position(self: any, bot: any): any
	local character = bot.player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root then root.CFrame.Position else nil
end

function Sim.teleportBot(self: any, bot: any, position: any)
	local character = bot.player.Character
	if character then
		character:PivotTo(CF.new(position))
	end
end

-- Move `bot` along a list of waypoints at its walking speed.
function Sim.walk(self: any, bot: any, waypoints: { any })
	bot.path = table.clone(waypoints)
end

-- Physics step for bots: horizontal walking + ground following / falling.
function Sim.stepBots(self: any, dt: number)
	local params = { FilterType = roblox.Enum.RaycastFilterType.Exclude, FilterDescendantsInstances = {} }
	local characters = {}
	for _, player in self.players do
		if player.Character then
			table.insert(characters, player.Character)
		end
	end
	params.FilterDescendantsInstances = characters
	for player, bot in self.bots do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root then
			local position = root.CFrame.Position
			local downed = player:GetAttribute("Downed") == true or player:GetAttribute("Spectating") == true
			local speed = bot.speed
			if player:GetAttribute("Carrying") then
				speed *= 0.85
			end
			if downed then
				speed = 0
			end
			local horizontal = V3.zero
			local goal = bot.path[1]
			if goal and speed > 0 then
				local flat = V3.new(goal.X - position.X, 0, goal.Z - position.Z)
				if flat.Magnitude < 0.6 then
					table.remove(bot.path, 1)
				else
					horizontal = flat.Unit * math.min(flat.Magnitude, speed * dt)
				end
			end
			local nextPos = position + horizontal
			-- Ground: collidable geometry below the feet.
			local hit = self:raycast(nextPos + V3.new(0, 0.5, 0), V3.new(0, -40, 0), params, true)
			local feet = nextPos.Y - 3
			local y = nextPos.Y
			if hit and hit.Position.Y >= feet - 0.6 then
				y = hit.Position.Y + 3
				self.falling[character] = nil
			else
				self.falling[character] = true
				y = nextPos.Y - 60 * dt
				if hit and y - 3 < hit.Position.Y then
					y = hit.Position.Y + 3
				end
			end
			local finalPos = V3.new(nextPos.X, y, nextPos.Z)
			self.velocities[root] = (finalPos - position) / math.max(dt, 1e-3)
			local look = if horizontal.Magnitude > 0.01 then horizontal.Unit else root.CFrame.LookVector
			character:PivotTo(CF.lookAt(finalPos, finalPos + V3.new(look.X, 0, look.Z)))
		end
	end
end

-- Advance the simulation by `seconds` in 60 Hz frames.
function Sim.run(self: any, seconds: number)
	local frames = math.max(1, math.floor(seconds * 60 + 0.5))
	local dt = 1 / 60
	for _ = 1, frames do
		self.queryCache = nil
		self:stepBots(dt)
		self.scheduler.runUntil(self.time + dt)
		signalFor(self.RunService, "Heartbeat"):Fire(dt)
	end
end

-- Run until `predicate()` is true or `timeout` seconds pass. Returns whether the predicate held.
function Sim.runUntil(self: any, predicate: () -> boolean, timeout: number): boolean
	local elapsed = 0
	while elapsed < timeout do
		if predicate() then
			return true
		end
		self:run(0.1)
		elapsed += 0.1
	end
	return predicate()
end

function Sim.instanceCount(self: any): number
	return #self.workspace:GetDescendants()
end

return Sim
