--!strict
--[[
	Assets: real models for props, with procedural fallbacks (A01, A10).

	Builders ask for a prop by key: Assets.place(parent, key, cf, fallback) creates a slot Model named
	"Prop_<key>" around `cf` and fills it with a clone of the curated Creator Store model when the asset
	library has one (normalised templates in ReplicatedStorage.RN_Assets, loaded by the server's
	AssetLibraryService), or else with the procedural fallback. Slots are tagged RN_AssetSlot, so a model that
	arrives after its slot was built (the lobby is built before any model has loaded) replaces the fallback in
	place: Assets.upgrade(key).

	Mount conventions (the slot's `cf` is its pivot; the model's front faces cf.LookVector):
	  floor   - pivot at the bottom centre
	  wall    - pivot at the centre of the model's back, flat against the wall
	  ceiling - pivot at the top centre
	  centre  - pivot at the middle (floating pickups)

	A slot's pivot is its WorldPivot: a slot the client moves (a spinning key) is refilled where it is now.

	Without the library (offline tests, a server that could not load a model, the `assets` flag off) every
	slot simply keeps its fallback, so the world is always complete. Switching the library off live puts the
	fallbacks back: Assets.revert(key).
]]

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Assets = {}

Assets.TAG = "RN_AssetSlot"
Assets.FOLDER = "RN_Assets"

export type Fallback = (slot: Model, cf: CFrame) -> ()

export type PlaceOptions = {
	variant: number?, -- which variant of the key (wraps around); defaults to the first
	scale: number?, -- extra uniform scale on top of the template's normalised size
}

local enabled = true

-- Each slot's fallback, to put back if the library is switched off (weak: slots come and go with levels).
local fallbacks: { [Model]: Fallback } = setmetatable({}, { __mode = "k" }) :: any

-- Switch real models off (the `assets` live flag): slots keep or get their fallbacks.
function Assets.setEnabled(value: boolean)
	enabled = value
end

local function folder(): Instance?
	return ReplicatedStorage:FindFirstChild(Assets.FOLDER)
end

-- Normalised template models for a key (variants in name order), or an empty list.
function Assets.variants(key: string): { Model }
	if not enabled then
		return {}
	end
	local root = folder()
	local holder = root and root:FindFirstChild(key)
	if not holder then
		return {}
	end
	local list: { Model } = {}
	for _, child in holder:GetChildren() do
		if child:IsA("Model") then
			table.insert(list, child)
		end
	end
	table.sort(list, function(a, b)
		return a.Name < b.Name
	end)
	return list
end

function Assets.has(key: string): boolean
	return #Assets.variants(key) > 0
end

local function pick(key: string, variant: number?): Model?
	local list = Assets.variants(key)
	if #list == 0 then
		return nil
	end
	local index = ((math.max(1, variant or 1) - 1) % #list) + 1
	return list[index]
end

-- Fill a slot with a clone of its template (replacing whatever it held). Returns false without a template.
function Assets.fill(slot: Model): boolean
	local key = slot:GetAttribute("AssetKey")
	if type(key) ~= "string" or typeof(slot:GetAttribute("SlotCF")) ~= "CFrame" then
		return false
	end
	local cf = slot.WorldPivot
	local variant = slot:GetAttribute("Variant")
	local template = pick(key, if type(variant) == "number" then variant else nil)
	if not template then
		return false
	end
	local model = template:Clone()
	local scale = slot:GetAttribute("Scale")
	if type(scale) == "number" and math.abs(scale - 1) > 1e-3 then
		model:ScaleTo(model:GetScale() * scale)
	end
	model:PivotTo(cf)
	slot:ClearAllChildren()
	model.Parent = slot
	slot:SetAttribute("Asset", true)
	return true
end

-- A prop slot at `cf` holding the real model for `key`, or the fallback until (unless) one arrives.
function Assets.place(parent: Instance, key: string, cf: CFrame, fallback: Fallback?, options: PlaceOptions?): Model
	local opts: PlaceOptions = options or {}
	local slot = Instance.new("Model")
	slot.Name = "Prop_" .. key
	slot:SetAttribute("AssetKey", key)
	slot:SetAttribute("SlotCF", cf)
	slot:SetAttribute("Variant", opts.variant or 1)
	slot:SetAttribute("Scale", opts.scale or 1)
	slot.WorldPivot = cf
	-- Slots a client builds for itself (moving carts, previews) are upgraded by that client only. (Studio's Run
	-- mode is client and server at once: there the server's library fills every slot.)
	local okClient, isLocal = pcall(function()
		return RunService:IsClient() and not RunService:IsServer()
	end)
	if okClient and isLocal then
		slot:SetAttribute("Local", true)
	end
	if fallback then
		fallbacks[slot] = fallback
	end
	if not Assets.fill(slot) then
		slot:SetAttribute("Asset", false)
		if fallback then
			fallback(slot, cf)
		end
	end
	slot:AddTag(Assets.TAG)
	slot.Parent = parent
	return slot
end

-- Replace the fallbacks of every slot for `key` (or every key) that has a template now. The server upgrades
-- the slots it built (they replicate); a client passes `localOnly` to upgrade only the slots it built itself.
function Assets.upgrade(key: string?, localOnly: boolean?): number
	local count = 0
	for _, slot in CollectionService:GetTagged(Assets.TAG) do
		local own = (slot:GetAttribute("Local") == true) == (localOnly == true)
		if own and slot:IsA("Model") and slot:GetAttribute("Asset") ~= true then
			local slotKey = slot:GetAttribute("AssetKey")
			if (key == nil or slotKey == key) and Assets.fill(slot) then
				count += 1
			end
		end
	end
	return count
end

-- Put the fallback back in every slot for `key` (or every key) that holds a real model: the library was
-- switched off. Same ownership rule as upgrade.
function Assets.revert(key: string?, localOnly: boolean?): number
	local count = 0
	for _, slot in CollectionService:GetTagged(Assets.TAG) do
		local own = (slot:GetAttribute("Local") == true) == (localOnly == true)
		if own and slot:IsA("Model") and slot:GetAttribute("Asset") == true then
			if key == nil or slot:GetAttribute("AssetKey") == key then
				slot:ClearAllChildren()
				local fallback = fallbacks[slot]
				if fallback then
					fallback(slot, slot.WorldPivot)
				end
				slot:SetAttribute("Asset", false)
				count += 1
			end
		end
	end
	return count
end

return Assets
