--!strict
--[[
	LobbyService: builds the elevator lobby (S25) and exposes its anchors (spawn, arrival points, ready zone).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local LobbyBuilder = require(ReplicatedStorage.Shared.World.LobbyBuilder)
local MathUtil = require(ReplicatedStorage.Shared.Util.MathUtil)
local Registry = require(script.Parent.Parent.Core.Registry)

local LobbyService = {}

local runtime: LobbyBuilder.LobbyRuntime
local model: Model

function LobbyService.runtime(): LobbyBuilder.LobbyRuntime
	return runtime
end

function LobbyService.isInReadyZone(position: Vector3): boolean
	return MathUtil.pointInBox(runtime.readyZone.cf, runtime.readyZone.size, position, 0.5)
end

function LobbyService.isInLobby(position: Vector3): boolean
	local b = runtime.bounds
	return position.X >= b.min.X
		and position.X <= b.max.X
		and position.Z >= b.min.Z
		and position.Z <= b.max.Z
		and position.Y > b.min.Y
end

function LobbyService.spawnFor(index: number): CFrame
	local base = runtime.spawn
	local angle = (index % 6) / 6 * math.pi * 2
	return base * CFrame.new(math.cos(angle) * 3, 0, math.sin(angle) * 3)
end

function LobbyService.arrivalFor(index: number): CFrame
	local list = runtime.arrival
	return list[((index - 1) % #list) + 1]
end

-- Ready-zone spot for a player who pressed PLAY (inside the departure elevator car).
function LobbyService.readySpot(index: number): CFrame
	local zone = runtime.readyZone
	local offsets =
		{ Vector3.new(-1.8, -2, 2), Vector3.new(1.8, -2, 2), Vector3.new(-1.8, -2, -2), Vector3.new(1.8, -2, -2) }
	local offset = offsets[((index - 1) % #offsets) + 1]
	local p = (zone.cf * CFrame.new(offset)).Position
	return CFrame.lookAt(p, p - zone.cf.LookVector * 10)
end

function LobbyService.setElevatorDoors(open: boolean)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and d:GetAttribute("LobbyElevator") then
			d:SetAttribute("Open", open)
			d.CanCollide = not open
		end
	end
end

function LobbyService.Init()
	Registry.add("Lobby", LobbyService)
	local result = LobbyBuilder.build()
	model = result.model
	runtime = result.runtime
	model.Parent = workspace
end

function LobbyService.Start()
	-- Nothing to start: the lobby is static. Keep players who fall out of the lobby safe.
	task.spawn(function()
		while true do
			task.wait(1)
			for _, player in Players:GetPlayers() do
				local character = player.Character
				local root = character and character:FindFirstChild("HumanoidRootPart")
				local p = if root and root:IsA("BasePart") then root.CFrame.Position else nil
				if p and p.Y < -60 and LobbyService.isInLobby(Vector3.new(p.X, 0, p.Z)) then
					Registry.get("Characters").teleport(player, LobbyService.spawnFor(1))
				end
			end
		end
	end)
end

return LobbyService
