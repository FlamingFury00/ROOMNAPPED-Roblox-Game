--!strict
--[[
	Components: the reusable interface kit (A07).

	Every interactive element has distinguishable default / hover / pressed / disabled / selected states,
	large touch targets, an icon + label pair where it carries meaning, and a click sound.
]]

local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Strings = require(ReplicatedStorage.Shared.Config.Strings)
local Theme = require(script.Parent.Theme)
local Create = require(script.Parent.Create)
local Icons = require(script.Parent.Icons)
local Motion = require(script.Parent.Motion)

local Components = {}

local C = Theme.Colors

-- Optional sound hook (set by the audio controller) so components stay decoupled from audio.
local soundHook: ((string) -> ())? = nil
function Components.setSoundHook(hook: (string) -> ())
	soundHook = hook
end
local function sound(name: string)
	if soundHook then
		(soundHook :: (string) -> ())(name)
	end
end
Components.sound = sound

-- Labels ------------------------------------------------------------------------------------------------

export type LabelProps = {
	text: string,
	size: UDim2?,
	position: UDim2?,
	anchor: Vector2?,
	font: Font?,
	textSize: number?,
	color: Color3?,
	align: Enum.TextXAlignment?,
	yAlign: Enum.TextYAlignment?,
	wrap: boolean?,
	stroke: boolean?,
	strokeColor: Color3?,
	scaled: boolean?,
	parent: Instance?,
	layoutOrder: number?,
	autoSize: Enum.AutomaticSize?,
	name: string?,
	rich: boolean?,
	transparency: number?,
}

function Components.label(props: LabelProps): TextLabel
	local label = Create.new("TextLabel", {
		Name = props.name or "Label",
		BackgroundTransparency = 1,
		Size = props.size or UDim2.new(1, 0, 0, (props.textSize or Theme.Text.body) + 6),
		Position = props.position or UDim2.new(),
		AnchorPoint = props.anchor or Vector2.zero,
		Text = props.text,
		RichText = props.rich == true,
		FontFace = props.font or Theme.Fonts.body,
		TextSize = props.textSize or Theme.Text.body,
		TextColor3 = props.color or C.text,
		TextTransparency = props.transparency or 0,
		TextXAlignment = props.align or Enum.TextXAlignment.Left,
		TextYAlignment = props.yAlign or Enum.TextYAlignment.Center,
		TextWrapped = props.wrap == true,
		TextScaled = props.scaled == true,
		LayoutOrder = props.layoutOrder or 0,
		AutomaticSize = props.autoSize or Enum.AutomaticSize.None,
	})
	if props.stroke then
		Create.textStroke(props.strokeColor or C.shadow, 2, 0.15).Parent = label
	end
	if props.scaled then
		Create.textLimit(8, props.textSize or Theme.Text.title).Parent = label
	end
	if props.parent then
		label.Parent = props.parent
	end
	return label
end

-- Panels -----------------------------------------------------------------------------------------------

export type PanelProps = {
	size: UDim2,
	position: UDim2?,
	anchor: Vector2?,
	title: string?,
	titleIcon: string?,
	variant: ("dark" | "glass" | "gold" | "light")?,
	padding: number?,
	parent: Instance?,
	name: string?,
	layoutOrder: number?,
	clip: boolean?,
}

