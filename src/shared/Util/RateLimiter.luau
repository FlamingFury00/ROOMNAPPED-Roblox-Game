--!strict
--[[
	Token-bucket rate limiter keyed by any value (usually a Player or "userId:event").

	Each key starts with a full bucket of `capacity` tokens which refill continuously at `refillPerSecond`.
	Allow() consumes one token and reports whether the request may proceed.
]]

local RateLimiter = {}
RateLimiter.__index = RateLimiter

type Bucket = { tokens: number, updated: number }

export type RateLimiter = typeof(setmetatable(
	{} :: {
		capacity: number,
		refill: number,
		_buckets: { [any]: Bucket },
		_clock: () -> number,
	},
	RateLimiter
))

function RateLimiter.new(capacity: number, refillPerSecond: number, clock: (() -> number)?): RateLimiter
	assert(capacity >= 1, "capacity must be >= 1")
	assert(refillPerSecond > 0, "refillPerSecond must be > 0")
	return setmetatable({
		capacity = capacity,
		refill = refillPerSecond,
		_buckets = {},
		_clock = clock or os.clock,
	}, RateLimiter)
end

function RateLimiter.Allow(self: RateLimiter, key: any, cost: number?): boolean
	local now = self._clock()
	local bucket = self._buckets[key]
	if not bucket then
		bucket = { tokens = self.capacity, updated = now }
		self._buckets[key] = bucket
	else
		local elapsed = math.max(0, now - bucket.updated)
		bucket.tokens = math.min(self.capacity, bucket.tokens + elapsed * self.refill)
		bucket.updated = now
	end
	local price = cost or 1
	if bucket.tokens >= price then
		bucket.tokens -= price
		return true
	end
	return false
end

function RateLimiter.Reset(self: RateLimiter, key: any)
	self._buckets[key] = nil
end

function RateLimiter.Clear(self: RateLimiter)
	table.clear(self._buckets)
end

return RateLimiter
