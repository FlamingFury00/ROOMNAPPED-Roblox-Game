--!strict
--[[
	AssetLibraryService: dresses the hotel with curated free Creator Store models (A01, A10).

	At startup every AssetManifest entry is loaded with AssetService:LoadAssetAsync (falling back to
	InsertService:LoadAsset, which still loads models the experience owner has in their inventory) and turned
	into a template in ReplicatedStorage.RN_Assets/<key>/<n>:

	  * cleaned: no scripts, sounds (old or new audio API), video, GUIs, prompts, click detectors, humanoids,
	    joints, constraints, highlights, adornments, pathfinding modifiers or legacy effects; every part
	    anchored, non-colliding, untouchable, invisible to raycasts and locked (collision stays with the
	    builders' simple proxies), invisible parts dropped; seats and spawn points disabled; the model's own
	    lights and particles only when the entry asks for them, never casting shadows;
	  * turned so its front faces -Z: seats say which way a piece of furniture faces; otherwise the front is the
	    side the model's Creator Store thumbnail shows, which follows from its pivot (see thumbnailFront), with
	    per-model corrections from the manifest;
	  * scaled uniformly into the entry's size and pivoted by its mount (bottom / back / top centre).

	Slots the builders already filled with procedural fallbacks are upgraded as each key arrives
	(World/Assets.upgrade), so the lobby that exists before any model loads is dressed too. Loading needs the
	experience's Security setting "Allow Loading Third Party Assets"; when models cannot load the hotel keeps
	its procedural props and admins are told why (publishing checklist).

	The `assets` feature flag is the kill switch for this third-party content: loading waits for the server's
	first read of the live flags, and switching the flag off on a running server drops every template and puts
	every slot's built-in prop back (switching it on again reloads).
]]

local AssetService = game:GetService("AssetService")
local InsertService = game:GetService("InsertService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local AssetManifest = require(Shared.Content.AssetManifest)
local CaretakerLook = require(Shared.Content.CaretakerLook)
local Assets = require(Shared.World.Assets)
local Log = require(Shared.Util.Log)
local Signal = require(Shared.Util.Signal)
local Registry = require(script.Parent.Parent.Core.Registry)

local AssetLibraryService = {}

AssetLibraryService.Loaded = Signal.new() -- (key)
AssetLibraryService.Finished = Signal.new() -- (loadedKeys, failedKeys)

local log = Log.new("Assets")

local CONCURRENCY = 6
local ATTEMPTS = 2

type Status = "pending" | "loading" | "ready" | "failed"

local status: { [string]: Status } = {}
local failures: { [string]: string } = {}
local finished = false
local loadedCount, failedCount = 0, 0
local root: Folder
-- Bumped whenever loading starts or the library is switched off: a load from an older generation drops its
-- results instead of publishing them.
local generation = 0

local function current(gen: number): boolean
	return gen == generation and Registry.get("Flags").feature("assets")
end

-- Cleaning ----------------------------------------------------------------------------------------------------

local REMOVE: { string } = {
	"LuaSourceContainer",
	"Sound",
	"SoundGroup",
	"ClickDetector",
	"ProximityPrompt",
	"DragDetector",
	"Tool",
	"Humanoid",
	"AnimationController",
	"Animator",
	"Animation",
	"Camera",
	"LayerCollector", -- ScreenGui / BillboardGui / SurfaceGui: no text or images from strangers' GUIs
	"JointInstance",
	"WeldConstraint",
	"Constraint",
	"BodyMover",
	"Explosion",
	"ForceField",
	"Fire",
	"Smoke",
	"Sparkles",
	"Dialog",
	"Configuration",
	"ValueBase",
	"BindableEvent",
	"BindableFunction",
	"RemoteEvent",
	"RemoteFunction",
	"UnreliableRemoteEvent",
	"VideoPlayer",
	"VideoDeviceInput",
	"Wire", -- the new audio graph (its Audio* objects are matched by name below)
	"Highlight",
	"GuiBase3d", -- selection boxes and handle adornments
	"PathfindingModifier", -- a stranger's model must not change where the Caretaker can walk
	"PathfindingLink",
	"Model", -- never: nested models are flattened instead (handled below)
}

local function shouldRemove(instance: Instance, entry: AssetManifest.Entry): boolean
	for _, class in REMOVE do
		if class ~= "Model" and instance:IsA(class) then
			return true
		end
	end
	-- AudioPlayer, AudioEmitter, AudioListener and the rest of the new audio API share no base class.
	if string.sub(instance.ClassName, 1, 5) == "Audio" then
		return true
	end
	if instance:IsA("Light") then
		return entry.lights ~= true
	end
	if instance:IsA("ParticleEmitter") or instance:IsA("Beam") or instance:IsA("Trail") then
		return entry.particles ~= true
	end
	return false
end

-- An invisible part (a hitbox, a collision proxy, an empty root) would only stretch the bounds the model is
-- fitted by. Keep the ones that carry something visible (a decal, or the lights and effects the entry wants)
-- and seats, which are usually invisible and say which way the furniture faces (frontYaw).
local function invisible(part: BasePart, entry: AssetManifest.Entry): boolean
	if part.Transparency < 0.99 or part:IsA("Seat") or part:IsA("VehicleSeat") then
		return false
	end
	for _, d in part:GetDescendants() do
		if d:IsA("Decal") or d:IsA("Light") or d:IsA("ParticleEmitter") then
			return false
		end
		-- Beams and trails may hang between attachments on parts of their own.
		if d:IsA("Attachment") and entry.particles == true then
			return false
		end
	end
	return true
end

-- Move every part (and what hangs off it) into one flat model; drop everything else.
local function clean(loaded: Instance, entry: AssetManifest.Entry, label: string): Model?
	local model = Instance.new("Model")
	for _, d in loaded:GetDescendants() do
		if d.Parent ~= nil and shouldRemove(d, entry) then
			d:Destroy()
		end
	end
	local parts: { BasePart } = {}
	for _, d in loaded:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(parts, d)
		end
	end
	local kept = 0
	local legacyMeshes = 0
	for _, part in parts do
		part.Anchored = true
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = false
		part.Locked = true
		part.Massless = true
		part.CastShadow = false
		if part:IsA("Seat") or part:IsA("VehicleSeat") then
			(part :: any).Disabled = true
		elseif part:IsA("SpawnLocation") then
			-- Every clone would be a place players can spawn at.
			part.Enabled = false
			part.Neutral = false
		end
		part.Parent = model -- flattened first, so dropping a part below never takes a nested one with it
	end
	for _, part in parts do
		if invisible(part, entry) then
			part:Destroy()
		else
			kept += 1
			local mesh = part:FindFirstChildOfClass("SpecialMesh")
			if mesh and mesh.MeshType == Enum.MeshType.FileMesh then
				legacyMeshes += 1
			end
		end
	end
	loaded:Destroy()
	if kept == 0 then
		model:Destroy()
		return nil
	end
	if legacyMeshes > 0 then
		-- Legacy meshes ignore their part's size: worth a look when such a model renders at an odd scale.
		log:Debug(string.format("%s: %d part(s) with legacy file meshes", label, legacyMeshes))
	end
	for _, d in model:GetDescendants() do
		if d:IsA("Light") then
			d.Shadows = false
		end
	end
	return model
end

AssetLibraryService.clean = clean -- exposed for tests

-- Bounds --------------------------------------------------------------------------------------------------------

-- World-axis bounding box of a model's parts: (centre, size).
local function bounds(model: Model): (Vector3, Vector3)
	local minV = Vector3.new(math.huge, math.huge, math.huge)
	local maxV = -minV
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			local cf, size = part.CFrame, part.Size / 2
			for _, sx in { -1, 1 } do
				for _, sy in { -1, 1 } do
					for _, sz in { -1, 1 } do
						local p = cf * Vector3.new(size.X * sx, size.Y * sy, size.Z * sz)
						minV = minV:Min(p)
						maxV = maxV:Max(p)
					end
				end
			end
		end
	end
	return (minV + maxV) / 2, maxV - minV
end

-- Facing --------------------------------------------------------------------------------------------------------

local DIRECTIONS: { { dir: Vector3, yaw: number } } = {
	-- yaw turns that direction onto -Z (the hotel's "front" convention).
	{ dir = Vector3.new(0, 0, -1), yaw = 0 },
	{ dir = Vector3.new(0, 0, 1), yaw = math.pi },
	{ dir = Vector3.new(1, 0, 0), yaw = math.pi / 2 },
	{ dir = Vector3.new(-1, 0, 0), yaw = -math.pi / 2 },
}

--[[
	The side of a loaded asset its Creator Store thumbnail shows. The thumbnail camera looks at a model from the
	Z side its pivot faces (an unrotated pivot looks along -Z, so most thumbnails show the -Z side) and from
	the model's front left. Every manifest model was picked because its thumbnail shows its front, so that side
	is the front; `turns` corrects the few whose thumbnail shows a side.
]]
local function thumbnailFront(loaded: Instance): Vector3
	local root: Instance = loaded
	local children = loaded:GetChildren()
	if #children == 1 then
		root = children[1]
	end
	local look = Vector3.new(0, 0, -1)
	if root:IsA("Model") then
		look = root:GetPivot().LookVector
	elseif root:IsA("BasePart") then
		look = root.CFrame.LookVector
	end
	return Vector3.new(0, 0, if look.Z > 1e-4 then 1 else -1)
end

-- Yaw that turns the model's front onto -Z: where its seats face when it has any (players sit facing the
-- front), else the side its thumbnail shows.
local function frontYaw(model: Model, thumbnail: Vector3): (number, string)
	local seats = Vector3.zero
	for _, part in model:GetDescendants() do
		if part:IsA("Seat") or part:IsA("VehicleSeat") then
			local look = part.CFrame.LookVector
			seats += Vector3.new(look.X, 0, look.Z)
		end
	end
	local front, why = thumbnail, "thumbnail"
	if seats.Magnitude > 0.5 then
		front, why = seats.Unit, "seat"
	end
	local best, bestDot = DIRECTIONS[1], -math.huge
	for _, d in DIRECTIONS do
		local dot = front:Dot(d.dir)
		if dot > bestDot then
			best, bestDot = d, dot
		end
	end
	return best.yaw, why
end

-- Normalising -----------------------------------------------------------------------------------------------------

-- How far "stretch" may pull a model's width or depth away from its height scale.
local STRETCH_LIMIT = 1.35

-- Scale a model about `centre` by `factors` along the world axes. Parts keep their rotation (a part turned
-- off the axes stretches along the axes nearest its own); file meshes, which ignore their part's size, take
-- the scale on the mesh instead.
local function stretch(model: Model, centre: Vector3, factors: Vector3)
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			local cf = part.CFrame
			local localFactors = Vector3.new(
				(factors * cf.RightVector).Magnitude,
				(factors * cf.UpVector).Magnitude,
				(factors * cf.LookVector).Magnitude
			)
			part.Size *= localFactors
			part.CFrame = cf.Rotation + (centre + (cf.Position - centre) * factors)
			for _, child in part:GetChildren() do
				if child:IsA("SpecialMesh") then
					if child.MeshType == Enum.MeshType.FileMesh then
						child.Scale *= localFactors
					end
					child.Offset *= localFactors
				elseif child:IsA("Attachment") then
					child.Position *= localFactors
				end
			end
		end
	end
end

local function normalise(model: Model, entry: AssetManifest.Entry, id: number, thumbnail: Vector3): Model
	local centre, extent = bounds(model)
	model.WorldPivot = CFrame.new(centre)
	-- Turn the front onto -Z.
	local yaw = 0
	local why = "none"
	if entry.facing == "auto" then
		yaw, why = frontYaw(model, thumbnail)
	elseif entry.facing == "wide" and extent.Z > extent.X then
		yaw, why = math.pi / 2, "wide"
	end
	local turn = entry.turns and entry.turns[id]
	if turn then
		yaw += math.rad(turn)
		why ..= string.format("%+d", turn)
	end
	model:PivotTo(CFrame.new(centre) * CFrame.Angles(0, yaw, 0))
	model.WorldPivot = CFrame.new(centre)
	-- Scale into the target size: uniformly, or per axis for "stretch".
	local middle, size = bounds(model)
	local target = entry.size
	local factors = Vector3.new(
		target.X / math.max(size.X, 1e-3),
		target.Y / math.max(size.Y, 1e-3),
		target.Z / math.max(size.Z, 1e-3)
	)
	if entry.fit == "stretch" then
		-- Height exact (things stand on top), width and depth within STRETCH_LIMIT of it.
		local fy = math.clamp(factors.Y, 0.02, 50)
		stretch(
			model,
			middle,
			Vector3.new(
				math.clamp(factors.X, fy / STRETCH_LIMIT, fy * STRETCH_LIMIT),
				fy,
				math.clamp(factors.Z, fy / STRETCH_LIMIT, fy * STRETCH_LIMIT)
			)
		)
	else
		local ratio = if entry.fit == "height"
			then factors.Y
			elseif entry.fit == "width" then factors.X
			else math.min(factors.X, factors.Y, factors.Z)
		model:ScaleTo(model:GetScale() * math.clamp(ratio, 0.02, 50))
	end
	-- Pivot by mount, at the origin.
	local c, s = bounds(model)
	local pivot: CFrame
	if entry.mount == "wall" then
		pivot = CFrame.new(c.X, c.Y, c.Z + s.Z / 2)
	elseif entry.mount == "centre" then
		pivot = CFrame.new(c)
	elseif entry.mount == "ceiling" then
		pivot = CFrame.new(c.X, c.Y + s.Y / 2, c.Z)
	else
		pivot = CFrame.new(c.X, c.Y - s.Y / 2, c.Z)
	end
	model.WorldPivot = pivot
	model:PivotTo(CFrame.new())
	-- Big pieces cast shadows; trinkets do not (S27).
	if entry.shadows ~= false then
		for _, part in model:GetDescendants() do
			if part:IsA("BasePart") and part.Size.Magnitude > 3 and part.Transparency < 0.5 then
				part.CastShadow = true
			end
		end
	end
	model:SetAttribute("SourceId", id)
	model:SetAttribute("Facing", why)
	return model
end

-- Loading ---------------------------------------------------------------------------------------------------------

local function fetch(id: number): (Instance?, string?)
	local ok, result = pcall(function()
		return AssetService:LoadAssetAsync(id)
	end)
	if ok and typeof(result) == "Instance" then
		return result, nil
	end
	local problem = tostring(result)
	-- Models the experience owner has in their inventory (or Roblox's own) still load the classic way.
	local okInsert, inserted = pcall(function()
		return InsertService:LoadAsset(id)
	end)
	if okInsert and typeof(inserted) == "Instance" then
		return inserted, nil
	end
	return nil, problem
end

local function loadKey(key: string, gen: number)
	local entry = AssetManifest.get(key)
	if not entry then
		return
	end
	status[key] = "loading"
	local holder = Instance.new("Folder")
	holder.Name = key
	local made = 0
	local lastProblem = "no ids"
	for index, id in entry.ids do
		if not current(gen) then
			break
		end
		local loaded, problem = nil, nil
		for attempt = 1, ATTEMPTS do
			loaded, problem = fetch(id)
			if loaded then
				break
			end
			if attempt < ATTEMPTS then
				task.wait(1.5 * attempt)
			end
		end
		if loaded then
			local ok, result = pcall(function(): Model?
				local thumbnail = thumbnailFront(loaded :: Instance)
				local model = clean(loaded :: Instance, entry, key .. " " .. id)
				return if model then normalise(model, entry, id, thumbnail) else nil
			end)
			if ok and result then
				local model = result :: Model
				model.Name = string.format("%02d", index)
				model.Parent = holder
				made += 1
			else
				lastProblem = if ok then "no parts" else tostring(result)
			end
		else
			lastProblem = problem or "unknown"
		end
	end
	if not current(gen) then
		-- Switched off (or restarted) while this key loaded: the slots keep their built-in props.
		holder:Destroy()
		if gen == generation then
			status[key] = "pending"
		end
		return
	end
	if made > 0 then
		holder.Parent = root
		status[key] = "ready"
		loadedCount += 1
		local upgraded = Assets.upgrade(key)
		log:Debug(string.format("%s: %d model(s), %d slot(s) upgraded", key, made, upgraded))
		AssetLibraryService.Loaded:Fire(key)
	else
		holder:Destroy()
		status[key] = "failed"
		failures[key] = lastProblem
		failedCount += 1
	end
end

-- The Caretaker ------------------------------------------------------------------------------------------------

local CARETAKER_TEMPLATE = "RN_CaretakerRig"

type Outfit = "full" | "lean" | "plain"

local ACCESSORY_PROPERTY: { [string]: string } = {
	Hat = "HatAccessory",
	Hair = "HairAccessory",
	Face = "FaceAccessory",
	Neck = "NeckAccessory",
	Shoulder = "ShouldersAccessory",
	Front = "FrontAccessory",
	Back = "BackAccessory",
	Waist = "WaistAccessory",
}

--[[
	A HumanoidDescription for the Caretaker:
	  full   every catalog piece in CaretakerLook
	  lean   the uniform with Roblox-made head and hat (when a user-made piece is gone or broken)
	  plain  no catalog items: a burgundy jacket and black trousers in body colours
]]
local function describe(outfit: Outfit): HumanoidDescription
	local look = CaretakerLook
	local description = Instance.new("HumanoidDescription")
	local function set(property: string, value: number?)
		if value and value > 0 then
			(description :: any)[property] = value
		end
	end
	local accessories: { [string]: { string } } = {}
	local function accessory(kind: string, id: number?)
		if id and id > 0 then
			accessories[kind] = accessories[kind] or {}
			table.insert(accessories[kind], tostring(id))
		end
	end
	if outfit == "full" then
		set("Face", look.face)
		set("Head", look.head)
		set("MoodAnimation", look.mood)
		set("Torso", look.torso)
		set("LeftArm", look.leftArm)
		set("RightArm", look.rightArm)
		set("LeftLeg", look.leftLeg)
		set("RightLeg", look.rightLeg)
		for _, item in look.accessories do
			accessory(item.type, item.id)
		end
	elseif outfit == "lean" then
		set("Head", look.fallback.head)
		set("MoodAnimation", look.fallback.mood)
		accessory("Hat", look.fallback.hat)
	end
	if outfit ~= "plain" then
		set("Shirt", look.shirt)
		set("Pants", look.pants)
	end
	for kind, ids in accessories do
		local property = ACCESSORY_PROPERTY[kind]
		if property then
			(description :: any)[property] = table.concat(ids, ",")
		end
	end
	local scales = look.scales
	description.HeightScale = scales.height
	description.WidthScale = scales.width
	description.DepthScale = scales.depth
	description.HeadScale = scales.head
	description.BodyTypeScale = scales.bodyType
	description.ProportionScale = scales.proportion
	local jacket = Color3.fromRGB(110, 28, 36)
	local trousers = Color3.fromRGB(20, 20, 22)
	description.HeadColor = look.skin
	description.TorsoColor = if outfit == "plain" then jacket else look.skin
	description.LeftArmColor = if outfit == "plain" then jacket else look.skin
	description.RightArmColor = if outfit == "plain" then jacket else look.skin
	description.LeftLegColor = if outfit == "plain" then trousers else look.skin
	description.RightLegColor = if outfit == "plain" then trousers else look.skin
	return description
end

-- Dress an R15 model from CaretakerLook and publish it for the clients' CaretakerView. A catalog piece that
-- fails takes the whole build down, so each failure retries with fewer user-made pieces.
local function buildCaretaker(gen: number)
	if not CaretakerLook.enabled then
		return
	end
	local model: Model? = nil
	local problems: { string } = {}
	for _, outfit: Outfit in { "full", "lean", "plain" } :: { Outfit } do
		local ok, result = pcall(function()
			return Players:CreateHumanoidModelFromDescriptionAsync(describe(outfit), Enum.HumanoidRigType.R15)
		end)
		if ok and typeof(result) == "Instance" and result:IsA("Model") then
			model = result
			result:SetAttribute("Outfit", outfit)
			break
		end
		table.insert(problems, outfit .. ": " .. tostring(result))
	end
	if not model then
		log:Warn(
			"the Caretaker could not be dressed (" .. table.concat(problems, "; ") .. "); clients use the built-in rig"
		)
		return
	end
	if #problems > 0 then
		log:Info("Caretaker outfit fell back (" .. table.concat(problems, "; ") .. ")")
	end
	for _, d in model:GetDescendants() do
		if d:IsA("LuaSourceContainer") or d:IsA("Sound") then
			d:Destroy()
		end
	end
	if not current(gen) then
		model:Destroy()
		return
	end
	model.Name = CARETAKER_TEMPLATE
	local existing = ReplicatedStorage:FindFirstChild(CARETAKER_TEMPLATE)
	if existing then
		existing:Destroy()
	end
	model.Parent = ReplicatedStorage
	log:Debug("Caretaker dressed and published")
end

-- Keys that failed and why (for the admin notice and the debug screen).
function AssetLibraryService.failures(): { [string]: string }
	return failures
end

function AssetLibraryService.summary(): (number, number, boolean)
	return loadedCount, failedCount, finished
end

function AssetLibraryService.isFinished(): boolean
	return finished
end

-- True when nothing at all could load: almost always the "Allow Loading Third Party Assets" setting.
function AssetLibraryService.blocked(): boolean
	return finished and loadedCount == 0 and failedCount > 0
end

function AssetLibraryService.Init()
	Registry.add("AssetLibrary", AssetLibraryService)
	local existing = ReplicatedStorage:FindFirstChild(Assets.FOLDER)
	if existing then
		existing:Destroy()
	end
	root = Instance.new("Folder")
	root.Name = Assets.FOLDER
	root.Parent = ReplicatedStorage
end

-- Load every manifest key (a few at a time) and dress the Caretaker.
local function loadAll()
	generation += 1
	local gen = generation
	finished = false
	loadedCount, failedCount = 0, 0
	table.clear(status)
	table.clear(failures)
	task.spawn(buildCaretaker, gen)
	local keys = AssetManifest.keys()
	local started = os.clock()
	local queue = table.clone(keys)
	local done = 0
	local function nextKey()
		local key = table.remove(queue, 1)
		if not key then
			return
		end
		task.spawn(function()
			local ok, problem = pcall(function(): any
				loadKey(key, gen)
				return nil
			end)
			if not ok and gen == generation then
				status[key] = "failed"
				failures[key] = tostring(problem)
				failedCount += 1
			end
			done += 1
			if current(gen) then
				nextKey()
			end
		end)
	end
	for _ = 1, CONCURRENCY do
		nextKey()
	end
	while done < #keys and current(gen) do
		task.wait(0.1)
	end
	if not current(gen) then
		return
	end
	finished = true
	local failedKeys = {}
	for key in failures do
		table.insert(failedKeys, key)
	end
	table.sort(failedKeys)
	log:Info(
		string.format(
			"asset library: %d/%d props ready in %.1fs%s",
			loadedCount,
			#keys,
			os.clock() - started,
			if #failedKeys > 0 then " (fallbacks: " .. table.concat(failedKeys, ", ") .. ")" else ""
		)
	)
	if AssetLibraryService.blocked() then
		local sample = failures[failedKeys[1]] or ""
		log:Warn(
			"no Creator Store model could load ("
				.. sample
				.. "). Turn on Game Settings > Security > "
				.. "Allow Loading Third Party Assets, then restart the server; until then the hotel uses its "
				.. "built-in props."
		)
	end
	AssetLibraryService.Finished:Fire(keys, failedKeys)
end

-- The `assets` flag went off on a running server: drop every template (clients put their own slots back as
-- the templates disappear), put the built-in props back in the server's slots and retire the Caretaker's
-- outfit (runs from now on use the built-in rig).
local function switchOff()
	generation += 1
	finished = true
	root:ClearAllChildren()
	local reverted = Assets.revert()
	local rig = ReplicatedStorage:FindFirstChild(CARETAKER_TEMPLATE)
	if rig then
		rig:Destroy()
	end
	log:Info(string.format("asset library switched off: %d slot(s) back to built-in props", reverted))
end

function AssetLibraryService.Start()
	local flags = Registry.get("Flags")
	local function applyFlag()
		Assets.setEnabled(flags.feature("assets"))
	end
	applyFlag()
	flags.Changed:Connect(applyFlag)
	-- Headless test engines have no asset loading at all: they keep the procedural props.
	local canLoad = pcall(function(): any
		return (AssetService :: any).LoadAssetAsync
	end)
	if #AssetManifest.keys() == 0 or not canLoad or not RunService:IsServer() then
		finished = true
		AssetLibraryService.Finished:Fire({}, {})
		return
	end
	task.spawn(function()
		-- A kill switch already thrown must stop the very first load: wait for this server's first read of the
		-- live flags (a moment; the hotel shows its built-in props meanwhile).
		flags.waitReady(8)
		local on = flags.feature("assets")
		flags.Changed:Connect(function()
			local now = flags.feature("assets")
			if now ~= on then
				on = now
				if now then
					task.spawn(loadAll)
				else
					switchOff()
				end
			end
		end)
		if on then
			loadAll()
		else
			finished = true
			log:Info("asset library off (feature flag)")
		end
	end)
end

return AssetLibraryService
