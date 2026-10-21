# Content ownership record (A10)

This record lists where every asset in the ROOMNAPPED release comes from and why we are allowed to use it.
Release rule: **nothing ships unless it is original, Roblox-owned, bundled with the Roblox client, or from
a Roblox licensed partner library.** No marketplace models, no third-party scripts and no community
uploads are used.

Last reviewed: 2026-10-21, against Roblox client `version-9ac8595712b447a7` (0.744).

## Summary

| Asset type | Source | Permission |
| --- | --- | --- |
| Code | Written for this project (`src/`, `tests/`, `tools/`) | Original |
| 3D geometry (hotel kit, rooms, props, Caretaker, lobby, elevator) | Built procedurally from Roblox `Part`s, `WedgePart`s and `CornerWedgePart`s by `src/shared/World/*` and `src/client/Controllers/CaretakerView.luau` | Original; no meshes, models or packages are inserted |
| Materials | Roblox built-in `Enum.Material` values | Engine feature |
| UI icons | Composed from `Frame`s, `UICorner`s and `UIStroke`s in `src/client/UI/Icons.luau` | Original |
| Images and particles | Textures bundled with the Roblox client (`rbxasset://textures/...`, list below) | Shipped with every Roblox client; referenced in place, never re-uploaded |
| Fonts | Roblox built-in font families (`rbxasset://fonts/families/...`, list below) | Shipped with every Roblox client |
| Audio | 67 cues from the Roblox Creator Store: Roblox-owned audio and Roblox's licensed partner libraries ProSoundEffects and APM Music (table below) | Free to use in Roblox experiences; no synthesized or self-uploaded audio |
| Player avatars | `rbxthumb://` headshots and the players' own characters | Roblox platform feature |
| Lighting and sky | Engine `Lighting`, `Atmosphere`, post effects and the default sky | Engine feature |

## Bundled client textures

Referenced by path (the files ship inside every Roblox client and are verified present in the
`content-textures2` package of the version above):

| Path | Used for |
| --- | --- |
| `rbxasset://textures/particles/sparkles_main.dds` | sparkles, key glints, capture burst |
| `rbxasset://textures/particles/fire_main.dds` | fires |
| `rbxasset://textures/particles/fire_sparks_main.dds` | fire embers, live-wire sparks |
| `rbxasset://textures/particles/smoke_main.dds` | smoke, steam from doused fires, cold mist |
| `rbxasset://textures/particles/explosion01_core_main.dds` | impacts |
| `rbxasset://textures/particles/explosion01_smoke_main.dds` | impact smoke |
| `rbxasset://textures/particles/explosion01_shockwave_main.dds` | shockwaves |
| `rbxasset://textures/particles/explosion01_implosion_main.dds` | room fold / capture swirl |
| `rbxasset://textures/particles/forcefield_glow_main.dds` | glows |
| `rbxasset://textures/particles/forcefield_vortex_main.dds` | vortex and magnet fields |
| `rbxasset://textures/particles/SquareParticle.png` | confetti, debris, droplets |
| `rbxasset://textures/sparkle.png` | small sparkles |
| `rbxasset://textures/glow.png` | soft glows |
| `rbxasset://textures/whiteCircle.png` | round particles |
| `rbxasset://textures/ui/InspectMenu/ico_favorite@3x.png` | feedback rating stars (falls back to a vector star if it ever fails to load) |

## Fonts

All are Roblox built-in families: Luckiest Guy (display), Fredoka One (headings), Builder Sans (body),
Roboto Mono (key glyphs), Creepster, Fondamento and Special Elite (themed signs in the hotel).

## Audio

Every id is a public Creator Store audio asset. Owners: APMOfficial (9), ProSoundEffects (35), Roblox (23).
Alternates are tried in order at runtime if the primary fails to load, and they follow the same rule.
The list is generated from `tools/content/audio_catalog.json` (which also records durations and
audition notes); `tools/content/gen_audio.py` refuses any entry whose source is not `roblox` or `partner`.

