--!strict
--[[
	CharacterService: character setup and safe teleports.

	* Characters never collide with each other (S19: no player-body blocking) and never collide with
	  decoration.
	* ROOMNAPPED health lives in hearts (HealthService); the Humanoid never dies from gameplay. If a character
	  is lost anyway (reset, void), it respawns and is placed back where it belongs (lobby or the last safe
	  point of the current run).
]]

local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Net = require(ReplicatedStorage.Shared.Net.Net)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Engine = require(ReplicatedStorage.Shared.Util.Engine)
local Registry = require(script.Parent.Parent.Core.Registry)

local CharacterService = {}
CharacterService.Spawned = Signal.new() -- (player, character)

local GROUP_PLAYERS = "RN_Players"
local GROUP_CRATES = "RN_Crates"

local function setGroup(instance: Instance)
	if instance:IsA("BasePart") then
		instance.CollisionGroup = GROUP_PLAYERS
	end
end

function CharacterService.root(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

function CharacterService.humanoid(player: Player): Humanoid?
	local character = player.Character
	if not character then
		return nil
	end
	return character:FindFirstChildOfClass("Humanoid")
end

function CharacterService.position(player: Player): Vector3?
	local root = CharacterService.root(player)
	return if root then root.CFrame.Position else nil
end

-- Head position used for line-of-sight checks.
function CharacterService.eye(player: Player): Vector3?
	local character = player.Character
	if not character then
		return nil
	end
	local head = character:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		return head.CFrame.Position
	end
	local root = CharacterService.root(player)
	return if root then root.CFrame.Position + Vector3.new(0, 1.5, 0) else nil
end

function CharacterService.teleport(player: Player, cf: CFrame)
	local character = player.Character
	if not character then
		return
	end
	local root = CharacterService.root(player)
	if root then
		Engine.stop(root)
	end
	character:PivotTo(cf)
	Net.fire(player, "Teleported", cf)
end

function CharacterService.setGroup(part: BasePart, group: string)
	part.CollisionGroup = group
end

local function onCharacterAdded(player: Player, character: Model)
	for _, d in character:GetDescendants() do
		setGroup(d)
	end
	character.DescendantAdded:Connect(setGroup)
	local humanoid = character:WaitForChild("Humanoid", 10)
	if humanoid and humanoid:IsA("Humanoid") then
		humanoid.BreakJointsOnDeath = false
		humanoid.WalkSpeed = GameConfig.Movement.WalkSpeed
		humanoid.UseJumpPower = false
		humanoid.JumpHeight = GameConfig.Movement.JumpHeight
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.Viewer
		humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
		humanoid.Died:Connect(function()
			task.delay(Players.RespawnTime, function()
				if player.Parent == Players and player.Character == character then
					pcall(function()
						player:LoadCharacterAsync()
					end)
				end
			end)
		end)
	end
	CharacterService.Spawned:Fire(player, character)
	-- Place the character where it belongs (run checkpoint or lobby) once it exists.
	task.defer(function()
		if Registry.has("Expedition") then
			Registry.get("Expedition").onCharacterSpawned(player, character)
		end
	end)
end

function CharacterService.Init()
	Registry.add("Characters", CharacterService)
	pcall(function()
		PhysicsService:RegisterCollisionGroup(GROUP_PLAYERS)
	end)
	pcall(function()
		PhysicsService:RegisterCollisionGroup(GROUP_CRATES)
	end)
	PhysicsService:CollisionGroupSetCollidable(GROUP_PLAYERS, GROUP_PLAYERS, false)
end

function CharacterService.Start()
	local function hook(player: Player)
		player.CharacterAdded:Connect(function(character)
			onCharacterAdded(player, character)
		end)
		if player.Character then
			task.spawn(onCharacterAdded, player, player.Character)
		end
	end
	Players.PlayerAdded:Connect(hook)
	for _, player in Players:GetPlayers() do
		hook(player)
	end
	Net.on("RequestUnstuck", function(player: Player)
		Registry.get("Expedition").unstuck(player)
	end)
end

CharacterService.GROUP_PLAYERS = GROUP_PLAYERS
CharacterService.GROUP_CRATES = GROUP_CRATES

return CharacterService
