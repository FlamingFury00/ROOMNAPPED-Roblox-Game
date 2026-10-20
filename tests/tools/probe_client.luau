-- Diagnostic: boot server + client, launch the tutorial and print client-side state.
local Sim = require("../harness/Sim")
local ClientSim = require("../harness/ClientSim")
local sim = Sim.new("build/test.rbxl")
sim:startServer()
sim:run(0.3)
local bot = sim:addBot("Alice", 1001)
sim:snapshot(bot)
local client = ClientSim.attach(sim, bot)
client:start()
sim:run(1)
print("profile", sim:state(bot, "me", "profile.status"))
local ClientState = client:module("Core.ClientState")
print(
	"client state ready",
	ClientState.isReady(),
	"client profile",
	ClientState.get("me", "profile.status"),
	"phase",
	ClientState.get("global", "run.phase")
)
local originalToServer = client.toServer
client.toServer = function(self, remote, ...)
	print("-> server", remote.Name, ...)
	return originalToServer(self, remote, ...)
end
local Components = client:module("UI.Components")
local button = client:find("PlayButton")
print("button", button, button and button.ClassName)
client:click(button)
sim:run(0.3)
print(
	"ready",
	sim:state(bot, "global", "players.1001.ready"),
	"lobby",
	sim:state(bot, "global", "lobby.countdownEndsAt")
)
local ServerNet = sim:module("ReplicatedStorage.Shared.Net.Net")
print("server rejected", ServerNet.rejected)
local remote = sim.game.ReplicatedStorage.RoomnappedRemotes.SetReady
local remote2 = sim.game.ReplicatedStorage.RoomnappedRemotes.SetReady
print("same userdata", remote == remote2, rawequal(remote, remote2))
sim:send(bot, "SetReady", true)
sim:run(0.3)
print("ready after sim:send", sim:state(bot, "global", "players.1001.ready"))
for _, m in bot.inbox do
	print("inbox", m.name, m.args[1], m.args[2])
end
for _, entry in client.sentLog or {} do
	print(entry)
end
sim:runUntil(function()
	return sim:state(bot, "global", "run.phase") == "Explore"
end, 30)
sim:run(2)
print("phase", sim:state(bot, "global", "run.phase"))
local RunInfo = client:module("Core.RunInfo")
print("client phase", RunInfo.phase(), "participant", RunInfo.isParticipant(), "level", RunInfo.level() ~= nil)
print("level model", RunInfo.levelModel())
for _, c in sim.workspace:GetChildren() do
	print(" ws child", c.Name, c.ClassName)
end
print("caretaker state", sim:state(bot, "global", "caretaker.mode"))
for _, e in sim.errors do
	print("ERROR", e)
end
for _, w in sim.warnings do
	print("WARN", w)
end
