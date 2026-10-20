--!strict
--[[
	UIRoot: the ScreenGuis every interface lives in, plus the menu (modal) stack (U01, U19).

	Layers (DisplayOrder):
	  World   1  - nothing full-screen; reserved for screen-space effects under the HUD
	  Hud     5  - in-run and lobby HUD, laid out on the 1280x720 virtual canvas inside the core-UI safe area
	  Dim    18  - full-bleed dim behind menus
	  Menus  20  - modal screens (mission board, collection, settings, results...)
	  Overlay 30 - toasts, hints and fades that must sit on top of everything
	  Cinema 40  - full-bleed black bars / fades for cinematics (no safe-area inset)

	Menus are a stack: opening one blocks gameplay input, frees the mouse and gives gamepads a selection;
	B / the close button pops the top menu.
]]

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Theme = require(script.Parent.Theme)
local Create = require(script.Parent.Create)
local Motion = require(script.Parent.Motion)
local Responsive = require(script.Parent.Responsive)
local Components = require(script.Parent.Components)
local Device = require(script.Parent.Parent.Core.Device)

export type Screen = {
	name: string,
	frame: GuiObject,
	-- Optional hooks.
	onOpen: ((any?) -> ())?,
	onClose: (() -> ())?,
	defaultSelection: (() -> GuiObject?)?,
	-- Menus that should not close when another menu opens on top of them (confirm dialogs stack).
	keepUnder: boolean?,
	-- If false the menu cannot be closed by B / the dim (results waiting on the server, etc.).
	closable: boolean?,
}

local UIRoot = {}

UIRoot.StackChanged = Signal.new() -- (topName?)

local playerGui: PlayerGui = Players.LocalPlayer:WaitForChild("PlayerGui") :: PlayerGui

local function screenGui(name: string, order: number, insets: Enum.ScreenInsets): ScreenGui
	local existing = playerGui:FindFirstChild(name)
	if existing and existing:IsA("ScreenGui") then
		existing:Destroy()
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = name
	gui.DisplayOrder = order
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ScreenInsets = insets
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = playerGui
	return gui
end

UIRoot.Guis = {
	Hud = screenGui("RN_Hud", 5, Enum.ScreenInsets.CoreUISafeInsets),
	Dim = screenGui("RN_Dim", 18, Enum.ScreenInsets.None),
	Menus = screenGui("RN_Menus", 20, Enum.ScreenInsets.CoreUISafeInsets),
	Overlay = screenGui("RN_Overlay", 30, Enum.ScreenInsets.CoreUISafeInsets),
	Cinema = screenGui("RN_Cinema", 40, Enum.ScreenInsets.None),
}

-- Virtual-canvas roots (1280x720 reference, scaled to the safe area).
UIRoot.Hud = Responsive.root(UIRoot.Guis.Hud, "HudRoot")
UIRoot.Menus = Responsive.root(UIRoot.Guis.Menus, "MenuRoot")
UIRoot.Overlay = Responsive.root(UIRoot.Guis.Overlay, "OverlayRoot")

local dim = Create.new("TextButton", {
	Name = "Dim",
	Size = UDim2.fromScale(1, 1),
	BackgroundColor3 = Theme.Colors.ink,
	BackgroundTransparency = 1,
	Text = "",
	AutoButtonColor = false,
	Visible = false,
	Modal = true, -- frees the mouse from shift-lock / first person while a menu is open
	Parent = UIRoot.Guis.Dim,
})

local cinemaFade = Create.new("Frame", {
	Name = "Fade",
	Size = UDim2.fromScale(1, 1),
	BackgroundColor3 = Color3.new(0, 0, 0),
	BackgroundTransparency = 1,
	BorderSizePixel = 0,
	Visible = false,
	Parent = UIRoot.Guis.Cinema,
})

local screens: { [string]: Screen } = {}
local stack: { Screen } = {}
local blockHook: ((boolean) -> ())? = nil

-- InputController registers itself here (avoids a require cycle).
function UIRoot.setBlockHook(hook: (boolean) -> ())
	blockHook = hook
end

