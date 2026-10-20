--!strict
--[[
	Attach: weld cosmetic models (suitcases) to a character's hand without affecting its physics.
]]

local Attach = {}

function Attach.hand(character: Model): BasePart?
	local hand = character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm")
	if hand and hand:IsA("BasePart") then
		return hand
	end
	return nil
end

-- Weld `model` (PrimaryPart = grip) below the character's right hand. Returns false if no hand exists.
function Attach.toHand(character: Model, model: Model, offset: CFrame?): boolean
	local hand = Attach.hand(character)
	local grip = model.PrimaryPart
	if not hand or not grip then
		return false
	end
	local target = hand.CFrame * CFrame.new(0, -hand.Size.Y / 2 - 0.1, 0) * (offset or CFrame.Angles(0, math.pi / 2, 0))
	model:PivotTo(target)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Massless = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.CastShadow = true
			if d ~= grip then
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = grip
				weld.Part1 = d
				weld.Parent = d
			end
		end
	end
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = hand
	weld.Part1 = grip
	weld.Parent = grip
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = false
		end
	end
	model.Parent = character
	return true
end

-- Place a model on the floor at `cf` (anchored, non-colliding decoration that stays put).
function Attach.place(model: Model, cf: CFrame)
	model:PivotTo(cf)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.Massless = true
		elseif d:IsA("WeldConstraint") then
			d:Destroy()
		end
	end
end

return Attach
