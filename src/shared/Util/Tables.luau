--!strict
--[[
	Table helpers shared by server and client.
]]

local Tables = {}

function Tables.deepCopy<T>(value: T): T
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for k, v in value :: any do
		copy[Tables.deepCopy(k)] = Tables.deepCopy(v)
	end
	return (copy :: any) :: T
end

-- Fill in keys missing from `target` using `template`, recursively. Existing values are kept.
-- Values whose type disagrees with the template are replaced by the template value.
function Tables.reconcile(target: { [any]: any }, template: { [any]: any }): { [any]: any }
	for key, templateValue in template do
		local current = target[key]
		if current == nil then
			target[key] = Tables.deepCopy(templateValue)
		elseif type(templateValue) == "table" then
			if type(current) ~= "table" then
				target[key] = Tables.deepCopy(templateValue)
			else
				Tables.reconcile(current, templateValue)
			end
		elseif type(current) ~= type(templateValue) then
			target[key] = templateValue
		end
	end
	return target
end

function Tables.count(t: { [any]: any }): number
	local n = 0
	for _ in t do
		n += 1
	end
	return n
end

function Tables.keys(t: { [any]: any }): { any }
	local out = {}
	for k in t do
		table.insert(out, k)
	end
	table.sort(out, function(a, b)
		return tostring(a) < tostring(b)
	end)
	return out
end

function Tables.deepEqual(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for k, v in a do
		if not Tables.deepEqual(v, b[k]) then
			return false
		end
	end
	for k in b do
		if a[k] == nil then
			return false
		end
	end
	return true
end

function Tables.shallowMerge(...: { [any]: any }?): { [any]: any }
	local out = {}
	for i = 1, select("#", ...) do
		local t = select(i, ...)
		if t then
			for k, v in t do
				out[k] = v
			end
		end
	end
	return out
end

function Tables.map<T, U>(list: { T }, fn: (T, number) -> U): { U }
	local out = table.create(#list)
	for i, v in list do
		out[i] = fn(v, i)
	end
	return out
end

function Tables.filter<T>(list: { T }, fn: (T) -> boolean): { T }
	local out = {}
	for _, v in list do
		if fn(v) then
			table.insert(out, v)
		end
	end
	return out
end

function Tables.contains(list: { any }, value: any): boolean
	return table.find(list, value) ~= nil
end

-- Recursively freeze a definition table so content data cannot be mutated at runtime.
function Tables.deepFreeze<T>(value: T): T
	if type(value) == "table" and not table.isfrozen(value :: any) then
		for _, v in value :: any do
			Tables.deepFreeze(v)
		end
		table.freeze(value :: any)
	end
	return value
end

return Tables
