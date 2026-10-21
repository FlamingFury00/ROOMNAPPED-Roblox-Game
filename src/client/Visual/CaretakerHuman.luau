--!strict
--[[
	CaretakerHuman: the Caretaker as a full R15 character (A03).

	The server dresses an R15 model from catalog items (CaretakerLook, AssetLibraryService) and publishes it as
	ReplicatedStorage.RN_CaretakerRig. Each client clones it, anchors its root to the interpolated position and
	plays Roblox's own animation packs on it (Roblox-made animations play in every experience):

	  Patrol / Investigate / Search   Elder idle, walk and look-around (a creaky old night manager)
	  Chase / Hunt / Lunge / Alert    Werewolf idle, run and look-around (hunched and fast)
	  Dormant                         sitting asleep, chin on chest

	On top of the animation the view adds what the mode needs: head turns and tilts on the neck, a crouch and
	reach for the lunge, a stagger for React, a lean into the wind, frost and a blue tint when chilled, the
	fade for Phase - plus a swinging lantern, a key ring and glowing eyes. CaretakerView falls back to its
	part-built bellhop when no template exists (offline tests, or the catalog could not be reached).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CaretakerHuman = {}

CaretakerHuman.TEMPLATE = "RN_CaretakerRig"

-- Roblox-made R15 animations (verified type-24 assets created by Roblox).
local ANIMATIONS: { [string]: number } = {
	idle = 845397899, -- Elder_Idle
	walk = 845403856, -- Elder_Walk
	look = 845400520, -- Elder_LookAround
	huntIdle = 1083195517, -- Werewolf Idle
	run = 1083216690, -- Werewolf Run
	huntLook = 1083214717, -- Werewolf Look Around
	sit = 2506281703, -- SitV2
	point = 507770453, -- R15Point
}

-- Studs per second each looping clip was authored for (at height scale 1).
local CLIP_SPEED: { [string]: number } = { walk = 9, run = 18 }

export type HumanRig = {
	model: Model,
	humanoid: Humanoid,
	root: BasePart,
	head: BasePart,
	torso: BasePart,
	parts: { BasePart },
	clothes: { Clothing },
	clothingColors: { [Clothing]: Color3 },
	tracks: { [string]: AnimationTrack },
	current: string,
	neck: Motor6D?,
	neckC0: CFrame,
	waist: Motor6D?,
	waistC0: CFrame,
	shoulderL: Motor6D?,
	shoulderLC0: CFrame,
	shoulderR: Motor6D?,
	shoulderRC0: CFrame,
	rootLift: number, -- root height above the floor
	heightScale: number,
	lantern: BasePart,
	lanternLight: PointLight,
	eyeL: BasePart,
	eyeR: BasePart,
	eyeLight: PointLight,
	headTop: number, -- height of the top of the head above the root, for the badge
}

function CaretakerHuman.available(): boolean
	local template = ReplicatedStorage:FindFirstChild(CaretakerHuman.TEMPLATE)
	return template ~= nil and template:IsA("Model") and template:FindFirstChildOfClass("Humanoid") ~= nil
end

local function weldTo(part: BasePart, to: BasePart, offset: CFrame)
	part.CFrame = to.CFrame * offset
	local weld = Instance.new("Weld")
	weld.Part0 = to
	weld.Part1 = part
	weld.C0 = offset
	weld.Parent = part
end

local function prop(model: Model, name: string, size: Vector3, color: Color3, material: Enum.Material): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color
	part.Material = material
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = model
	return part
end

local function motor(model: Model, partName: string, motorName: string): (Motor6D?, CFrame)
	local part = model:FindFirstChild(partName)
	local m = part and part:FindFirstChild(motorName)
	if m and m:IsA("Motor6D") then
		return m, m.C0
	end
	return nil, CFrame.new()
end

function CaretakerHuman.build(parent: Instance): HumanRig?
	local template = ReplicatedStorage:FindFirstChild(CaretakerHuman.TEMPLATE)
	if not (template and template:IsA("Model")) then
		return nil
	end
	local model = template:Clone()
	model.Name = "Caretaker"
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart")
	local head = model:FindFirstChild("Head")
	local torso = model:FindFirstChild("UpperTorso")
	local rightHand = model:FindFirstChild("RightHand")
	local leftHand = model:FindFirstChild("LeftHand")
	if
		not humanoid
		or not (root and root:IsA("BasePart"))
		or not (head and head:IsA("BasePart"))
		or not (torso and torso:IsA("BasePart"))
		or not (rightHand and rightHand:IsA("BasePart"))
		or not (leftHand and leftHand:IsA("BasePart"))
	then
		model:Destroy()
		return nil
	end
	-- A puppet: no state machine, no physics fighting the anchored root, no name or health bar.
	humanoid.EvaluateStateMachine = false
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	humanoid.BreakJointsOnDeath = false
	root.Anchored = true
	root.Transparency = 1
	local parts: { BasePart } = {}
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.Massless = true
			if d ~= root then
				table.insert(parts, d)
			end
		end
	end
	local clothes: { Clothing } = {}
	local clothingColors: { [Clothing]: Color3 } = {}
	for _, d in model:GetChildren() do
		if d:IsA("Clothing") then
			table.insert(clothes, d)
			clothingColors[d] = d.Color3
		end
	end

	-- Lantern in the right hand, keys at the left, glowing eyes.
	local lanternFrame =
		prop(model, "LanternFrame", Vector3.new(0.7, 0.95, 0.7), Color3.fromRGB(56, 46, 38), Enum.Material.Metal)
	weldTo(lanternFrame, rightHand, CFrame.new(0, -0.95, -0.15))
	local lantern =
		prop(model, "Lantern", Vector3.new(0.5, 0.6, 0.5), Color3.fromRGB(255, 200, 110), Enum.Material.Neon)
	weldTo(lantern, lanternFrame, CFrame.new(0, 0.02, 0))
	local lanternLight = Instance.new("PointLight")
	lanternLight.Color = Color3.fromRGB(255, 190, 110)
	lanternLight.Range = 16
	lanternLight.Brightness = 1.6
	lanternLight.Shadows = false -- a moving shadowed light redraws its shadow map every frame
	lanternLight.Parent = lantern
	-- Keys in the left hand, unless the outfit already hangs a key ring at the belt.
	local wearsKeys = false
	for _, d in model:GetChildren() do
		if d:IsA("Accessory") and d.AccessoryType == Enum.AccessoryType.Waist then
			wearsKeys = true
		end
	end
	local extras: { BasePart } = { lanternFrame, lantern }
	if not wearsKeys then
		local ring =
			prop(model, "KeyRing", Vector3.new(0.1, 0.7, 0.7), Color3.fromRGB(232, 184, 74), Enum.Material.Foil)
		ring.Shape = Enum.PartType.Cylinder
		weldTo(ring, leftHand, CFrame.new(0, -0.55, 0))
		table.insert(extras, ring)
		for i = 0, 2 do
			local key = prop(model, "Key", Vector3.new(0.1, 0.5, 0.2), Color3.fromRGB(232, 184, 74), Enum.Material.Foil)
			weldTo(key, ring, CFrame.new(0, -0.45 - (i % 2) * 0.08, -0.12 + i * 0.12) * CFrame.Angles(0.3 * i, 0, 0.2))
			table.insert(extras, key)
		end
	end
	local headSize = head.Size
	-- Glowing pupils at eye level: the face-front attachment marks it on every head shape (glasses hang
	-- there); the classic head's eyes sit a little above its centre.
	local faceFront = head:FindFirstChild("FaceFrontAttachment")
	local eyeLine = if faceFront and faceFront:IsA("Attachment")
		then faceFront.CFrame * CFrame.new(0, headSize.Y * 0.03, -0.02)
		else CFrame.new(0, headSize.Y * 0.08, -headSize.Z * 0.5 - 0.01)
	local eyes: { BasePart } = {}
	for _, side in { -1, 1 } do
		local eye = prop(model, "Eye", Vector3.new(0.16, 0.12, 0.08), Color3.fromRGB(255, 240, 180), Enum.Material.Neon)
		weldTo(eye, head, eyeLine * CFrame.new(side * headSize.X * 0.17, 0, 0))
		table.insert(eyes, eye)
	end
	local eyeLight = Instance.new("PointLight")
	eyeLight.Color = Color3.fromRGB(255, 230, 170)
	eyeLight.Range = 5
	eyeLight.Brightness = 0.8
	eyeLight.Shadows = false
	eyeLight.Parent = head
	for _, p in extras do
		table.insert(parts, p)
	end
	for _, p in eyes do
		table.insert(parts, p)
	end

	-- Animations (Roblox's own: they play in every experience).
	local animator = humanoid:FindFirstChildOfClass("Animator") or Instance.new("Animator")
	animator.Parent = humanoid
	local tracks: { [string]: AnimationTrack } = {}
	for name, id in ANIMATIONS do
		local animation = Instance.new("Animation")
		animation.AnimationId = "rbxassetid://" .. tostring(id)
		local ok, track = pcall(function()
			return animator:LoadAnimation(animation)
		end)
		if ok and track then
			track.Looped = name ~= "point"
			track.Priority = if name == "point" then Enum.AnimationPriority.Action else Enum.AnimationPriority.Movement
			tracks[name] = track
		end
	end

	local neck, neckC0 = motor(model, "Head", "Neck")
	local waist, waistC0 = motor(model, "UpperTorso", "Waist")
	local shoulderL, shoulderLC0 = motor(model, "LeftUpperArm", "LeftShoulder")
	local shoulderR, shoulderRC0 = motor(model, "RightUpperArm", "RightShoulder")
	local hip = humanoid.HipHeight
	local rig: HumanRig = {
		model = model,
		humanoid = humanoid,
		root = root,
		head = head,
		torso = torso,
		parts = parts,
		clothes = clothes,
		clothingColors = clothingColors,
		tracks = tracks,
		current = "",
		neck = neck,
		neckC0 = neckC0,
		waist = waist,
		waistC0 = waistC0,
		shoulderL = shoulderL,
		shoulderLC0 = shoulderLC0,
		shoulderR = shoulderR,
		shoulderRC0 = shoulderRC0,
		rootLift = hip + root.Size.Y / 2,
		heightScale = math.max(0.5, (hip + root.Size.Y / 2) / 2.5),
		lantern = lantern,
		lanternLight = lanternLight,
		eyeL = eyes[1],
		eyeR = eyes[2],
		eyeLight = eyeLight,
		headTop = (head.Position.Y + headSize.Y / 2) - root.Position.Y,
	}
	model.Parent = parent
	return rig
end

local function play(r: HumanRig, name: string, fade: number)
	if r.current == name then
		return
	end
	local previous = r.tracks[r.current]
	if previous then
		previous:Stop(fade)
	end
	local track = r.tracks[name]
	if track then
		track:Play(fade)
	end
	r.current = name
end

-- One-shot gesture on top of the loop (spotting a player).
function CaretakerHuman.gesture(r: HumanRig, name: string)
	local track = r.tracks[name]
	if track then
		track:Play(0.1)
	end
end

export type Pose = {
	mode: string,
	modeTime: number, -- seconds in this mode
	headYaw: number,
	headTilt: number,
	crouch: number, -- 0..1
	reach: number, -- 0..1 arms forward
	lean: number, -- radians, + = forward
	wobble: number, -- radians, side to side
	chilled: boolean,
	alpha: number, -- 1 visible, 0 gone
}

local appliedAlpha: { [HumanRig]: number } = setmetatable({}, { __mode = "k" }) :: any
local appliedChill: { [HumanRig]: boolean } = setmetatable({}, { __mode = "k" }) :: any

-- `position` is the server's hover point (Geometry.Caretaker.HoverY above the floor).
function CaretakerHuman.animate(r: HumanRig, position: Vector3, hover: number, yaw: number, speed: number, pose: Pose)
	local hunting = pose.mode == "Chase" or pose.mode == "Hunt" or pose.mode == "Lunge" or pose.mode == "Alert"
	local searching = pose.mode == "Search" or pose.mode == "Investigate"
	local clip: string
	if pose.mode == "Dormant" then
		clip = "sit"
	elseif speed > 1.2 then
		clip = if hunting or speed > 13 then "run" else "walk"
	elseif hunting then
		clip = if pose.mode == "Hunt" then "huntLook" else "huntIdle"
	else
		clip = if searching then "look" else "idle"
	end
	play(r, clip, 0.25)
	local track = r.tracks[clip]
	if track and CLIP_SPEED[clip] then
		track:AdjustSpeed(math.clamp(speed / (CLIP_SPEED[clip] * r.heightScale), 0.4, 1.8))
	end

	-- Root: on the floor (sitting sinks a little), turned to face its heading, leaning and staggering.
	local floor = position.Y - hover
	local sink = if clip == "sit" then r.rootLift * 0.45 else 0
	local crouch = pose.crouch * 0.6
	r.root.CFrame = CFrame.new(position.X, floor + r.rootLift - sink - crouch, position.Z)
		* CFrame.Angles(0, yaw, 0)
		* CFrame.Angles(-pose.lean * 0.5, 0, pose.wobble)

	-- Joints on top of the animation (C0 composes with the animated Transform).
	if r.neck then
		local nod = if clip == "sit" then 0.55 else 0
		r.neck.C0 = r.neckC0 * CFrame.Angles(pose.headTilt * 0.5 - nod, pose.headYaw, pose.headTilt * 0.4)
	end
	if r.waist then
		r.waist.C0 = r.waistC0 * CFrame.Angles(-pose.lean * 0.6 - pose.crouch * 0.35, 0, 0)
	end
	local reach = pose.reach
	if r.shoulderL then
		r.shoulderL.C0 = r.shoulderLC0 * CFrame.Angles(reach * 1.25, 0, -reach * 0.15)
	end
	if r.shoulderR then
		r.shoulderR.C0 = r.shoulderRC0 * CFrame.Angles(reach * 1.0, 0, reach * 0.15)
	end

	-- Lantern flicker.
	local now = os.clock()
	r.lanternLight.Brightness = 1.5 + math.sin(now * 11) * 0.12 + math.sin(now * 23) * 0.08

	-- Chilled: icy tint on the clothes and skin.
	if appliedChill[r] ~= pose.chilled then
		appliedChill[r] = pose.chilled
		for _, c in r.clothes do
			c.Color3 = if pose.chilled
				then (r.clothingColors[c] or Color3.new(1, 1, 1)):Lerp(Color3.fromRGB(150, 200, 255), 0.6)
				else r.clothingColors[c] or Color3.new(1, 1, 1)
		end
	end

	-- Fade (Phase / Off), written only when it changes by a hundredth.
	local transparency = math.round((1 - math.clamp(pose.alpha, 0, 1)) * 100) / 100
	if appliedAlpha[r] ~= transparency then
		appliedAlpha[r] = transparency
		for _, part in r.parts do
			part.LocalTransparencyModifier = transparency
		end
	end
end

function CaretakerHuman.setEyes(r: HumanRig, eye: Color3, lantern: Color3)
	r.eyeL.Color = eye
	r.eyeR.Color = eye
	r.eyeLight.Color = eye
	r.lantern.Color = lantern
	r.lanternLight.Color = lantern
end

function CaretakerHuman.destroy(r: HumanRig)
	for _, track in r.tracks do
		track:Stop(0)
	end
	r.model:Destroy()
end

return CaretakerHuman
