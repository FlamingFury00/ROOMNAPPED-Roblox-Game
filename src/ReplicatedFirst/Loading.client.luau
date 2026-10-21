--!strict
--[[
	Loading: the branded check-in screen (U20).

	Runs from ReplicatedFirst before anything else, replaces the default Roblox loading screen and stays up
	until the game has loaded AND the player's save is Ready, so nobody lands in the lobby with an empty
	profile. It never hides a problem: a failed load shows "your progress is safe" with Retry, a save from a
	newer version says so, and a slow load offers Continue instead of blocking forever.

	This script cannot use the client UI kit (it lives in StarterPlayerScripts and loads later), so it keeps
	its own small copies of the theme colours and fonts.
]]

local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

ReplicatedFirst:RemoveDefaultLoadingScreen()

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui

local INK = Color3.fromRGB(22, 14, 26)
local PLUM = Color3.fromRGB(48, 28, 54)
local PLUM_LIGHT = Color3.fromRGB(78, 48, 86)
local GOLD = Color3.fromRGB(255, 202, 92)
local GOLD_LIGHT = Color3.fromRGB(255, 230, 160)
local GOLD_DARK = Color3.fromRGB(184, 122, 36)
local CREAM = Color3.fromRGB(255, 244, 222)
local DIM = Color3.fromRGB(214, 190, 204)
local RED = Color3.fromRGB(244, 72, 84)
local SHADOW = Color3.fromRGB(8, 4, 10)

local FONT_DISPLAY = Font.new("rbxasset://fonts/families/LuckiestGuy.json", Enum.FontWeight.Regular)
local FONT_HEADING = Font.new("rbxasset://fonts/families/FredokaOne.json", Enum.FontWeight.Regular)
local FONT_BODY = Font.new("rbxasset://fonts/families/BuilderSans.json", Enum.FontWeight.Bold)

local MIN_SECONDS = 2.2
local SLOW_SECONDS = 40

local startedAt = os.clock()
local reducedMotion = false

-- Strings (fallback to the key until the shared catalogue has replicated) --------------------------------------

local Strings: any = nil
local function t(key: string, fallback: string): string
	if Strings then
		local ok, text = pcall(Strings.t, key)
		if ok and type(text) == "string" and text ~= key then
			return text
		end
	end
	return fallback
end

-- Instance helpers -------------------------------------------------------------------------------------------------

local function build(className: string, props: { [string]: any }, children: { any }?): any
	local instance = Instance.new(className)
	for key, value in props do
		if key ~= "Parent" then
			(instance :: any)[key] = value
		end
	end
	if children then
		for _, child in children do
			child.Parent = instance
		end
	end
	if props.Parent then
		instance.Parent = props.Parent
	end
	return instance
end
-- Overloaded so mixed child lists ({ UICorner, UIStroke, ... }) type-check.
local make: ((string, { [string]: any }) -> any) & ((string, { [string]: any }, { any }) -> any) = build :: any

local function corner(radius: UDim): UICorner
	return make("UICorner", { CornerRadius = radius })
end

local function stroke(color: Color3, thickness: number, contextual: boolean?): UIStroke
	return make("UIStroke", {
		Color = color,
		Thickness = thickness,
		LineJoinMode = Enum.LineJoinMode.Round,
		ApplyStrokeMode = if contextual then Enum.ApplyStrokeMode.Contextual else Enum.ApplyStrokeMode.Border,
	})
end

local function label(props: { [string]: any }): TextLabel
	local defaults: { [string]: any } = {
		BackgroundTransparency = 1,
		TextColor3 = CREAM,
		FontFace = FONT_BODY,
		TextSize = 22,
		TextWrapped = true,
	}
	for key, value in props do
		defaults[key] = value
	end
	return make("TextLabel", defaults)
end

-- Layout -------------------------------------------------------------------------------------------------------------

local gui = make("ScreenGui", {
	Name = "RN_Loading",
	DisplayOrder = 100,
	IgnoreGuiInset = true,
	ScreenInsets = Enum.ScreenInsets.None,
	ResetOnSpawn = false,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	Parent = playerGui,
})

