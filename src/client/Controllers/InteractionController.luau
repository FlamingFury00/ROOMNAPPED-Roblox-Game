--!strict
--[[
	InteractionController: the one context action (U06, S04, S12, S16, S20).

	Every frame the best available action near the player is resolved, in priority order:
	  revive a downed teammate (hold) > pick up the dropped suitcase > unfold / recall the selected room >
	  steal the target room (hold) > flip a power lever
	One key (E / X / the big touch button) performs it. Holds run locally for instant feedback and are
	verified by the server (start, range and line of sight every frame, and the final duration); a
	rejected hold explains why. A world prompt shows the action with the current device's glyph, and
	teammates' holds show a filling ring over their target so everyone sees the steal / revive happening.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.Config.GameConfig)
local RoomDefs = require(Shared.Config.RoomDefs)
local Strings = require(Shared.Config.Strings)
local Signal = require(Shared.Util.Signal)
local Net = require(Shared.Net.Net)
local ClientState = require(script.Parent.Parent.Core.ClientState)
local RunInfo = require(script.Parent.Parent.Core.RunInfo)
local Device = require(script.Parent.Parent.Core.Device)
local InputController = require(script.Parent.InputController)
local AudioController = require(script.Parent.AudioController)
local PlacementController = require(script.Parent.PlacementController)
local Theme = require(script.Parent.Parent.UI.Theme)
local Create = require(script.Parent.Parent.UI.Create)
local Icons = require(script.Parent.Parent.UI.Icons)
local Components = require(script.Parent.Parent.UI.Components)
local Toasts = require(script.Parent.Parent.UI.Toasts)
local DeployRules = require(Shared.Logic.DeployRules)

local InteractionController = {}
InteractionController.priority = 60

export type Action = {
	kind: string, -- revive | cargo | deploy | recall | capture | lever
	target: string,
	text: string,
	hold: boolean,
	duration: number,
	position: Vector3,
	valid: boolean,
	reasonText: string?,
	color: Color3,
	icon: string,
}

InteractionController.ActionChanged = Signal.new() -- (action?)
InteractionController.HoldProgress = Signal.new() -- (progress 0..1, kind) ; progress < 0 = ended

local C = Theme.Colors
local localPlayer = Players.LocalPlayer

local current: Action? = nil
local currentKey = ""

type Hold = { kind: string, target: string, started: number, duration: number, loop: AudioController.LoopHandle? }
local hold: Hold? = nil

-- Prompt UI ------------------------------------------------------------------------------------------------

local promptAnchor: Attachment? = nil
local prompt: BillboardGui? = nil
local promptKey: TextLabel? = nil
local promptKeyImage: ImageLabel? = nil
local promptText: TextLabel? = nil
local promptReason: TextLabel? = nil
local promptRing: Components.HoldHandle? = nil
local promptCard: Frame? = nil

local function ensurePrompt()
	if prompt and prompt.Parent then
		return
	end
	local anchor = Instance.new("Attachment")
	anchor.Name = "RN_PromptAnchor"
	anchor.Parent = Workspace.Terrain
	promptAnchor = anchor
	local gui = Create.new("BillboardGui", {
		Name = "RN_ActionPrompt",
		Size = UDim2.fromOffset(320, 96),
		StudsOffsetWorldSpace = Vector3.new(0, 2.2, 0),
		AlwaysOnTop = true,
		LightInfluence = 0,
		MaxDistance = 60,
		ResetOnSpawn = false,
		Adornee = anchor,
		Enabled = false,
		Parent = localPlayer:WaitForChild("PlayerGui"),
	})
	local card = Create.new("Frame", {
		Name = "Card",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(0, 56),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = C.panelDark,
		BackgroundTransparency = 0.1,
		Parent = gui,
	}, {
		Create.corner(Theme.Radius.pill),
		Create.stroke(C.gold, 2.5, 0),
		Create.padding(6, 10),
		Create.list(Enum.FillDirection.Horizontal, 10, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center),
	})
	local keyHolder = Create.new("Frame", {
		Name = "Key",
		Size = UDim2.fromOffset(44, 44),
		BackgroundTransparency = 1,
		LayoutOrder = 1,
		Parent = card,
	})
	promptRing = Components.holdCircle(keyHolder, C.gold)
	local keyBack = Create.new("Frame", {
		Name = "KeyBack",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.72, 0.72),
		BackgroundColor3 = C.cream,
		ZIndex = 2,
		Parent = keyHolder,
	}, { Create.corner(Theme.Radius.small) })
	promptKey = Create.new("TextLabel", {
		Name = "KeyText",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Text = "E",
		FontFace = Theme.Fonts.heading,
		TextSize = 22,
		TextColor3 = C.textDark,
		ZIndex = 3,
		Parent = keyBack,
	})
	promptKeyImage = Create.new("ImageLabel", {
		Name = "KeyImage",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Visible = false,
		ZIndex = 3,
		Parent = keyBack,
	})
	local textColumn = Create.new("Frame", {
		Name = "Texts",
		Size = UDim2.fromOffset(0, 48),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundTransparency = 1,
		LayoutOrder = 2,
		Parent = card,
	}, { Create.list(Enum.FillDirection.Vertical, 0, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center) })
	promptText = Components.label({
		name = "Action",
		text = "",
		font = Theme.Fonts.heading,
		textSize = 22,
		size = UDim2.fromOffset(0, 26),
		autoSize = Enum.AutomaticSize.X,
		stroke = true,
		layoutOrder = 1,
		parent = textColumn,
	})
	promptReason = Components.label({
		name = "Reason",
		text = "",
		font = Theme.Fonts.bodyBold,
		textSize = 16,
		color = C.red,
		size = UDim2.fromOffset(0, 20),
		autoSize = Enum.AutomaticSize.X,
		stroke = true,
		layoutOrder = 2,
		parent = textColumn,
	})
	promptCard = card
	prompt = gui
end

local function refreshPrompt(action: Action?)
	ensurePrompt()
	local gui = prompt :: BillboardGui
	if not action then
		gui.Enabled = false
		return
	end
	(promptAnchor :: Attachment).WorldPosition = action.position
	gui.Enabled = true
	local touch = Device.isTouch()
	local image = InputController.keyImage("Use")
	local keyLabel = promptKey :: TextLabel
	local keyImage = promptKeyImage :: ImageLabel
	if image then
		keyImage.Image = image
		keyImage.Visible = true
		keyLabel.Visible = false
	else
		keyImage.Visible = false
		keyLabel.Visible = true
		keyLabel.Text = if touch then "☝" else InputController.keyLabel("Use")
	end
	local holdWord = if action.hold then Strings.t("action.hold") .. " · " else ""
	(promptText :: TextLabel).Text = holdWord .. action.text;
	(promptText :: TextLabel).TextColor3 = if action.valid then C.text else C.textMuted
	local reason = promptReason :: TextLabel
	reason.Text = action.reasonText or ""
	reason.Visible = action.reasonText ~= nil and action.reasonText ~= ""
	local stroke = (promptCard :: Frame):FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = if action.valid then action.color else C.red
	end
	(promptRing :: Components.HoldHandle).setColor(action.color);
	(promptRing :: Components.HoldHandle).set(0)
end

-- Teammate hold rings -----------------------------------------------------------------------------------------

type RemoteHold = {
	gui: BillboardGui,
	anchor: Attachment,
	ring: Components.HoldHandle,
	started: number,
	duration: number,
}
local remoteHolds: { [string]: RemoteHold } = {}

local function stopRemoteHold(userKey: string)
	local h = remoteHolds[userKey]
	if h then
		remoteHolds[userKey] = nil
		h.gui:Destroy()
		h.anchor:Destroy()
	end
end

local function startRemoteHold(userKey: string, kind: string, target: string)
	stopRemoteHold(userKey)
	local level = RunInfo.level()
	local position: Vector3? = nil
	if kind == "capture" and level then
		position = level.target.capturePoint
	elseif kind == "revive" then
		local player = RunInfo.playerFor(target)
		local character = player and player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			position = root.CFrame.Position
		end
	end
	if not position then
		return
	end
	local anchor = Instance.new("Attachment")
	anchor.WorldPosition = position :: Vector3
	anchor.Parent = Workspace.Terrain
	local gui = Create.new("BillboardGui", {
		Name = "RN_TeamHold",
		Size = UDim2.fromOffset(64, 64),
		StudsOffsetWorldSpace = Vector3.new(0, 3.2, 0),
		AlwaysOnTop = true,
		LightInfluence = 0,
		MaxDistance = 120,
		Adornee = anchor,
		Parent = localPlayer:WaitForChild("PlayerGui"),
	})
	local ring = Components.holdCircle(gui, if kind == "capture" then C.gold else C.green)
	local holder = Create.new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.5, 0.5),
		BackgroundTransparency = 1,
		ZIndex = 3,
		Parent = gui,
	})
	Icons.make(if kind == "capture" then "suitcase" else "heart", C.white, C.ink).Parent = holder
	remoteHolds[userKey] = {
		gui = gui,
		anchor = anchor,
		ring = ring,
		started = os.clock(),
		duration = if kind == "capture" then GameConfig.Capture.HoldSeconds else GameConfig.Revive.HoldSeconds,
	}