function Components.panel(props: PanelProps): (Frame, Frame)
	local variant = props.variant or "dark"
	local top, bottom, strokeColor = C.panelLight, C.panel, C.gold
	local transparency = 0.04
	if variant == "glass" then
		top, bottom, strokeColor = C.panel, C.panelDark, C.goldDark
		transparency = 0.18
	elseif variant == "gold" then
		top, bottom, strokeColor = C.goldLight, C.gold, C.goldDark
	elseif variant == "light" then
		top, bottom, strokeColor = C.cream, C.goldLight, C.goldDark
	end
	local frame = Create.new("Frame", {
		Name = props.name or "Panel",
		Size = props.size,
		Position = props.position or UDim2.new(),
		AnchorPoint = props.anchor or Vector2.zero,
		BackgroundColor3 = C.white,
		BackgroundTransparency = transparency,
		BorderSizePixel = 0,
		LayoutOrder = props.layoutOrder or 0,
		ClipsDescendants = props.clip == true,
	}, {
		Create.corner(Theme.Radius.large),
		Create.gradient(top, bottom, 90),
		Create.stroke(strokeColor, 3, 0),
	})
	-- Inner highlight line for a little depth.
	Create.new("Frame", {
		Name = "Highlight",
		BackgroundColor3 = C.white,
		BackgroundTransparency = 0.88,
		BorderSizePixel = 0,
		Size = UDim2.new(1, -24, 0, 2),
		Position = UDim2.new(0.5, 0, 0, 6),
		AnchorPoint = Vector2.new(0.5, 0),
		Parent = frame,
	})
	local pad = props.padding or Theme.Spacing.large
	local content = Create.new("Frame", {
		Name = "Content",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -pad * 2, 1, -pad * 2 - (if props.title then 30 else 0)),
		Position = UDim2.fromOffset(pad, pad + (if props.title then 30 else 0)),
		Parent = frame,
	})
	if props.title then
		local ribbon = Create.new("Frame", {
			Name = "TitleRibbon",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, 0, 0, 2),
			Size = UDim2.fromOffset(0, 46),
			AutomaticSize = Enum.AutomaticSize.X,
			BackgroundColor3 = C.white,
			BorderSizePixel = 0,
			ZIndex = 3,
			Parent = frame,
		}, {
			Create.corner(Theme.Radius.pill),
			Create.gradient(C.goldLight, C.gold, 90),
			Create.stroke(C.goldDark, 3, 0),
			Create.padding(4, 22),
			Create.list(
				Enum.FillDirection.Horizontal,
				8,
				Enum.HorizontalAlignment.Center,
				Enum.VerticalAlignment.Center
			),
		})
		if props.titleIcon then
			local holder = Create.new("Frame", {
				Name = "IconHolder",
				BackgroundTransparency = 1,
				Size = UDim2.fromOffset(28, 28),
				LayoutOrder = 1,
				ZIndex = 3,
				Parent = ribbon,
			})
			Icons.make(props.titleIcon :: string, C.textDark, C.goldLight).Parent = holder
		end
		Components.label({
			text = props.title :: string,
			font = Theme.Fonts.heading,
			textSize = Theme.Text.large,
			color = C.textDark,
			size = UDim2.fromOffset(0, 36),
			autoSize = Enum.AutomaticSize.X,
			align = Enum.TextXAlignment.Center,
			layoutOrder = 2,
			parent = ribbon,
			name = "Title",
		}).ZIndex =
			3
	end
	if props.parent then
		frame.Parent = props.parent
	end
	return frame, content
end

-- Buttons ----------------------------------------------------------------------------------------------

export type ButtonVariant = "primary" | "secondary" | "danger" | "success" | "ghost" | "blue"

local VARIANTS: { [string]: { face: Color3, faceTop: Color3, base: Color3, text: Color3, stroke: Color3 } } = {
	primary = { face = C.gold, faceTop = C.goldLight, base = C.goldDark, text = C.textDark, stroke = C.textDark },
	secondary = {
		face = C.panelLight,
		faceTop = Color3.fromRGB(110, 72, 120),
		base = C.panelDark,
		text = C.text,
		stroke = C.shadow,
	},
	danger = {
		face = C.red,
		faceTop = Color3.fromRGB(255, 120, 128),
		base = C.redDark,
		text = C.white,
		stroke = C.shadow,
	},
	success = {
		face = C.green,
		faceTop = Color3.fromRGB(160, 245, 170),
		base = C.greenDark,
		text = C.textDark,
		stroke = C.textDark,
	},
	blue = {
		face = C.blue,
		faceTop = Color3.fromRGB(170, 215, 255),
		base = Color3.fromRGB(40, 100, 190),
		text = C.white,
		stroke = C.shadow,
	},
	ghost = { face = C.panelDark, faceTop = C.panel, base = C.ink, text = C.textDim, stroke = C.shadow },
}

