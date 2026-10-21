--!strict
--[[
	MovementController: how the local character moves through room effects (R01, R02, R08, S13, S16).

	The character is simulated by its owner (the client), so movement modifiers live here and the server
	only judges the outcome (falls, hazards, launch combos):

	* Ice (frozen basins / pools): momentum-based sliding - the horizontal velocity eases toward the input
	  with low traction, so you glide, overshoot and drift.
	* Wind (active Fan lanes): a capped push along the lane, weaker further from the fan. Walking into it
	  keeps only a fifth of the push, so it is slower but always possible - even carrying the suitcase along
	  a ledge, where a full push would hold the carrier in place.
	* Ice + wind: on a frozen basin that feeds a launch ramp, a Fan blowing toward the ramp boosts the slide;
	  hitting the ramp fast enough throws you across the gap on a fixed arc to the landing point.
	* Knockback from hazards, slow walking on ledges and while carrying the suitcase, and a full movement
	  lock while downed.

	Horizontal velocity is driven through one LinearVelocity (plane mode) that is only enabled while a
	modifier is active; the rest of the time the default humanoid controller is untouched. Momentum always
	starts from the measured velocity, so walls naturally stop a slide.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.Config.GameConfig)
local MathUtil = require(Shared.Util.MathUtil)
local Signal = require(Shared.Util.Signal)
local Net = require(Shared.Net.Net)
local ClientState = require(script.Parent.Parent.Core.ClientState)
local RunInfo = require(script.Parent.Parent.Core.RunInfo)
local CameraController = require(script.Parent.CameraController)
local AudioController = require(script.Parent.AudioController)

local MovementController = {}
MovementController.priority = 20

MovementController.Launched = Signal.new() -- (launchId)
MovementController.SurfaceChanged = Signal.new() -- (onIce: boolean, inWind: boolean)

local W = GameConfig.Wind
local ICE = GameConfig.Ice

local NORMAL_WIND_TRACTION = 9
local KNOCK_SECONDS = 0.38
local KNOCK_TRACTION = 3.2
local ICE_GRACE_SECONDS = 0.25 -- keep sliding momentum briefly after leaving ice (ramp lips, seams)

local player = Players.LocalPlayer

type CharacterRig = {
	character: Model,
	humanoid: Humanoid,
	root: BasePart,
	velocity: LinearVelocity,
	attachment: Attachment,
}

local rig: CharacterRig? = nil
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true

local knockUntil = 0
local knockVelocity = Vector3.zero
local flightUntil = 0
local flightVelocity = Vector3.zero
local launchCooldownUntil = 0
local lastIceAt = -math.huge
local onIceNow = false
local inWindNow = false
local lastWalkSpeed = -1
local lastJumpHeight = -1
local wasDowned = false

-- Public queries (hints, HUD) -------------------------------------------------------------------------

function MovementController.isOnIce(): boolean
	return onIceNow
end

function MovementController.isInWind(): boolean
	return inWindNow
end

function MovementController.isFlying(): boolean
	return os.clock() < flightUntil
end

-- Character setup ---------------------------------------------------------------------------------------

local function teardownRig()
	if rig then
		rig.velocity:Destroy()
		rig.attachment:Destroy()
		rig = nil
	end
end

local function setupCharacter(character: Model)
	teardownRig()
	local humanoid = character:WaitForChild("Humanoid", 10)
	local root = character:WaitForChild("HumanoidRootPart", 10)
	if not humanoid or not root or not humanoid:IsA("Humanoid") or not root:IsA("BasePart") then
		return
	end
	if character.Parent == nil or player.Character ~= character then
		return
	end
	-- Hearts replace humanoid health; nothing in this game kills a humanoid.
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Dead, false)
	humanoid.BreakJointsOnDeath = false

	local attachment = Instance.new("Attachment")
	attachment.Name = "RN_Locomotion"
	attachment.Parent = root
	local velocity = Instance.new("LinearVelocity")
	velocity.Name = "RN_Locomotion"
	velocity.Attachment0 = attachment
	velocity.RelativeTo = Enum.ActuatorRelativeTo.World
	velocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Plane
	velocity.PrimaryTangentAxis = Vector3.xAxis
	velocity.SecondaryTangentAxis = Vector3.zAxis
	velocity.ForceLimitsEnabled = true
	velocity.ForceLimitMode = Enum.ForceLimitMode.Magnitude
	velocity.MaxForce = math.max(2000, root.AssemblyMass * 2400)
	velocity.Enabled = false
	velocity.Parent = root

	rig = {
		character = character,
		humanoid = humanoid,
		root = root,
		velocity = velocity,
		attachment = attachment,
	}
	rayParams.FilterDescendantsInstances = { character }
	lastWalkSpeed = -1
	lastJumpHeight = -1
	knockUntil = 0
	flightUntil = 0
