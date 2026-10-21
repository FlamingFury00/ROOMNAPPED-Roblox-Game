--!strict
--[[
	ROOMNAPPED server bootstrap (S01).

	Services live in Services/ and are initialised in dependency order: Init() registers each service and
	builds static content without yielding; Start() connects events and may spawn loops. Adding a room or a
	mission is a config change - no service needs editing.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage.Shared.Net.Net)
local Log = require(ReplicatedStorage.Shared.Util.Log)
local StateServer = require(script.Core.StateServer)

local log = Log.new("Server")

local ORDER = {
	"FlagsService",
	"TelemetryService",
	"ProfileService",
	"CharacterService",
	"AssetLibraryService",
	"LobbyService",
	"SessionService",
	"ExpeditionService",
	"EffectService",
	"RoomService",
	"HazardService",
	"HealthService",
	"CargoService",
	"CaptureService",
	"CaretakerService",
	"InteractionService",
	"RewardService",
	"PingService",
	"DebugService",
}

Net.initServer()
StateServer.start()

local services = {}
for _, name in ORDER do
	local module = script.Services:FindFirstChild(name)
	assert(module and module:IsA("ModuleScript"), "Missing service " .. name)
	local service = (require :: any)(module)
	services[name] = service
end

for _, name in ORDER do
	local service = services[name]
	if service.Init then
		service.Init()
	end
end

for _, name in ORDER do
	local service = services[name]
	if service.Start then
		local ok, problem = pcall(service.Start)
		if not ok then
			warn("[Server] " .. name .. ".Start failed: " .. tostring(problem))
		end
	end
end

log:Info("ROOMNAPPED server ready")