export type ButtonProps = {
	text: string?,
	icon: string?,
	iconColor: Color3?,
	variant: ButtonVariant?,
	size: UDim2,
	position: UDim2?,
	anchor: Vector2?,
	textSize: number?,
	layoutOrder: number?,
	parent: Instance?,
	name: string?,
	onClick: (() -> ())?,
	sound: string?,
	keyHint: string?,
}

export type ButtonHandle = {
	instance: TextButton,
	setText: (string) -> (),
	setEnabled: (boolean) -> (),
	setVariant: (ButtonVariant) -> (),
	setSelected: (boolean) -> (),
	setKeyHint: (string?) -> (),
	label: TextLabel,
	enabled: boolean,
}

function Components.button(props: ButtonProps): ButtonHandle
	local variantName: ButtonVariant = props.variant or "primary"
	local depth = 5
	local root = Create.new("TextButton", {
		Name = props.name or "Button",
		Size = props.size,
		Position = props.position or UDim2.new(),
		AnchorPoint = props.anchor or Vector2.zero,
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		LayoutOrder = props.layoutOrder or 0,
		Selectable = true,
	})
	local base = Create.new("Frame", {
		Name = "Base",
		Size = UDim2.fromScale(1, 1),
		BorderSizePixel = 0,
		Parent = root,
	}, { Create.corner(Theme.Radius.medium) })
	local face = Create.new("Frame", {
		Name = "Face",
		Size = UDim2.new(1, 0, 1, -depth),
		Position = UDim2.fromOffset(0, 0),
		BorderSizePixel = 0,
		BackgroundColor3 = C.white,
		Parent = root,
	}, { Create.corner(Theme.Radius.medium) })
	local gradient = Create.gradient(C.white, C.white, 90)
	gradient.Parent = face
	local stroke = Create.stroke(C.shadow, 2.5, 0.25)
	stroke.Parent = base
	Create.new("Frame", {
		Name = "Shine",
		BackgroundColor3 = C.white,
		BackgroundTransparency = 0.82,
		BorderSizePixel = 0,
		Size = UDim2.new(1, -16, 0.38, 0),
		Position = UDim2.new(0.5, 0, 0, 5),
		AnchorPoint = Vector2.new(0.5, 0),
		Parent = face,
	}, { Create.corner(Theme.Radius.small) })
	local row = Create.new("Frame", {
		Name = "Row",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = face,
	}, {
		Create.list(Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center),
		Create.padding(4, 12),
	})
	local iconHolder: Frame? = nil
	if props.icon then
		iconHolder = Create.new("Frame", {
			Name = "IconHolder",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(0, 0.62),
			LayoutOrder = 1,
			Parent = row,
		}, { Create.aspect(1, Enum.DominantAxis.Height) })
		Icons.make(props.icon :: string, props.iconColor or C.white, C.panelDark).Parent = iconHolder
	end
	local label = Components.label({
		name = "Text",
		text = props.text or "",
		font = Theme.Fonts.heading,
		textSize = props.textSize or Theme.Text.large,
		color = C.text,
		size = UDim2.fromScale(0, 1),
		autoSize = Enum.AutomaticSize.X,
		align = Enum.TextXAlignment.Center,
		layoutOrder = 2,
		parent = row,
	})
	label.Visible = (props.text or "") ~= ""
	local textStroke = Create.textStroke(C.shadow, 2, 0.6)
	textStroke.Parent = label
	local keyBadge = Create.new("TextLabel", {
		Name = "KeyHint",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 4, 0, -6),
		Size = UDim2.fromOffset(26, 26),
		BackgroundColor3 = C.ink,
		Text = props.keyHint or "",
		TextColor3 = C.goldLight,
		FontFace = Theme.Fonts.mono,
		TextSize = 15,
		Visible = props.keyHint ~= nil,
		ZIndex = 5,
		Parent = root,
	}, { Create.corner(Theme.Radius.small), Create.stroke(C.gold, 1.5, 0) })

	local handle: ButtonHandle
	local hovering = false
	local pressed = false
	local selected = false

	local function paint()
		local v = VARIANTS[variantName] or VARIANTS.primary
		local enabled = handle.enabled
		local faceColor = if enabled then v.face else C.panelDark
		local topColor = if enabled then v.faceTop else C.panel
		if hovering and enabled then
			faceColor = faceColor:Lerp(C.white, 0.1)
			topColor = topColor:Lerp(C.white, 0.1)
		end
		gradient.Color = ColorSequence.new(topColor, faceColor)
		base.BackgroundColor3 = if enabled then v.base else C.ink
		label.TextColor3 = if enabled then v.text else C.textMuted
		textStroke.Color = v.stroke
		textStroke.Transparency = if v.text == C.textDark then 1 else 0.55
		stroke.Color = if selected then C.white else C.shadow
		stroke.Thickness = if selected then 3.5 else 2.5
		stroke.Transparency = if selected then 0 else 0.25
		face.Position = UDim2.fromOffset(0, if pressed and enabled then depth - 1 else 0)
		if iconHolder then
			Icons.tint(iconHolder, if enabled then (props.iconColor or v.text) else C.textMuted)
		end
	end

	handle = {
		instance = root,
		label = label,
		enabled = true,
		setText = function(text: string)
			label.Text = text
			label.Visible = text ~= ""
		end,
		setEnabled = function(value: boolean)
			-- Stay Active: a disabled button still answers a tap with the error sound and a shake.
			handle.enabled = value
			paint()
		end,
		setVariant = function(value: ButtonVariant)
			variantName = value
			paint()
		end,
		setSelected = function(value: boolean)
			selected = value
			paint()
		end,
		setKeyHint = function(text: string?)
			keyBadge.Text = text or ""
			keyBadge.Visible = text ~= nil and text ~= ""
		end,
	}

	root.MouseEnter:Connect(function()
		hovering = true
		paint()
		if handle.enabled then
			sound("ui_hover")
		end
	end)
	root.MouseLeave:Connect(function()
		hovering = false
		pressed = false
		paint()
	end)
	root.InputBegan:Connect(function(input: InputObject)
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			pressed = true
			paint()
		end
	end)
	root.InputEnded:Connect(function(input: InputObject)
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			pressed = false
			paint()
		end
	end)
	root.Activated:Connect(function()
		if not handle.enabled then
			sound("ui_error")
			Motion.shake(root)
			return
		end
		sound(props.sound or "ui_click")
		if props.onClick then
			(props.onClick :: () -> ())()
		end
	end)
	paint()
	if props.parent then
		root.Parent = props.parent
	end
	return handle
