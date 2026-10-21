-- Diagnostic: a client-side teleport during a run and what the movement guard does with it.
local Sim = require("../harness/Sim")
local roblox = require("@lune/roblox")
local V3 = roblox.Vector3
local sim = Sim.new("build/test.rbxl")
sim:startServer()
sim:run(0.3)
local bot = sim:addBot("Tess", 1001)
sim:snapshot(bot)
sim:run(0.6)
sim:send(bot, "SetReady", true)
sim:runUntil(function()
	return sim:state(bot, "global", "run.phase") == "Explore"
end, 30)
local level = sim:state(bot, "global", "level")
local start = sim:position(bot)
print("start", start, "phase", sim:state(bot, "global", "run.phase"))
local target = level.target.capturePoint
print("target", target)
sim:teleportBot(bot, target + V3.new(0, 3, 0))
for i = 1, 6 do
	sim:run(1 / 60)
	print(i, sim:position(bot))
end
sim:run(0.2)
print("after", sim:position(bot))
for _, e in sim.errors do
	print("ERR", e)
end
