--[[
	Headless test runner.

	Usage: lune run tests/run.luau <place.rbxl> [filter]
	Every tests/specs/*.spec.luau file returns function(ctx). Each spec file gets a freshly loaded place so
	module state never leaks between files.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")

local Env = require("./harness/Env")
local Spec = require("./harness/Spec")

local placePath = process.args[1] or "build/test.rbxl"
local filter = process.args[2]

local specDir = "tests/specs"
local files = {}
for _, name in fs.readDir(specDir) do
	if string.sub(name, -10) == ".spec.luau" then
		table.insert(files, name)
	end
end
table.sort(files)

local totalPassed, totalFailed = 0, 0
for _, name in files do
	Spec.reset()
	local loaded = Env.load(placePath)
	local ctx = {
		game = loaded.game,
		require = loaded.require,
		env = loaded.env,
		find = function(path: string)
			return Env.find(loaded.game, path)
		end,
		module = function(path: string)
			return loaded.require(Env.find(loaded.game, path))
		end,
		roblox = roblox,
		Spec = Spec,
		placePath = placePath,
	}
	local specFn = (require :: any)("./specs/" .. string.sub(name, 1, -6))
	local ok, err = pcall(specFn, ctx)
	if not ok then
		print("  ERROR loading " .. name .. ": " .. tostring(err))
		totalFailed += 1
	else
		local passed, failed = Spec.run(filter)
		print(string.format("%-40s %3d passed  %3d failed", name, passed, failed))
		totalPassed += passed
		totalFailed += failed
	end
end

print(string.format("\nTOTAL: %d passed, %d failed", totalPassed, totalFailed))
process.exit(if totalFailed > 0 then 1 else 0)
