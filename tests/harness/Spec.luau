--[[
	Minimal BDD-style test framework used by the Lune test runner.

	describe(name, fn) / it(name, fn) register tests; expect(value) returns matchers that raise on failure.
]]

local Spec = {}

type TestCase = { name: string, fn: () -> () }
type Suite = { name: string, tests: { TestCase }, beforeEach: { () -> () } }

local suites: { Suite } = {}
local current: Suite? = nil

function Spec.describe(name: string, fn: () -> ())
	local suite: Suite = { name = name, tests = {}, beforeEach = {} }
	table.insert(suites, suite)
	local previous = current
	current = suite
	fn()
	current = previous
end

function Spec.it(name: string, fn: () -> ())
	assert(current, "it() must be called inside describe()")
	table.insert(current.tests, { name = name, fn = fn })
end

function Spec.beforeEach(fn: () -> ())
	assert(current, "beforeEach() must be called inside describe()")
	table.insert(current.beforeEach, fn)
end

local function show(value: any): string
	if type(value) == "string" then
		return string.format("%q", value)
	elseif type(value) == "table" then
		local parts = {}
		local count = 0
		for k, v in value do
			count += 1
			if count > 12 then
				table.insert(parts, "...")
				break
			end
			table.insert(parts, tostring(k) .. "=" .. (type(v) == "table" and "{...}" or tostring(v)))
		end
		return "{" .. table.concat(parts, ", ") .. "}"
	end
	return tostring(value)
end

local function deepEqual(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for k, v in a do
		if not deepEqual(v, b[k]) then
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
Spec.deepEqual = deepEqual

function Spec.expect(actual: any)
	local matchers = {}
	function matchers.toBe(expected: any)
		if actual ~= expected then
			error(string.format("expected %s to be %s", show(actual), show(expected)), 2)
		end
	end
	function matchers.toEqual(expected: any)
		if not deepEqual(actual, expected) then
			error(string.format("expected %s to deep-equal %s", show(actual), show(expected)), 2)
		end
	end
	function matchers.toBeTruthy()
		if not actual then
			error(string.format("expected %s to be truthy", show(actual)), 2)
		end
	end
	function matchers.toBeFalsy()
		if actual then
			error(string.format("expected %s to be falsy", show(actual)), 2)
		end
	end
	function matchers.toBeNil()
		if actual ~= nil then
			error(string.format("expected %s to be nil", show(actual)), 2)
		end
	end
	function matchers.toBeNear(expected: number, epsilon: number?)
		local eps = epsilon or 1e-6
		if type(actual) ~= "number" or math.abs(actual - expected) > eps then
			error(string.format("expected %s to be within %s of %s", show(actual), tostring(eps), show(expected)), 2)
		end
	end
	function matchers.toBeGreaterThan(expected: number)
		if not (actual > expected) then
			error(string.format("expected %s > %s", show(actual), show(expected)), 2)
		end
	end
	function matchers.toBeLessThan(expected: number)
		if not (actual < expected) then
			error(string.format("expected %s < %s", show(actual), show(expected)), 2)
		end
	end
	function matchers.toContain(expected: any)
		local found = false
		if type(actual) == "string" then
			found = string.find(actual, expected, 1, true) ~= nil
		elseif type(actual) == "table" then
			for _, v in actual do
				if deepEqual(v, expected) then
					found = true
					break
				end
			end
		end
		if not found then
			error(string.format("expected %s to contain %s", show(actual), show(expected)), 2)
		end
	end
	function matchers.toThrow(fragment: string?)
		local ok, err = pcall(actual)
		if ok then
			error("expected function to throw", 2)
		end
		if fragment and not string.find(tostring(err), fragment, 1, true) then
			error(string.format("expected error containing %q, got %s", fragment, tostring(err)), 2)
		end
	end
	return matchers
end

function Spec.run(filter: string?): (number, number)
	local passed, failed = 0, 0
	for _, suite in suites do
		for _, test in suite.tests do
			local label = suite.name .. " > " .. test.name
			if filter == nil or string.find(label, filter, 1, true) then
				local ok, err = pcall(function()
					for _, hook in suite.beforeEach do
						hook()
					end
					test.fn()
				end)
				if ok then
					passed += 1
				else
					failed += 1
					print("  FAIL  " .. label .. "\n        " .. tostring(err))
				end
			end
		end
	end
	return passed, failed
end

function Spec.reset()
	table.clear(suites)
	current = nil
end

return Spec