end

-- Resolution ------------------------------------------------------------------------------------------------

local function rootPosition(): Vector3?
	local character = localPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root.CFrame.Position
	end
	return nil
end

local function roomName(roomId: string): string
	local def = RoomDefs.get(roomId)
	return if def then Strings.t(def.nameKey) else roomId
end

local function roomColor(roomId: string): Color3
	local def = RoomDefs.get(roomId)
	return if def then def.glow else C.gold
end

local function resolve(): Action?
	if not RunInfo.isParticipant() or not RunInfo.isActivePhase() or RunInfo.myStatus() ~= "Active" then
		return nil
	end
	local position = rootPosition()
	local level = RunInfo.level()
	if not position or not level then
		return nil
	end

	-- 1. Revive the nearest downed teammate.
	local bestRevive: Action? = nil
	local bestReviveDistance = GameConfig.Revive.Range
	for key, entry in RunInfo.roster() do
		if key ~= RunInfo.myKey() and entry.status == "Downed" then
			local player = RunInfo.playerFor(key)
			local character = player and player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") then
				local d = (root.CFrame.Position - position).Magnitude
				if d <= bestReviveDistance then
					bestReviveDistance = d
					bestRevive = {
						kind = "revive",
						target = key,
						text = Strings.t("action.revive", { name = entry.display or key }),
						hold = true,
						duration = GameConfig.Revive.HoldSeconds,
						position = root.CFrame.Position,
						valid = true,
						reasonText = nil,
						color = C.green,
						icon = "heart",
					}
				end
			end
		end
	end
	if bestRevive then
		return bestRevive
	end

	-- 2. Pick up the dropped suitcase.
	local cargo = ClientState.get("global", "cargo")
	if type(cargo) == "table" and cargo.state == "Dropped" and typeof(cargo.position) == "Vector3" then
		if (cargo.position - position).Magnitude <= GameConfig.Interaction.CargoPickupRange then
			return {
				kind = "cargo",
				target = "cargo",
				text = Strings.t("action.pickup"),
				hold = false,
				duration = 0,
				position = cargo.position,
				valid = true,
				reasonText = nil,
				color = C.gold,
				icon = "suitcase",
			}
		end
	end

	-- 3. Unfold / recall the selected room.
	local placement = PlacementController.candidate()
	if placement then
		local name = roomName(placement.roomId)
		local text = if placement.kind == "recall"
			then Strings.t("action.recall", { room = name })
			else Strings.t("action.deploy", { room = name })
		local reasonText: string? = nil
		if not placement.valid then
			reasonText = Strings.t(DeployRules.reasonKey(placement.reason :: any), placement.reasonParams)
		elseif placement.noEffect then
			reasonText = Strings.t("placement.noEffect")
		elseif placement.dir then
			reasonText = Strings.t("placement.dir." .. placement.dir)
		end
		return {
			kind = placement.kind :: string,
			target = placement.socketId or "",
			text = text,
			hold = false,
			duration = 0,
			position = placement.position,
			valid = placement.valid,
			reasonText = reasonText,
			color = roomColor(placement.roomId),
			icon = "suitcase",
		}
	end

	-- 4. Steal the target room.
	local target = ClientState.get("global", "rooms.target")
	if
		RunInfo.phase() == "Explore"
		and type(target) == "table"
		and target.state == "Intact"
		and level.target
		and (level.target.capturePoint - position).Magnitude <= GameConfig.Capture.Range
	then
		return {
			kind = "capture",
			target = "target",
			text = Strings.t("action.capture", { room = roomName(level.target.room) }),
			hold = true,
			duration = GameConfig.Capture.HoldSeconds,
			position = level.target.capturePoint,
			valid = true,
			reasonText = nil,
			color = C.gold,
			icon = "suitcase",
		}
	end

	-- 5. Power levers.
	if type(level.levers) == "table" then
		local bestLever: string? = nil
		local bestDistance = GameConfig.Interaction.LeverRange
		local bestPosition = Vector3.zero
		for leverId, lever in level.levers do
			local p = (lever.cf :: CFrame).Position
			local d = (p - position).Magnitude
			if d <= bestDistance then
				bestDistance = d
				bestLever = leverId
				bestPosition = p
			end
		end
		if bestLever then
			return {
				kind = "lever",
				target = bestLever,
				text = Strings.t("action.lever"),
				hold = false,
				duration = 0,
				position = bestPosition,
				valid = true,
				reasonText = nil,
				color = C.orange,
				icon = "bolt",
			}
		end
	end
	return nil
