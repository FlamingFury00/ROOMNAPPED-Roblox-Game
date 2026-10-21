--!strict
--[[
	HudLayout: the touch-screen arrangement of the HUD (U01).

	On touch screens the HUD keeps clear of Roblox's controls (TouchZones): everything that is not a button
	around the jump button lives in a top band of three rows, which phones also draw a little smaller -

	  row 1  hearts .............. objective + keys ............ menu
	  row 2  team ................ threat / escape timer ........ suitcase status
	  row 3  ..................... one message line (hint or toast)

	Keyboards and controllers keep the full-size desktop layout. HUD pieces read their scale and place from
	here and listen to HudLayout.Changed.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Device = require(script.Parent.Parent.Core.Device)
local Responsive = require(script.Parent.Responsive)
local TouchZones = require(script.Parent.TouchZones)
local UIRoot = require(script.Parent.UIRoot)

export type Group = "objective" | "vitals" | "menu" | "message" | "status" | "lobby"

local HudLayout = {}

HudLayout.Changed = Signal.new()

-- Phone (compact touch) scale per group; tablets use TABLET, keyboards and controllers 1.
local PHONE: { [Group]: number } = {
	objective = 0.85,
	vitals = 0.85,
	menu = 0.82,
	message = 0.8,
	status = 0.85,
	lobby = 0.86,
}
local TABLET = 0.9

-- Canvas y of the message line on touch screens: below the objective column (row 1 + row 2).
local MESSAGE_TOP_PHONE = 106
local MESSAGE_TOP_TABLET = 150

function HudLayout.touch(): boolean
	return TouchZones.active()
end

-- Phones: touch screens whose canvas is short (landscape phones).
function HudLayout.phone(): boolean
	return TouchZones.active() and Responsive.isCompact(UIRoot.Guis.Hud)
end

function HudLayout.scale(group: Group): number
	if not TouchZones.active() then
		return 1
	end
	if Responsive.isCompact(UIRoot.Guis.Hud) then
		return PHONE[group]
	end
	return TABLET
end

function HudLayout.messageTop(): number
	return if HudLayout.phone() then MESSAGE_TOP_PHONE else MESSAGE_TOP_TABLET
end

function HudLayout.zones(): TouchZones.Zones
	return TouchZones.get(UIRoot.Guis.Hud)
end

-- Centre of a circle of direction markers (radius + marker size) in the middle of the screen, nudged right
-- so the circle never reaches into the thumbstick zone.
function HudLayout.orbitCentre(radius: number, size: number): Vector2
	local zones = HudLayout.zones()
	local centre = zones.canvas / 2
	return Vector2.new(math.max(centre.X, zones.stick.x1 + radius + size / 2 + 4), centre.Y)
end

TouchZones.track(UIRoot.Guis.Hud)
TouchZones.Changed:Connect(function()
	HudLayout.Changed:Fire()
end)
Device.Changed:Connect(function()
	HudLayout.Changed:Fire()
end)

return HudLayout
