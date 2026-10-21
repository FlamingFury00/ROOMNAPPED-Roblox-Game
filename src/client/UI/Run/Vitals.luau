--!strict
--[[
	Vitals: your hearts and your team (U03, U10, U12).

	Hearts sit top-left: full / empty heart shapes (not just colour), a pop and shake when one is lost and a
	slow pulse on the last heart. Below them, one card per teammate shows their avatar, name, hearts and a
	status badge with an icon and a word - Downed (with the time left to revive them), Recovering, Out,
	Offline or Left - plus a suitcase badge on whoever carries the stolen room.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local Strings = require(Shared.Config.Strings)
local GameConfig = require(Shared.Config.GameConfig)
local RunInfo = require(script.Parent.Parent.Parent.Core.RunInfo)
local Theme = require(script.Parent.Parent.Theme)
local Create = require(script.Parent.Parent.Create)
local Icons = require(script.Parent.Parent.Icons)
local Motion = require(script.Parent.Parent.Motion)
local Components = require(script.Parent.Parent.Components)

local Vitals = {}

local C = Theme.Colors

export type Handle = { frame: Frame, setVisible: (boolean) -> () }

type Card = {
	frame: Frame,
	name: TextLabel,
	hearts: Frame,
	heartCount: number,
	heartMax: number,
	status: Frame,
	statusText: TextLabel,
	statusIcon: Frame,
	statusIconFrame: Frame?,
	carry: Frame,
	ring: Components.HoldHandle,
	lastStatus: string,
}

local STATUS: { [string]: { key: string, icon: string, color: Color3 } } = {
	Downed = { key = "hud.team.downed", icon = "heart", color = C.red },
	Recovering = { key = "hud.team.recovering", icon = "refresh", color = C.orange },
	Eliminated = { key = "hud.team.out", icon = "cross", color = C.textMuted },
	Left = { key = "hud.team.left", icon = "door", color = C.textMuted },
	Disconnected = { key = "hud.team.offline", icon = "offline", color = C.textMuted },
}

local function heartRow(parent: Instance, size: number, count: number, max: number): Frame
	local row = parent:FindFirstChild("HeartRow") :: Frame?
	if row then
		row:ClearAllChildren()
	else
		row = Create.new("Frame", {
			Name = "HeartRow",
			Size = UDim2.fromOffset(0, size),
			AutomaticSize = Enum.AutomaticSize.X,
			BackgroundTransparency = 1,
			Parent = parent,
		})
	end
	local r = row :: Frame
	Create.list(
		Enum.FillDirection.Horizontal,
		math.floor(size * 0.15),
		Enum.HorizontalAlignment.Left,
		Enum.VerticalAlignment.Center
	).Parent =
		r
	for i = 1, max do
		local holder = Create.new("Frame", {
			Name = "Heart" .. i,
			Size = UDim2.fromOffset(size, size),
			BackgroundTransparency = 1,
			LayoutOrder = i,
			Parent = r,
		})
		Icons.make(if i <= count then "heart" else "heartEmpty", if i <= count then C.heart else C.heartEmpty, C.white).Parent =
			holder
	end
	return r
end

function Vitals.create(parent: Instance): Handle
	local column = Create.new("Frame", {
		Name = "Vitals",
		Position = UDim2.fromOffset(16, 14),
		Size = UDim2.fromOffset(260, 400),
		BackgroundTransparency = 1,
		Parent = parent,
	}, { Create.list(Enum.FillDirection.Vertical, 10, Enum.HorizontalAlignment.Left, Enum.VerticalAlignment.Top) })

	-- My hearts -------------------------------------------------------------------------------------------
	local heartsPanel = Create.new("Frame", {
		Name = "MyHearts",
		Size = UDim2.fromOffset(0, 58),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = C.panelDark,
		BackgroundTransparency = 0.15,
		LayoutOrder = 1,
		Parent = column,
	}, { Create.corner(Theme.Radius.pill), Create.stroke(C.gold, 2, 0.3), Create.padding(8, 14) })
	local myHearts = -1
	local myMax = -1
	local lowPulse = false
	local pulsing = false
	-- Solo runs: the one extra life, shown until the run ends (greyed once spent).
	local extraLife: Frame? = nil
	local extraLifeLeft = -1

	-- Team cards ---------------------------------------------------------------------------------------------
	local cards: { [string]: Card } = {}

	local function makeCard(key: string): Card
		local frame = Create.new("Frame", {
			Name = "Card_" .. key,
			Size = UDim2.fromOffset(250, 56),
			BackgroundColor3 = C.panelDark,
			BackgroundTransparency = 0.18,
			Parent = column,
		}, { Create.corner(Theme.Radius.medium), Create.stroke(C.shadow, 2, 0.4) })
		local userId = tonumber(key) or 0
		local avatar = Create.new("ImageLabel", {
			Name = "Avatar",
			Position = UDim2.fromOffset(6, 6),
			Size = UDim2.fromOffset(44, 44),
			BackgroundColor3 = C.panelLight,
			Image = string.format("rbxthumb://type=AvatarHeadShot&id=%d&w=48&h=48", userId),
			Parent = frame,
		}, { Create.corner(Theme.Radius.pill) })
		local ring = Components.holdCircle(avatar, C.red)
		ring.frame.BackgroundTransparency = 1
		ring.frame.Visible = false
		local fill = ring.frame:FindFirstChild("Fill")
		if fill and fill:IsA("Frame") then
			fill.BackgroundTransparency = 0.45
		end
		local name = Components.label({
			text = RunInfo.displayName(key),
			font = Theme.Fonts.heading,
			textSize = 17,
			size = UDim2.new(1, -110, 0, 22),
			position = UDim2.fromOffset(58, 5),
			stroke = true,
			parent = frame,
		})
		name.TextTruncate = Enum.TextTruncate.AtEnd
		local hearts = Create.new("Frame", {
			Name = "Hearts",
			Position = UDim2.fromOffset(58, 30),
			Size = UDim2.fromOffset(90, 20),
			BackgroundTransparency = 1,
			Parent = frame,
		})
		local status = Create.new("Frame", {
			Name = "Status",
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -8, 0.5, 0),
			Size = UDim2.fromOffset(0, 28),
			AutomaticSize = Enum.AutomaticSize.X,
			BackgroundColor3 = C.red,
			Visible = false,
			Parent = frame,
		}, {
			Create.corner(Theme.Radius.pill),
			Create.padding(2, 8),
			Create.list(
				Enum.FillDirection.Horizontal,
				4,
				Enum.HorizontalAlignment.Center,
				Enum.VerticalAlignment.Center
			),
		})
		local statusIcon = Create.new(
			"Frame",
			{ Size = UDim2.fromOffset(18, 18), BackgroundTransparency = 1, LayoutOrder = 1, Parent = status }
		)
		local statusText = Components.label({
			text = "",
			font = Theme.Fonts.bodyHeavy,
			textSize = 14,
			size = UDim2.fromOffset(0, 22),
			autoSize = Enum.AutomaticSize.X,
			layoutOrder = 2,
			parent = status,
		})
		local carry = Create.new("Frame", {
			Name = "Carry",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(46, 44),
			Size = UDim2.fromOffset(24, 24),
			BackgroundColor3 = C.gold,
			Visible = false,
			ZIndex = 3,
			Parent = frame,
		}, { Create.corner(Theme.Radius.pill), Create.stroke(C.ink, 2, 0) })
		local carryIcon = Create.new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(0.72, 0.72),
			BackgroundTransparency = 1,
			ZIndex = 4,
			Parent = carry,
		})
		Icons.make("suitcase", C.ink, C.gold).Parent = carryIcon
		return {
			frame = frame,
			name = name,
			hearts = hearts,
			heartCount = -1,
			heartMax = -1,
			status = status,
			statusText = statusText,
			statusIcon = statusIcon,
			statusIconFrame = nil,
			carry = carry,
			ring = ring,
			lastStatus = "",
		}
	end

	local function refresh()
		local roster = RunInfo.roster()
		local mine = roster[RunInfo.myKey()]
		-- My hearts.
		if mine then
			local hearts = mine.hearts or 0
			local max = mine.max or 3
			if hearts ~= myHearts or max ~= myMax then
				local lost = myHearts >= 0 and hearts < myHearts
				myHearts, myMax = hearts, max
				heartRow(heartsPanel, 40, hearts, max)
				if lost then
					Motion.pop(heartsPanel, 1.25)
					Motion.shake(heartsPanel)
				elseif myHearts >= 0 then
					Motion.pop(heartsPanel, 0.9)
				end
				lowPulse = hearts == 1
			end
			local firstKey = next(roster)
			local solo = firstKey == nil or next(roster, firstKey) == nil
			local left = if solo and type(mine.selfRecoveries) == "number" then mine.selfRecoveries else -1
			if left ~= extraLifeLeft then
				extraLifeLeft = left
				if extraLife then
					(extraLife :: Frame):Destroy()
					extraLife = nil
				end
				if left >= 0 then
					local chip = Components.chip(
						"refresh",
						Strings.t(if left > 0 then "hud.extraLife" else "hud.extraLifeUsed"),
						if left > 0 then C.blue else C.panelLight,
						2
					)
					chip.Name = "ExtraLife"
					chip.Parent = column
					extraLife = chip
				end
			end
		end
		-- Teammates.
		local seen: { [string]: boolean } = {}
		for key, entry in roster do
			if key ~= RunInfo.myKey() then
				seen[key] = true
				local card = cards[key]
				if not card then
					card = makeCard(key)
					cards[key] = card
				end
				local c = card :: Card
				c.frame.LayoutOrder = 10 + (entry.order or 0)
				c.name.Text = entry.display or RunInfo.displayName(key)
				local hearts = entry.hearts or 0
				local max = entry.max or 3
				if hearts ~= c.heartCount or max ~= c.heartMax then
					c.heartCount, c.heartMax = hearts, max
					heartRow(c.hearts, 18, hearts, max)
				end
				local status = entry.status or "Active"
				if status ~= c.lastStatus then
					c.lastStatus = status
					local style = STATUS[status]
					c.status.Visible = style ~= nil
					if style then
						c.status.BackgroundColor3 = style.color
						c.statusText.Text = Strings.t(style.key)
						if c.statusIconFrame then
							(c.statusIconFrame :: Frame):Destroy()
						end
						local icon = Icons.make(style.icon, C.white, style.color)
						icon.Parent = c.statusIcon
						c.statusIconFrame = icon
						Motion.pop(c.frame, 0.92)
					end
					local faded = status == "Eliminated" or status == "Left" or status == "Disconnected"
					c.frame.BackgroundTransparency = if faded then 0.55 else 0.18
					c.name.TextTransparency = if faded then 0.4 else 0
				end
				c.carry.Visible = entry.carrying == true
			end
		end
		for key, card in cards do
			if not seen[key] then
				card.frame:Destroy()
				cards[key] = nil
			end
		end
	end

	RunInfo.RosterChanged:Connect(refresh)
	refresh()

	-- Per-frame: downed countdown rings and the low-heart pulse.
	RunService.Heartbeat:Connect(function()
		local now = RunInfo.serverNow()
		local roster = RunInfo.roster()
		for key, card in cards do
			local entry = roster[key]
			if entry and entry.status == "Downed" and type(entry.downedEndsAt) == "number" then
				local remaining = math.max(0, entry.downedEndsAt - now)
				card.ring.frame.Visible = true
				card.ring.set(remaining / GameConfig.Downed.WindowSeconds)
				card.statusText.Text = Strings.t("hud.team.downed") .. " " .. tostring(math.ceil(remaining))
			elseif card.ring.frame.Visible then
				card.ring.frame.Visible = false
			end
		end
		local stroke = heartsPanel:FindFirstChildOfClass("UIStroke")
		if lowPulse and stroke then
			stroke.Color = C.red:Lerp(C.gold, 0.5 + 0.5 * math.sin(os.clock() * 6))
			stroke.Transparency = 0
			pulsing = true
		elseif pulsing and stroke then
			-- Back to the resting look once, not every frame.
			pulsing = false
			stroke.Color = C.gold
			stroke.Transparency = 0.3
		end
	end)

	return {
		frame = column,
		setVisible = function(value: boolean)
			column.Visible = value
		end,
	}
end

return Vitals
