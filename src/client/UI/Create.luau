--!strict
--[[
	Create: tiny declarative Instance builder used by every UI module.

	Create.new("Frame", { Size = ..., [Create.Event.Activated] = fn }, { children })
	* string keys are assigned as properties (Parent last)
	* Create.Event.Name keys connect to that event
	* children may be Instances or nil (nil entries are skipped, which keeps conditional UI terse)
]]

local Create = {}

local EVENT_MARKER = {}

export type EventKey = { name: string, marker: any }

Create.Event = setmetatable({}, {
	__index = function(_, name: string): EventKey
		return { name = name, marker = EVENT_MARKER }
	end,
}) :: any

local function build(className: string, props: { [any]: any }?, children: { any }?): any
	local instance = Instance.new(className)
	local parent: Instance? = nil
	if props then
		for key, value in props do
			if type(key) == "table" and (key :: any).marker == EVENT_MARKER then
				((instance :: any)[(key :: any).name] :: RBXScriptSignal):Connect(value)
			elseif key == "Parent" then
				parent = value
			elseif type(key) == "string" then
				(instance :: any)[key] = value
			end
		end
	end
	if children then
		-- Generalised iteration visits every present entry, so `nil` holes are simply skipped.
		for _, child in children do
			if child then
				child.Parent = instance
			end
		end
	end
	if parent then
		instance.Parent = parent
	end
	return instance
end

-- Declared as an overload so heterogeneous child lists ({ UICorner, UIStroke, ... }) type-check: the
-- solver only pushes the expected `{ any }` into a table literal when the parameter is not optional.
export type CreateFn = ((string, { [any]: any }?) -> any) & ((string, { [any]: any }?, { any }) -> any)
Create.new = (build :: any) :: CreateFn

-- Common decorators ------------------------------------------------------------------------------------

function Create.corner(radius: UDim?): UICorner
	local corner = Instance.new("UICorner")
	corner.CornerRadius = radius or UDim.new(0, 12)
	return corner
end

function Create.stroke(color: Color3, thickness: number?, transparency: number?): UIStroke
	local stroke = Instance.new("UIStroke")
	stroke.Color = color
	stroke.Thickness = thickness or 2
	stroke.Transparency = transparency or 0
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	return stroke
end

function Create.textStroke(color: Color3, thickness: number?, transparency: number?): UIStroke
	local stroke = Instance.new("UIStroke")
	stroke.Color = color
	stroke.Thickness = thickness or 2
	stroke.Transparency = transparency or 0
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	stroke.LineJoinMode = Enum.LineJoinMode.Round
	return stroke
end

function Create.gradient(top: Color3, bottom: Color3, rotation: number?): UIGradient
	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new(top, bottom)
	gradient.Rotation = rotation or 90
	return gradient
end

function Create.padding(all: number, horizontal: number?): UIPadding
	local padding = Instance.new("UIPadding")
	local h = horizontal or all
	padding.PaddingTop = UDim.new(0, all)
	padding.PaddingBottom = UDim.new(0, all)
	padding.PaddingLeft = UDim.new(0, h)
	padding.PaddingRight = UDim.new(0, h)
	return padding
end

function Create.list(
	direction: Enum.FillDirection,
	spacing: number?,
	hAlign: Enum.HorizontalAlignment?,
	vAlign: Enum.VerticalAlignment?
): UIListLayout
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = direction
	layout.Padding = UDim.new(0, spacing or 8)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.HorizontalAlignment = hAlign or Enum.HorizontalAlignment.Left
	layout.VerticalAlignment = vAlign or Enum.VerticalAlignment.Top
	return layout
end

function Create.aspect(ratio: number): UIAspectRatioConstraint
	local constraint = Instance.new("UIAspectRatioConstraint")
	constraint.AspectRatio = ratio
	return constraint
end

function Create.textLimit(minSize: number, maxSize: number): UITextSizeConstraint
	local constraint = Instance.new("UITextSizeConstraint")
	constraint.MinTextSize = minSize
	constraint.MaxTextSize = maxSize
	return constraint
end

return Create