local background = make("Frame", {
	Name = "Background",
	Size = UDim2.fromScale(1, 1),
	BackgroundColor3 = Color3.new(1, 1, 1),
	BorderSizePixel = 0,
	Parent = gui,
}, {
	make("UIGradient", {
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, PLUM_LIGHT),
			ColorSequenceKeypoint.new(0.55, PLUM),
			ColorSequenceKeypoint.new(1, INK),
		}),
		Rotation = 90,
	}),
})

-- Wallpaper pattern: soft diamonds that drift slowly (hotel damask).
local pattern = make("Frame", {
	Name = "Pattern",
	BackgroundTransparency = 1,
	Size = UDim2.new(1, 240, 1, 240),
	Position = UDim2.fromOffset(-120, -120),
	Parent = background,
})
for row = 0, 9 do
	for col = 0, 15 do
		make("Frame", {
			Name = "Diamond",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale((col + (row % 2) * 0.5) / 15, row / 9),
			Size = UDim2.fromOffset(26, 26),
			Rotation = 45,
			BackgroundColor3 = GOLD,
			BackgroundTransparency = 0.93,
			BorderSizePixel = 0,
			Parent = pattern,
		}, { corner(UDim.new(0, 4)) })
	end
end
-- Vignette.
make("Frame", {
	Name = "Vignette",
	Size = UDim2.fromScale(1, 1),
	BackgroundColor3 = SHADOW,
	BorderSizePixel = 0,
	Parent = background,
}, {
	make("UIGradient", {
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.35),
			NumberSequenceKeypoint.new(0.25, 0.9),
			NumberSequenceKeypoint.new(0.75, 0.9),
			NumberSequenceKeypoint.new(1, 0.25),
		}),
		Rotation = 90,
	}),
})

local center = make("Frame", {
	Name = "Center",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromScale(0.5, 0.5),
	Size = UDim2.fromOffset(1000, 620),
	BackgroundTransparency = 1,
	Parent = gui,
})
local centerScale = make("UIScale", { Parent = center })

-- Suitcase emblem built from frames.
local emblem = make("Frame", {
	Name = "Emblem",
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.fromOffset(500, 20),
	Size = UDim2.fromOffset(170, 150),
	BackgroundTransparency = 1,
	Parent = center,
})
make("Frame", {
	Name = "Handle",
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.fromOffset(85, 0),
	Size = UDim2.fromOffset(64, 30),
	BackgroundTransparency = 1,
	Parent = emblem,
}, { corner(UDim.new(0, 10)), stroke(GOLD_DARK, 7) })
local caseBody = make("Frame", {
	Name = "Body",
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.fromOffset(85, 22),
	Size = UDim2.fromOffset(170, 118),
	BackgroundColor3 = Color3.new(1, 1, 1),
	Parent = emblem,
}, {
	corner(UDim.new(0, 18)),
	stroke(SHADOW, 4),
	make(
		"UIGradient",
		{ Color = ColorSequence.new(Color3.fromRGB(176, 96, 60), Color3.fromRGB(120, 60, 40)), Rotation = 90 }
	),
})
for _, x in { 44, 126 } do
	make("Frame", {
		Name = "Strap",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromOffset(x, 0),
		Size = UDim2.new(0, 16, 1, 0),
		BackgroundColor3 = Color3.fromRGB(90, 46, 30),
		BorderSizePixel = 0,
		Parent = caseBody,
	})
end
make("Frame", {
	Name = "Latch",
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.fromOffset(85, 10),
	Size = UDim2.fromOffset(34, 18),
	BackgroundColor3 = GOLD,
	Parent = caseBody,
}, { corner(UDim.new(0, 5)), stroke(GOLD_DARK, 2) })
local doorGlow = make("Frame", {
	Name = "Door",
	AnchorPoint = Vector2.new(0.5, 1),
	Position = UDim2.new(0, 85, 1, -10),
	Size = UDim2.fromOffset(40, 58),
	BackgroundColor3 = GOLD_LIGHT,
	Parent = caseBody,
}, { corner(UDim.new(0, 6)), stroke(GOLD_DARK, 2) })
make("Frame", {
	Name = "Knob",
	AnchorPoint = Vector2.new(0.5, 0.5),
	Position = UDim2.fromOffset(30, 30),
	Size = UDim2.fromOffset(7, 7),
	BackgroundColor3 = GOLD_DARK,
	Parent = doorGlow,
}, { corner(UDim.new(1, 0)) })