end

-- Environment queries --------------------------------------------------------------------------------------

local function inBoxes(boxes: any, position: Vector3, margin: number): boolean
	if type(boxes) ~= "table" then
		return false
	end
	for _, b in boxes do
		if MathUtil.pointInBox(b.cf, b.size, position, margin) then
			return true
		end
	end
	return false
end

local function floorIsIce(r: CharacterRig): boolean
	local origin = r.root.CFrame.Position
	local depth = r.humanoid.HipHeight + r.root.Size.Y / 2 + 1.6
	local result = Workspace:Raycast(origin, Vector3.new(0, -depth, 0), rayParams)
	if not result then
		return false
	end
	local part = result.Instance
	return part:HasTag("RN_IceCollider") and part:GetAttribute("Solid") == true
end

type WindSample = { push: Vector3, boost: Vector3?, boostLaunch: string? }

-- Sum of active Fan lanes at a position, plus the slide boost direction if we are on a boosted slide.
local function windAt(level: any, position: Vector3, onIce: boolean): WindSample
	local sample: WindSample = { push = Vector3.zero, boost = nil, boostLaunch = nil }
	local sockets = ClientState.get("global", "sockets")
	if type(sockets) ~= "table" or not level then
		return sample
	end
	for socketId, info in sockets do
		if info.room == "Fan" and info.state ~= "Folding" and type(info.dir) == "string" then
			local socket = level.sockets and level.sockets[socketId]
			local laneId = socket and socket.lanes and socket.lanes[info.dir]
			local lane = laneId and level.lanes[laneId]
			if lane and MathUtil.pointInBox(lane.cf, lane.size, position, 0) then
				local strength = 1
				if info.dir ~= "Across" then
					local origin = socket.doorCF.Position
					local along = (position - origin):Dot(lane.vector)
					local t = math.clamp(along / math.max(lane.size.Z, 1), 0, 1)
					strength = 1 - W.LaneStrengthFalloff * t
				end
				sample.push += lane.vector * strength
				if onIce and type(lane.slides) == "table" then
					for _, launchId in lane.slides do
						local launch = level.launches and level.launches[launchId]
						if launch and MathUtil.pointInBox(launch.slide.cf, launch.slide.size, position, 0.5) then
							sample.boost = lane.vector
							sample.boostLaunch = launchId
						end
					end
				end
			end
		end
	end
	if sample.push.Magnitude > 1 then
		sample.push = sample.push.Unit
	end
	return sample
end

-- A lane's push on a player who is steering `moveFlat`. Only HeadwindScale of the part that opposes the
-- stick survives, so a Fan left blowing the wrong way slows the escape instead of trapping the carrier;
-- standing still or walking with the wind takes the full push.
local function playerPush(push: Vector3, moveFlat: Vector3): Vector3
	local scaled = push * W.PlayerPushSpeed
	if moveFlat.Magnitude > 0.1 then
		local forward = moveFlat.Unit
		local against = -scaled:Dot(forward)
		if against > 0 then
			scaled += forward * against * (1 - W.HeadwindScale)
		end
	end
	return scaled
