--!strict
--[[
	Tagged logger. Debug output is only printed in Studio or when verbose logging is enabled.
]]

local RunService = game:GetService("RunService")

local Log = {}
Log.__index = Log

export type Logger = typeof(setmetatable({} :: { tag: string }, Log))

local verbose = false
local okStudio, isStudio = pcall(function()
	return RunService:IsStudio()
end)
if okStudio and isStudio then
	verbose = true
end

function Log.setVerbose(enabled: boolean)
	verbose = enabled
end

function Log.new(tag: string): Logger
	return setmetatable({ tag = tag }, Log)
end

function Log.Info(self: Logger, ...: any)
	print("[" .. self.tag .. "]", ...)
end

function Log.Debug(self: Logger, ...: any)
	if verbose then
		print("[" .. self.tag .. ":debug]", ...)
	end
end

function Log.Warn(self: Logger, ...: any)
	warn("[" .. self.tag .. "]", ...)
end

return Log
