# ROOMNAPPED

**Steal the room. Build your escape.**

ROOMNAPPED is a co-op heist game for Roblox (1–4 players). Every player carries hotel rooms folded into
suitcases. Unfold a room into any glowing doorway and its effect pours into the hall: a Freezer turns a
flooded corridor into an ice bridge, a Fan blows you (and the Caretaker) down the hall, a Laundry floods a
basin, a Greenhouse grows a vine bridge, a Magnet drags metal crates. Combine rooms to cross each wing,
reach the target room, fold it up with a three-second hold and carry the suitcase back to the elevator
before the Caretaker wakes up and the escape clock runs out.

The whole experience — world geometry, rooms, the Caretaker, effects, UI and icons — is built in code
from Roblox primitives. Audio is Roblox-owned or from Roblox's licensed partner libraries, textures and
fonts are the ones bundled with the Roblox client, and nothing is synthesized or uploaded by us. See
[docs/CONTENT_OWNERSHIP.md](docs/CONTENT_OWNERSHIP.md).

## What is in the release

| Area | Contents |
| --- | --- |
| Missions | Check-In (tutorial) plus six expeditions: Soggy Suites, Frostbite Floor, The Boiler Wing, Luggage Line, Greenhouse Atrium, Magnet Vault. Each has bonus challenges, keys and a target-room reward. |
| Rooms | Freezer, Fan, Laundry, Greenhouse, Magnet — two slots per player, up to two active rooms per player and four per team. |
| Room combos | Ice bridge, ice launch, doused flames, frozen live water, power cut, crate bridge, weighted switch, vine bridge, pinned or frozen carts, Caretaker blown away. |
| Threats | The Caretaker (sleeps, patrols, investigates, chases, searches; reacts to cold and wind), floods, fires, live wires, runaway luggage carts, pits and gates. |
| Team play | Hearts with grace and regeneration, downed state with team revive, solo self-recovery, spectating, contextual pings, shared escape clock. |
| Progression | Room blueprints from missions, credits from extractions and challenges, 23 room skins and suitcases bought with earned credits (no Robux). |
| Platforms | Keyboard and mouse, touch (phones and tablets) and gamepad, with device-aware prompts and a responsive HUD that keeps touch targets above 44 pt on phones. |
| Comfort | Reduced motion, low effects mode, text and UI size, separate music / effects / ambience / interface volume. |
| Live operations | Session-locked saves with retries and an honest "Saving… / Saved" state, feature flags that disable a room or mission without touching profiles, server analytics funnel and custom events, admin test tools. |

## Getting started

The toolchain is pinned in [rokit.toml](rokit.toml): Rojo 7.7.1, Lune 0.11.0, selene 0.32.0,
StyLua 2.6.0 and luau-lsp 1.70.1.

```bash
rokit install                      # install the pinned tools
tools/build.sh build/ROOMNAPPED.rbxl   # build the place file
rojo serve                         # live-sync into Roblox Studio (Rojo plugin)
tools/check.sh                     # format, type analysis, build and the headless test suite
```

Open `build/ROOMNAPPED.rbxl` in Studio and press Play. In Studio, DataStores fall back to an in-memory
store unless the place is published with API access enabled, and the lobby says "Test server - progress
is not saved" while that is the case.

### Tests

`lune run tests/run.luau build/test.rbxl [filter]` runs everything headlessly against the built place:

* **Unit specs** for the shared rules (effects, deploy rules, health, rewards, profile schema, run state
  machine, cart timelines) and utilities.
* **Layout specs** that solve every mission layout and check that its main route is walkable.
* **Server simulations** (`tests/harness/Sim.luau`) that run the real server services with bot players:
  every mission is played start to finish by a scripted squad.
* **Full-stack play tests** (`tests/harness/ClientSim.luau`) that run the shipped client next to the real
  server: a bot presses real input bindings and touch buttons, and every controller, visual and HUD module
  runs its real code. Any error fails the test.
* **Interface specs** (`tests/harness/ClientEnv.luau`) that build every screen and HUD widget.

Set `RN_LAYOUT_SIMS_NO_CLIENT=1` to run the layout playthroughs without the client attached (faster), or
`RN_SKIP_LAYOUT_SIMS=1` to skip them.

### Visual previews

`tools/preview/` renders offline previews for QA without Studio:

```bash
# Interface: drive the real client into a scenario and render its ScreenGuis.
lune run tools/preview/export_gui.luau build/test.rbxl escape tools/preview/out/gui.json
python3 tools/preview/render_gui.py tools/preview/out/gui.json tools/preview/out/gui.png --size 1920x1080 --inset 0

# The same scenario on a phone (844x390 screen, 750x311 HUD safe area).
lune run tools/preview/export_gui.luau build/test.rbxl phone:escape tools/preview/out/phone.json
python3 tools/preview/render_gui.py tools/preview/out/phone.json tools/preview/out/phone.png --size 750x311 --inset 0

# World geometry of a layout, the lobby or a single room prefab.
lune run tools/preview/export.luau build/test.rbxl L3 tools/preview/out/scene.json
python3 tools/preview/render.py tools/preview/out/scene.json tools/preview/out/L3 --views 4 --size 1280x720
```

Scenarios: `lobby`, `explore`, `placement`, `escape`, `downed`, `spectate`, `results`, `menu:<Screen>`
(MissionBoard, Collection, Settings, Debug, Feedback), each optionally prefixed with `phone:`.

## Project layout

```
src/
  ReplicatedFirst/   loading screen
  shared/            code used by server and client
    Config/          GameConfig, rooms, missions, skins, strings, audio ids, feature flags
    Content/Layouts  mission layouts L0–L6
    Logic/           pure rules: effects, deploy, health, rewards, profiles, run state, carts, navigation
    Net/             remote definitions with argument schemas and rate limits, replicated state paths
    World/           procedural hotel kit, room prefabs, props, level and lobby builders
    Util/            Signal, Trove, rate limiter, math and table helpers, logging
  server/            services (session, expedition, rooms, effects, hazards, Caretaker, health, cargo,
                     capture, interaction, rewards, profiles, flags, telemetry, debug ...)
  client/            controllers (input, camera, movement, placement, interaction, visuals, audio ...)
    UI/              responsive HUD and screens, components, vector icons
tests/               headless harness and specs
tools/               build/check scripts, audio catalog, preview renderers
docs/                design brief and release documents
```

## Documentation

* [Design brief](docs/ROOMNAPPED_Project_Design.md) — the product and component specification.
* [Technical design](docs/TECHNICAL_DESIGN.md) — architecture, networking, persistence and how each
  system in the brief is implemented.
* [QA plan](docs/QA_PLAN.md) — automated coverage, device and state test matrices (A11, A12).
* [Publishing checklist](docs/PUBLISHING_CHECKLIST.md) — release and rollback steps (A13, S32).
* [Content ownership record](docs/CONTENT_OWNERSHIP.md) — provenance of every asset (A10).
* [Store media plan](docs/STORE_MEDIA.md) — icon, thumbnails and gameplay clip (A09).
