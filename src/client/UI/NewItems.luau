--!strict
--[[
	NewItems: rooms and skins unlocked during this session (a room blueprint from a run, a reward skin, a skin
	bought with credits) stay marked NEW until the player looks at them in the collection, and the Rooms
	button counts how many are waiting. Everything already owned when the profile first loads is old news.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local ClientState = require(script.Parent.Parent.Core.ClientState)

local NewItems = {}
NewItems.Changed = Signal.new()

local started = false
local known: { [string]: boolean }? = nil -- "room:<id>" / "skin:<id>" owned at the last profile update
local fresh: { [string]: boolean } = {}

local function ownedKeys(profile: any): { [string]: boolean }
	local keys = {}
	if type(profile.rooms) == "table" then
		for id, owned in profile.rooms do
			if owned == true then
				keys["room:" .. id] = true
			end
		end
	end
	if type(profile.skins) == "table" and type(profile.skins.owned) == "table" then
		for id, owned in profile.skins.owned do
			if owned == true then
				keys["skin:" .. id] = true
			end
		end
	end
	return keys
end

-- kind: "room" or "skin".
function NewItems.isNew(kind: string, id: string): boolean
	return fresh[kind .. ":" .. id] == true
end

function NewItems.markSeen(kind: string, id: string)
	local key = kind .. ":" .. id
	if fresh[key] then
		fresh[key] = nil
		NewItems.Changed:Fire()
	end
end

-- Ids of the new items of one kind.
function NewItems.list(kind: string): { string }
	local out = {}
	local prefix = kind .. ":"
	for key in fresh do
		if string.sub(key, 1, #prefix) == prefix then
			table.insert(out, string.sub(key, #prefix + 1))
		end
	end
	table.sort(out)
	return out
end

function NewItems.count(): number
	local count = 0
	for _ in fresh do
		count += 1
	end
	return count
end

function NewItems.start()
	if started then
		return
	end
	started = true
	ClientState.observe("me", "profile", function(profile: any)
		if type(profile) ~= "table" or profile.status ~= "Ready" then
			return
		end
		local now = ownedKeys(profile)
		local previous = known
		known = now
		if previous == nil then
			return
		end
		local added = false
		for key in now do
			if not previous[key] then
				fresh[key] = true
				added = true
			end
		end
		if added then
			NewItems.Changed:Fire()
		end
	end)
end

return NewItems