| Cue | Asset id | Name | Owner | Alternates |
| --- | --- | --- | --- | --- |
| `capture_charge_loop` | 9125805094 | Rising Synth Tone Ascending In Pitch Waverin (SFX) | ProSoundEffects | 9126236071, 16480578036 |
| `capture_success` | 9116384485 | Magic Burst 1 (SFX) | ProSoundEffects | 9116384473, 9125647212 |
| `caretaker_alert` | 9045122943 | Ghost With The Most - Hit1 | APMOfficial | 1845713466, 9042321434 |
| `caretaker_grab` | 9120729973 | Whoosh Impact 1 (SFX) | ProSoundEffects | 9125989410, 9113077334 |
| `caretaker_hum_loop` | 9119469188 | Spirit Presence Constant Airy Hissing 2 (SFX) | ProSoundEffects | 9119514343, 9113586520 |
| `caretaker_keys` | 9116177077 | Keys Movement 2 (SFX) | ProSoundEffects | 9116177238, 9116161848 |
| `caretaker_search` | 9114495513 | Floor Creaks Short Med Wood Creaks 12 (SFX) | ProSoundEffects | 9114840555, 9125562923 |
| `caretaker_step` | 9116478399 | Massive Footstep Impact 22 (SFX) | ProSoundEffects | 9116477578, 9114523345 |
| `cargo_bank` | 17208380755 | Roblox GUI - Purchase | Roblox | 10066947742, 9113728042 |
| `cargo_drop` | 9114186861 | Drop Suitcase 3 (SFX) | ProSoundEffects | 9114186811, 9113245890 |
| `cargo_pickup` | 9119671087 | Suitcase Movement 8 (SFX) | ProSoundEffects | 9119671558, 17208319162 |
| `clock_tick_loop` | 9043366741 | TICK TOCK 09 100BPM | APMOfficial | 1835342630, 9116463812 |
| `crate_impact` | 9120906197 | Wood Impact 6 (SFX) | ProSoundEffects | 9120900308, 9117973587 |
| `crate_slide` | 9126002028 | Statue Slide Drag On Wood Ramp Various Versi (SFX) | ProSoundEffects | 9125759586, 9120842179 |
| `door_close` | 9114135555 | Door Closes 2 (SFX) | ProSoundEffects | 9114136719, 9114829386 |
| `door_open` | 9114135682 | Door Creak 1 (SFX) | ProSoundEffects | 9114829485, 9114145395 |
| `drain_gurgle` | 9125498759 | Drain Bubbling Liquid Gurgle Emptying Drain  (SFX) | ProSoundEffects | 9119152211, 9114167406 |
| `electric_loop` | 9125516674 | Electrical Zap Room Constant Sparking Arcing (SFX) | ProSoundEffects | 9112889082, 9114238020 |
| `electric_zap` | 9119594871 | Static Zap Body Two Buzzy Impacts 2 (SFX) | ProSoundEffects | 9119594718, 9116272073 |
| `elevator_ding` | 9114302017 | Elevator Bell Synth Chimes 2 (SFX) | ProSoundEffects | 9114302926, 9114301685 |
| `elevator_doors` | 365551881 | SlidingDoor | Roblox | 9114305290, 9114305596 |
| `elevator_move_loop` | 9125446564 | Command Room Tone Deep Air Conditioning Hum  (SFX) | ProSoundEffects | 9112777512, 9125710803 |
| `extinguish` | 9119165436 | Sizzle Short And Explosive Sear 1 (SFX) | ProSoundEffects | 9114437277, 9114588467 |
| `fan_motor_loop` | 9112777640 | Fan Swish Rhythmic 2 (SFX) | ProSoundEffects | 9119907761, 9117174637 |
| `fire_ignite` | 9114443037 | Fire Whoosh 7 (SFX) | ProSoundEffects | 9114439997, 9114446183 |
| `fire_loop` | 9112780193 | Fireplace Constant Burning Flame 1 (SFX) | ProSoundEffects | 9112780462, 9112906846 |
| `freeze` | 9125611419 | Ice Freeze Large Piece Crackles Liquid Nitro (SFX) | ProSoundEffects | 9125611312, 9114858583 |
| `heartbeat_loop` | 1842342421 | Heartbeat (a) | APMOfficial | 9043365727, 9043365842 |
| `hotel_ambience_loop` | 9112775414 | Eerie Ambience 2 (SFX) | ProSoundEffects | 9113203785, 9114493195 |
| `ice_crack` | 9114858588 | Ice Crackle Large Block Cracks 3 (SFX) | ProSoundEffects | 9114858605, 9112796414 |
| `ice_melt` | 75232856473344 | WellWater_DrippyLoop_01 | Roblox | 9120510269, 9112893331 |
| `lever_switch` | 12222170 | switch.wav | Roblox | 9125626478, 9116259834 |
| `magnet_hum` | 9125636146 | Magic Force Field Constant Deep Electrical H (SFX) | ProSoundEffects | 9125784811, 9112889303 |
| `metal_clank` | 9116541944 | Metal Clanks 2 (SFX) | ProSoundEffects | 9116673678, 9116617140 |
| `music_escape` | 1836271798 | Spooky Chase | APMOfficial | 9042675817, 9042777725, 1848090337 |
| `music_explore` | 9043067401 | A Curious Case A | APMOfficial | 1837467266, 9043066611, 9043067384 |
| `music_lobby` | 1840096894 | Hotel Lobby (a) | APMOfficial | 1842207993, 9046234388, 1841998269 |
| `music_results_fail` | 1838221720 | Story Time - Comic - Sad | APMOfficial | 1838221912, 1844306643, 1838635121 |
| `music_results_win` | 1837762472 | Victory Dance (sting a) | APMOfficial | 1838221725, 1845466651, 1838686024 |
| `music_tutorial` | 130053244401794 | TutorialMusic_01 | Roblox | 9043066413, 9048586338, 1841928563 |
| `placement_invalid` | 17208214688 | Roblox GUI - Call Decline | Roblox | 17208353912, 16480558943 |
| `player_downed` | 1836245036 | Comic Falling Sting | APMOfficial | 79348298352567, 9113480915 |
| `player_hurt` | 79348298352567 | Official OOF Sound Effect | Roblox | 12222058, 12222046 |
| `player_revive` | 9116395089 | Magic Glows Soft Clusters Of Chiming Hits 4 (SFX) | ProSoundEffects | 9114369623, 17208327798 |
| `pressure_plate` | 16480560857 | Audio/Roblox_Pinball_Giant_Button_Press_01 | Roblox | 16480567946, 9119713923 |
| `respawn` | 9116406610 | Magic Poofs Thumpy Wheezy Exhale 1 (SFX) | ProSoundEffects | 9116406643, 9116385087 |
| `room_fold` | 9119707271 | Swish Suck Reversed Metallic Swoosh Impact 2 (SFX) | ProSoundEffects | 9118158252, 15675028888 |
| `room_select` | 17208323435 | Roblox GUI - Equip | Roblox | 10128760939, 17208396156 |
| `room_unfold` | 9118478607 | Robot Transform Metal Bangs Clunks 4 (SFX) | ProSoundEffects | 9126229255, 9114514975 |
| `splash` | 9120585252 | Water Splash Big Water Splash Dive In 1 (SFX) | ProSoundEffects | 9117823374, 12222054 |
| `ui_click` | 15675032796 | Roblox_UI_Small_Click | Roblox | 17208396156, 10066968815 |
| `ui_close` | 17208186900 | Roblox GUI - Back | Roblox | 10066914500, 15675012262 |
| `ui_coin` | 127645268874265 | CoinTransfer_01 | Roblox | 16480548103, 9113849651 |
| `ui_countdown_go` | 16480579685 | Audio/Roblox_Pinball_8Bit_Blip_04 | Roblox | 9125485591, 9113399767 |
| `ui_countdown_tick` | 16480580213 | Audio/Roblox_Pinball_8Bit_Blip_01 | Roblox | 9113399926, 9118777841 |
| `ui_error` | 17208353912 | Roblox GUI - Negative | Roblox | 17208214688, 17208220181 |
| `ui_hover` | 17208339919 | Roblox GUI - Hover 01 | Roblox | 17208343514, 10066931761 |
| `ui_notify` | 99437156604053 | PV_ToastNotif | Roblox | 17208372272, 17208361335 |
| `ui_open` | 15675024286 | Roblox_UI_Whoosh_01 | Roblox | 17208405682, 17208204604 |
| `ui_ready` | 17208361335 | Roblox GUI - Notification High | Roblox | 12221990, 9125485659 |
| `ui_reward` | 12222253 | victory.wav | Roblox | 1844442542, 1844692556 |
| `ui_success` | 17208209318 | Roblox GUI - Call Accept | Roblox | 10128760939, 99366249808641 |
| `ui_toggle` | 17208408337 | Roblox GUI - Tab | Roblox | 12222183, 9119717523 |
| `vine_grow` | 9112747580 | Beanstalk Growth 1 (SFX) | ProSoundEffects | 9114514963, 9120261928 |
| `water_fill` | 365203457 | FaucetTurnOn | Roblox | 365551014, 9120575856 |
| `water_loop` | 9114492495 | Flood Bubbling Water 1 (SFX) | ProSoundEffects | 9120606720, 365551014 |
| `wind_loop` | 9118747525 | Rumble Ambience Interior Wind Turbo Shaft 1 (SFX) | ProSoundEffects | 9114057128, 15675021174 |

## Before every release

1. Run `python3 tools/content/gen_audio.py` and `tools/check.sh` (the generator rejects community audio).
2. Play each music and loop cue once in a published test place; replace any id that fails to load (the
   runtime falls back to the alternates and logs a warning, so check the server and client logs).
3. Search `src/` for `rbxassetid://` and `rbxasset://` and confirm every hit is listed above.
4. Confirm no `Model`, `MeshPart`, `Decal`, `Texture` or package has been inserted into the place by hand
   (the place is built entirely by Rojo from this repository).
