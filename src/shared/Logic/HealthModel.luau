--!strict
--[[
	HealthModel: hearts, damage grace, downed window, revive and solo self-recovery (S16).

	All functions are pure over a HealthState table and an explicit clock so the rules can be tested
	exhaustively and replayed deterministically.

	Status:
	  Active      - can move and act
	  Downed      - waiting for a teammate revive until downedUntil
	  Recovering  - solo self-recovery in progress (automatic, once per run)
	  Eliminated  - downed window expired; spectating until the run ends
]]

export type Status = "Active" | "Downed" | "Recovering" | "Eliminated"

export type HealthConfig = {
	MaxHearts: number,
	DamageGraceSeconds: number,
	RegenDelaySeconds: number,
	RegenIntervalSeconds: number,
	ReviveHearts: number,
	SelfRecoveryHearts: number,
	DownedWindowSeconds: number,
	SoloRecoveryDelaySeconds: number,
	SelfRecoveries: number,
}

export type HealthState = {
	hearts: number,
	max: number,
	status: Status,
	graceUntil: number,
	lastDamageAt: number,
	nextRegenAt: number,
	downedUntil: number,
	recoverAt: number,
	selfRecoveriesLeft: number,
	solo: boolean,
	downs: number,
}

export type DamageResult = "Ignored" | "Hurt" | "Downed" | "Recovering"
export type UpdateEvent = "Regen" | "Eliminated" | "SelfRecovered"

local HealthModel = {}

function HealthModel.new(config: HealthConfig, solo: boolean, now: number): HealthState
	return {
		hearts = config.MaxHearts,
		max = config.MaxHearts,
		status = "Active",
		graceUntil = now,
		lastDamageAt = -math.huge,
		nextRegenAt = math.huge,
		downedUntil = math.huge,
		recoverAt = math.huge,
		selfRecoveriesLeft = if solo then config.SelfRecoveries else 0,
		solo = solo,
		downs = 0,
	}
end

function HealthModel.canBeDamaged(state: HealthState, now: number): boolean
	return state.status == "Active" and now >= state.graceUntil
end

function HealthModel.damage(config: HealthConfig, state: HealthState, amount: number, now: number): DamageResult
	if not HealthModel.canBeDamaged(state, now) then
		return "Ignored"
	end
	state.hearts = math.max(0, state.hearts - math.max(1, math.floor(amount)))
	state.graceUntil = now + config.DamageGraceSeconds
	state.lastDamageAt = now
	state.nextRegenAt = now + config.RegenDelaySeconds
	if state.hearts > 0 then
		return "Hurt"
	end
	state.downs += 1
	if state.solo and state.selfRecoveriesLeft > 0 then
		state.status = "Recovering"
		state.recoverAt = now + config.SoloRecoveryDelaySeconds
		return "Recovering"
	end
	state.status = "Downed"
	state.downedUntil = now + config.DownedWindowSeconds
	return "Downed"
end

-- Force the player down regardless of hearts (debug tool / unrecoverable hazards).
function HealthModel.forceDown(config: HealthConfig, state: HealthState, now: number): DamageResult
	if state.status ~= "Active" then
		return "Ignored"
	end
	state.graceUntil = now
	state.hearts = 1
	return HealthModel.damage(config, state, 1, now)
end

function HealthModel.canRevive(state: HealthState): boolean
	return state.status == "Downed"
end

function HealthModel.revive(config: HealthConfig, state: HealthState, now: number): boolean
	if state.status ~= "Downed" then
		return false
	end
	state.status = "Active"
	state.hearts = math.min(state.max, config.ReviveHearts)
	state.graceUntil = now + config.DamageGraceSeconds
	state.lastDamageAt = now
	state.nextRegenAt = now + config.RegenDelaySeconds
	state.downedUntil = math.huge
	return true
end

-- Advance timers. Returns the events that happened, in order.
function HealthModel.update(config: HealthConfig, state: HealthState, now: number): { UpdateEvent }
	local events: { UpdateEvent } = {}
	if state.status == "Recovering" then
		if now >= state.recoverAt then
			state.status = "Active"
			state.hearts = math.min(state.max, config.SelfRecoveryHearts)
			state.selfRecoveriesLeft -= 1
			state.recoverAt = math.huge
			state.graceUntil = now + config.DamageGraceSeconds * 2
			state.nextRegenAt = now + config.RegenDelaySeconds
			table.insert(events, "SelfRecovered")
		end
	elseif state.status == "Downed" then
		if now >= state.downedUntil then
			state.status = "Eliminated"
			state.downedUntil = math.huge
			table.insert(events, "Eliminated")
		end
	elseif state.status == "Active" then
		if state.hearts < state.max and now >= state.nextRegenAt then
			state.hearts += 1
			state.nextRegenAt = now + config.RegenIntervalSeconds
			table.insert(events, "Regen")
		end
	end
	return events
end

-- A team is wiped when nobody can still act or come back on their own (S16).
-- Downed players only count as recoverable while at least one teammate is active.
function HealthModel.isTeamWiped(states: { HealthState }): boolean
	if #states == 0 then
		return true
	end
	for _, state in states do
		if state.status == "Active" or state.status == "Recovering" then
			return false
		end
	end
	return true
end

function HealthModel.configFrom(gameConfig: any): HealthConfig
	return {
		MaxHearts = gameConfig.Health.MaxHearts,
		DamageGraceSeconds = gameConfig.Health.DamageGraceSeconds,
		RegenDelaySeconds = gameConfig.Health.RegenDelaySeconds,
		RegenIntervalSeconds = gameConfig.Health.RegenIntervalSeconds,
		ReviveHearts = gameConfig.Health.ReviveHearts,
		SelfRecoveryHearts = gameConfig.Health.SelfRecoveryHearts,
		DownedWindowSeconds = gameConfig.Downed.WindowSeconds,
		SoloRecoveryDelaySeconds = gameConfig.Downed.SoloRecoveryDelaySeconds,
		SelfRecoveries = gameConfig.Solo.SelfRecoveries,
	}
end

return HealthModel
