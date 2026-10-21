--!strict
--[[
	PoseController: what players' bodies do on top of Roblox's default animations (A05).

	  carrying   the suitcase hangs from a straight right arm, the free arm out for balance and the body
	             leaning away from the weight (more for the room cargo than for the small selected-room case)
	  downed     slumped where they sit, head lolling, cartoon stars circling overhead
	  reviving   crouched over the teammate with both hands reaching down
	  capturing  arms out holding the suitcase open towards the room, leaning back against the pull
	  escaped    a cheer when the squad gets out (Roblox's own R15 emote, which plays in every experience)

	Poses blend onto the animated joints every frame (Motor6D.Transform, written after the Animator has run),
	on every client and for every character it can see, so teammates see each other's poses. R6 bodies get
	the arm and lean parts of each pose. Nothing here replicates or touches physics.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local RunInfo = require(script.Parent.Parent.Core.RunInfo)
local InteractionController = require(script.Parent.InteractionController)

local PoseController = {}
PoseController.priority = 70

local CHEER_ANIMATION = "rbxassetid://507770677" -- R15 Cheer (Roblox)
local STAR_IMAGE = "rbxassetid://81834701835654" -- four-point star (A10)
local BLEND_RATE = 7 -- per second

-- carry | carryLight | downed | revive | capture
type Pose = string
local POSES: { Pose } = { "carry", "carryLight", "downed", "revive", "capture" }

type Rig = {
	character: Model,
	r15: boolean,
	joints: { [string]: Motor6D },
	legs: { upper: number, lower: number },
	weights: { [Pose]: number },
	stars: BillboardGui?,
	starLabels: { ImageLabel },
	cheered: boolean,
}

local rigs: { [Model]: Rig } = setmetatable({}, { __mode = "k" }) :: any

local function rad(degrees: number): number
	return math.rad(degrees)
end

local function motor(parent: Instance?, name: string): Motor6D?
	local m = parent and parent:FindFirstChild(name)
	return if m and m:IsA("Motor6D") then m else nil
end

local function buildRig(character: Model): Rig?
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return nil
	end
	local joints: { [string]: Motor6D } = {}
	local r15 = humanoid.RigType == Enum.HumanoidRigType.R15
	local function add(key: string, m: Motor6D?)
		if m then
			joints[key] = m
		end
	end
	local legs = { upper = 1.2, lower = 1.3 }
	if r15 then
		add("rightShoulder", motor(character:FindFirstChild("RightUpperArm"), "RightShoulder"))
		add("rightElbow", motor(character:FindFirstChild("RightLowerArm"), "RightElbow"))
		add("leftShoulder", motor(character:FindFirstChild("LeftUpperArm"), "LeftShoulder"))
		add("leftElbow", motor(character:FindFirstChild("LeftLowerArm"), "LeftElbow"))
		add("waist", motor(character:FindFirstChild("UpperTorso"), "Waist"))
		add("neck", motor(character:FindFirstChild("Head"), "Neck"))
		add("root", motor(character:FindFirstChild("LowerTorso"), "Root"))
		add("rightHip", motor(character:FindFirstChild("RightUpperLeg"), "RightHip"))
		add("leftHip", motor(character:FindFirstChild("LeftUpperLeg"), "LeftHip"))
		add("rightKnee", motor(character:FindFirstChild("RightLowerLeg"), "RightKnee"))
		add("leftKnee", motor(character:FindFirstChild("LeftLowerLeg"), "LeftKnee"))
		local upper = character:FindFirstChild("RightUpperLeg")
		local lower = character:FindFirstChild("RightLowerLeg")
		local foot = character:FindFirstChild("RightFoot")
		if upper and upper:IsA("BasePart") and lower and lower:IsA("BasePart") then
			legs.upper = upper.Size.Y
			legs.lower = lower.Size.Y + (if foot and foot:IsA("BasePart") then foot.Size.Y * 0.5 else 0)
		end
	else
		local torso = character:FindFirstChild("Torso")
		add("rightShoulder", motor(torso, "Right Shoulder"))
		add("leftShoulder", motor(torso, "Left Shoulder"))
		add("neck", motor(torso, "Neck"))
	end
	if not joints.rightShoulder then
		return nil
	end
	local weights = {} :: { [Pose]: number }
	for _, pose in POSES do
		weights[pose] = 0
	end
	return {
		character = character,
		r15 = r15,
		joints = joints,
		legs = legs,
		weights = weights,
		stars = nil,
		starLabels = {},
		cheered = false,
	}
end

-- Pose targets (joint Transforms; R15 joints are aligned with the body: X right, Y up, -Z forward) ----------

local function poseTargets(rig: Rig, pose: Pose, t: number): { [string]: CFrame }
	if not rig.r15 then
		-- R6 shoulder joints turn about their own X axis (out from the body): arms down and still.
		if pose == "carry" or pose == "carryLight" or pose == "downed" then
			return { rightShoulder = CFrame.new(), leftShoulder = CFrame.new() }
		end
		return {}
	end
	if pose == "carry" or pose == "carryLight" then
		local heavy = pose == "carry"
		local sway = math.sin(t * 2.2) * rad(2)
		return {
			rightShoulder = CFrame.Angles(0, 0, rad(if heavy then 9 else 5)),
			rightElbow = CFrame.new(),
			leftShoulder = CFrame.Angles(rad(8), 0, rad(if heavy then -22 else -10)),
			waist = CFrame.Angles(0, 0, rad(if heavy then 8 else 4) + sway),
		}
	elseif pose == "downed" then
		return {
			waist = CFrame.Angles(rad(-26), 0, math.sin(t * 1.7) * rad(6)),
			neck = CFrame.Angles(
				rad(-16) + math.sin(t * 2.3) * rad(7),
				math.sin(t * 1.3) * rad(14),
				math.sin(t * 1.9) * rad(10)
			),
			rightShoulder = CFrame.Angles(rad(14), 0, rad(10)),
			leftShoulder = CFrame.Angles(rad(14), 0, rad(-10)),
			rightElbow = CFrame.Angles(rad(12), 0, 0),
			leftElbow = CFrame.Angles(rad(12), 0, 0),
		}
	elseif pose == "revive" then
		-- A squat: thighs forward, shins back, the body lowered so the feet stay on the floor.
		local hip, knee = rad(62), rad(-96)
		local legs = rig.legs
		local drop = legs.upper * (1 - math.cos(hip)) + legs.lower * (1 - math.cos(hip + knee))
		local pump = math.sin(t * 6) * rad(5)
		return {
			root = CFrame.new(0, -drop, 0),
			rightHip = CFrame.Angles(hip, 0, 0),
			leftHip = CFrame.Angles(hip, 0, 0),
			rightKnee = CFrame.Angles(knee, 0, 0),
			leftKnee = CFrame.Angles(knee, 0, 0),
			waist = CFrame.Angles(rad(-34), 0, 0),
			neck = CFrame.Angles(rad(-14), 0, 0),
			rightShoulder = CFrame.Angles(rad(68) + pump, 0, rad(-6)),
			leftShoulder = CFrame.Angles(rad(68) - pump, 0, rad(6)),
			rightElbow = CFrame.Angles(rad(18), 0, 0),
			leftElbow = CFrame.Angles(rad(18), 0, 0),
		}
	elseif pose == "capture" then
		local shake = math.sin(t * 31) * rad(1.6)
		return {
			waist = CFrame.Angles(rad(12) + shake, 0, 0),
			neck = CFrame.Angles(rad(-6), 0, 0),
			rightShoulder = CFrame.Angles(rad(82) + shake, 0, rad(-8)),
			leftShoulder = CFrame.Angles(rad(82) - shake, 0, rad(8)),
			rightElbow = CFrame.Angles(rad(10), 0, 0),
			leftElbow = CFrame.Angles(rad(10), 0, 0),
		}
	end
	return {}
end

-- What the player is doing -------------------------------------------------------------------------------

local function poseFor(player: Player, character: Model): Pose?
	if player:GetAttribute("Downed") == true then
		return "downed"
	end
	local kind = InteractionController.holdKind(player)
	if kind == "revive" then
		return "revive"
	elseif kind == "capture" then
		return "capture"
	end
	if player:GetAttribute("Carrying") == true or character:FindFirstChild("CargoSuitcase") then
		return "carry"
	end
	if character:FindFirstChild("HeldSuitcase") then
		return "carryLight"
	end
	return nil
end

-- Dizzy stars -----------------------------------------------------------------------------------------------

local function setStars(rig: Rig, on: boolean)
	if on and not rig.stars then
		local head = rig.character:FindFirstChild("Head")
		if not (head and head:IsA("BasePart")) then
			return
		end
		local gui = Instance.new("BillboardGui")
		gui.Name = "RN_DizzyStars"
		gui.Size = UDim2.fromScale(3.2, 1.6)
		gui.StudsOffsetWorldSpace = Vector3.new(0, head.Size.Y * 0.5 + 0.9, 0)
		gui.LightInfluence = 0
		gui.MaxDistance = 90
		gui.Adornee = head
		local labels: { ImageLabel } = {}
		for i = 1, 3 do
			local star = Instance.new("ImageLabel")
			star.Name = "Star" .. i
			star.AnchorPoint = Vector2.new(0.5, 0.5)
			star.Size = UDim2.fromScale(0.3, 0.6)
			star.BackgroundTransparency = 1
			star.Image = STAR_IMAGE
			star.ImageColor3 = Color3.fromRGB(255, 220, 90)
			star.Parent = gui
			table.insert(labels, star)
		end
		gui.Parent = rig.character
		rig.stars = gui
		rig.starLabels = labels
	elseif not on and rig.stars then
		(rig.stars :: BillboardGui):Destroy()
		rig.stars = nil
		rig.starLabels = {}
	end
end

local function spinStars(rig: Rig, t: number)
	for i, star in rig.starLabels do
		local angle = t * 3.4 + (i - 1) * math.pi * 2 / 3
		local depth = math.sin(angle) -- -1 behind the head, 1 in front
		star.Position = UDim2.fromScale(0.5 + math.cos(angle) * 0.36, 0.5 + depth * 0.18)
		local size = 0.24 + (depth + 1) * 0.06
		star.Size = UDim2.fromScale(size, size * 2)
		star.ImageTransparency = 0.45 - depth * 0.4
		star.Rotation = t * 160 + i * 40
		star.ZIndex = if depth > 0 then 2 else 1
	end
end

-- Cheer ----------------------------------------------------------------------------------------------------

local function cheer(rig: Rig)
	if rig.cheered or not rig.r15 then
		return
	end
	rig.cheered = true
	local humanoid = rig.character:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		return
	end
	local animation = Instance.new("Animation")
	animation.AnimationId = CHEER_ANIMATION
	local ok, track = pcall(function()
		return animator:LoadAnimation(animation)
	end)
	if ok and track then
		track.Priority = Enum.AnimationPriority.Action
		track:Play(0.15)
	end
end

-- Frame ----------------------------------------------------------------------------------------------------

local function step(dt: number)
	local t = os.clock()
	local blend = math.clamp(dt * BLEND_RATE, 0, 1)
	for _, player in Players:GetPlayers() do
		local character = player.Character
		if not character or not character.Parent then
			continue
		end
		local rig = rigs[character]
		if not rig then
			local made = buildRig(character)
			if not made then
				continue
			end
			rig = made
			rigs[character] = made
		end
		local r = rig :: Rig
		local active = poseFor(player, character)
		local any = false
		for _, pose in POSES do
			local goal = if pose == active then 1 else 0
			local w = r.weights[pose] + (goal - r.weights[pose]) * blend
			if w < 0.005 then
				w = 0
			end
			r.weights[pose] = w
			if w > 0 then
				any = true
			end
		end
		setStars(r, active == "downed")
		if r.stars then
			spinStars(r, t)
		end
		if not any then
			continue
		end
		for _, pose in POSES do
			local w = r.weights[pose]
			if w > 0 then
				for key, target in poseTargets(r, pose, t) do
					local m = r.joints[key]
					if m then
						m.Transform = m.Transform:Lerp(target, w)
					end
				end
			end
		end
	end
end

local function onPhase(phase: string)
	if phase ~= "Results" or RunInfo.run().outcome ~= "Success" then
		for _, rig in rigs do
			rig.cheered = false
		end
		return
	end
	for key in RunInfo.roster() do
		local player = RunInfo.playerFor(key)
		local character = player and player.Character
		local rig = character and rigs[character]
		if rig then
			cheer(rig)
		end
	end
end

function PoseController.start()
	-- Stepped runs after the Animator has written this frame's joint transforms.
	RunService.Stepped:Connect(function(_: number, dt: number)
		step(dt)
	end)
	RunInfo.PhaseChanged:Connect(onPhase)
end

return PoseController
