--!strict
--[[
	HintsController: contextual hints and the guided first expedition (U13, S24, S26).

	The tutorial (Check-In) walks a new player through the core loop one step at a time, each hint in the
	wording of the device they are using: move -> grab the Freezer -> unfold it at the glowing door -> walk
	across the ice -> recall rooms -> find the target -> hold to steal it -> run. A step only advances when
	the player has actually done it, and every completed step is reported for the onboarding funnel.

	Outside the tutorial, first-time hints explain new situations once per session (ice, fans, ledges,
	reviving). Players can turn hints off in Settings.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.Config.GameConfig)
local Strings = require(Shared.Config.Strings)
local MathUtil = require(Shared.Util.MathUtil)
local Signal = require(Shared.Util.Signal)
local Net = require(Shared.Net.Net)
local ClientState = require(script.Parent.Parent.Core.ClientState)
local RunInfo = require(script.Parent.Parent.Core.RunInfo)
local Device = require(script.Parent.Parent.Core.Device)
local SettingsController = require(script.Parent.SettingsController)
local PlacementController = require(script.Parent.PlacementController)
local MovementController = require(script.Parent.MovementController)
local Theme = require(script.Parent.Parent.UI.Theme)
local Create = require(script.Parent.Parent.UI.Create)
local Icons = require(script.Parent.Parent.UI.Icons)
local Motion = require(script.Parent.Parent.UI.Motion)
local Components = require(script.Parent.Parent.UI.Components)
local UIRoot = require(script.Parent.Parent.UI.UIRoot)

local HintsController = {}
HintsController.priority = 80

HintsController.Changed = Signal.new() -- (key?)

local C = Theme.Colors
local localPlayer = Players.LocalPlayer

-- UI ------------------------------------------------------------------------------------------------------

local pill = Create.new("Frame", {
	Name = "Hint",
	AnchorPoint = Vector2.new(0.5, 1),
	Position = UDim2.new(0.5, 0, 1, -160),
	Size = UDim2.fromOffset(0, 54),
	AutomaticSize = Enum.AutomaticSize.X,
	BackgroundColor3 = C.panelDark,
	BackgroundTransparency = 0.08,
	Visible = false,
	Parent = UIRoot.Hud,
}, {
	Create.corner(Theme.Radius.pill),
	Create.stroke(C.gold, 2.5, 0),
	Create.padding(6, 20),
	Create.list(Enum.FillDirection.Horizontal, 12, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center),
})
local iconHolder = Create.new("Frame", {
	Name = "Icon",
	Size = UDim2.fromOffset(32, 32),
	BackgroundTransparency = 1,
	LayoutOrder = 1,
	Parent = pill,
})
Icons.make("info", C.gold, C.ink).Parent = iconHolder
local label = Components.label({
	name = "Text",
	text = "",
	font = Theme.Fonts.heading,
	textSize = Theme.Text.medium,
	size = UDim2.fromOffset(0, 40),
	autoSize = Enum.AutomaticSize.X,
	layoutOrder = 2,
	stroke = true,
	parent = pill,
})
Create.new("UISizeConstraint", { MaxSize = Vector2.new(760, 60), Parent = label })

local currentKey: string? = nil
local shownAt = 0

local function show(key: string?)
	if key == currentKey then
		return
	end
	currentKey = key
	if not key then
		pill.Visible = false
		HintsController.Changed:Fire(nil)
		return
	end
	label.Text = Strings.t(key)
	pill.Visible = true
	shownAt = os.clock()
	Motion.pop(pill, 0.8)
	Components.sound("ui_notify")
	HintsController.Changed:Fire(key)
end

local function deviceKey(base: string): string
	local key = base .. "." .. Device.hintSuffix()
	if Strings.has(key) then
		return key
	end
	return base .. ".keyboard"
end

-- State -----------------------------------------------------------------------------------------------------

type TutorialStep = "move" | "select" | "deploy" | "cross" | "recall" | "find" | "capture" | "escape" | "done"

local step: TutorialStep = "move"
local spawnPosition: Vector3? = nil
local stepStarted = 0
local seen: { [string]: boolean } = {}
local timedUntil = 0
local timedKey: string? = nil

local function rootPosition(): Vector3?
	local character = localPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root.CFrame.Position
	end
	return nil
end

local function advance(nextStep: TutorialStep, telemetry: string?)
	step = nextStep
	stepStarted = os.clock()
	if telemetry then
		Net.send("TutorialStep", telemetry)
	end
end

local function nearestSocketDistance(position: Vector3): number
	local level = RunInfo.level()
	local best = math.huge
	if level then
		for _, socket in level.sockets do
			best = math.min(best, (socket.interactPoint - position).Magnitude)
		end
	end
	return best
end

local function anyDeepBasinSolid(): boolean
	local zones = ClientState.get("global", "zones") or {}
	local level = RunInfo.level()
	if not level then
		return false
	end
	for id in level.basins or {} do
		local zone = zones[id]
		if type(zone) == "table" and (zone.phase == "Ice" or zone.phase == "Freezing" or zone.phase == "Thawing") then
			return true
		end
	end
	return false
end

local function myDeployedCount(): number
	local entry = RunInfo.myEntry()
	local n = 0
	if entry and type(entry.deployed) == "table" then
		for _ in entry.deployed do
			n += 1
		end
	end
	return n
end

local function tutorialHint(position: Vector3): string?
	local level = RunInfo.level()
	if not level then
		return nil
	end
	local phase = RunInfo.phase()
	if phase == "Escape" or phase == "Capture" then
		if step ~= "escape" and step ~= "done" then
			advance("escape", "captured")
		end
	end
	if step == "move" then
		spawnPosition = spawnPosition or position
		if (position - (spawnPosition :: Vector3)).Magnitude > 10 then
			advance("select", "moved")
			return nil
		end
		return deviceKey("hint.move")
	elseif step == "select" then
		if anyDeepBasinSolid() then
			advance("cross", "deployed")
			return nil
		end
		if PlacementController.selectedSlot() ~= 0 then
			advance("deploy", "selected")
			return nil
		end
		if nearestSocketDistance(position) < 26 then
			return deviceKey("hint.select")
		end
		return "hint.find"
	elseif step == "deploy" then
		if myDeployedCount() > 0 or anyDeepBasinSolid() then
			advance("cross", "deployed")
			return nil
		end
		if PlacementController.selectedSlot() == 0 then
			advance("select", nil)
			return nil
		end
		return deviceKey("hint.deploy")
	elseif step == "cross" then
		local target = level.target
		local crossed = target ~= nil
			and (target.capturePoint - position).Magnitude
				< (target.capturePoint - (spawnPosition or position)).Magnitude * 0.55
		if crossed or os.clock() - stepStarted > 25 then
			advance("recall", "crossed")
			return nil
		end
		return if MovementController.isOnIce() then "hint.slippery" else "hint.cross"
	elseif step == "recall" then
		if os.clock() - stepStarted > 6 then
			advance("find", nil)
			return nil
		end
		return "hint.recall"
	elseif step == "find" then
		local target = level.target
		if target and (target.capturePoint - position).Magnitude < GameConfig.Capture.Range + 6 then
			advance("capture", "foundTarget")
			return nil
		end
		return "hint.find"
	elseif step == "capture" then
		return deviceKey("hint.capture")
	elseif step == "escape" then
		if os.clock() - stepStarted > 7 then
			advance("done", nil)
			return nil
		end
		return "hint.escape"
	end
	return nil
end

local function situationalHint(position: Vector3): string?
	local level = RunInfo.level()
	if not level then
		return nil
	end
	if timedKey and os.clock() < timedUntil then
		return timedKey
	end
	timedKey = nil
	local function once(key: string, seconds: number): string?
		if seen[key] then
			return nil
		end
		seen[key] = true
		timedKey = key
		timedUntil = os.clock() + seconds
		return key
	end
	if MovementController.isOnIce() and not seen["hint.slippery"] then
		return once("hint.slippery", 5)
	end
	local candidate = PlacementController.candidate()
	local fanKey = deviceKey("hint.fan")
	if candidate and candidate.dir and not seen[fanKey] then
		return once(fanKey, 6)
	end
	for _, ledge in level.ledges or {} do
		if MathUtil.pointInBox(ledge.cf, ledge.size, position, 4) and not seen["hint.ledge"] then
			return once("hint.ledge", 6)
		end
	end
	for key, entry in RunInfo.roster() do
		if key ~= RunInfo.myKey() and entry.status == "Downed" and not seen["hint.revive"] then
			local player = RunInfo.playerFor(key)
			local character = player and player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") and (root.CFrame.Position - position).Magnitude < 30 then
				return once("hint.revive", 6)
			end
		end
	end
	return nil
end

local function evaluate()
	if not SettingsController.get().hints or not RunInfo.isParticipant() or not RunInfo.isActivePhase() then
		show(nil)
		return
	end
	if RunInfo.myStatus() ~= "Active" then
		show(nil)
		return
	end
	local position = rootPosition()
	if not position then
		return
	end
	local key: string? = nil
	if RunInfo.isTutorial() and step ~= "done" then
		key = tutorialHint(position :: Vector3)
		-- A step may have just advanced (side effect of tutorialHint); ask once more for the new step.
		if key == nil and (step :: string) ~= "done" then
			key = tutorialHint(position :: Vector3)
		end
	else
		key = situationalHint(position :: Vector3)
	end
	-- Avoid flicker: a hint stays at least 1.2 s before switching to another one.
	if currentKey and key ~= currentKey and os.clock() - shownAt < 1.2 and key ~= nil then
		return
	end
	show(key)
end

function HintsController.current(): string?
	return currentKey
end

function HintsController.start()
	RunInfo.PhaseChanged:Connect(function(phase: string)
		if phase == "Launching" or phase == "Prep" then
			step = "move"
			spawnPosition = nil
			stepStarted = os.clock()
		end
		if phase == "Results" and RunInfo.isTutorial() then
			Net.send("TutorialStep", "finished")
		end
	end)
	Device.Changed:Connect(function()
		currentKey = nil
	end)
	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt: number)
		accumulator += dt
		if accumulator >= 0.2 then
			accumulator = 0
			evaluate()
		end
	end)
end

return HintsController
