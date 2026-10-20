--!strict
--[[
	ProfileStore: session-locked profile persistence on top of a DataStore-like object (S21, DOC03).

	Record layout stored under each key:
	  { profile = <ProfileSchema.Profile>, lock = { job = <session id>, place = <place id>, t = <os.time> } | nil }

	Guarantees:
	  * Load takes the session lock with UpdateAsync. A lock held by another live server is waited on and
	    retried; a lock older than LockStealAge seconds (or still held after every attempt) is taken over.
	  * Data written by a newer schema is never downgraded: load reports "Newer" and the caller must not save.
	  * Every save is an UpdateAsync that first checks the lock is still ours; if another server took it, the
	    save is abandoned (lockLost) so two servers can never overwrite each other.
	  * Load failures never fall back to a blank profile, so a DataStore outage cannot wipe progress.
]]

local ProfileStore = {}
ProfileStore.__index = ProfileStore

export type Options = {
	store: any,
	sessionId: string,
	placeId: number,
	now: () -> number,
	wait: (number) -> (),
	budget: (() -> number)?,
	migrate: (any) -> any?,
	makeDefault: () -> any,
	sanitize: (any) -> any,
	loadAttempts: number,
	saveAttempts: number,
	retryBaseSeconds: number,
	lockWaitSeconds: number,
	lockStealAge: number,
}

export type Store = typeof(setmetatable({} :: { options: Options }, ProfileStore))

export type LoadStatus = "Ready" | "Failed" | "Newer"

function ProfileStore.new(options: Options): Store
	return setmetatable({ options = options }, ProfileStore)
end

local function waitForBudget(self: Store)
	local budget = self.options.budget
	if not budget then
		return
	end
	local waited = 0
	while budget() <= 0 and waited < 10 do
		self.options.wait(0.5)
		waited += 0.5
	end
end

-- Load (and lock) a profile. Returns status, profile.
function ProfileStore.load(self: Store, key: string, userId: number): (LoadStatus, any?)
	local o = self.options
	for attempt = 1, o.loadAttempts do
		waitForBudget(self)
		local outcome: string? = nil
		local loaded: any = nil
		local ok, problem = pcall(function()
			o.store:UpdateAsync(key, function(current: any): (any, any)
				outcome = nil
				local record = current
				if type(record) ~= "table" or record.profile == nil then
					record = { profile = o.makeDefault(), lock = nil }
				end
				local lock = record.lock
				if type(lock) == "table" and lock.job ~= o.sessionId then
					local age = o.now() - (tonumber(lock.t) or 0)
					if age < o.lockStealAge and attempt < o.loadAttempts then
						outcome = "locked"
						return nil, nil
					end
				end
				local migrated = o.migrate(record.profile)
				if migrated == nil then
					outcome = "newer"
					return nil, nil
				end
				record.profile = migrated
				record.lock = { job = o.sessionId, place = o.placeId, t = o.now() }
				outcome = "ok"
				loaded = migrated
				return record, { userId }
			end)
		end)
		if ok and outcome == "ok" then
			return "Ready", o.sanitize(loaded)
		elseif ok and outcome == "newer" then
			return "Newer", nil
		elseif ok and outcome == "locked" then
			o.wait(o.lockWaitSeconds)
		else
			if not ok then
				warn("[ProfileStore] load attempt", attempt, "failed:", problem)
			end
			o.wait(o.retryBaseSeconds * 2 ^ (attempt - 1))
		end
	end
	return "Failed", nil
end

-- Save a profile. Returns (saved, lockLost).
function ProfileStore.save(self: Store, key: string, userId: number, profile: any, release: boolean): (boolean, boolean)
	local o = self.options
	local lockLost = false
	for attempt = 1, o.saveAttempts do
		waitForBudget(self)
		local outcome: string? = nil
		local ok, problem = pcall(function()
			o.store:UpdateAsync(key, function(current: any): (any, any)
				outcome = nil
				if type(current) == "table" and type(current.lock) == "table" and current.lock.job ~= o.sessionId then
					outcome = "lost"
					return nil, nil
				end
				outcome = "ok"
				local lock = if release then nil else { job = o.sessionId, place = o.placeId, t = o.now() }
				return { profile = profile, lock = lock }, { userId }
			end)
		end)
		if ok and outcome == "ok" then
			return true, false
		elseif ok and outcome == "lost" then
			lockLost = true
			return false, lockLost
		else
			if not ok then
				warn("[ProfileStore] save attempt", attempt, "failed:", problem)
			end
			if attempt < o.saveAttempts then
				o.wait(o.retryBaseSeconds * 2 ^ (attempt - 1))
			end
		end
	end
	return false, lockLost
end

return ProfileStore