local logo = label({
	Name = "Logo",
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.fromOffset(500, 168),
	Size = UDim2.fromOffset(1000, 130),
	Text = "ROOMNAPPED",
	FontFace = FONT_DISPLAY,
	TextSize = 118,
	TextColor3 = Color3.new(1, 1, 1),
	TextWrapped = false,
	Rotation = -3,
	Parent = center,
})
make("UIGradient", {
	Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, GOLD_LIGHT),
		ColorSequenceKeypoint.new(0.55, GOLD),
		ColorSequenceKeypoint.new(1, GOLD_DARK),
	}),
	Rotation = 90,
	Parent = logo,
})
stroke(SHADOW, 6, true).Parent = logo
local logoScale = make("UIScale", { Scale = 0.6, Parent = logo })

local tagline = label({
	Name = "Tagline",
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.fromOffset(500, 296),
	Size = UDim2.fromOffset(900, 40),
	Text = "Steal the room. Build your escape.",
	FontFace = FONT_HEADING,
	TextSize = 32,
	TextColor3 = CREAM,
	Parent = center,
})
stroke(SHADOW, 3, true).Parent = tagline

local barBack = make("Frame", {
	Name = "Bar",
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.fromOffset(500, 380),
	Size = UDim2.fromOffset(540, 26),
	BackgroundColor3 = INK,
	BackgroundTransparency = 0.15,
	Parent = center,
}, { corner(UDim.new(1, 0)), stroke(GOLD_DARK, 3) })
local barFill = make("Frame", {
	Name = "Fill",
	Size = UDim2.fromScale(0.04, 1),
	BackgroundColor3 = Color3.new(1, 1, 1),
	BorderSizePixel = 0,
	ClipsDescendants = true,
	Parent = barBack,
}, {
	corner(UDim.new(1, 0)),
	make("UIGradient", { Color = ColorSequence.new(GOLD_LIGHT, GOLD), Rotation = 90 }),
})
local shimmer = make("Frame", {
	Name = "Shimmer",
	Size = UDim2.new(0, 80, 1, 0),
	BackgroundColor3 = Color3.new(1, 1, 1),
	BackgroundTransparency = 0.55,
	BorderSizePixel = 0,
	Parent = barFill,
}, {
	make("UIGradient", {
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.5, 0.2),
			NumberSequenceKeypoint.new(1, 1),
		}),
	}),
})

local status = label({
	Name = "Status",
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.fromOffset(500, 418),
	Size = UDim2.fromOffset(900, 36),
	Text = "Checking you in...",
	FontFace = FONT_HEADING,
	TextSize = 28,
	TextColor3 = GOLD_LIGHT,
	Parent = center,
})
stroke(SHADOW, 2.5, true).Parent = status

local tip = label({
	Name = "Tip",
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.fromOffset(500, 466),
	Size = UDim2.fromOffset(820, 60),
	Text = "",
	TextSize = 22,
	TextColor3 = DIM,
	Parent = center,
})

