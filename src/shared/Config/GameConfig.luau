--!strict
--[[
	GameConfig: every tunable gameplay value in one place.

	Values marked "brief" come straight from the ROOMNAPPED design brief §3 (starting defaults to tune after
	playtests). Everything else is a derived tuning value chosen to support those defaults.
]]

local Tables = require(script.Parent.Parent.Util.Tables)

local GameConfig = {
	Version = "1.0.0",
	SaveSchemaVersion = 4,

	Loadout = {
		Slots = 2, -- brief: equipped room slots per player
		StarterRooms = { "Freezer", "Fan" },
	},

	Deploy = {
		ActivePerPlayer = 2, -- brief: active room limit per player
		ActivePerTeam = 4, -- brief: active room limit per team
		Range = 14, -- max distance from the socket door to deploy
		UnfoldSeconds = 0.9,
		FoldSeconds = 0.7,
		PlayerCooldownSeconds = 0.6,
	},

	Health = {
		MaxHearts = 3, -- brief: starting health in hearts
		DamageGraceSeconds = 1.5, -- brief: invulnerability after a hit
		RegenDelaySeconds = 18, -- time without damage before hearts start regenerating
		RegenIntervalSeconds = 12, -- one heart per interval while out of danger
		ReviveHearts = 2,
		SelfRecoveryHearts = 3,
		FallRespawnDelaySeconds = 0.6,
	},

	Capture = {
		HoldSeconds = 3, -- brief: cancelable hold, server verified
		Range = 11,
		FoldCinematicSeconds = 2.2,
	},

	Revive = {
		HoldSeconds = 3, -- brief: nearby teammate must finish the hold
		Range = 7,
	},

	Downed = {
		WindowSeconds = 20, -- brief: downed window before spectating
		SoloRecoveryDelaySeconds = 2.2,
	},

	Escape = {
		WindowSeconds = 90, -- brief: escape window after capture
		WarningSeconds = 20,
	},

	Solo = {
		SelfRecoveries = 1, -- brief: once per run
	},

	Interaction = {
		DefaultRange = 9,
		RangeTolerance = 4, -- server-side slack for latency
		HoldToleranceSeconds = 0.3, -- server accepts holds this much shorter than nominal (latency)
		MaxHoldDriftSeconds = 2.5, -- holds older than nominal + drift are discarded
		CargoPickupRange = 8,
		LeverRange = 8,
		LineOfSightSlack = 1.5,
	},

	-- The client owns its character, so a modified client could put it anywhere. The server keeps every run
	-- member to what legitimate movement can do (HazardService), and a success faster than anyone can play the
	-- route pays like practice (RewardRules).
	Integrity = {
		-- Studs/s across the floor: walking is 16, ice and wind lanes stay under 26; the short bursts above this
		-- (boosted slide 46, launch flight, knockback) fit easily in the allowance below.
		MaxMoveSpeed = 40,
		-- Catch-up allowance: a lagging client's position can arrive all at once (nearly four seconds of walking),
		-- yet it is a small part of any wing, so it never skips a room.
		MoveBurstStuds = 60,
		TeleportSettleSeconds = 1.5, -- a server teleport this recent may not have reached the client yet
		MinRunPace = 24, -- studs/s over the whole route, there and back: no squad keeps this up
	},

	Squad = {
		MaxPlayers = 4, -- brief: one squad of up to four per server
		LaunchCountdownSeconds = 15,
		AllReadyCountdownSeconds = 3,
		ElevatorRideSeconds = 3.5,
		ResultsTimeoutSeconds = 30,
		IntroGraceSeconds = 2,
	},

	Cargo = {
		CarrierSpeedMultiplier = 0.85,
		DropOffset = 3,
		RecoverDelaySeconds = 1.5,
	},

	Movement = {
		WalkSpeed = 16,
		JumpHeight = 7.2,
		DownedWalkSpeed = 0,
		LedgeSpeedMultiplier = 0.55,
	},

	Ice = {
		Traction = 1.35, -- lower = more slippery
		MaxSpeed = 26,
		StopTraction = 0.6,
	},

	Wind = {
		PlayerPushSpeed = 13,
		HeadwindScale = 0.2, -- share of the push that still holds back a player walking into a lane
		PlayerMaxSpeed = 24,
		PlayerAcceleration = 45,
		SlideBoostSpeed = 46,
		SlideBoostAcceleration = 75,
		LaunchMinSpeed = 30,
		LaunchFlightSeconds = 0.75,
		CratePushSpeed = 9,
		CaretakerPushSpeed = 7,
		CaretakerMaxPushback = 14, -- studs per exposure before it braces
		CaretakerBraceSeconds = 4, -- immunity after a pushback so wind cannot stun-lock it
		LaneStrengthFalloff = 0.35,
	},

	Cold = {
		CaretakerSlowMultiplier = 0.55,
		CartSlowMultiplier = 0.35,
		FieldPadding = 2,
	},

	Magnet = {
		PullSpeed = 7,
		MaxCombinedSpeed = 9,
	},

	Effects = {
		FillSeconds = 1.5,
		DrainSeconds = 3,
		FreezeSeconds = 0.8,
		MeltSeconds = 2,
		IceExitGraceSeconds = 0.75,
		FireWarningSeconds = 3,
		VineGrowSeconds = 4,
		VineRetractSeconds = 3,
		PowerSwitchCooldownSeconds = 0.75,
		SlideZoneRequiresIce = true,
	},

	Hazards = {
		FallDamage = 1,
		FireDamage = 1,
		ShockDamage = 1,
		CartDamage = 1,
		CartKnockback = 55,
		FireKnockback = 40,
		ShockKnockback = 45,
		TickSeconds = 0.1,
		FallDepth = 3.5, -- studs below the floor that count as having fallen into a pit
	},

	Caretaker = {
		PatrolSpeed = 7,
		InvestigateSpeed = 10,
		ChaseSpeed = 15.5,
		HuntSpeedBase = 13,
		HuntSpeedPerExtraPlayer = 0.6,
		HuntSpeedFinalStretchBonus = 1.2,
		VisionRange = 60,
		VisionHalfAngleDegrees = 60,
		HearingMultiplier = 1,
		LoseSightSeconds = 2.5,
		SearchSeconds = 5,
		InvestigateLookSeconds = 3,
		LungeRange = 6,
		LungeWindupSeconds = 0.4,
		LungeDashSpeed = 26,
		StrikeRange = 3.6,
		ReactSeconds = 2,
		HoverHeight = 3.2,
		TickRate = 30,
		SnapshotRate = 15,
		StuckSeconds = 3,
		PhaseDelaySeconds = 2.5,
		SoloDetectionMultiplier = 0.8,
		WakeDelayAfterCaptureSeconds = 1.2,
	},

	Noise = {
		Deploy = 55,
		Recall = 40,
		Splash = 40,
		CrateImpact = 30,
		Lever = 30,
		Ping = 0,
	},

	Data = {
		AutosaveSeconds = 120,
		SessionLockStaleSeconds = 1800,
		LoadAttempts = 6,
		SaveAttempts = 5,
		RetryBaseSeconds = 1,
		MaxGrantHistory = 64,
		LockWaitSeconds = 4,
	},

	Pings = {
		CooldownSeconds = 1,
		Burst = 3,
		BurstWindowSeconds = 6,
		LifetimeSeconds = 6,
		MaxDistance = 140,
	},

	Rewards = {
		ExtractionCredits = 20,
		DuplicateBlueprintCredits = 60, -- fixed cosmetic credit for duplicate blueprints (Easy missions)
		DuplicateDifficultyCredits = 25, -- extra duplicate credit per difficulty step, so harder missions pay more
		DuplicateSkinCredits = 40,
		KeyCredits = 10,
		FirstClearBonusCredits = 30,
	},

	Onboarding = {
		FirstUsefulActionTargetSeconds = 60, -- brief: measured from first controllable spawn
		TutorialMissionId = "M0",
		-- Tutorial milestones the client reports (anything else is ignored by the server).
		TutorialSteps = { "moved", "selected", "deployed", "crossed", "foundTarget", "captured", "finished" },
	},

	Feedback = {
		Tags = { "fun", "confusing", "hard", "easy" }, -- optional tag on the post-run rating
	},

	Performance = {
		MobileFpsFloor = 30, -- brief: target on the recorded test device
		LowEffectsParticleScale = 0.25,
		MaxShadowLightsPerLevel = 10,
	},

	Expedition = {
		TargetMinMinutes = 6, -- brief
		TargetMaxMinutes = 10, -- brief
	},

	RateLimits = {
		-- [remote] = { burst, refillPerSecond }
		Default = { 10, 5 },
		Interaction = { 8, 4 },
		Deploy = { 4, 1.5 },
		Ping = { 3, 0.5 },
		Lobby = { 12, 4 },
		Purchase = { 3, 0.5 },
		Settings = { 4, 0.5 },
		Debug = { 20, 10 },
	},
}

return Tables.deepFreeze(GameConfig)
