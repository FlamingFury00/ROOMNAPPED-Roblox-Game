# QA plan (A11 input & device QA, A12 state & save QA)

Two layers: automated checks that run on every push, and a short manual matrix that runs on real devices
before each release. Anything the automation already proves is not repeated by hand.

## 1. Automated (every push, `tools/check.sh` and CI)

| Check | What it proves |
| --- | --- |
| StyLua, selene, luau-lsp `--!strict` analysis | Formatting, lint and type errors are caught before runtime. |
| `logic.spec`, `effectmodel.spec`, `util.spec` | Room effects and combos (order independence, safe exits, vines that go dormant on frozen water, gates reported exactly when they open or block), deploy rules and limits, health/downed/revive rules, reward plans, profile schema and every migration up to v4, run state machine, cart timelines, rate limiter and utilities. |
| `layouts.spec` | For every mission: each authored solo playthrough completes under the shared rules, a starter-only (Freezer + Fan) solution exists next to a genuinely different alternative, every bonus challenge is achievable, and the escape fits comfortably in the window. |
| `world.spec` | Every layout builds without validation errors, every mission references a layout, every room builds with every skin inside its reserved bounds, and every suitcase skin builds. |
| `sim.spec` (real server, bot players) | Full tutorial solo run with banking and save; Caretaker catch → safe failure; spoofed and malformed remotes rejected without breaking the run; disconnect mid-run (orphaned rooms fold, run continues); dropping and rejoining the same server keeps the save and reports the lost run; one squad of at most four (the fifth player waits); Results → lobby does not relaunch while PLAY AGAIN does; two players claiming one socket in the same frame get exactly one room (the other is told it is taken); a skin bought with exactly enough credits and pressed six times is charged once; a store outage shows Saving until a write lands, a long one is reported, retried in the background and confirmed, and a rejoin proves what was written; missions, rooms and the shop switched off live leave the selection and loadouts, refuse purchases and come back when switched on; ten consecutive runs without instance growth. |
| `layout_sims.spec` (real server **and** real client) | Every mission played start to finish by a scripted player using only starter rooms where required; no client or server error allowed; the run must succeed without the player being hurt. |
| `play.spec` (real server **and** real client) | Lobby → PLAY → tutorial through the client's own input bindings; revive through the context hold; downed lock and recovery; spectating after the downed window; pings, turning a fan and recalling it; a touch phone (844×390, 750×311 safe area) using slot buttons and the touch action button, with layout assertions that keep the action button clear of the jump button and the top bar. |
| `chaos.spec` (real server, real client on the leader) | On every mission a squad of bots sends random valid, invalid and malformed requests (deploys, recalls, holds, levers, pings, cargo drops, lobby requests mid-run), leaves the run, drops out and rejoins while a late joiner hammers the lobby. Every second: no server or client error, room caps per player and team, rooms and the suitcase only owned by the squad, outsiders never in the run they found, hearts in range; afterwards a clean Prep, no instance growth and a normal next run. Fixed seeds. |
| `ui.spec` | The real client bootstrap shows the lobby HUD and menu bar; PLAY readies up; the mission board browses, selects and picks a bonus target; the collection edits the loadout, equips and buys skins; settings apply instantly and save; Results reports success and failure honestly, the feedback prompt follows a return to the lobby and never follows PLAY AGAIN; content switched off live shows as resting and its buttons do nothing; lobby-only UI hides during a run; admins get the test tools; toasts render. |

Visual QA: `tools/preview` renders every interface scenario on desktop (`<scenario>`) and on a phone safe
area (`phone:<scenario>`) plus world geometry for each layout. The `squad` scenario fills the lobby with four
players and long names (the tallest the squad panel gets). Review the renders whenever UI or layout code
changes.

## 2. Device and input matrix (A11)

Run the tutorial and one later mission on each row. A cell passes when the mission can be completed with
only that input, every prompt shows the right glyphs, and nothing on the HUD overlaps or is cut off.

| Device | Input | Focus |
| --- | --- | --- |
| Windows or macOS desktop, 1080p and 1440p | Keyboard + mouse | Key prompts (1/2, E, R, Q, G, F, M), shift-lock, menu navigation with the mouse. |
| Desktop | Xbox or PlayStation controller | D-pad slot selection, X hold, Y turn, B back/cancel, menu selection never lost, Select opens Settings. |
| Phone, notched (e.g. iPhone 13–15) | Touch | Safe areas, slot buttons, action button above the jump button, ping long-press wheel, readable text. |
| Phone, small (e.g. iPhone SE / 360 dp Android) | Touch | Objective text fits or truncates cleanly, menus scroll, Results compact layout. |
| Tablet (iPad / Android tablet) | Touch | Large-screen jump button placement, two-column menus. |
| Console or ten-foot interface (if console is enabled) | Gamepad | Same as the controller row at couch distance. |
| Any | Low graphics quality (1–3) and *Low effects* on | Effects still show state (ice, water, wind, fire), frame rate holds. |
| Any | Reduced motion on | No camera shake or punch, UI pops replaced by fades, game still readable. |
| Any | Text & UI size 85 % and 130 % | Nothing overlaps; menus still fit. |
| Any | 300 ms simulated latency (Studio network settings) | Holds still complete (server tolerance), deploy and recall feel responsive, no rubber-banding into hazards. |

## 3. State and save matrix (A12)

| Case | Expected result |
| --- | --- |
| Spam PLAY / ready toggles, spam deploy and recall | Rate limits hold; no duplicate rooms; state stays consistent. |
| Two players deploy into the same socket at the same moment | Exactly one room unfolds; the other player gets a clear rejection. |
| Player leaves mid-run (solo, squad, carrying the suitcase) | Run fails or continues as designed; the suitcase drops or returns; the leaver is told unbanked loot was lost. |
| Last player leaves | Run ends, the hotel resets, no orphan instances. |
| Squad wipe | Results show the failure; nothing owned is lost. |
| Replay from Results ×3 | Each run starts clean; rewards are granted once per run. |
| DataStore failure during save (Studio: disable API access mid-session) | "Couldn't save yet" toast, retries, Results never claims "Saved" before a confirmed write. |
| Rejoin the same server and another server | Profile persists; the session lock prevents double writes. |
| Profile written by a newer build | The player is told the profile is newer; nothing is overwritten. |
| Room or mission disabled via `RoomnappedConfig` | Within five minutes it is not offered (selection and loadouts move off it, menus show it resting); owned content stays owned. Automated on one server by `sim.spec` and `ui.spec`; this row checks the DataStore path. |
| Purchase a skin with exactly enough credits, then spam the buy button | One purchase, correct balance, no negative credits. |

## 4. Exit criteria for a release

- All CI jobs (`verify`, `playthroughs`, `chaos`) green on the release commit.
- Every row of §2 and §3 passed on the release build (record device, OS and build version).
- No open crash, data-loss, stuck-run or duplicate-reward issue.
- Store media claims checked against the build (`docs/STORE_MEDIA.md`).