end

-- Launch -----------------------------------------------------------------------------------------------

local function tryLaunch(r: CharacterRig, level: any, position: Vector3, horizontal: Vector3, now: number): boolean
	if now < launchCooldownUntil or type(level.launches) ~= "table" then
		return false
	end
	for launchId, launch in level.launches do
		if MathUtil.pointInBox(launch.trigger.cf, launch.trigger.size, position, 0.6) then
			local along = horizontal:Dot(launch.direction)
			if along >= W.LaunchMinSpeed then
				local T = W.LaunchFlightSeconds
				local g = Workspace.Gravity
				local delta = (launch.landing :: Vector3) - position
				local flat = Vector3.new(delta.X, 0, delta.Z) / T
				local vy = delta.Y / T + 0.5 * g * T
				flightVelocity = flat
				flightUntil = now + T + 0.12
				launchCooldownUntil = now + 1.2
				r.root.AssemblyLinearVelocity = Vector3.new(flat.X, vy, flat.Z)
				r.humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
				CameraController.punchFov(14, 0.9)
				CameraController.shake(0.6, 0.35)
				AudioController.at("caretaker_grab", position, { volume = 0.8, pitch = 1.25 })
				MovementController.Launched:Fire(launchId)
				return true
			end
		end
	end
	return false
end

-- Main step ---------------------------------------------------------------------------------------------

local function setHumanoidLimits(r: CharacterRig, walk: number, jump: number)
	if walk ~= lastWalkSpeed then
		lastWalkSpeed = walk
		r.humanoid.WalkSpeed = walk
	end
	if jump ~= lastJumpHeight then
		lastJumpHeight = jump
		r.humanoid.UseJumpPower = false
		r.humanoid.JumpHeight = jump
	end
end

