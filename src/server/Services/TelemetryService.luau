--!strict
--[[
	TelemetryService: server-side analytics (S26, DOC04, DOC05).

	* Onboarding funnel (one-time per player): Joined -> FirstRun -> FirstDeploy -> FirstCombo ->
	  FirstCapture -> FirstExtraction -> Replayed. The highest logged step is stored in the profile so each
	  step is sent once.
	* Expedition funnel (recurring, session id = run id): Start -> Deploy -> Combo -> Capture -> Extract.
	* Custom events: RoomDeployed, Combo, RunResult, RoomPair, Feedback, Ping, KeyCollected, CaretakerHit.
	  Custom fields carry the room pair, device and build version.

	AnalyticsService only accepts events from published servers; every call is pcall-wrapped and Studio
	logs instead, so analytics can never break gameplay.
]]

local AnalyticsService = game:GetService("AnalyticsService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.Config.GameConfig)
local Log = require(Shared.Util.Log)
local Registry = require(script.Parent.Parent.Core.Registry)

local log = Log.new("Telemetry")

local TelemetryService = {}

local F1 = Enum.AnalyticsCustomFieldKeys.CustomField01.Name
local F2 = Enum.AnalyticsCustomFieldKeys.CustomField02.Name
local F3 = Enum.AnalyticsCustomFieldKeys.CustomField03.Name

local ONBOARDING = {
	Joined = 1,
	FirstRun = 2,
	FirstDeploy = 3,
	FirstCombo = 4,
	FirstCapture = 5,
	FirstExtraction = 6,
	Replayed = 7,
}

local studio = RunService:IsStudio()
local expeditionStep: { [string]: { [number]: number } } = {}

local function enabled(): boolean
	return Registry.get("Flags").feature("analytics")
end

local function safe(name: string, fn: () -> ())
	if not enabled() then
		return
	end
	if studio then
		log:Debug(name)
		return
	end
	xpcall(fn, function(problem: any)
		log:Warn(name, "failed:", problem)
	end)
end

local function onboarding(player: Player, stepName: string)
	local step = ONBOARDING[stepName]
	if not step or player.Parent ~= Players then
		return
	end
	local Profiles = Registry.get("Profiles")
	local profile = Profiles.get(player)
	if not profile or profile.flags.onboardingFunnel >= step then
		return
	end
	Profiles.update(player, function(p: any)
		p.flags.onboardingFunnel = step
	end)
	safe("onboarding " .. stepName, function()
		AnalyticsService:LogOnboardingFunnelStepEvent(player, step, stepName)
	end)
end

local function expedition(run: any, entry: any, step: number, stepName: string)
	local perRun = expeditionStep[run.id]
	if not perRun then
		perRun = {}
		expeditionStep[run.id] = perRun
	end
	if (perRun[entry.userId] or 0) >= step then
		return
	end
	perRun[entry.userId] = step
	safe("expedition " .. stepName, function()
		AnalyticsService:LogFunnelStepEvent(entry.player, "Expedition", run.id, step, stepName, {
			[F1] = run.mission.id,
			[F2] = table.concat(entry.loadout, "+"),
			[F3] = GameConfig.Version,
		})
	end)
end

local function custom(player: Player, name: string, value: number, f1: string?, f2: string?, f3: string?)
	if player.Parent ~= Players then
		return
	end
	safe("custom " .. name, function()
		AnalyticsService:LogCustomEvent(player, name, value, {
			[F1] = f1 or "",
			[F2] = f2 or "",
			[F3] = f3 or GameConfig.Version,
		})
	end)
end

-- Hooks ------------------------------------------------------------------------------------------------

function TelemetryService.clientReady(player: Player, device: string)
	onboarding(player, "Joined")
	custom(player, "Session", 1, device, GameConfig.Version)
end

function TelemetryService.runStarted(run: any)
	for _, entry in run.roster do
		onboarding(entry.player, "FirstRun")
		expedition(run, entry, 1, "Start")
		custom(entry.player, "RoomPair", 1, table.concat(entry.loadout, "+"), entry.device, run.mission.id)
		local profile = Registry.get("Profiles").get(entry.player)
		if profile and profile.stats.runs > 0 then
			onboarding(entry.player, "Replayed")
		end
	end
end

function TelemetryService.exploreStarted(_run: any) end

function TelemetryService.deployed(run: any, entry: any, roomId: string, socketId: string)
	onboarding(entry.player, "FirstDeploy")
	expedition(run, entry, 2, "Deploy")
	custom(entry.player, "RoomDeployed", 1, roomId, run.mission.id, socketId)
end

function TelemetryService.combo(run: any, comboId: string, _entry: any?)
	for _, entry in run.roster do
		if entry.connected and not entry.left then
			onboarding(entry.player, "FirstCombo")
			expedition(run, entry, 3, "Combo")
		end
	end
	local first = run.roster[run.order[1]]
	if first then
		custom(first.player, "Combo", 1, comboId, run.mission.id)
	end
end

function TelemetryService.captured(run: any, _entry: any)
	for _, entry in run.roster do
		if entry.connected and not entry.left then
			onboarding(entry.player, "FirstCapture")
			expedition(run, entry, 4, "Capture")
		end
	end
end

function TelemetryService.runEnded(run: any, summary: any)
	for _, entry in run.roster do
		if entry.connected and not entry.left then
			if summary.success then
				onboarding(entry.player, "FirstExtraction")
				expedition(run, entry, 5, "Extract")
			end
			custom(
				entry.player,
				"RunResult",
				math.floor(summary.durationSeconds),
				summary.outcome,
				run.mission.id,
				tostring(#run.order)
			)
		end
	end
	expeditionStep[run.id] = nil
end

function TelemetryService.playerLeftRun(run: any, entry: any, reason: string)
	custom(entry.player, "LeftRun", 1, reason, run.mission.id)
end

function TelemetryService.downed(run: any, entry: any)
	custom(entry.player, "Downed", 1, run.mission.id)
end

function TelemetryService.revived(run: any, target: any, _by: any)
	custom(target.player, "Revived", 1, run.mission.id)
end

function TelemetryService.caretakerHit(run: any, entry: any)
	custom(entry.player, "CaretakerHit", 1, run.mission.id)
end

function TelemetryService.keyCollected(run: any, entry: any, keyId: string)
	custom(entry.player, "KeyCollected", 1, keyId, run.mission.id)
end

function TelemetryService.feedback(player: Player, rating: number, tag: string?)
	custom(player, "Feedback", rating, tag or "", GameConfig.Version)
end

function TelemetryService.tutorialStep(player: Player, step: string)
	custom(player, "TutorialStep", 1, string.sub(step, 1, 32))
end

function TelemetryService.ping(player: Player, kind: string)
	custom(player, "Ping", 1, kind)
end

function TelemetryService.purchase(player: Player, skinId: string, price: number)
	local profile = Registry.get("Profiles").get(player)
	safe("economy sink", function()
		AnalyticsService:LogEconomyEvent(
			player,
			Enum.AnalyticsEconomyFlowType.Sink,
			"Credits",
			price,
			if profile then profile.credits else 0,
			Enum.AnalyticsEconomyTransactionType.Shop.Name,
			skinId
		)
	end)
end

function TelemetryService.creditsEarned(player: Player, amount: number, balance: number)
	safe("economy source", function()
		AnalyticsService:LogEconomyEvent(
			player,
			Enum.AnalyticsEconomyFlowType.Source,
			"Credits",
			amount,
			balance,
			Enum.AnalyticsEconomyTransactionType.Gameplay.Name,
			"Extraction"
		)
	end)
end

function TelemetryService.Init()
	Registry.add("Telemetry", TelemetryService)
end

function TelemetryService.Start() end

return TelemetryService
