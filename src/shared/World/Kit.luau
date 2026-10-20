--!strict
--[[
	Kit: low-level part factory used by every procedural builder.

	Defaults are chosen for performance (S27): everything is anchored, decoration never collides, never
	fires touch events and is invisible to raycasts, and only large structural pieces cast shadows.
	Properties are assigned before parenting, which is markedly cheaper for big builds.
]]

local Kit = {}

export type PartProps = {
	name: string?,
	size: Vector3,
	cf: CFrame,
	color: Color3?,
	material: Enum.Material?,
	transparency: number?,
	reflectance: number?,
	solid: boolean?, -- collides and is raycast-visible (structure)
	query: boolean?, -- raycast-visible even when not solid
	shadow: boolean?,
	tag: string?,
	attrs: { [string]: any }?,
	physics: PhysicalProperties?,
}

local function apply(part: BasePart, props: PartProps, parent: Instance?)
	part.Name = props.name or part.Name
	part.Anchored = true
	part.Size = props.size
	part.CFrame = props.cf
	part.Color = props.color or Color3.fromRGB(200, 200, 200)
	part.Material = props.material or Enum.Material.SmoothPlastic
	part.Transparency = props.transparency or 0
	part.Reflectance = props.reflectance or 0
	local solid = props.solid == true
	part.CanCollide = solid
	part.CanTouch = false
	part.CanQuery = solid or props.query == true
	part.CastShadow = if props.shadow ~= nil then props.shadow else solid
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	if props.physics then
		part.CustomPhysicalProperties = props.physics
	end
	if props.tag then
		part:AddTag(props.tag)
	end
	if props.attrs then
		for key, value in props.attrs do
			part:SetAttribute(key, value)
		end
	end
	if parent then
		part.Parent = parent
	end
end

function Kit.part(parent: Instance?, props: PartProps): Part
	local part = Instance.new("Part")
	apply(part, props, parent)
	return part
end

function Kit.wedge(parent: Instance?, props: PartProps): WedgePart
	local part = Instance.new("WedgePart")
	apply(part, props, parent)
	return part
end

function Kit.cornerWedge(parent: Instance?, props: PartProps): CornerWedgePart
	local part = Instance.new("CornerWedgePart")
	apply(part, props, parent)
	return part
end

-- Cylinder whose axis is the part's local X axis (Roblox convention).
function Kit.cylinder(parent: Instance?, props: PartProps): Part
	local part = Instance.new("Part")
	part.Shape = Enum.PartType.Cylinder
	apply(part, props, parent)
	return part
end

export type PostProps = {
	name: string?,
	cf: CFrame,
	height: number,
	diameter: number,
	color: Color3?,
	material: Enum.Material?,
	solid: boolean?,
	shadow: boolean?,
	transparency: number?,
}

-- Upright cylinder centred at `cf`, with `height` along the frame's Y axis and `diameter` across.
function Kit.post(parent: Instance?, props: PostProps): Part
	return Kit.cylinder(parent, {
		name = props.name,
		size = Vector3.new(props.height, props.diameter, props.diameter),
		cf = props.cf * CFrame.Angles(0, 0, math.pi / 2),
		color = props.color,
		material = props.material,
		solid = props.solid,
		shadow = props.shadow,
		transparency = props.transparency,
	})
end

function Kit.ball(parent: Instance?, props: PartProps): Part
	local part = Instance.new("Part")
	part.Shape = Enum.PartType.Ball
	apply(part, props, parent)
	return part
end

function Kit.model(parent: Instance?, name: string): Model
	local model = Instance.new("Model")
	model.Name = name
	if parent then
		model.Parent = parent
	end
	return model
end

function Kit.folder(parent: Instance?, name: string): Folder
	local folder = Instance.new("Folder")
	folder.Name = name
	if parent then
		folder.Parent = parent
	end
	return folder
end

