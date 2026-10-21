--[[
	export_gui: drive the shipped client into a scenario and dump its ScreenGui tree for render_gui.py.

	Usage (from the repo root):
	  lune run tools/preview/export_gui.luau <place.rbxl> <scenario> <out.json>

	Scenarios: lobby | explore | placement | escape | downed | spectate | results
	           menu:<ScreenName> (MissionBoard, Collection, Settings, Debug, Feedback ...)
	           phone:<scenario> runs any of them on a touch phone (render with --size 750x311)

	The server and client both run headlessly (tests/harness/Sim + ClientSim), so the interface shows real
	replicated state, real strings and real layout properties.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local roblox = require("@lune/roblox")

local Sim = require("../../tests/harness/Sim")
local ClientSim = require("../../tests/harness/ClientSim")

local placePath = process.args[1] or "build/test.rbxl"
local scenario = process.args[2] or "lobby"
local outPath = process.args[3] or "tools/preview/out/gui.json"
-- An 844x390 phone whose HUD safe area (notch, home bar and the Roblox top bar removed) is 750x311.
local touch = string.sub(scenario, 1, 6) == "phone:"
if touch then
	scenario = string.sub(scenario, 7)
end

local V3 = roblox.Vector3

-- Scenario driver --------------------------------------------------------------------------------------------

local sim = Sim.new(placePath)
sim:startServer()
sim:run(0.3)
local a = sim:addBot("Alice", 1001)
sim:snapshot(a)
local b: any = nil
if scenario == "downed" or scenario == "spectate" then
	b = sim:addBot("Bob", 1002)
	sim:snapshot(b)
end
local client = ClientSim.attach(
	sim,
	a,
	if touch
		then { device = "touch", viewport = roblox.Vector2.new(844, 390), safeArea = roblox.Vector2.new(750, 311) }
		else nil
)
client:start()
sim:run(1.5)

local function phase(): string?
	return sim:state(a, "global", "run.phase")
end

local function launch()
	sim:send(a, "SetReady", true)
	if b then
		sim:send(b, "SetReady", true)
	end
	sim:runUntil(function()
		return phase() == "Explore"
	end, 30)
	sim:run(2.5)
end

local function tileIndexAt(level: any, position: any): number
	local best, bestDistance = 1, math.huge
	for i, tile in level.tiles do
		local d = (tile.cf.Position - position).Magnitude
		if d < bestDistance then
			best, bestDistance = i, d
		end
	end
	return best
end

local function walkTo(point: any, timeout: number?)
	local level = sim:state(a, "global", "level")
	local from = tileIndexAt(level, sim:position(a))
	local to = tileIndexAt(level, point)
	local path = {}
	local step = if to >= from then 1 else -1
	for i = from, to, step do
		table.insert(path, level.tiles[i].cf.Position + V3.new(0, 3, 0))
	end
	table.insert(path, point)
	sim:walk(a, path)
	sim:runUntil(function()
		local p = sim:position(a)
		return p ~= nil and V3.new(p.X - point.X, 0, p.Z - point.Z).Magnitude < 1.5
	end, timeout or 30)
end

if scenario == "lobby" then
	sim:run(1)
elseif string.sub(scenario, 1, 5) == "menu:" then
	local UIRoot = client:module("UI.UIRoot")
	UIRoot.open(string.sub(scenario, 6))
	sim:run(1)
elseif scenario == "explore" then
	launch()
elseif scenario == "placement" then
	launch()
	local level = sim:state(a, "global", "level")
	walkTo(level.sockets.S1.interactPoint)
	client:tap("RN_Slot1")
	sim:run(0.6)
elseif scenario == "escape" or scenario == "results" then
	launch()
	local level = sim:state(a, "global", "level")
	walkTo(level.sockets.S1.interactPoint)
	client:tap("RN_Slot1")
	sim:run(0.3)
	client:tap("RN_Use")
	sim:run(2.5)
	walkTo(level.target.capturePoint, 40)
	client:press("RN_Use")
	sim:run(3.4)
	client:release("RN_Use")
	sim:runUntil(function()
		return phase() == "Escape"
	end, 6)
	sim:run(3)
	if scenario == "results" then
		walkTo(level.tiles[1].cf.Position + V3.new(0, 3, 0), 60)
		sim:walk(a, { level.exit.cf.Position })
		sim:runUntil(function()
			return phase() == "Results"
		end, 20)
		sim:run(5)
	end
elseif scenario == "downed" then
	launch()
	sim:send(a, "Debug", "down")
	sim:run(2)
elseif scenario == "spectate" then
	launch()
	sim:send(a, "Debug", "down")
	sim:run(22)
else
	error("unknown scenario " .. scenario)
end

if #sim.errors > 0 then
	print("WARNING: errors during scenario:\n" .. table.concat(sim.errors, "\n----\n"))
end
for _, w in sim.warnings do
	if string.find(w, "[Client]", 1, true) then
		print("WARNING: " .. w)
	end
end

-- Serialization ------------------------------------------------------------------------------------------------

local function udim2(v: any)
	return { v.X.Scale, v.X.Offset, v.Y.Scale, v.Y.Offset }
end

local function color(c: any)
	return { c.R, c.G, c.B }
end

local function colorSequence(cs: any)
	local out = {}
	for _, k in cs.Keypoints do
		table.insert(out, { k.Time, k.Value.R, k.Value.G, k.Value.B })
	end
	return out
end

local function numberSequence(ns: any)
	local out = {}
	for _, k in ns.Keypoints do
		table.insert(out, { k.Time, k.Value })
	end
	return out
end

local function try(fn: () -> any): any
	local ok, value = pcall(fn)
	return if ok then value else nil
end

local function serialize(inst: any): any?
	local class = inst.ClassName
	local node: { [string]: any } = { class = class, name = inst.Name, children = {} }
	if inst:IsA("GuiObject") then
		node.visible = inst.Visible
		node.size = udim2(inst.Size)
		node.position = udim2(inst.Position)
		node.anchor = { inst.AnchorPoint.X, inst.AnchorPoint.Y }
		node.rotation = inst.Rotation
		node.bg = color(inst.BackgroundColor3)
		node.bgt = inst.BackgroundTransparency
		node.z = inst.ZIndex
		node.order = inst.LayoutOrder
		node.auto = inst.AutomaticSize.Name
		node.clip = inst.ClipsDescendants
		if inst:IsA("TextLabel") or inst:IsA("TextButton") or inst:IsA("TextBox") then
			node.text = inst.Text
			node.textSize = inst.TextSize
			node.font = try(function()
				return inst.FontFace.Family
			end)
			node.weight = try(function()
				return inst.FontFace.Weight.Name
			end)
			node.textColor = color(inst.TextColor3)
			node.textT = inst.TextTransparency
			node.xAlign = inst.TextXAlignment.Name
			node.yAlign = inst.TextYAlignment.Name
			node.wrapped = inst.TextWrapped
			node.scaled = inst.TextScaled
			node.rich = inst.RichText
		end
		if inst:IsA("ScrollingFrame") then
			node.canvasPosition = { inst.CanvasPosition.X, inst.CanvasPosition.Y }
			node.canvasSize = udim2(inst.CanvasSize)
		end
		if inst:IsA("ImageLabel") or inst:IsA("ImageButton") then
			node.image = inst.Image
			node.imageT = inst.ImageTransparency
			node.imageColor = color(inst.ImageColor3)
		end
	elseif inst:IsA("ScreenGui") then
		node.enabled = inst.Enabled
		node.order = inst.DisplayOrder
		node.insets = inst.ScreenInsets.Name
	elseif class == "UICorner" then
		node.radius = { inst.CornerRadius.Scale, inst.CornerRadius.Offset }
	elseif class == "UIStroke" then
		node.color = color(inst.Color)
		node.thickness = inst.Thickness
		node.transparency = inst.Transparency
		node.mode = inst.ApplyStrokeMode.Name
		node.enabled = inst.Enabled
	elseif class == "UIGradient" then
		node.color = colorSequence(inst.Color)
		node.transparency = numberSequence(inst.Transparency)
		node.rotation = inst.Rotation
		node.enabled = inst.Enabled
	elseif class == "UIPadding" then
		node.pad = {
			inst.PaddingTop.Scale,
			inst.PaddingTop.Offset,
			inst.PaddingBottom.Scale,
			inst.PaddingBottom.Offset,
			inst.PaddingLeft.Scale,
			inst.PaddingLeft.Offset,
			inst.PaddingRight.Scale,
			inst.PaddingRight.Offset,
		}
	elseif class == "UIListLayout" then
		node.fill = inst.FillDirection.Name
		node.padding = { inst.Padding.Scale, inst.Padding.Offset }
		node.hAlign = inst.HorizontalAlignment.Name
		node.vAlign = inst.VerticalAlignment.Name
		node.sort = inst.SortOrder.Name
		node.wraps = try(function()
			return inst.Wraps
		end)
	elseif class == "UIGridLayout" then
		node.cellSize = udim2(inst.CellSize)
		node.cellPadding = udim2(inst.CellPadding)
		node.fill = inst.FillDirection.Name
		node.hAlign = inst.HorizontalAlignment.Name
		node.vAlign = inst.VerticalAlignment.Name
		node.sort = inst.SortOrder.Name
	elseif class == "UIScale" then
		node.scale = inst.Scale
	elseif class == "UIAspectRatioConstraint" then
		node.ratio = inst.AspectRatio
		node.dominant = inst.DominantAxis.Name
		node.aspectType = inst.AspectType.Name
	elseif class == "UISizeConstraint" then
		node.min = { inst.MinSize.X, inst.MinSize.Y }
		node.max = { inst.MaxSize.X, inst.MaxSize.Y }
	elseif class == "UITextSizeConstraint" then
		node.min = inst.MinTextSize
		node.max = inst.MaxTextSize
	elseif inst:IsA("GuiBase2d") then
		-- BillboardGui / SurfaceGui are world-space; skip them.
		return nil
	else
		return nil
	end
	for _, child in inst:GetChildren() do
		local childNode = serialize(child)
		if childNode then
			table.insert(node.children, childNode)
		end
	end
	return node
end

local guis = {}
for _, gui in client.playerGui:GetChildren() do
	if gui:IsA("ScreenGui") then
		local node = serialize(gui)
		if node then
			table.insert(guis, node)
		end
	end
end
fs.writeFile(outPath, serde.encode("json", { scenario = scenario, guis = guis }, false))
print("wrote " .. outPath .. " (" .. #guis .. " screen guis)")
