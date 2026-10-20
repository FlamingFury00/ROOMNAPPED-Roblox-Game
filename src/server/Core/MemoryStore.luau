--!strict
--[[
	MemoryStore: in-process stand-in for a DataStore with the same UpdateAsync/GetAsync contract.

	Used automatically when DataStores are unavailable (Studio without API access, unpublished place) so the
	exact same profile code path runs everywhere, and by the headless tests (with fault injection).
]]

local Tables = require(game:GetService("ReplicatedStorage").Shared.Util.Tables)

local MemoryStore = {}
MemoryStore.__index = MemoryStore

export type MemoryStore = typeof(setmetatable(
	{} :: {
		data: { [string]: any },
		failNext: number,
		calls: number,
	},
	MemoryStore
))

function MemoryStore.new(): MemoryStore
	return setmetatable({ data = {}, failNext = 0, calls = 0 }, MemoryStore)
end

-- Make the next `count` calls raise an error (simulates DataStore outages in tests).
function MemoryStore.injectFailures(self: MemoryStore, count: number)
	self.failNext = count
end

function MemoryStore.UpdateAsync(self: MemoryStore, key: string, transform: (any, any) -> ...any): any
	self.calls += 1
	if self.failNext > 0 then
		self.failNext -= 1
		error("MemoryStore: injected failure")
	end
	local current = Tables.deepCopy(self.data[key])
	local result = transform(current, nil)
	if result == nil then
		return Tables.deepCopy(self.data[key])
	end
	self.data[key] = Tables.deepCopy(result)
	return Tables.deepCopy(result)
end

function MemoryStore.GetAsync(self: MemoryStore, key: string): any
	self.calls += 1
	if self.failNext > 0 then
		self.failNext -= 1
		error("MemoryStore: injected failure")
	end
	return Tables.deepCopy(self.data[key])
end

function MemoryStore.SetAsync(self: MemoryStore, key: string, value: any)
	self.calls += 1
	self.data[key] = Tables.deepCopy(value)
end

return MemoryStore
