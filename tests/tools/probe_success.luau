-- Diagnostic: scripted tutorial run; reports pacing and caretaker pressure during the escape.
local Sim = require("../harness/Sim")
local roblox = require("@lune/roblox")
local V3 = roblox.Vector3
local sim = Sim.new("build/test.rbxl")
sim:startServer()
sim:run(0.3)
local bot = sim:addBot("Alice", 1001)
sim:snapshot(bot)
sim:run(0.6)
sim:send(bot, "SetReady", true)
sim:runUntil(function()
	return sim:state(bot, "global", "run.phase") == "Explore"
end, 30)
local level = sim:state(bot, "global", "level")
local function tileAt(p)
	local best, bd = 1, math.huge
	for i, t in level.tiles do
		local d = (t.cf.Position - p).Magnitude
		if d < bd then
			best, bd = i, d
		end
	end
	return best
end
local function route(toIndex)
	local from = tileAt(sim:position(bot))
	local pts = {}
	local step = if toIndex >= from then 1 else -1
	for i = from, toIndex, step do
		table.insert(pts, level.tiles[i].cf.Position + V3.new(0, 3, 0))
	end
	return pts
end
local exploreStart = sim.time
local s1 = level.sockets.S1.interactPoint
local p = route(tileAt(s1))
table.insert(p, s1)
sim:walk(bot, p)
sim:runUntil(function()
	return #bot.path == 0
end, 20)
sim:send(bot, "RequestDeploy", "S1", 1)
sim:run(1.5)
local target = level.target.capturePoint
p = route(tileAt(target))
table.insert(p, target)
sim:walk(bot, p)
sim:runUntil(function()
	return #bot.path == 0
end, 30)
sim:send(bot, "HoldBegin", "capture", "target")
sim:run(3.05)
sim:send(bot, "HoldEnd", "capture", "target", true)
sim:runUntil(function()
	return sim:state(bot, "global", "run.phase") == "Escape"
end, 5)
local escapeStart = sim.time
p = route(1)
table.insert(p, level.exit.cf.Position)
sim:walk(bot, p)
local minDist = math.huge
local Registry = sim:module("ServerScriptService.Server.Core.Registry")
while sim:state(bot, "global", "run.phase") ~= "Results" and sim.time - escapeStart < 95 do
	sim:run(0.1)
	local run = Registry.get("Expedition").current()
	if run then
		local cp = Registry.get("Caretaker").position(run)
		local bp = sim:position(bot)
		if cp and bp then
			minDist = math.min(minDist, (cp - bp).Magnitude)
		end
	end
end
print("outcome", sim:state(bot, "global", "run.outcome"))
print(
	string.format(
		"explore %.1fs, escape %.1fs, min caretaker distance %.1f studs",
		escapeStart - exploreStart,
		sim.time - escapeStart,
		minDist
	)
)
print(
	"hearts",
	sim:state(bot, "global", "roster.1001.hearts"),
	"combos",
	table.concat(sim:state(bot, "global", "run.combos") or {}, ",")
)
sim:run(4)
local results = sim:state(bot, "me", "results")
print("saving", results and results.saving, "credits", sim:state(bot, "me", "profile.credits"))
if results and results.plan then
	for _, line in results.plan.lines do
		print("  reward line", line.key, line.amount, line.item)
	end
end
print("errors", #sim.errors)