end

local function actionKey(a: Action?): string
	if not a then
		return ""
	end
	return table.concat({ a.kind, a.target, a.text, tostring(a.valid), a.reasonText or "", Device.kind() }, "|")
end

-- Holds -------------------------------------------------------------------------------------------------------

local function endHold(completed: boolean)
	local h = hold
	if not h then
		return
	end
	hold = nil
	if h.loop then
		h.loop.stop(0.15)
	end
	Net.send("HoldEnd", h.kind, h.target, completed)
	InteractionController.HoldProgress:Fire(-1, h.kind)
	if promptRing then
		(promptRing :: Components.HoldHandle).set(0)
	end
end

local function beginAction()
	local a = current
	if not a then
		return
	end
	if not a.valid then
		AudioController.ui("placement_invalid", 1)
		if a.reasonText then
			Toasts.show("error", a.reasonText :: string, true)
		end
		return
	end
	if a.kind == "deploy" or a.kind == "recall" then
		PlacementController.execute()
	elseif a.hold then
		hold = {
			kind = a.kind,
			target = a.target,
			started = os.clock(),
			duration = a.duration,
			loop = if a.kind == "capture"
				then AudioController.loop("capture_charge_loop", { group = "Effects", volume = 0.9 })
				else nil,
		}
		Net.send("HoldBegin", a.kind, a.target)
	else
		Net.send("Interact", a.kind, a.target)
		AudioController.ui("ui_click", 0.6)
	end
