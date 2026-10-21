# Publishing checklist (A13, S32)

Use this list for every release. Roblox publishing and audience rules change; recheck the Creator
Dashboard and the [publishing documentation](https://create.roblox.com/docs/production/publishing/publish-games-and-places)
each time instead of relying on past answers (DOC06).

## 0. Places and environments

ROOMNAPPED expects two places:

| Environment | Purpose | How the server knows |
| --- | --- | --- |
| **test** | Private place for the team and recruited testers. Admin test tools, verbose logs. | Its place id is listed in `FeatureFlags.TestPlaceIds` (`src/shared/Config/FeatureFlags.luau`). |
| **live** | The public experience. No admin test tools unless switched on for a while with `{"features": {"debugTools": true}}` in `flags/live`. | Any other published place id. |
| studio | Local play in Studio. In-memory saves unless API access is enabled. | `RunService:IsStudio()` |

Both places read live switches from the `RoomnappedConfig` DataStore (key `flags/test` or `flags/live`) at
start and again every five minutes, so a room, a mission or a feature can be turned off without
republishing, and running servers follow within five minutes (see §6).

## 1. Code gates

- [ ] All CI jobs are green on the release commit (`verify`, `playthroughs` and `chaos`).
- [ ] `tools/check.sh` passes locally (StyLua, luau-lsp strict analysis, build, headless tests).
- [ ] `release/ROOMNAPPED.rbxl` is rebuilt from the release commit (`tools/build.sh release/ROOMNAPPED.rbxl`)
      and that is the file opened in Studio to publish.
- [ ] `GameConfig.Version` is bumped. If the profile shape changed, `GameConfig.SaveSchemaVersion` is bumped
      and `ProfileSchema` has a migration with a unit test from the previous version.
- [ ] `docs/CONTENT_OWNERSHIP.md` is current: `python3 tools/content/gen_audio.py` ran cleanly and every
      `rbxasset://` / `rbxassetid://` reference in `src/` is listed.
- [ ] The test place's id is in `FeatureFlags.TestPlaceIds` (`src/shared/Config/FeatureFlags.luau`). Any
      other published place runs as **live**, where the admin test tools are off, so without it the test
      place has no tools for the §5 rehearsals.
- [ ] Strings are final (no placeholder keys visible in the interface renders under `tools/preview`).
- [ ] The QA plan's release matrix is signed off for this build (`docs/QA_PLAN.md`).

## 2. Build and publish

1. Build the place: `tools/build.sh build/ROOMNAPPED.rbxl` (CI also uploads it as the `ROOMNAPPED-place`
   artifact).
2. Publish to the **test** place first, either:
   - Studio: open the `.rbxl`, then *File → Publish to Roblox As…* (first time) or *Publish to Roblox*; or
   - Open Cloud, with an API key that has *Place Publishing* (`universe-places`) write access to the
     experience in `ROBLOX_API_KEY` (the universe id is looked up from the place id):
     ```bash
     ROBLOX_PLACE_ID=<place id> tools/publish.sh release/ROOMNAPPED.rbxl Published
     ```
     On Windows (PowerShell), the same request:
     ```powershell
     $placeId = <place id>
     $universeId = (Invoke-RestMethod "https://apis.roblox.com/universes/v1/places/$placeId/universe").universeId
     Invoke-RestMethod -Method Post `
       -Uri "https://apis.roblox.com/universes/v1/$universeId/places/$placeId/versions?versionType=Published" `
       -Headers @{ "x-api-key" = $env:ROBLOX_API_KEY } `
       -ContentType "application/octet-stream" -InFile "release\ROOMNAPPED.rbxl"
     ```
     The place must already exist (create the experience once in Studio or the Creator Hub). `Saved` instead
     of `Published` stores a version without putting it live.
3. Run the published-test checks in §5 on the test place.
4. Publish the same file to the **live** place. Never publish a build to live that has not run on test.

## 3. Experience settings (Creator Dashboard / Studio Game Settings)

**Basic info**
- [ ] Name, description and genre match `docs/STORE_MEDIA.md`; every promise in the description exists in
      the build (A09).
- [ ] Icon and thumbnails uploaded from the store media plan.

**Places**
- [ ] Max players: **4** (one squad per server). The server also caps a squad at four ready players and
      queues anyone else for the next run, so a larger value only fills servers with waiting players.
- [ ] Server fill: Roblox optimized.

**Avatar**
- [ ] R15 or R6 both work (the code looks up `RightHand` or `Right Arm`, and ground checks allow for R6 legs).
      Keep player choice unless a playtest shows a problem.

**Security**
- [ ] *Enable Studio Access to API Services*: on for the test place only (Studio saves).
- [ ] *Allow HTTP Requests*: off (not used). *Allow Third Party Sales / Teleports*: off.
- [ ] *Allow Loading Third Party Assets*: **on**. The hotel's furniture are free Creator Store models
      loaded at runtime (`AssetLibraryService`); the place file already sets it
      (`AssetService.AllowInsertFreeAssets` in `default.project.json`), so only confirm it is still ticked.
      With it off the hotel falls back to its procedural props and the server log says so.

**Communication**
- [ ] Text chat uses `TextChatService` (Roblox filtering and age rules apply automatically).
- [ ] In a published test server on desktop, the chat window sits at the middle of the right edge (the client
      moves it there); on a phone it opens top-left from the chat button. If a Roblox update stops the move,
      the window simply stays top-left, over the squad panel - acceptable, but note it.

**Monetization**
- [ ] No developer products or passes are sold; skins are bought with earned credits only. If paid items
      are ever added, follow DOC07 (process receipts on the server, idempotent grants).
- [ ] Private servers: off or free.

**Localization**
- [ ] Source language English. Interface text comes from `Strings.luau`; if automatic translation is enabled,
      review captured strings before turning it on for players.

## 4. Audience, maturity and devices

- [ ] Complete the **Maturity & Compliance questionnaire** truthfully. Expected answers for this build:
      cartoon peril (a non-graphic Caretaker grabs and knocks players down; no blood, no realistic weapons,
      no gambling or paid random items, no romance), free-form text chat through Roblox.
- [ ] Check the audience eligibility the dashboard shows after the questionnaire; do not promote to an
      audience the experience is not eligible for.
- [ ] Devices: Computer, Phone and Tablet enabled. Console: enable only after the gamepad pass in the QA
      plan has been run on a console or with a controller in the ten-foot interface.

## 5. Published-test checks (test place)

- [ ] DataStores: the lobby does **not** show "Test server - progress is not saved"; complete Check-In and
      rejoin: credits, blueprint and tutorial completion persisted.
- [ ] Session lock: join the same account on a second server while the first is still in game. The second
      server waits and retries (about 25 s), then takes the profile over; the first server's next save sees
      the lost lock and stops writing, so the two servers never overwrite each other.
- [ ] Analytics: within a day the Creator Dashboard shows the onboarding funnel, the `Expedition` funnel and
      the custom events (DOC04, DOC05). Studio sessions never submit events.
- [ ] Audio: every music track and loop plays; the logs show no "failed to load" audio warnings.
- [ ] Furniture: the server log's `[Assets]` line reports every prop key ready ("asset library: N/N props
      ready"); a key listed under "fallbacks" lost its model, so replace that id in `AssetManifest.luau`.
      Walk the lobby and one corridor: sofas, desks and clocks face into the room, wall lamps sit flat on the
      wall. The Caretaker wears the bellhop uniform (no "could not be dressed" warning in the log).
- [ ] Feature flags: write `{"rooms": {"Magnet": false}}` to `RoomnappedConfig` / `flags/test`. Within five
      minutes the Magnet room shows as *Resting* in the collection, leaves any loadout and cannot be
      equipped, and profiles still own it; remove the override and it comes back. (The admin console command
      `flag Magnet off` rehearses the same thing on one server instantly.)
- [ ] Admin tools appear only for the owner (or group rank 254+) and for ids in `adminUserIds`. On the live
      place they stay hidden for everyone until `flags/live` switches `debugTools` on.

## 6. Rollback

1. **Disable content first.** Bad room or mission: set it to `false` in `RoomnappedConfig` →
   `flags/live` (for example `{"missions": {"M4": false}}` or `{"rooms": {"Laundry": false}}`). Every server
   applies it within five minutes: a disabled mission is no longer selectable (a lobby that had it picked
   moves to another), a disabled room leaves loadouts and cannot be deployed. Runs already under way finish
   with what they launched with. Players keep everything they own; disabled content is just not offered.
2. **Revert the place.** In the Creator Dashboard, open the place's version history and restore the
   previous version, then migrate servers.
3. **Never** rename or wipe `RoomnappedProfiles_v1` to roll back. Profiles carry a schema version: older
   builds keep fields they do not know, newer builds migrate forward, and a build refuses a profile whose
   schema is newer than it understands (the player is asked to rejoin a newer server). So a release that
   bumps `GameConfig.SaveSchemaVersion` cannot be rolled back without locking out players who played it;
   bump it only when an older build would misread the data, never for additive fields.

## 7. Launch gate (G3)

- [ ] Recruit 15–25 unfamiliar testers on the test place before any promotion.
- [ ] Review time to first deploy, replay rate, D1/D7 return and failure reports, split by device.
- [ ] Write the iterate/go decision down before opening the experience to a larger audience.
