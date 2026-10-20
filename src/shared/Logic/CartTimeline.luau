--!strict
--[[
	CartTimeline: the shared maths for runaway luggage carts (S10 hazards).

	The server never moves a physical cart. It publishes a compact timeline per cart
	{ phase0, t0, rate, pinned, x0, coldMul } and evaluates hits from it; clients render the cart model from
	the same timeline against the synchronised server clock, so what you see is exactly what can hit you.

	A running cart follows a triangle wave across its track ([-range, range]). A Fan blowing across the
	track pins it at one end (`pinned` = +1 / -1): the cart travels from x0 to that end and stays there.
]]

local CartTimeline = {}

export type Timeline = {
	phase0: number,
	t0: number,
	rate: number,
	pinned: number,
	x0: number,
	coldMul: number,
}

local function approach(current: number, target: number, maxDelta: number): number
	if current < target then
		return math.min(current + maxDelta, target)
	end
	return math.max(current - maxDelta, target)
end

-- Lateral offset for a cycle phase (triangle wave in [-range, range]).
function CartTimeline.x(phase: number, range: number): number
	local f = phase - math.floor(phase)
	if f < 0.5 then
		return range * (-1 + 4 * f)
	end
	return range * (3 - 4 * f)
end

-- Phase that produces offset `x` while moving in the given direction (inverse of CartTimeline.x).
function CartTimeline.phaseFor(x: number, range: number, movingPositive: boolean): number
	local u = math.clamp(x / range, -1, 1)
	if movingPositive then
		return (u + 1) / 4
	end
	return (3 - u) / 4
end

-- Offset of a cart at server time `now`. `speed` is the cart's base speed (studs/s).
function CartTimeline.offset(timeline: Timeline, range: number, speed: number, now: number): number
	if timeline.pinned ~= 0 then
		local target = timeline.pinned * range
		return approach(timeline.x0, target, speed * timeline.coldMul * math.max(0, now - timeline.t0))
	end
	return CartTimeline.x(timeline.phase0 + timeline.rate * (now - timeline.t0), range)
end

-- True while the cart is moving toward +X (for wheel spin / facing on the client).
function CartTimeline.movingPositive(timeline: Timeline, range: number, speed: number, now: number): boolean
	if timeline.pinned ~= 0 then
		local x = CartTimeline.offset(timeline, range, speed, now)
		return timeline.pinned > 0 and x < range
	end
	local f = (timeline.phase0 + timeline.rate * (now - timeline.t0)) % 1
	return f < 0.5
end

return CartTimeline
