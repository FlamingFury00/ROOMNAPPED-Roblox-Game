--!strict
--[[
	SpectateController: what an eliminated player sees (S16, U12).

	When the downed window runs out the server parks the character in a sealed box under the level and marks
	the player as Spectating. The camera then follows a teammate who is still in the run; Prev / Next (or
	Slot 1 / Slot 2 keys and the D-pad) cycle between them. When the run ends the camera returns to the
	player's own character automatically.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local RunInfo = require(script.Parent.Parent.Core.RunInfo)
local InputController = require(script.Parent.InputController)

local SpectateController = {}
SpectateController.priority = 70

SpectateController.Changed = Signal.new() -- (targetKey?)

local localPlayer = Players.LocalPlayer
local spectating = false
local targetKey: string? = nil

local function candidates(): { string }
	local out = {}
	for key, entry in RunInfo.roster() do
		if
			key ~= RunInfo.myKey()
			and entry.status ~= "Eliminated"
			and entry.status ~= "Left"
			and entry.status ~= "Disconnected"
		then
			local player = RunInfo.playerFor(key)
			if player and player.Character then
				table.insert(out, key)
			end
		end
	end
	table.sort(out, function(a, b)
		local ea, eb = RunInfo.entry(a), RunInfo.entry(b)
		return (ea and ea.order or 0) < (eb and eb.order or 0)
	end)
	return out
end

local function focus(key: string?)
	targetKey = key
	local camera = Workspace.CurrentCamera :: Camera
	local subject: Instance? = nil
	if key then
		local player = RunInfo.playerFor(key)
		local character = player and player.Character
		subject = character and character:FindFirstChildOfClass("Humanoid")
	end
	if not subject then
		local character = localPlayer.Character
		subject = character and character:FindFirstChildOfClass("Humanoid")
	end
	if subject then
		camera.CameraSubject = subject :: Humanoid
	end
	SpectateController.Changed:Fire(key)
end

function SpectateController.isSpectating(): boolean
	return spectating
end

function SpectateController.target(): string?
	return targetKey
end

function SpectateController.cycle(step: number)
	if not spectating then
		return
	end
	local list = candidates()
	if #list == 0 then
		focus(nil)
		return
	end
	local index = if targetKey then table.find(list, targetKey :: string) or 0 else 0
	index = ((index - 1 + step) % #list) + 1
	focus(list[index])
end

local function refresh()
	local shouldSpectate = localPlayer:GetAttribute("Spectating") == true and RunInfo.inRunPhase()
	if shouldSpectate ~= spectating then
		spectating = shouldSpectate
		if spectating then
			local list = candidates()
			focus(list[1])
		else
			focus(nil)
		end
	elseif spectating then
		-- Keep following someone valid as teammates fall or leave.
		local list = candidates()
		if not targetKey or not table.find(list, targetKey :: string) then
			focus(list[1])
		end
	end
end

function SpectateController.start()
	localPlayer:GetAttributeChangedSignal("Spectating"):Connect(refresh)
	RunInfo.RosterChanged:Connect(refresh)
	RunInfo.PhaseChanged:Connect(refresh)
	localPlayer.CharacterAdded:Connect(function()
		task.defer(refresh)
	end)
	InputController.on("Slot1", function(state)
		if state == "Begin" and spectating then
			SpectateController.cycle(-1)
		end
	end)
	InputController.on("Slot2", function(state)
		if state == "Begin" and spectating then
			SpectateController.cycle(1)
		end
	end)
	refresh()
end

return SpectateController
