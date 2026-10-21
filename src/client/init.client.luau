--!strict
--[[
	ROOMNAPPED client bootstrap.

	Core services start first in a fixed order (state mirror, settings, audio, input, UI root). Every other
	ModuleScript under Controllers/, UI/Hud/ and UI/Screens/ is discovered automatically and started in
	ascending `priority` (default 100). A failing module is logged and skipped so one bug can never take the
	whole interface down.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local TextChatService = game:GetService("TextChatService")

local Shared = ReplicatedStorage.Shared
local Net = require(Shared.Net.Net)
local Log = require(Shared.Util.Log)

local log = Log.new("Client")

Net.initClient()

local Core = script.Core
local Controllers = script.Controllers
local UI = script.UI

local ClientState = require(Core.ClientState)
local Device = require(Core.Device)
local RunInfo = require(Core.RunInfo)
local SettingsController = require(Controllers.SettingsController)
local AudioController = require(Controllers.AudioController)
local InputController = require(Controllers.InputController)
local UIRoot = require(UI.UIRoot)
local Toasts = require(UI.Toasts)

local function safeStart(name: string, fn: () -> ())
	local ok: boolean, err: any = xpcall(fn :: any, function(message: any): string
		return debug.traceback(tostring(message), 2)
	end)
	if not ok then
		log:Warn("failed to start", name, err)
	end
end

-- Core, in dependency order.
ClientState.init()
safeStart("RunInfo", RunInfo.start)
safeStart("Settings", SettingsController.start)
safeStart("Audio", AudioController.start)
safeStart("Input", InputController.start)
UIRoot.setBlockHook(InputController.setBlocked)
safeStart("Toasts", Toasts.start)

-- Core GUI: hearts replace the health bar; there are no tools; the squad panel and team cards replace the
-- player list (which would open over the menu bar in the top-right corner); reset means "unstuck me".
-- Reporting and blocking stay in the Roblox menu.
task.spawn(function()
	local resetEvent = Instance.new("BindableEvent")
	resetEvent.Event:Connect(function()
		Net.send("RequestUnstuck")
	end)
	for _ = 1, 40 do
		local ok = pcall(function()
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Health, false)
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, false)
			StarterGui:SetCore("ResetButtonCallback", resetEvent)
		end)
		if ok then
			break
		end
		task.wait(0.25)
	end
end)

-- Chat: Roblox opens the chat window top-left, over the hearts and team cards in a run and the squad panel in
-- the lobby. With a keyboard or controller it sits at the middle of the right edge instead, which both HUDs keep
-- clear. Touch keeps Roblox's placement next to the chat button, because the touch controls own the right edge.
task.spawn(function()
	local config: ChatWindowConfiguration? = nil
	for _ = 1, 40 do
		config = TextChatService:FindFirstChildOfClass("ChatWindowConfiguration")
		if config then
			break
		end
		task.wait(0.25)
	end
	if not config then
		return
	end
	local window = config :: ChatWindowConfiguration
	local function place(kind: Device.Kind)
		local touch = kind == "touch"
		pcall(function()
			window.HorizontalAlignment = if touch then Enum.HorizontalAlignment.Left else Enum.HorizontalAlignment.Right
			window.VerticalAlignment = if touch then Enum.VerticalAlignment.Top else Enum.VerticalAlignment.Center
		end)
	end
	place(Device.kind())
	Device.Changed:Connect(place)
end)

-- Discovered modules ----------------------------------------------------------------------------------------

local CORE_NAMES: { [string]: boolean } = {
	SettingsController = true,
	AudioController = true,
	InputController = true,
}

type Startable = { start: (() -> ())?, priority: number? }

local discovered: { { name: string, module: Startable, priority: number } } = {}

local function collect(folder: Instance?)
	if not folder then
		return
	end
	for _, child in folder:GetChildren() do
		if child:IsA("ModuleScript") and not CORE_NAMES[child.Name] then
			local ok, result = pcall(require, child)
			if ok and type(result) == "table" then
				local module = result :: Startable
				if type(module.start) == "function" then
					table.insert(discovered, {
						name = child.Name,
						module = module,
						priority = if type(module.priority) == "number" then module.priority :: number else 100,
					})
				end
			elseif not ok then
				log:Warn("failed to load", child:GetFullName(), result)
			end
		end
	end
end

collect(Controllers)
collect(UI:FindFirstChild("Hud"))
collect(UI:FindFirstChild("Screens"))

table.sort(discovered, function(a, b)
	if a.priority == b.priority then
		return a.name < b.name
	end
	return a.priority < b.priority
end)

for _, item in discovered do
	safeStart(item.name, item.module.start :: () -> ())
end

-- Tell the server which device family we are on (telemetry, onboarding hints).
Net.send("ClientReady", Device.kind(), string.sub(Players.LocalPlayer.LocaleId, 1, 12))

log:Debug("client started with", #discovered, "modules")
