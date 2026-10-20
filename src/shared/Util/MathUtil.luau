--!strict
--[[
	Math helpers: smoothing, box tests and small geometry utilities.
]]

local MathUtil = {}

function MathUtil.clamp(x: number, lo: number, hi: number): number
	if x < lo then
		return lo
	elseif x > hi then
		return hi
	end
	return x
end

function MathUtil.lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

function MathUtil.inverseLerp(a: number, b: number, x: number): number
	if a == b then
		return 0
	end
	return (x - a) / (b - a)
end

-- Frame-rate independent exponential smoothing factor.
function MathUtil.dampAlpha(sharpness: number, dt: number): number
	return 1 - math.exp(-sharpness * dt)
end

function MathUtil.damp(current: number, target: number, sharpness: number, dt: number): number
	return current + (target - current) * MathUtil.dampAlpha(sharpness, dt)
end

function MathUtil.approach(current: number, target: number, maxDelta: number): number
	if current < target then
		return math.min(current + maxDelta, target)
	end
	return math.max(current - maxDelta, target)
end

function MathUtil.round(x: number, step: number?): number
	local s = step or 1
	return math.floor(x / s + 0.5) * s
end

-- True when `point` lies inside the oriented box (cf, size), grown by `margin` on every side.
function MathUtil.pointInBox(cf: CFrame, size: Vector3, point: Vector3, margin: number?): boolean
	local m = margin or 0
	local localPoint = cf:PointToObjectSpace(point)
	return math.abs(localPoint.X) <= size.X * 0.5 + m
		and math.abs(localPoint.Y) <= size.Y * 0.5 + m
		and math.abs(localPoint.Z) <= size.Z * 0.5 + m
end

-- Horizontal-only containment (ignores height), useful for floor regions.
function MathUtil.pointInBoxXZ(cf: CFrame, size: Vector3, point: Vector3, margin: number?): boolean
	local m = margin or 0
	local localPoint = cf:PointToObjectSpace(point)
	return math.abs(localPoint.X) <= size.X * 0.5 + m and math.abs(localPoint.Z) <= size.Z * 0.5 + m
end

-- Closest point to `point` inside the oriented box.
function MathUtil.closestPointInBox(cf: CFrame, size: Vector3, point: Vector3): Vector3
	local p = cf:PointToObjectSpace(point)
	local half = size * 0.5
	local clamped = Vector3.new(
		MathUtil.clamp(p.X, -half.X, half.X),
		MathUtil.clamp(p.Y, -half.Y, half.Y),
		MathUtil.clamp(p.Z, -half.Z, half.Z)
	)
	return cf:PointToWorldSpace(clamped)
end

function MathUtil.flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

function MathUtil.flatDistance(a: Vector3, b: Vector3): number
	local dx, dz = a.X - b.X, a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

function MathUtil.safeUnit(v: Vector3, fallback: Vector3?): Vector3
	local m = v.Magnitude
	if m < 1e-6 then
		return fallback or Vector3.zero
	end
	return v / m
end

-- Clamp the magnitude of a vector.
function MathUtil.clampMagnitude(v: Vector3, maxLength: number): Vector3
	local m = v.Magnitude
	if m > maxLength and m > 0 then
		return v * (maxLength / m)
	end
	return v
end

function MathUtil.yawOf(direction: Vector3): number
	return math.atan2(-direction.X, -direction.Z)
end

-- Shortest signed angle difference in radians.
function MathUtil.angleDelta(from: number, to: number): number
	local d = (to - from) % (2 * math.pi)
	if d > math.pi then
		d -= 2 * math.pi
	end
	return d
end

function MathUtil.closestPointOnSegment(a: Vector3, b: Vector3, p: Vector3): Vector3
	local ab = b - a
	local lengthSq = ab:Dot(ab)
	if lengthSq < 1e-9 then
		return a
	end
	local t = MathUtil.clamp((p - a):Dot(ab) / lengthSq, 0, 1)
	return a + ab * t
end

-- Deterministic pseudo-random generator (xorshift32) for reproducible procedural decoration.
function MathUtil.rng(seed: number): () -> number
	local state = math.floor(seed) % 4294967296
	if state == 0 then
		state = 2463534242
	end
	return function(): number
		state = bit32.bxor(state, bit32.lshift(state, 13))
		state = bit32.bxor(state, bit32.rshift(state, 17))
		state = bit32.bxor(state, bit32.lshift(state, 5))
		return state / 4294967296
	end
end

-- Stable string hash (FNV-1a 32-bit), used to derive decoration seeds from ids.
function MathUtil.hash(text: string): number
	local h = 2166136261
	for i = 1, #text do
		h = bit32.bxor(h, string.byte(text, i))
		h = (h * 16777619) % 4294967296
	end
	return h
end

return MathUtil
