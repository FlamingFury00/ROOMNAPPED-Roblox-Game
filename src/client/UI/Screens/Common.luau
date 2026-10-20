--!strict
--[[
	Common: shared building blocks for the lobby and menu screens (U15-U19).

	Windows with a title ribbon and close button, tab rows, scrolling lists, name/time formatting, avatar
	headshots and live 3D previews of rooms and suitcases. This module has no start(), so the client
	bootstrap ignores it; screens require it directly.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local Strings = require(Shared.Config.Strings)
local RoomDefs = require(Shared.Config.RoomDefs)
local SkinDefs = require(Shared.Config.SkinDefs)
local MissionDefs = require(Shared.Config.MissionDefs)
local ClientState = require(script.Parent.Parent.Parent.Core.ClientState)
local Theme = require(script.Parent.Parent.Theme)
local Create = require(script.Parent.Parent.Create)
local Components = require(script.Parent.Parent.Components)
local Icons = require(script.Parent.Parent.Icons)
local UIRoot = require(script.Parent.Parent.UIRoot)
local Responsive = require(script.Parent.Parent.Responsive)

type ButtonHandle = Components.ButtonHandle

local Common = {}

local C = Theme.Colors

-- Data access ------------------------------------------------------------------------------------------

function Common.profile(): { [string]: any }?
	local profile = ClientState.get("me", "profile")
	if type(profile) == "table" and profile.status == "Ready" and type(profile.rooms) == "table" then
		return profile
	end
	return nil
end

function Common.profileStatus(): string
	local profile = ClientState.get("me", "profile")
	if type(profile) == "table" and type(profile.status) == "string" then
		return profile.status
	end
	return "Loading"
end

function Common.isAdmin(): boolean
	return ClientState.get("me", "admin") == true
end

-- Formatting -------------------------------------------------------------------------------------------

function Common.formatTime(seconds: number?): string
	local s = math.max(0, math.floor((seconds or 0) + 0.5))
	return string.format("%d:%02d", s // 60, s % 60)
end

function Common.formatNumber(n: number): string
	local text = tostring(math.floor(n + 0.5))
	local formatted = text
	while true do
		local replaced, count = string.gsub(formatted, "^(-?%d+)(%d%d%d)", "%1,%2")
		formatted = replaced
		if count == 0 then
			break
		end
	end
	return formatted
end

function Common.roomName(roomId: string?): string
	local def = if roomId then RoomDefs.byId[roomId] else nil
	return if def then Strings.t(def.nameKey) else (roomId or "?")
end

function Common.skinName(skinId: string?): string
	local def = if skinId then SkinDefs.byId[skinId] else nil
	return if def then Strings.t(def.nameKey) else (skinId or "?")
end

function Common.missionName(missionId: string?): string
	local def = if missionId then MissionDefs.byId[missionId] else nil
	return if def then Strings.t(def.nameKey) else (missionId or "?")
end

function Common.challengeText(challenge: MissionDefs.Challenge): string
	return Strings.t(challenge.nameKey, { value = challenge.value })
end

function Common.findChallenge(challengeId: string): MissionDefs.Challenge?
	for _, mission in MissionDefs.list do
		for _, challenge in mission.challenges do
			if challenge.id == challengeId then
				return challenge
			end
		end
	end
	return nil
end

function Common.difficultyText(level: number): string
	return Strings.t("mission.difficulty" .. tostring(math.clamp(level, 1, 3)))
end

function Common.difficultyColor(level: number): Color3
	if level >= 3 then
		return C.red
	elseif level == 2 then
		return C.orange
	end
	return C.green
end

-- Avatars ----------------------------------------------------------------------------------------------

local headshots: { [number]: string } = {}
local pendingHeadshots: { [number]: { ImageLabel } } = {}

-- Fill an ImageLabel with a player's headshot (cached; never yields the caller).
function Common.headshot(image: ImageLabel, userId: number)
	local cached = headshots[userId]
	if cached then
		image.Image = cached
		return
	end
	local waiting = pendingHeadshots[userId]
	if waiting then
		table.insert(waiting, image)
		return
	end
	pendingHeadshots[userId] = { image }
	task.spawn(function()
		local ok, content = pcall(function()
			return Players:GetUserThumbnailAsync(userId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size150x150)
		end)
		local url = if ok and type(content) == "string" then content else ""
		headshots[userId] = url
		local list: { ImageLabel } = pendingHeadshots[userId] or {}
		pendingHeadshots[userId] = nil
		for _, target in list do
			if target.Parent then
				target.Image = url
			end
		end
	end)
end

-- Windows ----------------------------------------------------------------------------------------------

export type Window = { frame: Frame, content: Frame, close: ButtonHandle? }

-- A centred modal window on the menu canvas with a title ribbon and an optional close button.
function Common.window(name: string, title: string, icon: string?, size: Vector2, closable: boolean?): Window
	local frame, content = Components.panel({
		name = name,
		size = UDim2.fromOffset(size.X, size.Y),
		position = UDim2.fromScale(0.5, 0.52),
		anchor = Vector2.new(0.5, 0.5),
		title = title,
		titleIcon = icon,
		padding = 22,
	})
	-- Keep windows inside small canvases (phones clamp the scale, so the virtual canvas can be shorter
	-- than 720): shrink to the canvas with a margin, never grow past the designed size.
	local function fit()
		local canvas = Responsive.canvasSize(UIRoot.Guis.Menus)
		if canvas.X <= 0 or canvas.Y <= 0 then
			return
		end
		frame.Size = UDim2.fromOffset(math.min(size.X, canvas.X - 32), math.min(size.Y, canvas.Y - 28))
	end
	fit()
	Responsive.Changed:Connect(fit)
	local closeButton: ButtonHandle? = nil
	if closable ~= false then
		local close = Components.iconButton("cross", 58, function()
			UIRoot.back()
		end, "danger")
		close.instance.Name = "Close"
		close.instance.AnchorPoint = Vector2.new(0.5, 0.5)
		close.instance.Position = UDim2.new(1, -10, 0, 10)
		close.instance.ZIndex = 6
		for _, d in close.instance:GetDescendants() do
			if d:IsA("GuiObject") then
				d.ZIndex = 6
			end
		end
		close.instance.Parent = frame
		closeButton = close
	end
	frame.Parent = UIRoot.Menus
	return { frame = frame, content = content, close = closeButton }
end

-- A simple modal confirm dialog. Returns the Screen-ready frame; buttons call the callbacks.
function Common.confirmFrame(
	name: string,
	title: string,
	body: string,
	yesText: string,
	noText: string,
	onYes: () -> (),
	onNo: () -> (),
	yesVariant: Components.ButtonVariant?,
	icon: string?
): (Frame, ButtonHandle, ButtonHandle)
	local window = Common.window(name, title, icon or "alert", Vector2.new(620, 330), false)
	Components.label({
		text = body,
		size = UDim2.new(1, 0, 0, 120),
		position = UDim2.fromOffset(0, 10),
		wrap = true,
		textSize = Theme.Text.medium,
		font = Theme.Fonts.bodyBold,
		align = Enum.TextXAlignment.Center,
		yAlign = Enum.TextYAlignment.Center,
		parent = window.content,
	})
	local row = Create.new("Frame", {
		Name = "Buttons",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, 0),
		Size = UDim2.new(1, 0, 0, 84),
		Parent = window.content,
	}, {
		Create.list(Enum.FillDirection.Horizontal, 18, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center),
	})
	local no = Components.button({
		name = "Cancel",
		text = noText,
		variant = "secondary",
		size = UDim2.fromOffset(230, 78),
		layoutOrder = 1,
		onClick = onNo,
		parent = row,
	})
	local yes = Components.button({
		name = "Confirm",
		text = yesText,
		variant = yesVariant or "danger",
		size = UDim2.fromOffset(230, 78),
		layoutOrder = 2,
		onClick = onYes,
		parent = row,
	})
	return window.frame, yes, no
end

-- Tabs --------------------------------------------------------------------------------------------------

export type TabItem = { id: string, text: string, icon: string? }
export type Tabs = { frame: Frame, select: (string) -> (), selected: () -> string, buttons: { [string]: ButtonHandle } }

function Common.tabs(parent: Instance, items: { TabItem }, onSelect: (string) -> (), width: number?): Tabs
	local frame = Create.new("Frame", {
		Name = "Tabs",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 70),
		Parent = parent,
	}, {
		Create.list(Enum.FillDirection.Horizontal, 10, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center),
	})
	local buttons: { [string]: ButtonHandle } = {}
	local current = items[1] and items[1].id or ""
	local function paint()
		for id, button in buttons do
			button.setVariant(if id == current then "primary" else "secondary")
			button.setSelected(id == current)
		end
	end
	local tabs: Tabs
	tabs = {
		frame = frame,
		buttons = buttons,
		select = function(id: string)
			current = id
			paint()
			onSelect(id)
		end,
		selected = function(): string
			return current
		end,
	}
	for index, item in items do
		buttons[item.id] = Components.button({
			text = item.text,
			icon = item.icon,
			variant = "secondary",
			size = UDim2.fromOffset(width or 200, 62),
			textSize = Theme.Text.medium,
			layoutOrder = index,
			sound = "ui_toggle",
			onClick = function()
				if current ~= item.id then
					tabs.select(item.id)
				end
			end,
			parent = frame,
		})
	end
	paint()
	return tabs
end

-- Scrolling lists ----------------------------------------------------------------------------------------

function Common.scroll(
	parent: Instance,
	size: UDim2,
	position: UDim2?,
	spacing: number?,
	horizontal: boolean?
): ScrollingFrame
	local scroll = Create.new("ScrollingFrame", {
		Name = "Scroll",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = size,
		Position = position or UDim2.new(),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = if horizontal then Enum.AutomaticSize.X else Enum.AutomaticSize.Y,
		ScrollingDirection = if horizontal then Enum.ScrollingDirection.X else Enum.ScrollingDirection.Y,
		ScrollBarThickness = 8,
		ScrollBarImageColor3 = C.gold,
		ScrollBarImageTransparency = 0.2,
		VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar,
		HorizontalScrollBarInset = Enum.ScrollBarInset.ScrollBar,
		Selectable = false,
		Parent = parent,
	}, {
		Create.list(
			if horizontal then Enum.FillDirection.Horizontal else Enum.FillDirection.Vertical,
			spacing or 10,
			Enum.HorizontalAlignment.Left,
			Enum.VerticalAlignment.Top
		),
		Create.padding(6, 6),
	})
	return scroll
end

-- Small section heading used inside screens.
function Common.heading(parent: Instance, text: string, icon: string?, layoutOrder: number?): Frame
	local row = Create.new("Frame", {
		Name = "Heading",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 38),
		LayoutOrder = layoutOrder or 0,
		Parent = parent,
	}, {
		Create.list(Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center),
	})
	if icon then
		local holder = Create.new("Frame", {
			Name = "Icon",
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(28, 28),
			LayoutOrder = 1,
			Parent = row,
		})
		Icons.make(icon, C.gold, C.panelDark).Parent = holder
	end
	Components.label({
		text = text,
		font = Theme.Fonts.heading,
		textSize = Theme.Text.large,
		color = C.goldLight,
		size = UDim2.fromOffset(0, 34),
		autoSize = Enum.AutomaticSize.X,
		layoutOrder = 2,
		stroke = true,
		parent = row,
	})
	return row