end

local REJECT_KEYS: { [string]: string } = {
	range = "action.reason.range",
	sight = "action.reason.sight",
	timing = "action.reason.timing",
}

function InteractionController.current(): Action?
	return current
end

function InteractionController.holdProgress(): number
	local h = hold
	if not h then
		return 0
	end
	return math.clamp((os.clock() - h.started) / h.duration, 0, 1)
end

function InteractionController.start()
	InputController.on("Use", function(state)
		if state == "Begin" then
			beginAction()
		elseif hold then
			-- Released early: cancel (completion is sent automatically when the ring fills).
			endHold(false)
		end
	end)
	InputController.on("Drop", function(state)
		if state == "Begin" and localPlayer:GetAttribute("Carrying") == true then
			Net.send("DropCargo")
		end
	end)
	Net.listen("Effect", function(name: any, params: any)
		if type(params) ~= "table" then
			return
		end
		if name == "holdRejected" or name == "interactRejected" then
			if hold and (name == "interactRejected" or params.kind == (hold :: Hold).kind) then
				local h = hold :: Hold
				hold = nil
				if h.loop then
					h.loop.stop(0.1)
				end
				InteractionController.HoldProgress:Fire(-1, h.kind)
			end
			AudioController.ui("placement_invalid", 0.9)
			local key = REJECT_KEYS[params.reason]
			if key then
				Toasts.key("error", key, nil, true)
			end
		elseif name == "holdCancelled" then
			if hold then
				local h = hold :: Hold
				hold = nil
				if h.loop then
					h.loop.stop(0.1)
				end
				InteractionController.HoldProgress:Fire(-1, h.kind)
			end
		elseif name == "holdStart" and type(params.userId) == "string" and params.userId ~= RunInfo.myKey() then
			startRemoteHold(params.userId, params.kind, params.target)
		elseif name == "holdStop" and type(params.userId) == "string" then
			stopRemoteHold(params.userId)
		end
	end)
	Device.Changed:Connect(function()
		currentKey = ""
	end)
	RunService.Heartbeat:Connect(function()
		local a = resolve()
		-- An active hold keeps its action until it ends; moving away cancels it.
		if hold then
			local h = hold :: Hold
			if not a or a.kind ~= h.kind or a.target ~= h.target then
				endHold(false)
			else
				local progress = math.clamp((os.clock() - h.started) / h.duration, 0, 1)
				if h.loop then
					h.loop.setPitch(0.85 + progress * 0.6)
				end
				if promptRing then
					(promptRing :: Components.HoldHandle).set(progress)
				end
				InteractionController.HoldProgress:Fire(progress, h.kind)
				if progress >= 1 then
					endHold(true)
				end
			end
		end
		current = a
		local key = actionKey(a)
		if key ~= currentKey then
			currentKey = key
			refreshPrompt(a)
			InteractionController.ActionChanged:Fire(a)
		elseif a and promptAnchor then
			(promptAnchor :: Attachment).WorldPosition = a.position
		end
		-- Teammate hold rings fill over their duration.
		local now = os.clock()
		for userKey, h in remoteHolds do
			local p = (now - h.started) / h.duration
			h.ring.set(math.clamp(p, 0, 1))
			if p > 1.6 then
				stopRemoteHold(userKey)
			end
		end
	end)
	RunInfo.PhaseChanged:Connect(function()
		if hold then
			endHold(false)
		end
		for userKey in remoteHolds do
			stopRemoteHold(userKey)
		end
	end)
end

return InteractionController
