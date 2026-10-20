--!strict
--[[
	InputController: one place that maps keyboard, gamepad and touch buttons to game actions (S29, U06).

	Gameplay code listens to actions (InputController.on("Use", fn)) and never to raw keys, so every action
	works the same on every device. Touch buttons on the HUD call InputController.trigger, and the prompt
	glyphs (keyLabel / keyImage) always match the device the player is using right now.

	While a menu is open, gameplay actions are blocked (UIRoot sets this), so pressing E in the shop never
	unfolds a room behind it.
]]

local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Device = require(script.Parent.Parent.Core.Device)

export type Action = "Slot1" | "Slot2" | "Use" | "Rotate" | "Cancel" | "Ping" | "Drop" | "Menu"
export type State = "Begin" | "End"

local InputController = {}

InputController.Action = Signal.new() -- (action, state)

type Binding = { keys: { Enum.KeyCode }, pad: { Enum.KeyCode }, label: string, padLabel: string }

local BINDINGS: { [string]: Binding } = {
	Slot1 = { keys = { Enum.KeyCode.One }, pad = { Enum.KeyCode.DPadLeft }, label = "1", padLabel = "◀" },
	Slot2 = { keys = { Enum.KeyCode.Two }, pad = { Enum.KeyCode.DPadRight }, label = "2", padLabel = "▶" },
	Use = { keys = { Enum.KeyCode.E }, pad = { Enum.KeyCode.ButtonX }, label = "E", padLabel = "X" },
	Rotate = { keys = { Enum.KeyCode.R }, pad = { Enum.KeyCode.ButtonY }, label = "R", padLabel = "Y" },
	Cancel = { keys = { Enum.KeyCode.Q }, pad = { Enum.KeyCode.ButtonB }, label = "Q", padLabel = "B" },
	Ping = { keys = { Enum.KeyCode.G }, pad = { Enum.KeyCode.DPadUp }, label = "G", padLabel = "▲" },
	Drop = { keys = { Enum.KeyCode.F }, pad = { Enum.KeyCode.DPadDown }, label = "F", padLabel = "▼" },
	Menu = { keys = { Enum.KeyCode.M }, pad = { Enum.KeyCode.ButtonSelect }, label = "M", padLabel = "☰" },
}

-- Actions that keep working while a menu is open.
local UI_SAFE: { [string]: boolean } = { Menu = true }

local blocked = false
local held: { [string]: boolean } = {}

local function fire(action: string, state: State)
	if state == "Begin" then
		if held[action] then
			return
		end
		held[action] = true
	else
		if not held[action] then
			return
		end
		held[action] = nil
	end
	InputController.Action:Fire(action, state)
end

-- Listen to one action. Returns the connection.
function InputController.on(action: Action, fn: (State) -> ())
	return InputController.Action:Connect(function(name: string, state: State)
		if name == action then
			fn(state)
		end
	end)
end

-- Fire an action from a UI button (touch HUD). Respects blocking like keys do.
function InputController.trigger(action: Action, state: State)
	if blocked and not UI_SAFE[action] then
		return
	end
	fire(action, state)
end

function InputController.isHeld(action: Action): boolean
	return held[action] == true
end

function InputController.setBlocked(value: boolean)
	if value == blocked then
		return
	end
	blocked = value
	if blocked then
		-- Release anything held so holds cancel cleanly when a menu opens.
		for action in held do
			if not UI_SAFE[action] then
				fire(action, "End")
			end
		end
	end
end

function InputController.isBlocked(): boolean
	return blocked
end

-- Text shown in key badges for the current device ("E", "X", "" on touch).
function InputController.keyLabel(action: Action): string
	local binding = BINDINGS[action]
	if not binding then
		return ""
	end
	local kind = Device.kind()
	if kind == "gamepad" then
		return binding.padLabel
	elseif kind == "keyboard" then
		return binding.label
	end
	return ""
end

-- Platform glyph image for the action's gamepad button (Xbox / PlayStation art), when available.
function InputController.keyImage(action: Action): string?
	local binding = BINDINGS[action]
	if not binding or Device.kind() ~= "gamepad" then
		return nil
	end
	local ok, image = pcall(function()
		return UserInputService:GetImageForKeyCode(binding.pad[1])
	end)
	if ok and type(image) == "string" and image ~= "" then
		return image
	end
	return nil
end

function InputController.start()
	for action, binding in BINDINGS do
		local inputs: { any } = {}
		for _, key in binding.keys do
			table.insert(inputs, key)
		end
		for _, key in binding.pad do
			table.insert(inputs, key)
		end
		ContextActionService:BindActionAtPriority(
			"RN_" .. action,
			function(_name: string, inputState: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult
				if blocked and not UI_SAFE[action] then
					if inputState ~= Enum.UserInputState.Begin then
						fire(action, "End")
					end
					return Enum.ContextActionResult.Pass
				end
				if inputState == Enum.UserInputState.Begin then
					fire(action, "Begin")
				elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
					fire(action, "End")
				end
				return Enum.ContextActionResult.Sink
			end,
			false,
			Enum.ContextActionPriority.High.Value,
			table.unpack(inputs)
		)
	end
	-- Losing focus (alt-tab, opening the Roblox menu) must never leave an action stuck "held".
	UserInputService.WindowFocusReleased:Connect(function()
		for action in held do
			fire(action, "End")
		end
	end)
end

return InputController