end

-- A rounded card frame used by lists (mission cards, room cards, skin cards).
function Common.card(size: UDim2, color: Color3?, layoutOrder: number?): (TextButton, UIStroke)
	local card = Create.new("TextButton", {
		Name = "Card",
		Size = size,
		BackgroundColor3 = color or C.panelDark,
		BackgroundTransparency = 0.05,
		Text = "",
		AutoButtonColor = false,
		LayoutOrder = layoutOrder or 0,
		Selectable = true,
		ClipsDescendants = true,
	}, { Create.corner(Theme.Radius.medium) })
	local stroke = Create.stroke(C.shadow, 2.5, 0.2)
	stroke.Parent = card
	card.MouseEnter:Connect(function()
		if stroke.Color ~= C.gold then
			stroke.Transparency = 0
		end
	end)
	card.MouseLeave:Connect(function()
		if stroke.Color ~= C.gold then
			stroke.Transparency = 0.2
		end
	end)
	return card, stroke
end

-- Mark a card as the current choice (thick gold outline) or not.
function Common.setCardSelected(stroke: UIStroke, selected: boolean)
	stroke.Color = if selected then C.gold else C.shadow
	stroke.Thickness = if selected then 4 else 2.5
	stroke.Transparency = if selected then 0 else 0.2
