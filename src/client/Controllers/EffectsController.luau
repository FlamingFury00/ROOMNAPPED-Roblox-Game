--!strict
--[[
	EffectsController: one-shot feedback for server events (A06, U14, S29).

	Every important event gets a sound AND a visual (and a toast when it concerns the team), so nothing is
	audio-only or colour-only: hits, downs, revives, falls and splashes, cargo pickups and drops, crate
	impacts, levers, keys and combos. Zone, room and Caretaker visuals live in their own controllers; this
	one handles everything that is a moment rather than a state.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Net = require(Shared.Net.Net)
local RoomDefs = require(Shared.Config.RoomDefs)
local Signal = require(Shared.Util.Signal)
local RunInfo = require(script.Parent.Parent.Core.RunInfo)
local AudioController = require(script.Parent.AudioController)
local CameraController = require(script.Parent.CameraController)
local Haptics = require(script.Parent.Haptics)
local Vfx = require(script.Parent.Parent.Visual.Vfx)
local Toasts = require(script.Parent.Parent.UI.Toasts)
local Theme = require(script.Parent.Parent.UI.Theme)

local EffectsController = {}
EffectsController.priority = 50

-- HUD widgets listen to these (damage flash, combo pop...).
EffectsController.LocalHit = Signal.new() -- (source)
EffectsController.Combo = Signal.new() -- (comboId)
EffectsController.KeyCollected = Signal.new() -- (keyId, byMe)

local localPlayer = Players.LocalPlayer

local function characterPosition(key: any): Vector3?
	if type(key) ~= "string" then
		return nil
	end
	local player = RunInfo.playerFor(key)
	local character = player and player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root.CFrame.Position
	end
	return nil
end

local function isMe(key: any): boolean
	return key == RunInfo.myKey()
end

local function nameOf(key: any): string
	return if type(key) == "string" then RunInfo.displayName(key) else "?"
end

local function crateCenter(crateId: any): Vector3?
	if type(crateId) ~= "string" then
		return nil
	end
	local levelModel = RunInfo.levelModel()
	local crate = levelModel and levelModel:FindFirstChild("Crate_" .. crateId, true)
	if crate and crate:IsA("BasePart") then
		return crate.CFrame.Position
	end
	return nil
end

local HANDLERS: { [string]: (any) -> () } = {}

HANDLERS.hit = function(p: any)
	local position = characterPosition(p.userId)
	if isMe(p.userId) then
		AudioController.play("player_hurt", { volume = 1 })
		CameraController.shake(1.1, 0.35)
		Haptics.pulse(0.6, 0.15)
		EffectsController.LocalHit:Fire(p.source)
	elseif position then
		AudioController.at("player_hurt", position, { volume = 0.7 })
	end
	if position then
		local color = if p.source == "fire"
			then Color3.fromRGB(255, 150, 60)
			elseif p.source == "shock" then Color3.fromRGB(150, 220, 255)
			else Theme.Colors.red
		Vfx.burst(position, if p.source == "shock" then "sparks" else "magic", 12, {
			Color = ColorSequence.new(color),
		})
	end
end

HANDLERS.downed = function(p: any)
	local position = characterPosition(p.userId)
	if isMe(p.userId) then
		AudioController.play("player_downed", { volume = 1 })
		CameraController.shake(0.8, 0.5)
		Haptics.pulse(0.9, 0.35)
	else
		if position then
			AudioController.at("player_downed", position, { volume = 0.8 })
		end
		if not p.solo then
			Toasts.key("warn", "toast.teammateDown", { name = nameOf(p.userId) })
		end
	end
	if position then
		Vfx.ring(position - Vector3.new(0, 2.6, 0), Theme.Colors.red, 6, 0.5)
	end
end

HANDLERS.revived = function(p: any)
	local position = characterPosition(p.userId)
	if position then
		AudioController.at("player_revive", position, { volume = 1 })
		Vfx.burst(position, "magic", 26)
		Vfx.burst(position + Vector3.new(0, 1.5, 0), "hearts", 12)
		Vfx.ring(position - Vector3.new(0, 2.6, 0), Theme.Colors.green, 7, 0.6)
	end
	if not isMe(p.userId) then
		Toasts.key("success", "toast.revived", { name = nameOf(p.userId) })
	else
		AudioController.play("player_revive", { volume = 0.8 })
	end
end

HANDLERS.selfRecovered = function(p: any)
	if isMe(p.userId) then
		-- Solo players get one extra life; say so the moment it is spent.
		Toasts.key("warn", "toast.extraLifeUsed", nil)
	end
	task.delay(0.15, function()
		local position = characterPosition(p.userId)
		if position then
			AudioController.at("respawn", position, { volume = 1 })
			Vfx.burst(position, "poof", 16)
		end
	end)
end

HANDLERS.eliminated = function(p: any)
	if not isMe(p.userId) then
		AudioController.ui("ui_error", 0.6)
		Toasts.key("warn", "toast.teammateOut", { name = nameOf(p.userId) })
	end
end

HANDLERS.splash = function(p: any)
	if typeof(p.position) == "Vector3" then
		AudioController.at("splash", p.position, { volume = 1 })
		Vfx.burst(p.position, "splash", 40)
		Vfx.ring(p.position, Color3.fromRGB(190, 236, 255), 5, 0.5)
	end
	if isMe(p.userId) then
		CameraController.shake(0.6, 0.3)
	end
end

HANDLERS.fall = function(p: any)
	if typeof(p.position) == "Vector3" then
		AudioController.at("respawn", p.position, { volume = 0.7, pitch = 0.8 })
		Vfx.burst(p.position, "poof", 12)
	end
end

HANDLERS.key = function(p: any)
	local mine = isMe(p.userId)
	if mine then
		Toasts.key("key", "toast.keyFound", nil)
	else
		AudioController.ui("ui_coin", 0.5)
	end
	EffectsController.KeyCollected:Fire(p.key, mine)
end

HANDLERS.combo = function(p: any)
	if type(p.combo) ~= "string" then
		return
	end
	Toasts.key("combo", "toast.combo", { combo = "combo." .. p.combo })
	EffectsController.Combo:Fire(p.combo)
	local character = localPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		Vfx.burst(root.CFrame.Position + Vector3.new(0, 3, 0), "confetti", 30)
	end
end

HANDLERS.cargoPickup = function(p: any)
	local position = characterPosition(p.userId)
	if position then
		AudioController.at("cargo_pickup", position, { volume = 1 })
		Vfx.burst(position, "magic", 14)
	end
end

HANDLERS.cargoDrop = function(p: any)
	if typeof(p.position) == "Vector3" then
		AudioController.at("cargo_drop", p.position, { volume = 1 })
		Vfx.burst(p.position, "dust", 10)
	end
	Toasts.key("warn", "toast.cargoDropped", nil)
end

HANDLERS.cargoReturned = function(p: any)
	if typeof(p.position) == "Vector3" then
		AudioController.at("respawn", p.position, { volume = 0.8 })
		Vfx.burst(p.position, "poof", 14)
	end
	Toasts.key("info", "toast.cargoReturned", nil)
end

HANDLERS.cargoBanked = function(p: any)
	local position = characterPosition(p.userId)
	AudioController.play("cargo_bank", { volume = 1 })
	if position then
		Vfx.burst(position + Vector3.new(0, 2, 0), "confetti", 70)
		Vfx.burst(position + Vector3.new(0, 1, 0), "coins", 24)
		Vfx.flash(position, Theme.Colors.gold, 5, 30, 0.6)
	end
end

HANDLERS.crateSlot = function(p: any)
	local position = crateCenter(p.crate)
	if position then
		AudioController.at("crate_impact", position, { volume = 1, pitch = 0.85 })
		Vfx.burst(position + Vector3.new(0, 2.5, 0), "dust", 22)
		CameraController.shake(0.3, 0.25)
	end
end

HANDLERS.crateImpact = function(p: any)
	local position = crateCenter(p.crate)
	if position then
		AudioController.at("crate_impact", position, { volume = 0.8 })
		Vfx.burst(position, "dust", 10)
	end
end

HANDLERS.lever = function(p: any)
	local level = RunInfo.level()
	local lever = level and level.levers and level.levers[p.lever]
	if lever then
		local position = (lever.cf :: CFrame).Position
		AudioController.at("lever_switch", position, { volume = 1 })
		Vfx.burst(position + Vector3.new(0, 1, 0), "sparks", 10)
	end
end

HANDLERS.caretakerHit = function(p: any)
	local position = characterPosition(p.userId)
	if position then
		AudioController.at("caretaker_grab", position, { volume = 1 })
	end
	if isMe(p.userId) then
		CameraController.shake(1.4, 0.5)
	end
end

HANDLERS.caretakerHeard = function(p: any)
	-- A soft creak where it heard the noise, so players learn that noise attracts it.
	if typeof(p.position) == "Vector3" then
		AudioController.at("caretaker_search", p.position, { volume = 0.35 })
	end
end

HANDLERS.reward = function(p: any)
	if type(p.blueprint) == "string" then
		local def = RoomDefs.get(p.blueprint)
		Toasts.key("success", "toast.newRoom", { room = if def then def.nameKey else p.blueprint })
	end
	if type(p.credits) == "number" and p.credits > 0 then
		AudioController.ui("ui_coin", 0.8)
	end
	if type(p.mastery) == "table" then
		for _, skinId in p.mastery do
			if type(skinId) == "string" then
				Toasts.key("success", "toast.masterySkin", { item = "skin." .. skinId })
			end
		end
	end
end

function EffectsController.start()
	Net.listen("Effect", function(name: any, params: any)
		if type(name) ~= "string" then
			return
		end
		local handler = HANDLERS[name]
		if handler then
			local ok: boolean, err: any = pcall(handler, if type(params) == "table" then params else {})
			if not ok then
				warn("[Effects]", name, err)
			end
		end
	end)
end

return EffectsController
