--!strict
--[[
	CinematicController: transitions between the lobby and an expedition (S02, A06).

	* Departure: the elevator hums and rattles for the ride, fades to black just before arrival and opens on
	  the expedition floor with a ding - on a shot from the corridor as the doors part on the squad, which
	  then swings round behind the player.
	* Capture: a punch of field of view and shake as the room folds and the alarm starts; the camera pulls
	  back to watch the room fold into its doorway, and pushes in on the Caretaker as it wakes.
	* Extraction: the doors close on the squad from the corridor; a failure gets a slow sinking zoom.
	* Return: after the result the screen fades out before the trip back to the lobby and fades in there.
	A watchdog always fades back in, so the screen can never stay black. Shots are short, skipped with
	Reduced Motion, and always hand the camera back (CameraController.cinematic).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.Config.GameConfig)
local Net = require(Shared.Net.Net)
local RunInfo = require(script.Parent.Parent.Core.RunInfo)
local AudioController = require(script.Parent.AudioController)
local CameraController = require(script.Parent.CameraController)
local CaretakerView = require(script.Parent.CaretakerView)
local UIRoot = require(script.Parent.Parent.UI.UIRoot)
local Motion = require(script.Parent.Parent.UI.Motion)

local CinematicController = {}
CinematicController.priority = 35

local ride: AudioController.LoopHandle? = nil
local black = false
local token = 0

local function fadeOut(seconds: number)
	black = true
	UIRoot.fadeOut(seconds)
	token += 1
	local mine = token
	-- Watchdog: never leave the player in the dark.
	task.delay(7, function()
		if black and token == mine then
			black = false
			UIRoot.fadeIn(0.6)
		end
	end)
end

local function fadeIn(seconds: number)
	if not black then
		return
	end
	black = false
	UIRoot.fadeIn(seconds)
end

-- Shots -------------------------------------------------------------------------------------------------

local captureUntil = 0

-- In-run shots: for squad members on their feet (not downed or watching a teammate as a spectator).
local function shotsAllowed(): boolean
	local me = Players.LocalPlayer
	return RunInfo.isParticipant()
		and not Motion.isReduced()
		and me:GetAttribute("Downed") ~= true
		and me:GetAttribute("Spectating") ~= true
end

-- Results shots: anyone who was in this run.
local function resultShotsAllowed(): boolean
	return RunInfo.inThisRun() and not Motion.isReduced()
end

local function myRoot(): BasePart?
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

-- A point in the first tile's space (the elevator tile): x right, y up, a forward along the corridor.
local function elevatorPoint(x: number, y: number, a: number): Vector3?
	local level = RunInfo.level()
	local tile = level and level.tiles and level.tiles[1]
	if not tile then
		return nil
	end
	return (tile.cf :: CFrame) * Vector3.new(x, y, -a)
end

-- Roughly where the default camera settles behind the player, so handing control back does not jump.
local function behindPlayer(forward: Vector3): CFrame?
	local root = myRoot()
	if not root then
		return nil
	end
	local flat = Vector3.new(forward.X, 0, forward.Z)
	local dir = if flat.Magnitude > 1e-3 then flat.Unit else root.CFrame.LookVector
	local focus = root.CFrame.Position + Vector3.new(0, 1.5, 0)
	return CFrame.lookAt(focus - dir * 11 + Vector3.new(0, 3.6, 0), focus + dir * 6)
end

-- The doors part on the squad: from the corridor, then round behind the player.
local function arrivalShot()
	if not shotsAllowed() then
		return
	end
	local inside = elevatorPoint(0, 4.2, -12)
	local far = elevatorPoint(1.6, 5.8, 7.5)
	local near = elevatorPoint(0.8, 5.2, 3.6)
	local level = RunInfo.level()
	local tile = level and level.tiles and level.tiles[1]
	if not (inside and far and near and tile) then
		return
	end
	local finish = behindPlayer((tile.cf :: CFrame).LookVector)
	if not finish then
		return
	end
	CameraController.cinematic({
		{ cframe = CFrame.lookAt(far :: Vector3, inside :: Vector3), seconds = 0.01 },
		{ cframe = CFrame.lookAt(near :: Vector3, inside :: Vector3), seconds = 1.15, style = Enum.EasingStyle.Sine },
		{ cframe = finish :: CFrame, seconds = 1.2, style = Enum.EasingStyle.Quad },
	})
end

-- The theft: pull back to watch the room fold into its doorway.
local function captureShot()
	if not shotsAllowed() then
		return
	end
	local level = RunInfo.level()
	local door: CFrame? = if level and level.target then level.target.doorCF else nil
	if not door then
		return
	end
	-- doorCF looks out of the room into the corridor.
	local doorPoint = (door :: CFrame).Position + Vector3.new(0, 4.5, 0)
	local outward = (door :: CFrame).LookVector
	local wide = doorPoint + outward * 13 + Vector3.new(2.5, 2.4, 0)
	captureUntil = os.clock() + GameConfig.Capture.FoldCinematicSeconds
	CameraController.cinematic({
		{ cframe = CFrame.lookAt(wide, doorPoint), seconds = 0.55, style = Enum.EasingStyle.Quart },
	}, GameConfig.Capture.FoldCinematicSeconds - 0.8)
end

-- The Caretaker wakes: a quick push in on it, then back to the player. During a theft it waits for the
-- pull-back to finish, so the two shots play as one sequence ending as the escape starts.
local function wakeShot()
	if not shotsAllowed() then
		return
	end
	local wait = if os.clock() < captureUntil then captureUntil - os.clock() - 1.35 else 0.1
	task.wait(math.max(0.1, wait))
	if not shotsAllowed() then
		return
	end
	local position = CaretakerView.position()
	local root = myRoot()
	if not position or not root then
		return
	end
	local head = (position :: Vector3) + Vector3.new(0, 2.6, 0)
	local toPlayer = root.CFrame.Position - head
	local flat = Vector3.new(toPlayer.X, 0, toPlayer.Z)
	local dir = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.new(0, 0, 1)
	local finish = behindPlayer(-dir)
	if not finish then
		return
	end
	-- Coming off the capture shot, the camera is already looking at the doorway: push in from there.
	local fromCapture = os.clock() < captureUntil
	local shots: { CameraController.Shot } = {}
	if not fromCapture then
		table.insert(shots, {
			cframe = CFrame.lookAt(head + dir * 11 + Vector3.new(0, 1.2, 0), head),
			seconds = 0.01,
		})
	end
	table.insert(shots, {
		cframe = CFrame.lookAt(head + dir * 6.5 + Vector3.new(0, 0.6, 0), head),
		seconds = 0.75,
		fov = 52,
		style = Enum.EasingStyle.Quint,
	})
	table.insert(shots, { cframe = finish :: CFrame, seconds = 0.6, fov = 70, style = Enum.EasingStyle.Quad })
	CameraController.shake(0.5, 0.6)
	CameraController.cinematic(shots, 0)
end

-- Escaped: the doors close on the squad, seen from the corridor (handing back just before the fade).
local function extractionShot()
	if not resultShotsAllowed() then
		return
	end
	local inside = elevatorPoint(0, 4.2, -12)
	local near = elevatorPoint(1.4, 5.4, 4)
	local back = elevatorPoint(2, 6.2, 9)
	if not (inside and near and back) then
		return
	end
	CameraController.cinematic({
		{ cframe = CFrame.lookAt(near :: Vector3, inside :: Vector3), seconds = 0.01 },
		{ cframe = CFrame.lookAt(back :: Vector3, inside :: Vector3), seconds = 1.7, style = Enum.EasingStyle.Sine },
	}, 0.1)
end

-- Caught or out of time: a slow sinking push in while the banner shows (handing back before the fade).
local function failureShot()
	if not resultShotsAllowed() then
		return
	end
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local from = camera.CFrame
	CameraController.cinematic({
		{
			cframe = from * CFrame.new(0, -0.5, -3) * CFrame.Angles(math.rad(-4), 0, math.rad(3)),
			seconds = 1.55,
			fov = 58,
			style = Enum.EasingStyle.Quad,
		},
	}, 0.05)
end

local function stopRide()
	if ride then
		ride.stop(0.5)
		ride = nil
	end
end

local function onPhase(phase: string, previous: string)
	if phase == "Launching" and RunInfo.isParticipant() then
		stopRide()
		ride = AudioController.loop("elevator_move_loop", { group = "Effects", fadeIn = 0.6 })
		AudioController.setDuck(0.4, 0.8)
		CameraController.shake(0.25, GameConfig.Squad.ElevatorRideSeconds, 9)
		task.delay(math.max(0.5, GameConfig.Squad.ElevatorRideSeconds - 0.7), function()
			if RunInfo.phase() == "Launching" then
				fadeOut(0.5)
			end
		end)
	elseif phase == "Explore" and previous == "Launching" then
		stopRide()
		AudioController.setDuck(1, 1)
		if RunInfo.inThisRun() then
			AudioController.play("elevator_ding", { volume = 1 })
		end
		task.delay(0.15, function()
			fadeIn(0.7)
			task.spawn(arrivalShot)
		end)
	elseif phase == "Capture" then
		if RunInfo.isParticipant() then
			CameraController.punchFov(10, 1.2)
			CameraController.shake(0.6, 0.9)
			task.spawn(captureShot)
		end
	elseif phase == "Results" and previous ~= "Prep" and RunInfo.inThisRun() then
		-- Only the squad rides back (bystanders in the lobby are never teleported, so no fade for them).
		stopRide()
		local outcome = RunInfo.run().outcome
		if outcome == "Success" then
			AudioController.play("elevator_ding", { volume = 1 })
			task.spawn(extractionShot)
		elseif outcome == "Wiped" or outcome == "TimeUp" then
			task.spawn(failureShot)
		end
		task.delay(if outcome == "Success" then 2.1 else 1.7, function()
			if RunInfo.phase() == "Results" then
				fadeOut(0.45)
			end
		end)
	elseif phase == "Prep" then
		stopRide()
		AudioController.setDuck(1, 0.6)
		fadeIn(0.6)
	end
end

function CinematicController.start()
	RunInfo.PhaseChanged:Connect(onPhase)
	Net.listen("Effect", function(name: any)
		if name == "caretakerAlert" then
			task.spawn(wakeShot)
		end
	end)
	Net.listen("Teleported", function()
		if black then
			task.delay(0.25, function()
				fadeIn(0.6)
			end)
		end
	end)
end

return CinematicController
