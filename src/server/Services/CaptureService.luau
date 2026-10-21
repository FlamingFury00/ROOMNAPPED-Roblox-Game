--!strict
--[[
	CaptureService: stealing the target room (S12, A04).

	A completed (server-verified) 3 second hold at the intact target folds the room into the shared suitcase,
	raises the alert and starts the escape. Cancelling grants nothing; a capture produces exactly one cargo.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.Config.GameConfig)
local Kit = require(Shared.World.Kit)
local Palette = require(Shared.World.Palette)
local Registry = require(script.Parent.Parent.Core.Registry)
local StateServer = require(script.Parent.Parent.Core.StateServer)
local RunTypes = require(script.Parent.Parent.Core.RunTypes)

type Run = RunTypes.Run
type RosterEntry = RunTypes.RosterEntry

local CaptureService = {}

local global = StateServer.global("global")

function CaptureService.isCaptured(run: Run): boolean
	return run.scratch.capture ~= nil and run.scratch.capture.done == true
end

function CaptureService.capturePoint(run: Run): Vector3
	return run.runtime.target.capturePoint
end

function CaptureService.canCapture(run: Run, entry: RosterEntry): boolean
	return not run.ended
		and Registry.get("Expedition").phase() == "Explore"
		and not CaptureService.isCaptured(run)
		and entry.health.status == "Active"
end

function CaptureService.complete(run: Run, entry: RosterEntry)
	if not CaptureService.canCapture(run, entry) then
		return
	end
	run.scratch.capture = { done = true, by = entry.userId }
	local target = run.runtime.target
	global:Set({ "rooms", "target" }, { state = "Folding", room = target.room, since = workspace:GetServerTimeNow() })
	Registry.get("Expedition")
		.fireRun("capture", { room = target.room, by = entry.key, position = target.capturePoint })
	Registry.get("Cargo").spawnCargo(run, entry, target.room)
	Registry.get("Expedition").onCaptured(run, entry)
	Registry.get("Caretaker").noise(run, target.capturePoint, 1000)
	-- Remove the room once the fold cinematic has played, and seal the doorway.
	task.delay(GameConfig.Capture.FoldCinematicSeconds * 0.8, function()
		if run.ended then
			return
		end
		local room = run.model:FindFirstChild("TargetRoom")
		if room then
			room:Destroy()
		end
		local theme = Palette.get(run.layout.theme)
		local seal = Kit.solid(
			run.model,
			"TargetSeal",
			target.doorCF * CFrame.new(0, 5, 0.4),
			Vector3.new(8.2, 10, 0.8),
			theme.wall,
			theme.wallMaterial
		)
		local sign = Kit.decor(
			run.model,
			"VacantSign",
			target.doorCF * CFrame.new(0, 5.5, -0.05),
			Vector3.new(5, 1.6, 0.1),
			Color3.fromRGB(30, 20, 14),
			Enum.Material.Wood
		)
		Kit.surfaceText(sign, {
			face = Enum.NormalId.Front,
			text = "ROOM MISSING",
			color = Color3.fromRGB(255, 120, 100),
			font = Font.new("rbxasset://fonts/families/Creepster.json", Enum.FontWeight.Regular),
			lightInfluence = 0,
		})
		local _ = seal
		global:Set({ "rooms", "target" }, { state = "Gone", room = target.room })
	end)
end

function CaptureService.startRun(run: Run)
	run.scratch.capture = { done = false }
	global:Set({ "rooms" }, { target = { state = "Intact", room = run.runtime.target.room } })
end

function CaptureService.step(_run: Run, _dt: number) end

function CaptureService.endRun(run: Run)
	run.scratch.capture = nil
end

function CaptureService.Init()
	Registry.add("Capture", CaptureService)
end

function CaptureService.Start() end

return CaptureService