local function step(dt: number)
	local r = rig
	if not r or r.character.Parent == nil then
		return
	end
	local now = os.clock()
	local position = r.root.CFrame.Position
	local level = RunInfo.level()
	local inRun = RunInfo.isParticipant() and RunInfo.isActivePhase() and level ~= nil
	local downed = player:GetAttribute("Downed") == true

	-- Walk speed and jump: base, carrying, ledges, downed.
	local walk = GameConfig.Movement.WalkSpeed
	if player:GetAttribute("Carrying") == true then
		walk *= GameConfig.Cargo.CarrierSpeedMultiplier
	end
	if inRun and inBoxes(level.ledges, position, 0.3) then
		walk *= GameConfig.Movement.LedgeSpeedMultiplier
	end
	if downed then
		walk = GameConfig.Movement.DownedWalkSpeed
	end
	setHumanoidLimits(r, walk, if downed then 0 else GameConfig.Movement.JumpHeight)
	if downed ~= wasDowned then
		wasDowned = downed
		r.humanoid.Sit = downed
	elseif downed and not r.humanoid.Sit then
		-- Jumping out of the downed pose is not allowed.
		r.humanoid.Sit = true
	end

	if not inRun or downed then
		r.velocity.Enabled = false
		if onIceNow or inWindNow then
			onIceNow, inWindNow = false, false
			MovementController.SurfaceChanged:Fire(false, false)
		end
		return
	end

	local velocity = r.root.AssemblyLinearVelocity
	local horizontal = Vector3.new(velocity.X, 0, velocity.Z)
	local onIce = floorIsIce(r)
	if onIce then
		lastIceAt = now
	end
	local slippery = now - lastIceAt <= ICE_GRACE_SECONDS
	local wind = windAt(level, position, slippery)
	local inWind = wind.push.Magnitude > 0.01

	if onIce ~= onIceNow or inWind ~= inWindNow then
		onIceNow, inWindNow = onIce, inWind
		MovementController.SurfaceChanged:Fire(onIce, inWind)
	end

	-- Launch ramps (ice + wind).
	if slippery and tryLaunch(r, level, position, horizontal, now) then
		r.velocity.PlaneVelocity = Vector2.new(flightVelocity.X, flightVelocity.Z)
		r.velocity.Enabled = true
		return
	end

	local flying = now < flightUntil
	local knocked = now < knockUntil
	if not (flying or knocked or slippery or inWind) then
		r.velocity.Enabled = false
		return
	end

	local move = r.humanoid.MoveDirection
	local moveFlat = Vector3.new(move.X, 0, move.Z)
	local target: Vector3
	local traction: number
	local maxSpeed: number
	if flying then
		target, traction, maxSpeed = flightVelocity, 0, math.huge
	elseif knocked then
		target, traction, maxSpeed = Vector3.zero, KNOCK_TRACTION, math.huge
	elseif slippery then
		target = moveFlat * walk + playerPush(wind.push, moveFlat)
		traction = if moveFlat.Magnitude > 0.1 then ICE.Traction else ICE.StopTraction
		maxSpeed = ICE.MaxSpeed
	else
		target = moveFlat * walk + playerPush(wind.push, moveFlat)
		traction = NORMAL_WIND_TRACTION
		maxSpeed = W.PlayerMaxSpeed
	end

	local nextVelocity: Vector3
	local knockedNow = knocked and knockVelocity.Magnitude > 0
	if flying then
		nextVelocity = flightVelocity
	elseif wind.boost and slippery and not knockedNow then
		-- Boosted slide: accelerate along the lane up to the boost speed, steer gently across it.
		local dir = wind.boost :: Vector3
		local along = horizontal:Dot(dir)
		local lateral = horizontal - dir * along
		along = math.min(W.SlideBoostSpeed, along + W.SlideBoostAcceleration * dt)
		local steer = moveFlat * walk - dir * moveFlat:Dot(dir) * walk
		lateral += (steer - lateral) * MathUtil.dampAlpha(ICE.Traction, dt)
		nextVelocity = dir * along + lateral
		maxSpeed = W.SlideBoostSpeed
	else
		-- Regular steering. A knock starts from its impulse (already in `horizontal`) and bleeds off the same way.
		nextVelocity = horizontal + (target - horizontal) * MathUtil.dampAlpha(traction, dt)
	end
	nextVelocity = MathUtil.clampMagnitude(nextVelocity, maxSpeed)
	r.velocity.PlaneVelocity = Vector2.new(nextVelocity.X, nextVelocity.Z)
	r.velocity.Enabled = true
end

local function onKnockback(direction: any, strength: any)
	local r = rig
	if not r or typeof(direction) ~= "Vector3" or type(strength) ~= "number" then
		return
	end
	local impulse = (direction :: Vector3) * math.clamp(strength :: number, 0, 120)
	knockVelocity = Vector3.new(impulse.X, 0, impulse.Z)
	knockUntil = os.clock() + KNOCK_SECONDS
	flightUntil = 0
	local current = r.root.AssemblyLinearVelocity
	r.root.AssemblyLinearVelocity = Vector3.new(impulse.X, math.max(current.Y, impulse.Y), impulse.Z)
	r.velocity.PlaneVelocity = Vector2.new(impulse.X, impulse.Z)
	r.velocity.Enabled = true
	CameraController.shake(0.9, 0.3)
end

function MovementController.start()
	if player.Character then
		task.spawn(setupCharacter, player.Character)
	end
	player.CharacterAdded:Connect(function(character: Model)
		setupCharacter(character)
	end)
	player.CharacterRemoving:Connect(function()
		teardownRig()
	end)
	Net.listen("Knockback", onKnockback)
	Net.listen("Teleported", function()
		local r = rig
		knockUntil, flightUntil = 0, 0
		lastIceAt = -math.huge
		if r then
			r.velocity.Enabled = false
			r.root.AssemblyLinearVelocity = Vector3.zero
		end
	end)
	RunService.PreSimulation:Connect(step)
end

return MovementController