end

-- Small round icon button (close, settings, ping...).
function Components.iconButton(icon: string, size: number, onClick: () -> (), variant: ButtonVariant?): ButtonHandle
	local handle = Components.button({
		icon = icon,
		variant = variant or "secondary",
		size = UDim2.fromOffset(size, size),
		onClick = onClick,
		name = "IconButton_" .. icon,
	})
	local holder = handle.instance:FindFirstChild("IconHolder", true)
	if holder and holder:IsA("Frame") then
		holder.Size = UDim2.fromScale(0, 0.66)
	end
	return handle
end

-- Bars, toggles & sliders --------------------------------------------------------------------------------

export type BarHandle = { frame: Frame, set: (number) -> (), setColor: (Color3) -> () }

function Components.bar(size: UDim2, color: Color3, parent: Instance?): BarHandle
	local frame = Create.new("Frame", {
		Name = "Bar",
		Size = size,
		BackgroundColor3 = C.ink,
		BackgroundTransparency = 0.2,
		BorderSizePixel = 0,
	}, { Create.corner(Theme.Radius.pill), Create.stroke(C.shadow, 2, 0.3) })
	local fill = Create.new("Frame", {
		Name = "Fill",
		Size = UDim2.fromScale(0, 1),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Parent = frame,
	}, { Create.corner(Theme.Radius.pill), Create.gradient(color:Lerp(C.white, 0.25), color, 90) })
	if parent then
		frame.Parent = parent
	end
	return {
		frame = frame,
		set = function(value: number)
			fill.Size = UDim2.fromScale(math.clamp(value, 0, 1), 1)
			fill.Visible = value > 0.001
		end,
		setColor = function(c: Color3)
			fill.BackgroundColor3 = c
			local gradient = fill:FindFirstChildOfClass("UIGradient")
			if gradient then
				gradient.Color = ColorSequence.new(c:Lerp(C.white, 0.25), c)
			end
		end,
	}
