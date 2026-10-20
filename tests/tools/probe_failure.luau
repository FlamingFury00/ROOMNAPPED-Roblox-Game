-- Diagnostic: run the "stand still after capture" scenario and summarise what happened.
local Sim = require("../harness/Sim")
local sim = Sim.new("build/test.rbxl")
sim:startServer()
sim:run(0.3)
local bot = sim:addBot("Bob", 1001)
sim:snapshot(bot)
sim:run(0.6)
sim:send(bot, "SetReady", true)
sim:runUntil(function()
	return sim:state(bot, "global", "run.phase") == "Explore"
end, 30)
sim:send(bot, "Debug", "tp", "target")
sim:run(0.3)
sim:send(bot, "HoldBegin", "capture", "target")
sim:run(3.05)
sim:send(bot, "HoldEnd", "capture", "target", true)
local modes = {}
local lastMode = nil
local t0 = sim.time
while sim:state(bot, "global", "run.phase") ~= "Results" and sim.time - t0 < 140 do
	sim:run(0.1)
	local mode = sim:state(bot, "global", "caretaker.mode")
	if mode ~= lastMode then
		table.insert(modes, string.format("%.1f:%s", sim.time - t0, tostring(mode)))
		lastMode = mode
	end
end
print("outcome", sim:state(bot, "global", "run.outcome"), "after", math.floor(sim.time - t0), "s")
print("caretaker modes:", table.concat(modes, " "))
local effects = {}
for _, m in bot.inbox do
	if m.name == "Effect" then
		effects[m.args[1]] = (effects[m.args[1]] or 0) + 1
	end
end
for k, v in effects do
	print("effect", k, v)
end
print("warnings:", #sim.warnings)
for i = 1, math.min(10, #sim.warnings) do
	print("  ", sim.warnings[i])
end
print("errors:", #sim.errors)
