--!strict
--[[
	CinematicController: transitions between the lobby and an expedition (S02, A06).

	* Departure: the elevator hums and rattles for the ride, fades to black just before arrival and opens on
	  the expedition floor with a ding.
	* Capture: a punch of field of view and shake as the room folds and the alarm starts.
	* Return: after the result the screen fades out before the trip back to the lobby and fades in there.
	A watchdog always fades back in, so the screen can never stay black.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.Config.GameConfig)
local Net = require(Shared.Net.Net)
local RunInfo = require(script.Parent.Parent.Core.RunInfo)
local AudioController = require(script.Parent.AudioController)
local CameraController = require(script.Parent.CameraController)
local UIRoot = require(script.Parent.Parent.UI.UIRoot)

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
		AudioController.play("elevator_ding", { volume = 1 })
		task.delay(0.15, function()
			fadeIn(0.7)
		end)
	elseif phase == "Capture" then
		CameraController.punchFov(10, 1.2)
		CameraController.shake(0.6, 0.9)
	elseif phase == "Results" and RunInfo.inRunPhase() == false and previous ~= "Prep" then
		stopRide()
		local outcome = RunInfo.run().outcome
		if outcome == "Success" then
			AudioController.play("elevator_ding", { volume = 1 })
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
	Net.listen("Teleported", function()
		if black then
			task.delay(0.25, function()
				fadeIn(0.6)
			end)
		end
	end)
end

return CinematicController