end

export type HoldHandle = { frame: Frame, set: (number) -> (), setColor: (Color3) -> () }

-- Filling circle used for hold interactions (capture / revive). Readable without colour: it grows.
function Components.holdCircle(parent: Instance?, color: Color3?): HoldHandle
	local frame = Create.new("Frame", {
		Name = "HoldCircle",
		BackgroundColor3 = C.ink,
		BackgroundTransparency = 0.35,
		Size = UDim2.fromScale(1, 1),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
	}, { Create.corner(Theme.Radius.pill), Create.stroke(C.white, 3, 0.1), Create.aspect(1) })
	local fill = Create.new("Frame", {
		Name = "Fill",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0, 0),
		BackgroundColor3 = color or C.gold,
		BorderSizePixel = 0,
		Parent = frame,
	}, { Create.corner(Theme.Radius.pill) })
	if parent then
		frame.Parent = parent
	end
	return {
		frame = frame,
		set = function(progress: number)
			local p = math.clamp(progress, 0, 1)
			fill.Size = UDim2.fromScale(p, p)
		end,
		setColor = function(c: Color3)
			fill.BackgroundColor3 = c
		end,
	}
end

export type ToggleHandle = { frame: Frame, set: (boolean) -> (), get: () -> boolean }

-- Highlight shown while a gamepad has an element selected (rows use it instead of the default box).
local function selectionHighlight(target: GuiObject, stroke: UIStroke, normalColor: Color3, normalThickness: number)
	target.SelectionGained:Connect(function()
		stroke.Color = C.gold
		stroke.Thickness = normalThickness + 1.5
		stroke.Transparency = 0
	end)
	target.SelectionLost:Connect(function()
		stroke.Color = normalColor
		stroke.Thickness = normalThickness
		stroke.Transparency = 0.2
	end)
end

