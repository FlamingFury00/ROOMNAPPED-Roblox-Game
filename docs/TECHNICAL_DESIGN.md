# ROOMNAPPED — Technical design

How the design brief ([ROOMNAPPED_Project_Design.md](ROOMNAPPED_Project_Design.md)) is implemented. Component
ids (S, U, R, A) refer to the brief; the [traceability table](#traceability) at the end maps every one of
them to code and tests.

## 1. Principles

* **The server owns the game.** Clients send intentions (deploy, recall, hold, interact, ping); the server
  validates them, simulates rooms, hazards, health, cargo and the Caretaker, and replicates state. Clients
  draw that state and only simulate their own character's movement, as Roblox does.
* **Rules are pure and shared.** Room effects, deploy rules, health, rewards, profiles, the run state
  machine, cart timelines and navigation live in `src/shared/Logic` as Instance-free Luau. The server runs
  them authoritatively; the client calls the same functions to explain previews, so an explanation can
  never disagree with the server's decision.
* **Content is data.** Rooms, missions, skins, layouts, strings, audio ids and feature flags are config
  (`src/shared/Config`, `src/shared/Content`). Adding a mission or a layout needs no service changes.
* **Everything is built in code.** World geometry, room prefabs, the Caretaker, effects and icons are
  procedural, so the repository is the whole game and Rojo can rebuild the place at any time.
* **Every system is testable headlessly.** The same server and client code runs inside Lune with a small
  engine shim (`tests/harness`), so playthroughs and UI flows are automated.

## 2. Runtime layout

```
ReplicatedFirst/Loading         branded loading / profile gate (U20)
ReplicatedStorage/Shared        config, content, logic, net, world builders, utilities
ServerScriptService/Server      bootstrap + Core (state, profiles, registry) + Services
StarterPlayerScripts/Client     bootstrap + Core (state mirror, run info, device) + Controllers + UI
```

### Server bootstrap

`src/server/init.server.luau` creates the remotes, starts the state server and initialises services in a
fixed dependency order: Flags → Telemetry → Profile → Character → Lobby → Session → Expedition → Effect →
Room → Hazard → Health → Cargo → Capture → Caretaker → Interaction → Reward → Ping → Debug. `Init()`
registers each service in the `Registry` (late-bound lookups avoid require cycles) and builds static content
without yielding; `Start()` connects events and may spawn loops.

### Client bootstrap

`src/client/init.client.luau` starts the core modules in order (state mirror, settings, audio, input, UI
root) and then discovers every module under `Controllers/`, `UI/Hud/` and `UI/Screens/`, starting them by
ascending `priority`. A module that throws at start is logged and skipped so one bug cannot take the whole
interface down.

## 3. Networking (S20)

* **Remotes** are declared in `src/shared/Net/Remotes.luau`. Every client → server event has an argument
  schema (`string`, `integer`, `Vector3`, optional `?` …; strings capped at 64 characters) and a rate-limit
  bucket (token buckets in `GameConfig.RateLimits`). `Net.on` rejects anything that does not match before
  game code sees it.
* **Replicated state** (`src/server/Core/StateServer.luau` → `src/client/Core/ClientState.luau`): two
  channels, `global` (run phase, roster, sockets, zones, cargo, Caretaker mode, flags, lobby) and a private
  `me` channel per player (profile view, results). Services write with `channel:Set(path, value)`; writes are
  batched into one `StatePatch` per channel per frame with a sequence number. Clients fetch a snapshot with
  `GetSnapshot` and apply patches in order; patches that arrive early are buffered.
* **Streams**: the Caretaker's position is sent at 15 Hz over an `UnreliableRemoteEvent` and interpolated
  ~0.12 s in the past on clients.
* **Server checks** on every gameplay action: phase, roster membership and status (downed / eliminated
  players cannot act), distance with latency tolerance (`GameConfig.Interaction`), line of sight, and for
  holds the full duration measured on the server. Admin commands re-check permissions on the server.

## 4. The run (S02, S10, S17–S19)

`RunMachine` (pure) defines `Prep → Launching → Explore → Capture → Escape → Results → Prep`;
`ExpeditionService` drives it:

1. **Prep** — `SessionService` manages presence, the squad leader (longest present), mission selection and
   ready flags. The first ready player starts a 15 s countdown that drops to 3 s once everyone eligible is
   ready. At most `GameConfig.Squad.MaxPlayers` (4) can be ready; anyone else waits for the next run.
2. **Launching** — `LevelBuilder` assembles the mission layout (hotel kit modules, sockets, zones, keys,
   levers, plates, crates, carts, gates, ledges, the target room) while the elevator ride plays.
3. **Explore** — rooms, effects, hazards, health and the Caretaker step every frame in a fixed order:
   effects first, then movement-dependent hazards and damage (S09).
4. **Capture** — a verified 3 s hold folds the target room into a single shared suitcase.
5. **Escape** — 90 s to carry the suitcase to the elevator; the Caretaker hunts.
6. **Results** — rewards are planned and saved; every player sees their own results. The level is destroyed,
   replicated run state is cleared and every run connection lives in a `Trove`, so ten runs in a row do not
   grow the instance count (tested).

Players who join mid-run wait in the lobby and cannot affect or profit from the running mission. Leavers
drop the suitcase safely; their deployed rooms become orphaned and fold once empty (S19). A player who drops
and rejoins is a new session: the old roster entry is marked Disconnected, the player waits for the next run
and is told the interrupted run's loot was lost. Run-wide moments (stings, cinematics, alarms) are sent only
to the squad (`ExpeditionService.fireRun`), so the lobby never hears another squad's run.

## 5. Rooms and effects (S05–S09, R01–R13)

* **Loadout**: two slots, changeable only outside a run. Starter rooms are Freezer and Fan; others are
  earned as blueprints.
* **Deploying** (`RoomService`, `DeployRules`): the nearest socket in range; at most two active rooms per
  player and four per team; the first valid claim on a socket wins. Deploying is free; capacity is freed
  by recalling. A room folds only when its occupancy zone is empty — a blocked recall names who or what must
  leave. Fans have a direction (forward / across), chosen before unfolding.
* **Effects** (`EffectModel`): sockets link to zones. Each frame the model resolves water and cold first
  (basins move through Dry, Filling, Water, Draining, Freezing, Ice, Thawing and Melting), then everything that depends on
  water (fires doused, floats and switches, vine watering, electrified water), then gates. Removing a room
  removes its source immediately and shared zones recompute from what remains (R13). `EffectService` applies
  the resulting collision on the server and replicates each changed zone.
* **Movement modifiers** (`MovementController`, client): momentum on ice, a capped and falloff-weighted fan
  push, ice + wind launches on a fixed arc over gaps, knockback, ledge and carry slowdowns, the downed lock —
  all through one plane-mode `LinearVelocity` enabled only while a modifier applies. The server judges the
  outcomes (falls, hazards, launch combos detected over the whole flight arc).
* **Hazards** (`HazardService`): crates on rails (wind along parallel lanes, magnet pull), pressure plates,
  carts on deterministic timelines (`CartTimeline`, reproduced exactly by clients), fire and electrified
  water damage volumes, falls with return to the last safe point, golden keys.
* **Combos** are detected on the server (`EffectService`) and announced to the squad.

## 6. The Caretaker (S15, S18, A03)

A server-side data entity (no physics body) on the level's waypoint graph (`NavGraph`, A*). It sees with a
vision cone and line of sight and hears noises (deploys, splashes, levers, crates). Modes: Dormant, Patrol,
Investigate, Search, Chase, Lunge (0.4 s telegraphed wind-up), React, Hunt (after the capture), Phase (it
fades through walls when stuck or when no path exists). Cold slows it; wind pushes it back a bounded
distance and then it braces, so wind can never stun-lock it. Pressure scales with squad size through speed.
Clients render it from interpolated snapshots as a part-built bellhop with procedural gait, lantern, key
jingle and per-mode body language (`CaretakerView`).

## 7. Health, revive and spectating (S16, U03, U12)

`HealthModel` (pure) and `HealthService`: three hearts, 1.5 s damage grace, regeneration after 18 s out of
danger, a 20 s downed window with a 3 s team revive, one automatic solo self-recovery per run, then
elimination and spectating. The Humanoid never dies from gameplay. Downed and spectating states reach the
client through roster data and player attributes; `SpectateController` follows living teammates.

## 8. Persistence and rewards (S21–S23)

* `ProfileStore` stores `{ profile, lock }` per user in the `RoomnappedProfiles_v1` DataStore. Loading takes
  a session lock with `UpdateAsync` (waits and retries while another live session holds it, takes over stale
  or long-held locks); every save re-checks the lock and abandons if another session took it. Locks belong
  to a player session (a token), not to a server, so the release of a player's previous session can never
  clobber a quick rejoin on the same server. Load failures never fall back to blank data; data from a newer
  schema is never downgraded.
* `ProfileSchema` versions the save (`GameConfig.SaveSchemaVersion`, now 5), migrates older shapes and
  sanitises every field. Disabled or removed content stays in the profile untouched. v5 adds mission
  mastery: bonus challenges ever completed and missions extracted with every golden key, which drive the
  three stars on the mission board alongside the clear count and the best time.
* `ProfileService` autosaves every 120 s, saves on leave and in `BindToClose`, and exposes `saveNow()` so
  results can show "Saving…" until a confirmed write. Without DataStore access an in-memory store with the
  same contract is used and the player is told progress will not persist.
* `RewardRules` + `RewardService`: on success each member of the starting roster gets their own plan —
  blueprint of the captured room if new, else the reward skin they targeted, else duplicate credits — plus
  extraction, key, first-clear and challenge credits. The grant and the run id are written in one save
  (bounded grant ledger), so retries and reconnects can never pay twice.
* Credits only buy cosmetic skins (`SessionService`), each purchase deducts exactly once. No Robux sales.

## 9. Client presentation

* **Controllers**: input actions (keyboard, gamepad, touch share one action map), camera feel (decaying
  shake, FOV punches, safe cinematic shots), placement preview, the single context action with
  server-verified holds, pings (contextual tap, four-way wheel), hints and the guided tutorial,
  spectating, transitions, lighting grades per wing, world life (doors, lamps, alarms), zone visuals
  (water, ice, sparks, fires, vines, plates, levers, keys, carts, crates, wind), room unfold/fold/capture
  animations and living rooms, the Caretaker view, one-shot effects, audio with a music director.
* **UI** (`src/client/UI`): a modal stack (`UIRoot`) over five ScreenGuis (HUD, dim, menus, overlay, cinema).
  Everything is laid out on a 1280×720 virtual canvas that `Responsive` scales to the core-UI safe area
  (`ScreenInsets.CoreUISafeInsets`), clamped between 0.62 and 1.55 and multiplied by the player's text size
  setting. Phones (≈ 750×311 safe area) get a shorter canvas; windows refit, long panels scroll, Results
  switches to a compact layout, the lobby squad list goes compact (and scrolls rather than run under the
  mission card) and the touch action cluster is anchored to the real jump button. Touch targets are at
  least 72 virtual px (≈ 44 pt on a phone) unless the whole surrounding card is the target.
* **Honest controls**: anything the server would refuse is shown as unavailable with the reason before it is
  pressed — missions disabled by a live flag, the shop when it is switched off, *Unstuck* outside an active
  run or during its cooldown.
* **Icons** are vector compositions of frames (`Icons.luau`); the only images are engine-bundled textures.
* **Accessibility** (S29): separate volume groups, reduced motion, low effects, text and UI size, hints
  toggle, icons paired with words and never colour-only, every important event has both a sound and a
  visual, the whole mission is playable muted and without chat.

## 10. Live operations (S26, S28, S32)

* **Feature flags** (`FeatureFlags`, `FlagsService`): defaults < environment (studio / test / live by place id)
  < live overrides from the `RoomnappedConfig` DataStore (re-read every five minutes, so running servers
  follow a rollback) < admin test overrides (`flag <id> <on|off>`, one server). Rooms and missions can be
  disabled without touching profiles: a disabled mission leaves the lobby's selection, a disabled room
  leaves loadouts and both show as resting in the menus; features (pings, feedback prompt, analytics, debug
  tools, Caretaker, keys, shop) can be switched off. See [PUBLISHING_CHECKLIST.md](PUBLISHING_CHECKLIST.md).
* **Analytics** (`TelemetryService`): onboarding funnel (each whitelisted step logged once per player, the
  steps already sent stored as a bitmask in the profile — schema v4), the recurring `Expedition` funnel keyed by run id, and custom events (room deployed, combo, run
  result, room pair, feedback, ping, key, Caretaker hit) with device and build fields. Every call is
  pcall-wrapped; Studio only logs.
* **Feedback** (`Feedback` screen): a two-tap rating after some runs (1st, 3rd, then every 5th; once per
  session).
* **Debug tools** (`DebugService`, `Debug` screen): force phases, spawn rooms, give items, simulate downs
  and disconnects, toggle the Caretaker, teleports, set the escape timer, print run ids and stats. Only the
  owner, group rank 254+ and listed admin ids can use them; every command is re-checked on the server.

## 11. Performance (S27)

* Geometry is anchored parts from a small kit; decorative parts have `CanCollide`, `CanTouch` and
  `CanQuery` off. One level exists at a time and is destroyed between runs.
* The server never moves carts or the Caretaker physically: carts are timelines and the Caretaker is data,
  so the physics load is the players and a few crates.
* Replication is batched per frame per channel; the Caretaker uses an unreliable 15 Hz stream.
* Clients render zone and room visuals from replicated state with tweens and engine-bundled particle
  textures; the low effects mode scales particles to 25 % and drops depth of field. At most ten shadow-casting lights per level.
* A regression test runs ten consecutive expeditions and asserts the instance count does not grow.

## 12. Testing

See [QA_PLAN.md](QA_PLAN.md). In short: pure-rule unit specs, layout solvability specs, server simulations
with bot squads, full-stack playthroughs of every mission with the real client attached, a seeded chaos
soak of every mission (random, invalid and malformed requests, drop-outs and rejoins under continuous
invariant checks), touch-phone and squad play tests, interface specs, and offline renders of every screen on
desktop and phone sizes.

## Traceability

| Id | Component | Implementation | Verified by |
| --- | --- | --- | --- |
| S01 | Project structure | Rojo project, `init.server.luau`, `init.client.luau`, `Registry` | build, CI |
| S02 | Run state machine | `RunMachine`, `ExpeditionService` | logic, sim, layout_sims |
| S03 | Movement & camera | `MovementController`, `CameraController` | play, layout_sims |
| S04 | Context interactions | `InteractionController`, `InteractionService` | play, sim |
| S05 | Loadout | `SessionService`, `Collection` screen | ui |
| S06 | Sockets & placement | `RoomService`, `DeployRules`, `PlacementController` | logic, play |
| S07 | Fold & reclaim | `RoomService`, `RoomVisuals` | play, sim |
| S08 | Room effect engine | `EffectModel`, `EffectService`, `ZoneVisuals` | effectmodel, layouts |
| S09 | Combo resolution | `EffectModel` resolution order, `EffectService` combos | effectmodel, layout_sims |
| S10 | Level assembly | `LevelBuilder`, `Kit`, `Props`, `Layouts/L0–L6` | world, layouts |
| S11 | Hazards | `HazardService`, `CartTimeline`, `ZoneVisuals` | layout_sims |
| S12 | Room capture | `CaptureService`, `InteractionService` | play, sim |
| S13 | Shared cargo | `CargoService` | sim, layout_sims |
| S14 | Extraction & rewards | `ExpeditionService`, `RewardService`, `RewardRules` | logic, sim |
| S15 | Caretaker enemy | `CaretakerService`, `NavGraph`, `CaretakerView` | sim, layout_sims |
| S16 | Damage & recovery | `HealthModel`, `HealthService`, `Overlays` | logic, play |
| S17 | Session & friends | `SessionService` (squad of ≤ 4, waiting players) | sim |
| S18 | Solo & group scaling | Caretaker speed by squad size, solo self-recovery | logic, sim |
| S19 | Anti-grief & disconnect | orphaned rooms, safe cargo drop, no body blocking | sim, chaos |
| S20 | Network authority | `Net`, `Remotes`, `RateLimiter`, server checks | sim (spoofed requests), chaos |
| S21 | Save profile | `ProfileStore`, `ProfileSchema`, `ProfileService` | logic, sim |
| S22 | Reward persistence | `RewardService` grant ledger, honest saving state | logic, ui |
| S23 | Progression & missions | `MissionDefs`, unlocks, challenges, `MissionBoard` | logic, ui |
| S24 | Onboarding | Check-In mission, `HintsController`, onboarding funnel | play |
| S25 | Lobby & collection | `LobbyBuilder`, `LobbyService`, `LobbyHud`, `Collection` | ui |
| S26 | Analytics & feedback | `TelemetryService`, `Feedback` screen | ui |
| S27 | Performance budget | §11 | sim (ten runs), chaos |
| S28 | Debug & regression tools | `DebugService`, `Debug` screen, `tests/` | sim, ui |
| S29 | Accessibility & settings | `SettingsController`, `Settings` screen | ui |
| S30 | Localization readiness | `Strings.luau` catalog, no text in images, layouts tolerate longer strings | ui renders |
| S31 | Repeat-play content | six layouts + tutorial, challenges, keys, reward targets | layouts, layout_sims |
| S32 | Release & rollback | `FeatureFlags`, `FlagsService`, publishing checklist | sim, ui, manual (§5 of the checklist) |
| S33 | Home display | Deferred to P2 by the brief (§1, §2: showroom waits for G3 evidence) | — |
| S34 | Cosmetic monetization | P2. This release sells cosmetics for earned credits only; no Robux products | — |
| S35 | Live content pipeline | P2. Groundwork in place: rooms/missions are config with per-item disable flags | — |
| U01 | UI foundation | `UIRoot`, `Responsive`, `Components`, `Theme` | ui, renders |
| U02 | Objective & phase | `Objective` | play |
| U03 | Hearts & damage | `Vitals`, `Overlays` | play |
| U04 | Room quickbar | `Quickbar` | play |
| U05 | Placement preview | `PlacementController` | play |
| U06 | Context action | `InteractionController`, touch action button | play |
| U07 | Recall & cancel | `PlacementController`, `RoomService` blocked-recall reasons | play |
| U08 | Threat & escape timer | `Objective`, `Overlays` threat arrow | renders |
| U09 | Cargo status | `Overlays` | renders |
| U10 | Team status | `Vitals` | play |
| U11 | Ping system | `PingController`, `PingService` | play |
| U12 | Revive & spectate | `InteractionController`, `SpectateController`, `Overlays` | play |
| U13 | Onboarding hints | `HintsController` | play |
| U14 | Toast & error states | `Toasts`, `EffectsController` | ui |
| U15 | Lobby / Play screen | `LobbyHud`, `LobbyPrompts`, `MenuBar` | ui, play |
| U16 | Collection & loadout | `Collection` | ui |
| U17 | Mission select | `MissionBoard` | ui |
| U18 | Results & replay | `Results` | ui, play |
| U19 | Settings & help | `Settings` (controls help per device) | ui |
| U20 | Loading & reconnect | `ReplicatedFirst/Loading`, interrupted-run toast | manual |
| U21 | Cosmetic shop | P2. The credit shop lives in `Collection` (preview, owned state, price, confirmation) | ui |
| U22 | Showroom editor | Deferred with S33 | — |
| R01–R05 | Freezer, Fan, Laundry, Greenhouse, Magnet | `RoomDefs`, `RoomPrefabs`, `EffectModel`, `HazardService`, `RoomVisuals` | effectmodel, layout_sims |
| R06 | Deployment limits | `DeployRules` (2 per player, 4 per team) | logic, chaos |
| R07–R10 | Water + cold, ice + wind, water + fire, water + electricity | `EffectModel`, `MovementController`, `HazardService` | effectmodel, layout_sims |
| R11 | Geometry contract | `Kit`, `RoomPrefabs` reserved bounds | world |
| R12 | Unlocks & duplicates | `RewardRules`, `ProfileSchema` | logic |
| R13 | Deterministic cleanup | `EffectModel` source removal, `RoomService` | effectmodel, sim, chaos |
| A01 | Hotel modular kit | `Kit`, `Props`, `Palette`, `LevelBuilder` | world, renders |
| A02 | Room prefabs | `RoomPrefabs` (five rooms, every skin) | world |
| A03 | Caretaker rig | `CaretakerView` | play |
| A04 | Player/cargo animation | `RoomVisuals`, `Attach`, `CargoService` | play |
| A05 | Gameplay effects | `ZoneVisuals`, `Vfx`, `EffectsController`, low effects mode | play, renders |
| A06 | Audio pack | `AudioController`, `AudioIds` (licensed Creator Store audio) | — |
| A07 | UI art kit | `Icons`, `Components` | ui, renders |
| A08 | Public-test content | six layouts, lobby, mission board, 23 skins | layouts, world |
| A09 | Store-page media | [STORE_MEDIA.md](STORE_MEDIA.md) | manual |
| A10 | Content ownership record | [CONTENT_OWNERSHIP.md](CONTENT_OWNERSHIP.md), `gen_audio.py` source check | generator |
| A11 | Input & device QA | [QA_PLAN.md](QA_PLAN.md) §2, touch play test | play, manual |
| A12 | State & save QA | [QA_PLAN.md](QA_PLAN.md) §3 | sim, chaos, manual |
| A13 | Publishing checklist | [PUBLISHING_CHECKLIST.md](PUBLISHING_CHECKLIST.md) | manual |