function Kit.pointLight(
	parent: Instance,
	color: Color3,
	brightness: number,
	range: number,
	shadows: boolean?
): PointLight
	local light = Instance.new("PointLight")
	light.Color = color
	light.Brightness = brightness
	light.Range = range
	light.Shadows = shadows == true
	light.Parent = parent
	return light
end

function Kit.spotLight(
	parent: Instance,
	color: Color3,
	brightness: number,
	range: number,
	angle: number,
	face: Enum.NormalId,
	shadows: boolean?
): SpotLight
	local light = Instance.new("SpotLight")
	light.Color = color
	light.Brightness = brightness
	light.Range = range
	light.Angle = angle
	light.Face = face
	light.Shadows = shadows == true
	light.Parent = parent
	return light
end

function Kit.surfaceLight(
	parent: Instance,
	color: Color3,
	brightness: number,
	range: number,
	angle: number,
	face: Enum.NormalId
): SurfaceLight
	local light = Instance.new("SurfaceLight")
	light.Color = color
	light.Brightness = brightness
	light.Range = range
	light.Angle = angle
	light.Face = face
	light.Shadows = false
	light.Parent = parent
	return light
end

export type TextProps = {
	face: Enum.NormalId,
	text: string,
	color: Color3?,
	font: Font?,
	pixelsPerStud: number?,
	strokeColor: Color3?,
	strokeTransparency: number?,
	background: Color3?,
	backgroundTransparency: number?,
	scaled: boolean?,
	textSize: number?,
	lightInfluence: number?,
	brightness: number?,
	align: Enum.TextXAlignment?,
}

-- Text printed on a part face (room numbers, signage). Text is never baked into images (S30).
function Kit.surfaceText(part: BasePart, props: TextProps): (SurfaceGui, TextLabel)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "Sign"
	gui.Face = props.face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = props.pixelsPerStud or 40
	gui.LightInfluence = props.lightInfluence or 0.6
	gui.Brightness = props.brightness or 1
	gui.MaxDistance = 140
	gui.ResetOnSpawn = false
	gui.ClipsDescendants = true
	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundColor3 = props.background or Color3.new(0, 0, 0)
	label.BackgroundTransparency = props.backgroundTransparency or 1
	label.BorderSizePixel = 0
	label.Text = props.text
	label.TextColor3 = props.color or Color3.new(1, 1, 1)
	label.FontFace = props.font or Font.new("rbxasset://fonts/families/Fondamento.json", Enum.FontWeight.Bold)
	label.TextScaled = props.scaled ~= false
	if props.textSize then
		label.TextSize = props.textSize
	end
	label.TextXAlignment = props.align or Enum.TextXAlignment.Center
	label.TextStrokeColor3 = props.strokeColor or Color3.new(0, 0, 0)
	label.TextStrokeTransparency = props.strokeTransparency or 1
	label.Parent = gui
	gui.Parent = part
	return gui, label
end

function Kit.attachment(parent: BasePart, localCF: CFrame?, name: string?): Attachment
	local attachment = Instance.new("Attachment")
	attachment.Name = name or "Attachment"
	attachment.CFrame = localCF or CFrame.new()
	attachment.Parent = parent
	return attachment
end

-- Convenience: a decorative part (no collision, no queries) in tile/room space.
function Kit.decor(
	parent: Instance,
	name: string,
	cf: CFrame,
	size: Vector3,
	color: Color3,
	material: Enum.Material?
): Part
	return Kit.part(parent, {
		name = name,
		cf = cf,
		size = size,
		color = color,
		material = material or Enum.Material.SmoothPlastic,
	})
end

-- Convenience: a solid structural part.
function Kit.solid(
	parent: Instance,
	name: string,
	cf: CFrame,
	size: Vector3,
	color: Color3,
	material: Enum.Material?
): Part
	return Kit.part(parent, {
		name = name,
		cf = cf,
		size = size,
		color = color,
		material = material or Enum.Material.SmoothPlastic,
		solid = true,
	})
end

return Kit
