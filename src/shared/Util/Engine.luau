--!strict
--[[
	Engine: the few engine-computed values gameplay code reads, behind one seam.

	In Roblox these are plain property reads. The headless simulation (tests/harness) replaces this module
	with deterministic implementations, which lets the full server run without the Roblox engine.
]]

local Engine = {}

function Engine.velocity(part: BasePart): Vector3
	return part.AssemblyLinearVelocity
end

function Engine.placeId(): number
	return game.PlaceId
end

function Engine.jobId(): string
	return game.JobId
end

-- Zero an assembly's motion (used before teleports).
function Engine.stop(part: BasePart)
	part.AssemblyLinearVelocity = Vector3.zero
	part.AssemblyAngularVelocity = Vector3.zero
end

return Engine