-- Problem panel (failed / newer / slow), hidden until needed.
local problem = make("Frame", {
	Name = "Problem",
	AnchorPoint = Vector2.new(0.5, 0),
	Position = UDim2.fromOffset(500, 400),
	Size = UDim2.fromOffset(760, 210),
	BackgroundColor3 = PLUM,
	Visible = false,
	Parent = center,
}, { corner(UDim.new(0, 22)), stroke(GOLD, 3) })
local problemTitle = label({
	Name = "Title",
	Position = UDim2.fromOffset(24, 14),
	Size = UDim2.new(1, -48, 0, 36),
	FontFace = FONT_HEADING,
	TextSize = 30,
	TextColor3 = GOLD_LIGHT,
	Parent = problem,
})
local problemBody = label({
	Name = "Body",
	Position = UDim2.fromOffset(24, 52),
	Size = UDim2.new(1, -48, 0, 60),
	TextSize = 21,
	Parent = problem,
})
local buttonRow = make("Frame", {
	Name = "Buttons",
	BackgroundTransparency = 1,
	AnchorPoint = Vector2.new(0.5, 1),
	Position = UDim2.new(0.5, 0, 1, -14),
	Size = UDim2.new(1, -40, 0, 74),
	Parent = problem,
}, {
	make("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		Padding = UDim.new(0, 16),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}),
})

local function button(text: string, color: Color3, order: number): TextButton
	local b = make("TextButton", {
		Name = "Button",
		Size = UDim2.fromOffset(240, 68),
		BackgroundColor3 = color,
		Text = text,
		TextColor3 = INK,
		FontFace = FONT_HEADING,
		TextSize = 28,
		AutoButtonColor = true,
		LayoutOrder = order,
		Selectable = true,
		Parent = buttonRow,
	}, { corner(UDim.new(0, 16)), stroke(SHADOW, 3) })
	return b
end
local retryButton = button("Retry", GOLD, 1)
local continueButton = button("Continue", Color3.fromRGB(150, 210, 255), 2)

-- Responsive scale ----------------------------------------------------------------------------------------------------

local function fit()
	local camera = Workspace.CurrentCamera
	local size = if camera then camera.ViewportSize else Vector2.new(1280, 720)
	local s = math.min(size.X / 1100, size.Y / 680)
	centerScale.Scale = math.clamp(s, 0.45, 1.6)
end
fit()
local fitConnection: RBXScriptConnection? = nil
if Workspace.CurrentCamera then
	fitConnection = (Workspace.CurrentCamera :: Camera):GetPropertyChangedSignal("ViewportSize"):Connect(fit)
end

-- Animation ---------------------------------------------------------------------------------------------------------------

local progress = 0.04
local targetProgress = 0.08
local animTime = 0
local renderConnection = RunService.RenderStepped:Connect(function(dt: number)
	animTime += dt
	progress += (targetProgress - progress) * math.min(1, dt * 3)
	barFill.Size = UDim2.fromScale(math.clamp(progress, 0.04, 1), 1)
	shimmer.Position = UDim2.fromScale((animTime * 0.6) % 1.4 - 0.2, 0)
	if not reducedMotion then
		emblem.Position = UDim2.fromOffset(500, 20 + math.sin(animTime * 2.2) * 6)
		emblem.Rotation = math.sin(animTime * 1.3) * 3
		pattern.Position = UDim2.fromOffset(-120 + (animTime * 8) % 60, -120 + (animTime * 5) % 60)
		doorGlow.BackgroundColor3 = GOLD_LIGHT:Lerp(GOLD, (math.sin(animTime * 3) + 1) / 2)
	end
end)

TweenService:Create(logoScale, TweenInfo.new(0.7, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 })
	:Play()

-- Tips ----------------------------------------------------------------------------------------------------------------------

local tipIndex = math.random(1, 6)
local tipsRunning = true
task.spawn(function()
	while tipsRunning do
		tipIndex = tipIndex % 6 + 1
		tip.TextTransparency = 1
		tip.Text = t("loading.tip" .. tipIndex, "")
		TweenService:Create(tip, TweenInfo.new(0.4), { TextTransparency = 0 }):Play()
		task.wait(4.2)
		if not tipsRunning then
			break
		end
		TweenService:Create(tip, TweenInfo.new(0.3), { TextTransparency = 1 }):Play()
		task.wait(0.32)
	end
end)

-- Status tracking -----------------------------------------------------------------------------------------------------------

local profileStatus = "Loading"
local dismissed = false
local patchConnection: RBXScriptConnection? = nil

local function setStatus(key: string, fallback: string, value: number)
	status.Text = t(key, fallback)
	targetProgress = math.max(targetProgress, value)
end

local function finish()
	if dismissed then
		return
	end
	dismissed = true
	tipsRunning = false
	local wait = MIN_SECONDS - (os.clock() - startedAt)
	if wait > 0 then
		task.wait(wait)
	end
	targetProgress = 1
	setStatus("loading.ready", "Welcome!", 1)
	task.wait(0.45)
	local info = TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	for _, d in gui:GetDescendants() do
		if d:IsA("Frame") then
			TweenService:Create(d, info, { BackgroundTransparency = 1 }):Play()
		elseif d:IsA("TextLabel") or d:IsA("TextButton") then
			TweenService:Create(d, info, { TextTransparency = 1, BackgroundTransparency = 1 }):Play()
		elseif d:IsA("UIStroke") then
			TweenService:Create(d, info, { Transparency = 1 }):Play()
		end
	end
	TweenService:Create(centerScale, info, { Scale = centerScale.Scale * 1.12 }):Play()
	task.wait(0.65)
	renderConnection:Disconnect()
	if fitConnection then
		fitConnection:Disconnect()
	end
	if patchConnection then
		patchConnection:Disconnect()
		patchConnection = nil
	end
	gui:Destroy()
	player:SetAttribute("RN_LoadingDone", true)
end

local function showProblem(kind: string)
	problem.Visible = true
	barBack.Visible = false
	tip.Visible = false
	status.Visible = false
	if kind == "Failed" then
		problemTitle.Text = t("loading.failed", "We couldn't open your save.")
		problemBody.Text = t("loading.failedBody", "Your progress is safe - nothing was overwritten.")
		problemTitle.TextColor3 = RED:Lerp(CREAM, 0.3)
		retryButton.Visible = true
	elseif kind == "Newer" then
		problemTitle.Text = t("loading.newerTitle", "Please rejoin")
		problemBody.Text = t("loading.newer", "Your save comes from a newer version of the game.")
		retryButton.Visible = false
	else
		problemTitle.Text = t("loading.slow", "Still checking you in...")
		problemBody.Text = t("loading.slowBody", "This is taking longer than usual.")
		retryButton.Visible = false
	end
	retryButton.Text = t("loading.retry", "Retry")
	continueButton.Text = t("loading.continue", "Continue")
end

local function hideProblem()
	problem.Visible = false
	barBack.Visible = true
	tip.Visible = true
	status.Visible = true
end

continueButton.Activated:Connect(function()
	task.spawn(finish)
end)

local function evaluate()
	if dismissed then
		return
	end
	if profileStatus == "Ready" then
		hideProblem()
		task.spawn(finish)
	elseif profileStatus == "Failed" or profileStatus == "Newer" then
		showProblem(profileStatus)
	end
end

task.spawn(function()
	if not game:IsLoaded() then
		game.Loaded:Wait()
	end
	setStatus("loading.world", "Unfolding the hotel", 0.35)

	local shared = ReplicatedStorage:WaitForChild("Shared", 20)
	if shared then
		local config = shared:FindFirstChild("Config")
		local module = config and config:FindFirstChild("Strings")
		if module and module:IsA("ModuleScript") then
			local ok, result = pcall(require, module)
			if ok then
				Strings = result
				tagline.Text = t("brand.tagline", tagline.Text)
				setStatus("loading.world", "Unfolding the hotel", 0.45)
			end
		end
	end

	local remotes = ReplicatedStorage:WaitForChild("RoomnappedRemotes", 30)
	if not remotes then
		showProblem("Slow")
		return
	end
	setStatus("loading.profile", "Fetching your luggage", 0.6)
	local patch = remotes:WaitForChild("StatePatch", 10)
	if patch and patch:IsA("RemoteEvent") then
		patchConnection = patch.OnClientEvent:Connect(function(channel: any, _seq: any, patches: any)
			if channel ~= "me" or type(patches) ~= "table" then
				return
			end
			for _, p in patches do
				local path = if type(p) == "table" then p.p else nil
				if type(path) == "table" and path[1] == "profile" then
					if #path == 1 and type(p.v) == "table" and type(p.v.status) == "string" then
						profileStatus = p.v.status
					elseif path[2] == "status" and type(p.v) == "string" then
						profileStatus = p.v
					end
				end
			end
			evaluate()
		end)
	end
	local retry = remotes:WaitForChild("RetryProfile", 10)
	retryButton.Activated:Connect(function()
		if retry and retry:IsA("RemoteEvent") then
			retry:FireServer()
		end
		profileStatus = "Loading"
		hideProblem()
		setStatus("loading.profile", "Fetching your luggage", 0.6)
	end)
	local snapshotRemote = remotes:WaitForChild("GetSnapshot", 10)
	if snapshotRemote and snapshotRemote:IsA("RemoteFunction") then
		local ok, snapshot = pcall(function()
			return snapshotRemote:InvokeServer()
		end)
		if ok and type(snapshot) == "table" then
			local me = snapshot.me
			local profile = if type(me) == "table" and type(me.data) == "table" then me.data.profile else nil
			if type(profile) == "table" and type(profile.status) == "string" then
				profileStatus = profile.status
			end
		end
	end
	targetProgress = math.max(targetProgress, 0.8)
	evaluate()
	-- Never block forever.
	task.delay(math.max(0, SLOW_SECONDS - (os.clock() - startedAt)), function()
		if not dismissed and profileStatus ~= "Failed" and profileStatus ~= "Newer" then
			showProblem("Slow")
		end
	end)
end)
