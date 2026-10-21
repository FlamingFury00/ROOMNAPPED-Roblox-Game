--!strict
--[[
	Overlays: moment-to-moment feedback layered over the run HUD (U07, U09, U12, A06).

	* Damage vignette that flashes on hits, a darker one while downed and a slow pulse on the last heart.
	* Downed card with the revive / recovery countdown, and the spectator bar (Prev / Next) when out.
	* Big banners for the steal, the escape and the outcome; a combo stamp when rooms are combined.
	* The suitcase status (top right) and an edge arrow toward the Caretaker while it hunts you.

	Touch screens keep all of it clear of the thumbstick and the buttons around the jump button (HudLayout):
	the downed and spectator panels shrink onto the message line under the objective, banners play in the top
	band, the combo stamp below the free middle of the screen, and the Caretaker arrow circles the middle of
	the screen (where your character is) instead of running along its edges.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local GameConfig = require(Shared.Config.GameConfig)
local Strings = require(Shared.Config.Strings)
local Net = require(Shared.Net.Net)
local ClientState = require(script.Parent.Parent.Parent.Core.ClientState)
local RunInfo = require(script.Parent.Parent.Parent.Core.RunInfo)
local EffectsController = require(script.Parent.Parent.Parent.Controllers.EffectsController)
local SpectateController = require(script.Parent.Parent.Parent.Controllers.SpectateController)
local CaretakerView = require(script.Parent.Parent.Parent.Controllers.CaretakerView)
local Theme = require(script.Parent.Parent.Theme)
local Create = require(script.Parent.Parent.Create)
local Icons = require(script.Parent.Parent.Icons)
local Motion = require(script.Parent.Parent.Motion)
local Components = require(script.Parent.Parent.Components)
local UIRoot = require(script.Parent.Parent.UIRoot)
local Responsive = require(script.Parent.Parent.Responsive)
local Common = require(script.Parent.Parent.Screens.Common)
local HudLayout = require(script.Parent.Parent.HudLayout)

local Overlays = {}

local C = Theme.Colors
local localPlayer = Players.LocalPlayer

export type Handle = { setVisible: (boolean) -> () }

-- Vignette ---------------------------------------------------------------------------------------------------

local function edge(
	parent: Instance,
	name: string,
	size: UDim2,
	position: UDim2,
	anchor: Vector2,
	rotation: number
): Frame
	local frame = Create.new("Frame", {
		Name = name,
		Size = size,
		Position = position,
		AnchorPoint = anchor,
		BackgroundColor3 = C.red,
		BorderSizePixel = 0,
		ZIndex = 0,
		Parent = parent,
	})
	local gradient = Instance.new("UIGradient")
	gradient.Rotation = rotation
	gradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	gradient.Parent = frame
	return frame
end

function Overlays.create(parent: Instance): Handle
	local vignette = Create.new("Frame", {
		Name = "Vignette",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		ZIndex = 0,
		Parent = UIRoot.Guis.Cinema,
	})
	local edges = {
		edge(vignette, "Left", UDim2.fromScale(0.22, 1), UDim2.fromScale(0, 0), Vector2.zero, 0),
		edge(vignette, "Right", UDim2.fromScale(0.22, 1), UDim2.fromScale(1, 0), Vector2.new(1, 0), 180),
		edge(vignette, "Top", UDim2.fromScale(1, 0.26), UDim2.fromScale(0, 0), Vector2.zero, 90),
		edge(vignette, "Bottom", UDim2.fromScale(1, 0.26), UDim2.fromScale(0, 1), Vector2.new(0, 1), -90),
	}
	local flash = 0
	local function setVignette(alpha: number, color: Color3)
		vignette.Visible = alpha > 0.01
		for _, e in edges do
			e.BackgroundColor3 = color
			e.BackgroundTransparency = 1 - alpha
		end
	end
	EffectsController.LocalHit:Connect(function()
		flash = 1
	end)

	-- Downed card -------------------------------------------------------------------------------------------
	local downed = Create.new("Frame", {
		Name = "Downed",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.62),
		Size = UDim2.fromOffset(420, 150),
		BackgroundColor3 = C.panelDark,
		BackgroundTransparency = 0.12,
		Visible = false,
		Parent = parent,
	}, { Create.corner(Theme.Radius.large), Create.stroke(C.red, 3, 0) })
	-- Below the centre so the downed character stays in view, but always clear of the quickbar (short phone
	-- canvases would otherwise push it into the slots).
	local function placeDowned()
		local gui = parent:FindFirstAncestorOfClass("ScreenGui")
		local height = if gui then Responsive.canvasSize(gui).Y else 0
		if height > 0 and not HudLayout.touch() then
			downed.Position = UDim2.new(0.5, 0, 0, math.round(math.min(height * 0.62, height - 225)))
		end
	end
	local downedIcon = Create.new("Frame", {
		Position = UDim2.fromOffset(20, 22),
		Size = UDim2.fromOffset(56, 56),
		BackgroundTransparency = 1,
		Parent = downed,
	})
	Icons.make("heartEmpty", C.red, C.white).Parent = downedIcon
	local downedTitle = Components.label({
		text = Strings.t("hud.downed.title"),
		font = Theme.Fonts.display,
		textSize = 40,
		color = C.red,
		position = UDim2.fromOffset(90, 16),
		size = UDim2.new(1, -110, 0, 44),
		stroke = true,
		parent = downed,
	})
	local downedBody = Components.label({
		text = "",
		font = Theme.Fonts.bodyBold,
		textSize = Theme.Text.body,
		position = UDim2.fromOffset(90, 62),
		size = UDim2.new(1, -110, 0, 26),
		wrap = true,
		parent = downed,
	})
	local downedTimer = Components.bar(UDim2.new(1, -40, 0, 14), C.red, downed)
	downedTimer.frame.AnchorPoint = Vector2.new(0.5, 1)
	downedTimer.frame.Position = UDim2.new(0.5, 0, 1, -18)
	local downedScale = Create.new("UIScale", { Name = "TouchScale", Scale = 1, Parent = downed })
	local downedSeconds = Components.label({
		text = "",
		font = Theme.Fonts.heading,
		textSize = 18,
		align = Enum.TextXAlignment.Right,
		anchor = Vector2.new(1, 1),
		position = UDim2.new(1, -20, 1, -34),
		size = UDim2.fromOffset(80, 24),
		stroke = true,
		parent = downed,
	})

	-- Spectator bar -------------------------------------------------------------------------------------------
	local spectate = Create.new("Frame", {
		Name = "Spectate",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -24),
		Size = UDim2.fromOffset(580, 88),
		BackgroundColor3 = C.panelDark,
		BackgroundTransparency = 0.1,
		Visible = false,
		Parent = parent,
	}, { Create.corner(Theme.Radius.pill), Create.stroke(C.gold, 2.5, 0.2) })
	local prev = Components.button({
		text = Strings.t("hud.spectate.prev"),
		icon = "arrowUp",
		variant = "secondary",
		size = UDim2.fromOffset(124, 72),
		position = UDim2.new(0, 10, 0.5, 0),
		anchor = Vector2.new(0, 0.5),
		parent = spectate,
		onClick = function()
			SpectateController.cycle(-1)
		end,
	})
	local nextButton = Components.button({
		text = Strings.t("hud.spectate.next"),
		icon = "arrowUp",
		variant = "secondary",
		size = UDim2.fromOffset(124, 72),
		position = UDim2.new(1, -10, 0.5, 0),
		anchor = Vector2.new(1, 0.5),
		parent = spectate,
		onClick = function()
			SpectateController.cycle(1)
		end,
	})
	local prevIcon = prev.instance:FindFirstChild("IconHolder", true)
	if prevIcon and prevIcon:IsA("Frame") then
		prevIcon.Rotation = -90
	end
	local nextIcon = nextButton.instance:FindFirstChild("IconHolder", true)
	if nextIcon and nextIcon:IsA("Frame") then
		nextIcon.Rotation = 90
	end
	local spectateLabel = Components.label({
		text = "",
		font = Theme.Fonts.heading,
		textSize = Theme.Text.medium,
		align = Enum.TextXAlignment.Center,
		anchor = Vector2.new(0.5, 0.5),
		position = UDim2.fromScale(0.5, 0.5),
		size = UDim2.new(1, -296, 0, 32),
		stroke = true,
		parent = spectate,
	})
	-- Long display names truncate instead of running over Prev / Next.
	spectateLabel.TextTruncate = Enum.TextTruncate.AtEnd
	local spectateScale = Create.new("UIScale", { Name = "TouchScale", Scale = 1, Parent = spectate })
	SpectateController.Changed:Connect(function(key: string?)
		spectateLabel.Text = if key then Strings.t("hud.spectate.title", { name = RunInfo.displayName(key) }) else ""
	end)

	-- Banner & combo stamp --------------------------------------------------------------------------------------
	local banner = Create.new("Frame", {
		Name = "Banner",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.36),
		Size = UDim2.fromOffset(900, 150),
		BackgroundTransparency = 1,
		Visible = false,
		Parent = parent,
	})
	local bannerTitle = Components.label({
		text = "",
		font = Theme.Fonts.display,
		textSize = 84,
		align = Enum.TextXAlignment.Center,
		size = UDim2.new(1, 0, 0, 96),
		color = C.gold,
		stroke = true,
		strokeColor = C.ink,
		parent = banner,
	})
	local titleStroke = bannerTitle:FindFirstChildOfClass("UIStroke")
	if titleStroke then
		titleStroke.Thickness = 4
		titleStroke.Transparency = 0
	end
	local bannerSub = Components.label({
		text = "",
		font = Theme.Fonts.heading,
		textSize = Theme.Text.large,
		align = Enum.TextXAlignment.Center,
		size = UDim2.new(1, 0, 0, 36),
		position = UDim2.fromOffset(0, 100),
		stroke = true,
		parent = banner,
	})
	local bannerScale = Create.new("UIScale", { Name = "TouchScale", Scale = 1, Parent = banner })
	local bannerToken = 0
	local function showBanner(title: string, sub: string, color: Color3, seconds: number)
		bannerToken += 1
		local token = bannerToken
		bannerTitle.Text = title
		bannerTitle.TextColor3 = color
		bannerSub.Text = sub
		banner.Visible = true
		Motion.growIn(banner)
		task.delay(seconds, function()
			if token == bannerToken then
				banner.Visible = false
			end
		end)
	end

	local stamp = Create.new("Frame", {
		Name = "ComboStamp",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(420, 110),
		BackgroundColor3 = C.purple,
		Rotation = -6,
		Visible = false,
		Parent = parent,
	}, { Create.corner(Theme.Radius.large), Create.stroke(C.white, 4, 0) })
	Components.label({
		text = "COMBO!",
		font = Theme.Fonts.display,
		textSize = 44,
		align = Enum.TextXAlignment.Center,
		size = UDim2.new(1, 0, 0, 52),
		position = UDim2.fromOffset(0, 8),
		stroke = true,
		parent = stamp,
	})
	local stampText = Components.label({
		text = "",
		font = Theme.Fonts.heading,
		textSize = Theme.Text.large,
		align = Enum.TextXAlignment.Center,
		size = UDim2.new(1, 0, 0, 36),
		position = UDim2.fromOffset(0, 60),
		stroke = true,
		parent = stamp,
	})
	local stampScale = Create.new("UIScale", { Name = "TouchScale", Scale = 1, Parent = stamp })
	-- Desktop: screen centre. Touch: low in the free middle of the screen, between the thumbstick zone and
	-- the buttons around the jump button.
	local function stampHome(): UDim2
		if not HudLayout.touch() then
			return UDim2.fromScale(0.5, 0.5)
		end
		local zones = HudLayout.zones()
		local w, h = 420 * stampScale.Scale, 110 * stampScale.Scale
		local left = zones.stick.x1 + w / 2 + 8
		local right = zones.jump.x0 - 140 - w / 2
		return UDim2.fromOffset(
			math.round(math.max(left, math.min(right, zones.canvas.X / 2))),
			math.round(zones.canvas.Y - h / 2 - 16)
		)
	end
	local stampToken = 0
	EffectsController.Combo:Connect(function(comboId: string)
		stampToken += 1
		local token = stampToken
		stampText.Text = Strings.t("combo." .. comboId)
		stamp.Visible = true
		local home = stampHome()
		stamp.Position = home
		Motion.growIn(stamp)
		task.delay(1.5, function()
			if token == stampToken then
				Motion.tween(stamp, Theme.Tween.medium, {
					Position = if HudLayout.touch()
						then home + UDim2.fromOffset(0, -24)
						else UDim2.fromScale(0.5, 0.42),
				})
				task.delay(0.25, function()
					if token == stampToken then
						stamp.Visible = false
					end
				end)
			end
		end)
	end)

	-- Cargo status ---------------------------------------------------------------------------------------------
	local cargo = Create.new("Frame", {
		Name = "Cargo",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -16, 0, 122),
		Size = UDim2.fromOffset(0, 62),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = C.panelDark,
		BackgroundTransparency = 0.12,
		Visible = false,
		Parent = parent,
	}, {
		Create.corner(Theme.Radius.large),
		Create.padding(6, 14),
		Create.list(Enum.FillDirection.Horizontal, 10, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center),
	})
	local cargoStroke = Create.stroke(C.gold, 2.5, 0)
	cargoStroke.Parent = cargo
	local cargoScale = Create.new("UIScale", { Name = "TouchScale", Scale = 1, Parent = cargo })
	local cargoIconHolder = Create.new(
		"Frame",
		{ Size = UDim2.fromOffset(38, 38), BackgroundTransparency = 1, LayoutOrder = 1, Parent = cargo }
	)
	Icons.make("suitcase", C.gold, C.ink).Parent = cargoIconHolder
	local cargoTexts = Create.new("Frame", {
		Size = UDim2.fromOffset(0, 50),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundTransparency = 1,
		LayoutOrder = 2,
		Parent = cargo,
	}, { Create.list(Enum.FillDirection.Vertical, 0, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center) })
	local cargoTitle = Components.label({
		text = "",
		font = Theme.Fonts.heading,
		textSize = 19,
		size = UDim2.fromOffset(0, 24),
		autoSize = Enum.AutomaticSize.X,
		stroke = true,
		layoutOrder = 1,
		parent = cargoTexts,
	})
	local cargoRisk = Components.label({
		text = Strings.t("hud.cargo.risk"),
		font = Theme.Fonts.bodyBold,
		textSize = 14,
		color = C.orange,
		size = UDim2.fromOffset(0, 18),
		autoSize = Enum.AutomaticSize.X,
		layoutOrder = 2,
		parent = cargoTexts,
	})
	local lastCargo = ""
	local cargoCompact = false -- phones: the title alone (the objective already says what is at stake)
	local function refreshCargo(force: boolean?)
		if force then
			lastCargo = ""
		end
		local state = ClientState.get("global", "cargo")
		local s = if type(state) == "table" then state.state else "None"
		local visible = RunInfo.isParticipant() and s ~= nil and s ~= "None"
		cargo.Visible = visible
		if not visible then
			lastCargo = ""
			return
		end
		local key: string
		local params: { [string]: any }? = nil
		local color = C.gold
		if s == "Carried" then
			if state.carrier == RunInfo.myKey() then
				key = "hud.cargo.you"
			else
				key = "hud.cargo.carried"
				params = { name = state.carrierName or "?" }
			end
		elseif s == "Dropped" then
			key = "hud.cargo.dropped"
			color = C.red
		elseif s == "Banked" then
			key = "hud.cargo.banked"
			color = C.green
		else
			key = "hud.cargo.none"
		end
		local signature = key .. (if params then tostring(params.name) else "")
		if signature == lastCargo then
			return
		end
		lastCargo = signature
		cargoTitle.Text = Strings.t(key, params)
		cargoTitle.TextColor3 = if color == C.red then C.red else C.text
		cargoStroke.Color = color
		cargoRisk.Visible = not cargoCompact and (s == "Carried" or s == "Dropped")
		Motion.pop(cargo, 0.9)
		if s == "Dropped" then
			Motion.shake(cargo)
		end
	end
	ClientState.observe("global", "cargo", function()
		refreshCargo()
	end)

	-- Caretaker edge arrow -------------------------------------------------------------------------------------
	local threatArrow = Create.new("Frame", {
		Name = "ThreatArrow",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(54, 54),
		BackgroundColor3 = C.red,
		Visible = false,
		Parent = parent,
	}, { Create.corner(Theme.Radius.pill), Create.stroke(C.white, 3, 0) })
	local arrowHolder = Create.new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.62, 0.62),
		BackgroundTransparency = 1,
		Parent = threatArrow,
	})
	Icons.make("arrowUp", C.white, C.red).Parent = arrowHolder

	-- Touch layout ---------------------------------------------------------------------------------------------
	local function applyLayout()
		local touch = HudLayout.touch()
		local phone = HudLayout.phone()
		-- Suitcase status: right under the menu bar.
		local status = HudLayout.scale("status")
		cargoScale.Scale = status
		cargo.Position = if phone then UDim2.new(1, -10, 0, 96) else UDim2.new(1, -16, 0, if touch then 112 else 122)
		cargoCompact = phone
		refreshCargo(true)
		-- Downed and spectating: compact panels on the message line.
		local message = HudLayout.scale("message")
		downedScale.Scale = if touch then message else 1
		downedTitle.Visible = not touch
		downedIcon.Size = if touch then UDim2.fromOffset(32, 32) else UDim2.fromOffset(56, 56)
		downedIcon.Position = if touch then UDim2.fromOffset(14, 6) else UDim2.fromOffset(20, 22)
		downedBody.Position = if touch then UDim2.fromOffset(56, 5) else UDim2.fromOffset(90, 62)
		downedBody.Size = if touch then UDim2.new(1, -150, 0, 30) else UDim2.new(1, -110, 0, 26)
		downedBody.TextSize = if touch then Theme.Text.medium else Theme.Text.body
		downedBody.TextWrapped = not touch
		downedBody.TextTruncate = if touch then Enum.TextTruncate.AtEnd else Enum.TextTruncate.None
		downedSeconds.AnchorPoint = if touch then Vector2.new(1, 0) else Vector2.new(1, 1)
		downedSeconds.Position = if touch then UDim2.new(1, -14, 0, 8) else UDim2.new(1, -20, 1, -34)
		downedTimer.frame.Size = if touch then UDim2.new(1, -28, 0, 8) else UDim2.new(1, -40, 0, 14)
		downedTimer.frame.Position = if touch then UDim2.new(0.5, 0, 1, -7) else UDim2.new(0.5, 0, 1, -18)
		downed.Size = if touch then UDim2.fromOffset(480, 54) else UDim2.fromOffset(420, 150)
		spectateScale.Scale = if touch then message else 1
		if touch then
			local zones = HudLayout.zones()
			local top = HudLayout.messageTop()
			-- Both panels slide right of the thumbstick zone when they would reach below its top.
			local function lineCentre(width: number, height: number): number
				local centre = zones.canvas.X / 2
				if top + height * message > zones.stick.y0 then
					centre = math.max(centre, zones.stick.x1 + width * message / 2 + 8)
				end
				return math.round(centre)
			end
			downed.AnchorPoint = Vector2.new(0.5, 0)
			downed.Position = UDim2.fromOffset(lineCentre(480, 54), top)
			spectate.AnchorPoint = Vector2.new(0.5, 0)
			spectate.Position = UDim2.fromOffset(lineCentre(580, 88), top)
		else
			downed.AnchorPoint = Vector2.new(0.5, 0.5)
			placeDowned()
			spectate.AnchorPoint = Vector2.new(0.5, 1)
			spectate.Position = UDim2.new(0.5, 0, 1, -24)
		end
		-- Banners play in the top band on touch screens.
		bannerScale.Scale = if phone then 0.7 elseif touch then 0.85 else 1
		banner.Position = if touch
			then UDim2.new(0.5, 0, 0, math.round(75 * bannerScale.Scale / 0.7))
			else UDim2.fromScale(0.5, 0.36)
		stampScale.Scale = if phone then 0.7 elseif touch then 0.85 else 1
	end
	applyLayout()
	HudLayout.Changed:Connect(applyLayout)
	Responsive.Changed:Connect(applyLayout)

	-- Outcome / phase banners ----------------------------------------------------------------------------------
	RunInfo.PhaseChanged:Connect(function(newPhase: string, previous: string)
		local phase: string = newPhase
		if not RunInfo.isParticipant() and phase ~= "Results" then
			return
		end
		local current: string = phase
		if current == "Capture" then
			showBanner(Strings.t("banner.captured"), Strings.t("banner.capturedSub"), C.gold, 2.6)
		elseif current == "Results" and previous ~= "Prep" then
			local outcome = RunInfo.run().outcome
			if outcome == "Success" then
				showBanner(Strings.t("banner.extracted"), "", C.green, 2.2)
			elseif outcome == "Wiped" or outcome == "TimeUp" then
				local title = Common.failureText(outcome, RunInfo.run().cause)
				showBanner(title, "", C.red, 2)
			end
		end
	end)
	Net.listen("Effect", function(name: any)
		if name == "caretakerAlert" and RunInfo.isParticipant() then
			Components.sound("ui_countdown_go")
		end
	end)

	-- Per frame ----------------------------------------------------------------------------------------------------
	local visible = false
	RunService.RenderStepped:Connect(function(dt: number)
		local status = RunInfo.myStatus()
		local participant = visible and RunInfo.isParticipant()
		-- Vignette.
		flash = math.max(0, flash - dt * 2.4)
		local entry = RunInfo.myEntry()
		local lowHeart = participant and entry ~= nil and entry.hearts == 1 and status == "Active"
		local base = 0
		local color = C.red
		if participant and (status == "Downed" or status == "Recovering") then
			base = 0.55
			color = Color3.fromRGB(70, 10, 20)
		elseif lowHeart then
			base = 0.18 + 0.12 * math.sin(os.clock() * 5)
		end
		setVignette(math.max(base, flash * 0.75), if flash > base then C.red else color)

		-- Downed card.
		local isDowned = participant and (status == "Downed" or status == "Recovering")
		downed.Visible = isDowned
		if isDowned and entry then
			local solo = status == "Recovering"
			downedBody.Text = Strings.t(if solo then "hud.downed.solo" else "hud.downed.body")
			local endsAt = if solo then entry.recoverEndsAt else entry.downedEndsAt
			local window = if solo then GameConfig.Downed.SoloRecoveryDelaySeconds else GameConfig.Downed.WindowSeconds
			if type(endsAt) == "number" then
				local remaining = math.max(0, endsAt - RunInfo.serverNow())
				downedTimer.set(remaining / window)
				downedSeconds.Text = Strings.t("hud.downed.timer", { seconds = math.ceil(remaining) })
			end
		end

		-- Spectator bar.
		spectate.Visible = visible and SpectateController.isSpectating()

		-- Threat arrow toward a hunting Caretaker that is off-screen.
		local caretakerPosition = CaretakerView.position()
		local mode = CaretakerView.mode()
		local hunting = mode == "Chase" or mode == "Hunt" or mode == "Lunge" or mode == "Alert"
		local showArrow = false
		if participant and caretakerPosition and hunting then
			local camera = Workspace.CurrentCamera :: Camera
			local screen, onScreen = camera:WorldToViewportPoint(caretakerPosition :: Vector3)
			local character = localPlayer.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			local near = root
				and root:IsA("BasePart")
				and ((caretakerPosition :: Vector3) - root.CFrame.Position).Magnitude < 140
			if not onScreen and near then
				local viewport = camera.ViewportSize
				local centre = viewport / 2
				local direction = Vector2.new(screen.X, screen.Y) - centre
				if screen.Z < 0 then
					direction = -direction
				end
				if direction.Magnitude > 1 then
					direction = direction.Unit
					local canvas: Vector2
					if HudLayout.touch() then
						-- Circle the middle of the screen: the edges belong to the touch controls.
						local radius = if HudLayout.phone() then 96 else 150
						canvas = HudLayout.orbitCentre(radius, 54) + direction * radius
					else
						local margin = 60
						local sx = (viewport.X / 2 - margin) / math.max(1e-3, math.abs(direction.X))
						local sy = (viewport.Y / 2 - margin) / math.max(1e-3, math.abs(direction.Y))
						local point = centre + direction * math.min(sx, sy)
						canvas = Responsive.toCanvas(UIRoot.Guis.Hud, point)
					end
					-- UDim offsets are integers; never feed a non-finite value to the layout.
					if
						canvas.X == canvas.X
						and canvas.Y == canvas.Y
						and math.abs(canvas.X) < 1e5
						and math.abs(canvas.Y) < 1e5
					then
						threatArrow.Position = UDim2.fromOffset(math.round(canvas.X), math.round(canvas.Y))
					end
					threatArrow.Rotation = math.deg(math.atan2(direction.X, -direction.Y))
					arrowHolder.Rotation = 0
					showArrow = true
				end
			end
		end
		threatArrow.Visible = showArrow
	end)

	return {
		setVisible = function(value: boolean)
			visible = value
			if not value then
				downed.Visible = false
				spectate.Visible = false
				cargo.Visible = false
				threatArrow.Visible = false
				setVignette(0, C.red)
			else
				refreshCargo()
			end
		end,
	}
end

return Overlays