end

-- 3D previews -------------------------------------------------------------------------------------------

export type Preview = {
	frame: ViewportFrame,
	show: (builder: (() -> Model?)?, view: "room" | "suitcase") -> (),
	destroy: () -> (),
}

-- A ViewportFrame that slowly orbits a room or suitcase model.
function Common.preview(parent: Instance, size: UDim2, position: UDim2?): Preview
	local viewport = Create.new("ViewportFrame", {
		Name = "Preview",
		Size = size,
		Position = position or UDim2.new(),
		BackgroundColor3 = C.ink,
		BackgroundTransparency = 0.2,
		Ambient = Color3.fromRGB(150, 140, 160),
		LightColor = Color3.fromRGB(255, 240, 220),
		LightDirection = Vector3.new(-0.4, -1, -0.6),
		Parent = parent,
	}, { Create.corner(Theme.Radius.medium), Create.stroke(C.goldDark, 2, 0.2) })
	local camera = Instance.new("Camera")
	camera.FieldOfView = 38
	camera.Parent = viewport
	viewport.CurrentCamera = camera

	local model: Model? = nil
	local focus = Vector3.zero
	local radius = 10
	local height = 0.35
	local angle = 0
	local swing = 0.6
	local connection: RBXScriptConnection? = nil

	local function place()
		local yaw = math.sin(angle) * swing
		local offset = CFrame.Angles(0, yaw, 0) * Vector3.new(0, radius * height, radius)
		camera.CFrame = CFrame.lookAt(focus + offset, focus)
	end

	local function stop()
		if connection then
			connection:Disconnect()
			connection = nil
		end
	end

	local preview: Preview
	preview = {
		frame = viewport,
		show = function(builder: (() -> Model?)?, view: "room" | "suitcase")
			if model then
				model:Destroy()
				model = nil
			end
			stop()
			if not builder then
				return
			end
			local ok, built = pcall(builder :: () -> Model?)
			if not ok or not built then
				return
			end
			local m = built :: Model
			-- Strip things a ViewportFrame cannot render anyway (lights, guis, effects).
			for _, d in m:GetDescendants() do
				if d:IsA("Light") or d:IsA("SurfaceGui") or d:IsA("ParticleEmitter") or d:IsA("Sound") then
					d:Destroy()
				end
			end
			m.Parent = viewport
			model = m
			local cf, extents = m:GetBoundingBox()
			if view == "room" then
				-- Rooms are open toward the corridor (+Z of the room frame): look in through the doorway.
				focus = cf.Position + Vector3.new(0, -extents.Y * 0.08, 0)
				radius = math.max(extents.X, extents.Z) * 1.55
				height = 0.42
				swing = 0.5
			else
				focus = cf.Position
				radius = extents.Magnitude * 1.25
				height = 0.18
				swing = 1.1
			end
			angle = 0
			place()
			connection = RunService.RenderStepped:Connect(function(dt: number)
				if not viewport.Visible or not viewport:IsDescendantOf(game) then
					return
				end
				angle += dt * 0.55
				place()
			end)
		end,
		destroy = function()
			stop()
			if model then
				model:Destroy()
				model = nil
			end
			viewport:Destroy()
		end,
	}
	return preview
end

return Common
