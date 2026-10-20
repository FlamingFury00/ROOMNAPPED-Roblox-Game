--!strict
--[[
	RunMachine: the expedition state machine (S02).

	Prep -> Launching -> Explore -> Capture -> Escape -> Results -> Prep

	Launching covers the elevator ride while the level is assembled. Explore, Capture and Escape may
	short-circuit to Results on failure (team wipe, abandoned run, expired escape window). Results always
	returns to a clean Prep, so success, failure and retry share one exit path.
]]

export type Phase = "Prep" | "Launching" | "Explore" | "Capture" | "Escape" | "Results"
export type Outcome = "Success" | "Wiped" | "TimeUp" | "Abandoned"

local TRANSITIONS: { [string]: { [string]: boolean } } = {
	Prep = { Launching = true },
	Launching = { Explore = true, Results = true },
	Explore = { Capture = true, Results = true },
	Capture = { Escape = true, Results = true },
	Escape = { Results = true },
	Results = { Prep = true },
}

local IN_RUN: { [string]: boolean } = { Launching = true, Explore = true, Capture = true, Escape = true }

local RunMachine = {}
RunMachine.__index = RunMachine

export type Machine = typeof(setmetatable(
	{} :: {
		phase: Phase,
		enteredAt: number,
		history: { { phase: Phase, at: number } },
		outcome: Outcome?,
	},
	RunMachine
))

function RunMachine.new(now: number?): Machine
	local t = now or 0
	return setmetatable({
		phase = "Prep" :: Phase,
		enteredAt = t,
		history = { { phase = "Prep" :: Phase, at = t } },
		outcome = nil,
	}, RunMachine)
end

function RunMachine.canTransition(self: Machine, to: Phase): boolean
	local allowed = TRANSITIONS[self.phase]
	return allowed ~= nil and allowed[to] == true
end

function RunMachine.transition(self: Machine, to: Phase, now: number, outcome: Outcome?): boolean
	if not self:canTransition(to) then
		return false
	end
	self.phase = to
	self.enteredAt = now
	if to == "Results" then
		self.outcome = outcome or "Abandoned"
	elseif to == "Prep" then
		self.outcome = nil
	end
	table.insert(self.history, { phase = to, at = now })
	if #self.history > 32 then
		table.remove(self.history, 1)
	end
	return true
end

function RunMachine.inRun(self: Machine): boolean
	return IN_RUN[self.phase] == true
end

function RunMachine.isPhaseInRun(phase: string): boolean
	return IN_RUN[phase] == true
end

function RunMachine.allowed(from: string, to: string): boolean
	local allowed = TRANSITIONS[from]
	return allowed ~= nil and allowed[to] == true
end

return RunMachine