-- A labelled on/off switch. The whole row is the touch / click / gamepad target.
function Components.toggle(text: string, value: boolean, onChange: (boolean) -> (), layoutOrder: number?): ToggleHandle
	local state = value
	local frame = Create.new("Frame", {
		Name = "Toggle",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 72),
		LayoutOrder = layoutOrder or 0,
	})
	local hit = Create.new("TextButton", {
		Name = "Hit",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = C.panelDark,
		BackgroundTransparency = 0.55,
		Text = "",
		AutoButtonColor = false,
		Selectable = true,
		SelectionImageObject = Create.new("Frame", { BackgroundTransparency = 1 }),
		Parent = frame,
	}, { Create.corner(Theme.Radius.medium) })
	local rowStroke = Create.stroke(C.shadow, 1.5, 0.2)
	rowStroke.Parent = hit
	selectionHighlight(hit, rowStroke, C.shadow, 1.5)
	Components.label({
		text = text,
		size = UDim2.new(1, -150, 1, 0),
		position = UDim2.fromOffset(16, 0),
		font = Theme.Fonts.bodyBold,
		textSize = Theme.Text.body,
		parent = hit,
	})
	local track = Create.new("Frame", {
		Name = "Track",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -12, 0.5, 0),
		Size = UDim2.fromOffset(104, 44),
		BackgroundColor3 = C.panelDark,
		Parent = hit,
	}, { Create.corner(Theme.Radius.pill), Create.stroke(C.shadow, 2, 0.2) })
	local knob = Create.new("Frame", {
		Name = "Knob",
		AnchorPoint = Vector2.new(0, 0.5),
		Size = UDim2.fromOffset(36, 36),
		BackgroundColor3 = C.cream,
		ZIndex = 2,
		Parent = track,
	}, { Create.corner(Theme.Radius.pill) })
	local stateLabel = Components.label({
		text = "",
		font = Theme.Fonts.heading,
		textSize = 16,
		size = UDim2.new(0, 52, 1, 0),
		align = Enum.TextXAlignment.Center,
		parent = track,
	})
	local onText = string.upper(Strings.t("settings.on"))
	local offText = string.upper(Strings.t("settings.off"))
	local function knobPosition(): UDim2
		return if state then UDim2.new(1, -40, 0.5, 0) else UDim2.new(0, 4, 0.5, 0)
	end
	local function paint()
		track.BackgroundColor3 = if state then C.green else C.ink
		Motion.tween(knob, Theme.Tween.fast, { Position = knobPosition() })
		stateLabel.Position = if state then UDim2.fromOffset(6, 0) else UDim2.new(1, -58, 0, 0)
		stateLabel.Text = if state then onText else offText
		stateLabel.TextColor3 = if state then C.textDark else C.textDim
	end
	hit.Activated:Connect(function()
		state = not state
		sound("ui_toggle")
		paint()
		onChange(state)
	end)
	knob.Position = knobPosition()
	paint()
	return {
		frame = frame,
		set = function(v: boolean)
			state = v
			paint()
		end,
		get = function(): boolean
			return state
		end,
	}
end

export type SliderHandle = { frame: Frame, set: (number) -> () }