local function refresh()
	local top = stack[#stack]
	local any = top ~= nil
	if blockHook then
		(blockHook :: (boolean) -> ())(any)
	end
	if any then
		dim.Visible = true
		Motion.fade(dim, Theme.Tween.medium, { BackgroundTransparency = 0.45 })
		ContextActionService:BindActionAtPriority(
			"RN_UIBack",
			function(_: string, state: Enum.UserInputState): Enum.ContextActionResult
				if state == Enum.UserInputState.Begin then
					UIRoot.back()
				end
				return Enum.ContextActionResult.Sink
			end,
			false,
			Enum.ContextActionPriority.High.Value + 10,
			Enum.KeyCode.ButtonB
		)
	else
		local tween = Motion.fade(dim, Theme.Tween.fast, { BackgroundTransparency = 1 })
		tween.Completed:Once(function()
			if #stack == 0 then
				dim.Visible = false
			end
		end)
		ContextActionService:UnbindAction("RN_UIBack")
		GuiService.SelectedObject = nil
	end
	UIRoot.StackChanged:Fire(if top then top.name else nil)
end

local function selectDefault(screen: Screen)
	-- Only drive selection for gamepad players; mouse and touch players never see a selection box.
	if not Device.isGamepad() then
		return
	end
	local target: GuiObject? = nil
	if screen.defaultSelection then
		target = (screen.defaultSelection :: () -> GuiObject?)()
	end
	if target then
		GuiService.SelectedObject = target
	end
end

function UIRoot.register(screen: Screen)
	screens[screen.name] = screen
	screen.frame.Visible = false
	if screen.frame.Parent == nil then
		screen.frame.Parent = UIRoot.Menus
	end
end

function UIRoot.get(name: string): Screen?
	return screens[name]
end

function UIRoot.isOpen(name: string): boolean
	for _, screen in stack do
		if screen.name == name then
			return true
		end
	end
	return false
end

function UIRoot.top(): string?
	local top = stack[#stack]
	return if top then top.name else nil
end

function UIRoot.anyOpen(): boolean
	return #stack > 0
end

function UIRoot.close(name: string)
	for i = #stack, 1, -1 do
		local screen = stack[i]
		if screen.name == name then
			table.remove(stack, i)
			screen.frame.Visible = false
			if screen.onClose then
				(screen.onClose :: () -> ())()
			end
			Components.sound("ui_close")
			refresh()
			local below = stack[#stack]
			if below then
				below.frame.Visible = true
				selectDefault(below)
			end
			return
		end
	end
end

function UIRoot.open(name: string, arg: any?)
	local screen = screens[name]
	if not screen then
		warn("[UIRoot] unknown screen", name)
		return
	end
	if UIRoot.isOpen(name) then
		-- Re-opening brings it to the top and refreshes its content.
		if screen.onOpen then
			(screen.onOpen :: (any?) -> ())(arg)
		end
		return
	end
	if not screen.keepUnder then
		-- A normal menu replaces whatever menus were open.
		for i = #stack, 1, -1 do
			local other = stack[i]
			if other.closable ~= false then
				table.remove(stack, i)
				other.frame.Visible = false
				if other.onClose then
					(other.onClose :: () -> ())()
				end
			end
		end
	end
	table.insert(stack, screen)
	screen.frame.Visible = true
	if screen.onOpen then
		(screen.onOpen :: (any?) -> ())(arg)
	end
	Motion.growIn(screen.frame)
	Components.sound("ui_open")
	refresh()
	task.defer(selectDefault, screen)
end

function UIRoot.toggle(name: string)
	if UIRoot.isOpen(name) then
		UIRoot.close(name)
	else
		UIRoot.open(name)
	end
end

-- Pop the top menu (B button / close buttons / clicking the dim).
function UIRoot.back()
	local top = stack[#stack]
	if top and top.closable ~= false then
		UIRoot.close(top.name)
	end
end

function UIRoot.closeAll()
	for i = #stack, 1, -1 do
		local screen = stack[i]
		table.remove(stack, i)
		screen.frame.Visible = false
		if screen.onClose then
			(screen.onClose :: () -> ())()
		end
	end
	refresh()
end

dim.Activated:Connect(function()
	UIRoot.back()
end)

-- Cinematic fade to black and back. `hold` keeps it black until fadeIn is called.
function UIRoot.fadeOut(seconds: number?): Tween
	cinemaFade.Visible = true
	return Motion.fade(cinemaFade, TweenInfo.new(seconds or 0.35), { BackgroundTransparency = 0 })
end

function UIRoot.fadeIn(seconds: number?): Tween
	local tween = Motion.fade(cinemaFade, TweenInfo.new(seconds or 0.5), { BackgroundTransparency = 1 })
	tween.Completed:Once(function()
		if cinemaFade.BackgroundTransparency >= 0.99 then
			cinemaFade.Visible = false
		end
	end)
	return tween
end

return UIRoot
