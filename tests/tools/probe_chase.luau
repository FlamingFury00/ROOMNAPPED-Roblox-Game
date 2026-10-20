-- Diagnostic: tutorial capture with the client attached, then inspect caretaker values.
local Sim = require("../harness/Sim")
local ClientSim = require("../harness/ClientSim")
local roblox = require("@lune/roblox")
local V3 = roblox.Vector3
local sim = Sim.new("build/test.rbxl")
sim:startServer()
sim:run(0.3)
local bot = sim:addBot("Alice", 1001)
sim:snapshot(bot)
local client = ClientSim.attach(sim, bot)
client:start()
sim:run(1)
client:click(client:find("PlayButton"))
sim:runUntil(function()
	return sim:state(bot, "global", "run.phase") == "Explore"
end, 30)
sim:run(1)
local level = sim:state(bot, "global", "level")
sim:send(bot, "Debug", "tp", "target")
sim:run(0.5)
client:press("RN_Use")
sim:run(3.4)
client:release("RN_Use")
local Caretaker = client:module("Controllers.CaretakerView")
for i = 1, 20 do
	sim:run(0.25)
	local p = Caretaker.position()
	local cam = client.camera.CFrame
	local ok, screen, on = pcall(function()
		return client.camera:WorldToViewportPoint(p or V3.zero)
	end)
	print(
		string.format(
			"i=%d phase=%s mode=%s ctpos=%s screen=%s cam=%s",
			i,
			tostring(sim:state(bot, "global", "run.phase")),
			Caretaker.mode(),
			tostring(p),
			tostring(screen),
			tostring(cam.Position)
		)
	)
end
print("errors", #sim.errors)
print(sim.errors[1])