-- A labelled slider snapping to 5% steps. Drag or tap anywhere on the bar; with a gamepad, select the row
-- and use left / right (D-pad, stick or arrow keys) to adjust.
function Components.slider(
	text: string,
	value: number,
	onChange: (number) -> (),
	layoutOrder: number?,
	minValue: number?,
	maxValue: number?
): SliderHandle
	local lo, hi = minValue or 0, maxValue or 1
	local stepSize = (hi - lo) / 20
	local current = math.clamp(value, lo, hi)
	local frame = Create.new("Frame", {
		Name = "Slider",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 72),
		LayoutOrder = layoutOrder or 0,
	})
	local hit = Create.new("TextButton", {
		Name = "Hit",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = C.panelDark,
		BackgroundTransparency = 0.55,
		Text = "",
		AutoButtonColor = false,
		Selectable = true,
		SelectionImageObject = Create.new("Frame", { BackgroundTransparency = 1 }),
		Parent = frame,
	}, { Create.corner(Theme.Radius.medium) })
	-- Left / right adjust the value instead of moving the gamepad selection away.
	hit.NextSelectionLeft = hit
	hit.NextSelectionRight = hit
	local rowStroke = Create.stroke(C.shadow, 1.5, 0.2)
	rowStroke.Parent = hit
	selectionHighlight(hit, rowStroke, C.shadow, 1.5)
	Components.label({
		text = text,
		size = UDim2.new(0.36, -16, 1, 0),
		position = UDim2.fromOffset(16, 0),
		font = Theme.Fonts.bodyBold,
		parent = hit,
	})
	local valueLabel = Components.label({
		text = "",
		size = UDim2.new(0, 64, 1, 0),
		position = UDim2.new(1, -14, 0, 0),
		anchor = Vector2.new(1, 0),
		align = Enum.TextXAlignment.Right,
		font = Theme.Fonts.heading,
		color = C.goldLight,
		parent = hit,
	})
	local bar = Create.new("Frame", {
		Name = "Track",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.fromScale(0.38, 0.5),
		Size = UDim2.new(0.62, -96, 0, 14),
		BackgroundColor3 = C.ink,
		Parent = hit,
	}, { Create.corner(Theme.Radius.pill), Create.stroke(C.shadow, 2, 0.3) })
	local fill = Create.new("Frame", {
		Name = "Fill",
		Size = UDim2.fromScale(0, 1),
		BackgroundColor3 = C.gold,
		BorderSizePixel = 0,
		Parent = bar,
	}, { Create.corner(Theme.Radius.pill) })
	local knob = Create.new("Frame", {
		Name = "Knob",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(32, 32),
		Position = UDim2.fromScale(0, 0.5),
		BackgroundColor3 = C.cream,
		ZIndex = 2,
		Parent = bar,
	}, { Create.corner(Theme.Radius.pill), Create.stroke(C.goldDark, 3, 0) })
	local function render()
		local t = (current - lo) / math.max(1e-6, hi - lo)
		fill.Size = UDim2.fromScale(t, 1)
		knob.Position = UDim2.fromScale(t, 0.5)
		if hi <= 1 then
			valueLabel.Text = tostring(math.floor(current * 100 + 0.5)) .. "%"
		else
			valueLabel.Text = string.format("%.2fx", current)
		end
	end
	local function commit(nextValue: number)
		local snapped = math.clamp(lo + math.floor((nextValue - lo) / stepSize + 0.5) * stepSize, lo, hi)
		if math.abs(snapped - current) > 1e-6 then
			current = snapped
			render()
			onChange(current)
		end
	end
	local dragging = false
	local nextNudge = 0
	local function setFromX(x: number)
		local abs = bar.AbsolutePosition.X
		local width = math.max(1, bar.AbsoluteSize.X)
		local t = math.clamp((x - abs) / width, 0, 1)
		commit(lo + (hi - lo) * t)
	end
	hit.InputBegan:Connect(function(input: InputObject)
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			dragging = true
			setFromX(input.Position.X)
		end
	end)
	-- Global listeners (drag continues outside the bar); disconnected when the slider is destroyed.
	local connections: { RBXScriptConnection } = {}
	table.insert(
		connections,
		UserInputService.InputChanged:Connect(function(input: InputObject)
			if
				dragging
				and (
					input.UserInputType == Enum.UserInputType.MouseMovement
					or input.UserInputType == Enum.UserInputType.Touch
				)
			then
				setFromX(input.Position.X)
			elseif input.KeyCode == Enum.KeyCode.Thumbstick1 and GuiService.SelectedObject == hit then
				-- Stick nudges with a short repeat delay.
				local x = input.Position.X
				local now = os.clock()
				if math.abs(x) > 0.7 and now >= nextNudge then
					nextNudge = now + 0.16
					commit(current + math.sign(x) * stepSize)
				end
			end
		end)
	)
	table.insert(
		connections,
		UserInputService.InputEnded:Connect(function(input: InputObject)
			if
				input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch
			then
				if dragging then
					dragging = false
					sound("ui_toggle")
				end
			end
		end)
	)
	table.insert(
		connections,
		UserInputService.InputBegan:Connect(function(input: InputObject)
			if GuiService.SelectedObject ~= hit then
				return
			end
			local key = input.KeyCode
			if key == Enum.KeyCode.DPadLeft or key == Enum.KeyCode.Left then
				commit(current - stepSize)
				sound("ui_toggle")
			elseif key == Enum.KeyCode.DPadRight or key == Enum.KeyCode.Right then
				commit(current + stepSize)
				sound("ui_toggle")
			end
		end)
	)
	frame.Destroying:Connect(function()
		for _, connection in connections do
			connection:Disconnect()
		end
		table.clear(connections)
	end)
	render()
	return {
		frame = frame,
		set = function(v: number)
			current = math.clamp(v, lo, hi)
			render()
		end,
	}
end

export type BadgeHandle = { frame: Frame, set: (number) -> () }

