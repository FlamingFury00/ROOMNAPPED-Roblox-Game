--!strict
--[[
	Layout registry: every expedition layout by id (S31, A08). Missions reference these ids.
]]
local LayoutTypes = require(script.Parent.Parent.World.LayoutTypes)

local Layouts: { [string]: LayoutTypes.LayoutDef } = {}

for _, child in script:GetChildren() do
	if child:IsA("ModuleScript") then
		local layout = (require :: any)(child) :: LayoutTypes.LayoutDef
		assert(Layouts[layout.id] == nil, "duplicate layout id " .. layout.id)
		Layouts[layout.id] = layout
	end
end

return Layouts