-- Notification badge on a button's top-right corner: a count (9+ beyond nine) that pops when it rises and
-- hides at zero.
function Components.badge(parent: GuiObject): BadgeHandle
	local frame = Create.new("Frame", {
		Name = "Badge",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(1, -8, 0, 8),
		Size = UDim2.fromOffset(30, 30),
		BackgroundColor3 = C.red,
		Visible = false,
		Parent = parent,
	}, { Create.corner(Theme.Radius.pill), Create.stroke(C.white, 2, 0) })
	local label = Components.label({
		name = "Count",
		text = "",
		font = Theme.Fonts.heading,
		textSize = Theme.Text.small,
		align = Enum.TextXAlignment.Center,
		size = UDim2.fromScale(1, 1),
		parent = frame,
	})
	local shown = 0
	return {
		frame = frame,
		set = function(count: number)
			label.Text = if count > 9 then "9+" else tostring(count)
			frame.Visible = count > 0
			if count > shown then
				Motion.pop(frame, 0.5)
			end
			shown = count
		end,
	}
end

-- Small pill badge with icon + text (status chips, prices, hazards).
function Components.chip(icon: string?, text: string, color: Color3, layoutOrder: number?, textColor: Color3?): Frame
	local chip = Create.new("Frame", {
		Name = "Chip",
		Size = UDim2.fromOffset(0, 34),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = color,
		BackgroundTransparency = 0.05,
		LayoutOrder = layoutOrder or 0,
	}, {
		Create.corner(Theme.Radius.pill),
		Create.stroke(C.shadow, 2, 0.4),
		Create.padding(4, 12),
		Create.list(Enum.FillDirection.Horizontal, 6, Enum.HorizontalAlignment.Center, Enum.VerticalAlignment.Center),
	})
	if icon then
		local holder = Create.new(
			"Frame",
			{ BackgroundTransparency = 1, Size = UDim2.fromOffset(22, 22), LayoutOrder = 1, Parent = chip }
		)
		Icons.make(icon, textColor or C.white, color:Lerp(C.black, 0.4)).Parent = holder
	end
	Components.label({
		text = text,
		font = Theme.Fonts.bodyBold,
		textSize = Theme.Text.small,
		color = textColor or C.white,
		size = UDim2.fromOffset(0, 26),
		autoSize = Enum.AutomaticSize.X,
		layoutOrder = 2,
		parent = chip,
	})
	return chip
end

-- Full-width notice block for fixed-width panels: like a chip, but long text wraps instead of overflowing.
function Components.notice(icon: string, text: string, color: Color3, layoutOrder: number?, textColor: Color3?): Frame
	local notice = Create.new("Frame", {
		Name = "Notice",
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = color,
		BackgroundTransparency = 0.05,
		LayoutOrder = layoutOrder or 0,
	}, {
		Create.corner(Theme.Radius.medium),
		Create.stroke(C.shadow, 2, 0.4),
		Create.padding(6, 10),
		Create.list(Enum.FillDirection.Horizontal, 8, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Center),
	})
	local holder = Create.new(
		"Frame",
		{ BackgroundTransparency = 1, Size = UDim2.fromOffset(22, 22), LayoutOrder = 1, Parent = notice }
	)
	Icons.make(icon, textColor or C.white, color:Lerp(C.black, 0.4)).Parent = holder
	Components.label({
		text = text,
		font = Theme.Fonts.bodyBold,
		textSize = Theme.Text.small,
		color = textColor or C.white,
		size = UDim2.new(1, -30, 0, 0),
		autoSize = Enum.AutomaticSize.Y,
		wrap = true,
		layoutOrder = 2,
		parent = notice,
	})
	return notice
end

-- Modal backdrop that dims the world behind a screen (click to close optional).
function Components.backdrop(parent: Instance, onClick: (() -> ())?): TextButton
	local backdrop = Create.new("TextButton", {
		Name = "Backdrop",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = C.ink,
		BackgroundTransparency = 0.35,
		Text = "",
		AutoButtonColor = false,
		Parent = parent,
	})
	if onClick then
		backdrop.Activated:Connect(onClick)
	end
	return backdrop
end

return Components
