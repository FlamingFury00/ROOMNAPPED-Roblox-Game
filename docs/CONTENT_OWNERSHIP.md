# Content ownership record (A10)

This record lists where every asset in the ROOMNAPPED release comes from and why we are allowed to use it.
Release rules:

* **Code, audio and animations** are original, Roblox-owned, bundled with the Roblox client or from a
  Roblox licensed partner library. No third-party scripts ever run, and no community audio is used.
* **Furniture models, images and avatar items** may also come from the public Roblox Creator Store and
  catalog when they are free, carry no audio, and are not modelled on a brand, a film or another game.
  Models are loaded at runtime with `AssetService:LoadAssetAsync` (which returns them sandboxed) and the
  loader deletes every script, sound, GUI, prompt and constraint before anything is shown
  (`src/server/Services/AssetLibraryService.luau`). Every pick is listed below with its creator.

Last reviewed: 2026-10-21, against Roblox client `version-9ac8595712b447a7` (0.744).

## Summary

| Asset type | Source | Permission |
| --- | --- | --- |
| Code | Written for this project (`src/`, `tests/`, `tools/`) | Original |
| 3D architecture (hotel kit, rooms, lobby, elevator) | Built procedurally from Roblox `Part`s, `WedgePart`s and `CornerWedgePart`s by `src/shared/World/*` | Original |
| Furniture and props | Free Creator Store models, loaded at runtime (table below); every one has a procedural fallback built the same way as the architecture | Free Creator Store assets; scripts and audio stripped |
| The Caretaker | An R15 character dressed from catalog items (table below), animated with Roblox-made animation packs; the part-built bellhop in `CaretakerView.luau` is the fallback | Catalog items in an NPC's `HumanoidDescription`; Roblox animations |
| Materials | Roblox built-in `Enum.Material` values | Engine feature |
| UI icons | Composed from `Frame`s, `UICorner`s and `UIStroke`s in `src/client/UI/Icons.luau` | Original |
| Wallpapers, carpets, floors and paintings | Free Creator Store images used as MaterialVariants and picture-frame decals (table below) | Free Creator Store assets |
| Particles | Textures bundled with the Roblox client (`rbxasset://textures/...`, list below) | Shipped with every Roblox client; referenced in place, never re-uploaded |
| Fonts | Roblox built-in font families (`rbxasset://fonts/families/...`, list below) | Shipped with every Roblox client |
| Audio | 67 cues from the Roblox Creator Store: Roblox-owned audio and Roblox's licensed partner libraries ProSoundEffects and APM Music (table below) | Free to use in Roblox experiences; no synthesized or self-uploaded audio |
| Player avatars | `rbxthumb://` headshots and the players' own characters | Roblox platform feature |
| Lighting and sky | Engine `Lighting`, `Atmosphere`, post effects and the default sky | Engine feature |

## Creator Store models

Loaded by `AssetLibraryService` from `src/shared/Content/AssetManifest.luau`. Each was picked from contact
sheets of public, free Creator Store results (`tools/assets/scout.py`) on 2026-10-21 and checked for: free,
no audio, no brand or game likeness, a triangle budget (6,000 for small props, 20,000 for the hero sofa and
chandeliers) and a thumbnail showing the front. Loading needs the experience setting **Security > Allow
Loading Third Party Assets**, which the place file already carries (`AssetService.AllowInsertFreeAssets`
in `default.project.json`).

| Prop key | Asset ids | Name (creator) |
| --- | --- | --- |
| armchair | 1253590181, 138623098643136 | cozy leather chair (rysida); Green Chair (pipepedro9 / Parkour Games Fans) |
| sofa | 80597511587533, 11290198233 | Luxury Sofa (FouDDy); Couch (Old Sofa) (BlkMatt) |
| bench | 83282298311815, 16017612847 | Kiester Bench (MACKIEJ56); Bench_White (DEV_MohamedTarek) |
| sideTable | 11930694315, 8544032055 | #antique #furniture (BRA1122555); small_table_wood (DerRuecken) |
| coffeeTable | 9589128284 | Coffee Table (turohabaneero) |
| grandfatherClock | 13534278784, 18985183180 | Old Clock (zzz_1551); Grandfather Clock (Solvyra) |
| wallClock | 125444652358924, 72312535411205 | Mantle Antique Wall Clock, Pendulum Wall Clock (chatillo201017) |
| mirror | 16017770957 | Ornate Mirror (DEV_MohamedTarek) |
| keyRack | 4826812656 | Keybox (LIAS FAN GROUP) |
| wallSconce | 2416484976, 8803156531 | Old Wall Lamp (Festivereinhard2); Wall lantern (Cholin178) |
| ceilingLamp | 475636989 | Ceiling Light (wakydawg119) |
| chandelier | 17370166704, 10627959279 | ChandelierPBR (GT_oli); Chandelier (OffByByte) |
| floorLamp | 16276432775 | Lamp (MissMariaAntoinette) |
| tableLamp | 8763605702, 15020876796 | Table Lamp (Cholin178); A Banker's Favorite Lamp (Thetijdmjd) |
| bigPlant | 8704290264, 10758068779, 8569543269 | Potted Plant (d_ytme); Potted Plant (PuggleyCake); Indoor Tree (BN895) |
| smallPlant | 87801222295603, 8259072716, 14924964084 | Plant Tree (CancelGrav); Plant Decoration (noe_bsc); SolariumPottedPlant_E (Milliankah) |
| flowerVase | 2060720336, 14924836767, 13558787444 | Flower Vase (UnixeI); Vase_w_Flowers_LG (Milliankah); hydrangea urn (exoopss) |
| receptionDesk | 2653577393 | Bar Counter (Gypherviz) |
| deskBell | 4948213579 | Little tiny bell (ACRG22) |
| luggageCart | 11498050741, 15040967563 | Luggage_Cart (Straysnack); gold luggage cart (taleshka666) |
| umbrellaStand | 140669320531443 | Umbrella Holder (Blaye1100) |
| statue | 15603344661, 85011138302601 | realistic angel statue (dbbooq); Asklepios_LG (OB3Y_Y) |
| rug | 11829259774 | Realistic Rug (caductis) |
| fireExtinguisher | 14003556037, 5307188544 | Extinguisher (zzz_1551); Fire extinguisher (acxirv) |
| wetFloorSign | 95220285653886, 16945975184 | Free Wet Floor Sign - Procedural Floors (At0_mik); Wet Floor Sign (skrigliets) |

Rejected on likeness grounds although they looked right: re-uploads of props from DOORS, FNaF, Hello
Neighbor, Piggy and SCP, branded vending machines and the Shining-pattern carpet.

## Surface textures and paintings

Free Creator Store images (the image asset each decal wraps, matched by creator and upload time and viewed
on its own thumbnail; tiles were checked for seams by tiling them 2x2). The surfaces are MaterialVariants
in the place file (`src/MaterialService/*.model.json`) that the themes in `src/shared/World/Palette.luau`
put on walls, floors, carpets and ceilings; the paintings hang in the hotel's frames
(`src/shared/Content/Artwork.luau`).

| MaterialVariant | Image id | Name (creator) |
| --- | --- | --- |
| RN_WallDamaskRed | 95115328923362 | wall (TheMasterNinjaO) |
| RN_WallDamaskGreen | 17557248412 | foreste (xaov_Lakayleia) |
| RN_WallDamaskNavy | 93245924735654 | fancy wallpaper (DisBuilder) |
| RN_WallDamaskMint | 9502411649 | textura verde victoriana clara (FurRuBear) |
| RN_WallStripes | 1587315754 | Striped Wallpaper [Cream/Tan] (Yuvha) |
| RN_WallTiles | 748527930 | White Tile Texture (IROCK108) |
| RN_WallBrick | 106832102497540 | Old Brick Wall (SpaceSurpher) |
| RN_WallMossBrick | 12969213627 | Mossy Brick Wall (Myzicx) |
| RN_CarpetLattice | 96947613328020 | Hotel carpet (natethegamer1467) |
| RN_CarpetMedallion | 133466011073486 | Hotel Carpet (ProfessionalBloxxer7) |
| RN_CarpetMoss | 13209499244 | Moss ColorMap (voidfxul) |
| RN_FloorParquet | 132171894739555 | luxury wood parquet (Decalshejsankawaii) |
| RN_FloorHerringbone | 4546985492 | Herringbone Parquet Floor (6vrse) |
| RN_FloorMarbleWhite | 13244172992 | White Marble Floor (Myzicx) |
| RN_FloorMarbleBlack | 8569440485 | Black marble floor (Besvare) |
| RN_FloorChecker | 71661415583957 | Checkered marble kitchen tile floor (BornYETl) |
| RN_Concrete | 10438628935, 10438645466, 10438659826 | dirty_concrete colour, normal and roughness (Chrn_E; Poly Haven CC0 source) |
| RN_RustMetal | 134162642420787 | corroded metal (Soy_DarkFox) |
| RN_Ice | 6989477160 | seamless ice texture (MilleSimon) |
| RN_GoldDeco | 7105226276 | PatternNo5 (Mysteryexe1) |

Paintings (public-domain works; image ids): 18430235398 Rembrandt, *The Storm on the Sea of Galilee*
(BrotherRaskolnikov); 1409031210 Vigee Le Brun, *Marie Antoinette and her Children* (Rambo_builder);
72130553645630 moonlit coastal capriccio (SparterO9); 111154086863275 ship in a storm (dddu_dddu);
17206697773 Georgiana Cavendish (mariontje); 1564409880 *The Man with the Golden Helmet* (Andrew_Alba);
3360739154 Dutch lady with a ruff (awsomesstv80415); 130601462587585 Rembrandt Peale, *Rubens Peale with a
Geranium* (rox_llq); 91327321009394 and 140408481713108 still lifes (Verity942); 6683780280 Victorian
watermill (VIE_nnese); 5687258726 Gainsborough, *The Baillie Family* (Annie_Sparkling); 16487841857
stormy sea with a rowboat (Thxo_lgs); 230190583 Rembrandt, *St Paul in Prison* (gordonfreeman564).

Rejected: images whose own thumbnail is a moderation placeholder, decals with no matching image, tiles
that showed seams, and anything named after a film, game or brand (for example the Shining carpets).

## The Caretaker

Built by `Players:CreateHumanoidModelFromDescriptionAsync` from `src/shared/Content/CaretakerLook.luau`
(catalog items work in an NPC's description whether or not anyone owns them). If a piece fails the server
retries with the Roblox-made fallbacks, then with plain body colours.

| Piece | Asset id | Name (creator) |
| --- | --- | --- |
| Shirt | 10126112559 | Bellhop [+] (Eclipse's Trashbin) |
| Pants | 10126117868 | Bellhop [-] (Eclipse's Trashbin) |
| Dynamic head and mood | 74871478197941, 85699644348712 | The Friendly Eviscerator - Head (Roblox) |
| Hat | 84923485112253 | Bellhop Hat (Farington Industries) |
| Hair | 7611015444 | Gray Grandpa Balding Old Man Hair (DawsonDelRey) |
| Neck | 4602807964 | Black Bow Tie (WhoToTrus) |
| Waist | 8466492470 | Keyring (Reverse_Polarity) |
| Fallback head, mood, hat | 13692947484, 13692949813, 116778751 | Stare - Head, Marching Band Cap (Roblox) |

Animations are Roblox's own R15 packs (Elder, Werewolf, SitV2, R15 emotes; ids in
`src/client/Visual/CaretakerHuman.luau`), which play in every experience.

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

Every id is a public Creator Store audio asset. Alternates are tried in order at runtime if the primary
fails to load, and they follow the same rule.
The list is generated from `tools/content/audio_catalog.json` (which also records durations and
audition notes); `tools/content/gen_audio.py` refuses any entry whose source is not `roblox` or `partner`.
Only recorded sounds and licensed music ship: `tests/specs/audio.spec.luau` fails the build if any cue or
alternate is a synth tone, 8-bit blip, chiptune or electronic beep, or if the code plays a name the
catalog does not define.

<!-- audio-table: generated by tools/content/gen_audio.py, do not edit by hand -->
Owners: APMOfficial (9), ProSoundEffects (38), Roblox (21).

| Cue | Asset id | Name | Owner | Alternates |
| --- | --- | --- | --- | --- |
| `capture_charge_loop` | 9126236071 | Wind Suck Slow Backwards Swooshing Build Up  (SFX) | ProSoundEffects | 9120767390, 9120769043 |
| `capture_success` | 9116384485 | Magic Burst 1 (SFX) | ProSoundEffects | 9116384473, 9125647212 |
| `caretaker_alert` | 9045122943 | Ghost With The Most - Hit1 | APMOfficial | 1845713466, 9042321434 |
| `caretaker_grab` | 9120729973 | Whoosh Impact 1 (SFX) | ProSoundEffects | 9125989410, 9113077334 |
| `caretaker_hum_loop` | 9119469188 | Spirit Presence Constant Airy Hissing 2 (SFX) | ProSoundEffects | 9119514343, 9113586520 |
| `caretaker_keys` | 9116177077 | Keys Movement 2 (SFX) | ProSoundEffects | 9116177238, 9116161848 |
| `caretaker_search` | 9114495513 | Floor Creaks Short Med Wood Creaks 12 (SFX) | ProSoundEffects | 9114840555, 9125562923 |
| `caretaker_snore_loop` | 9113862735 | Comic Snoring Male Vocals Steady Pace 5 (SFX) | ProSoundEffects | 9113862891, 9113863048 |
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
| `elevator_ding` | 9125485591 | Desk Bell Counter Service Single Ringing Din (SFX) | ProSoundEffects | 9125485659, 9125485871 |
| `elevator_doors` | 365551881 | SlidingDoor | Roblox | 9114305290, 9114305596 |
| `elevator_move_loop` | 9125446564 | Command Room Tone Deep Air Conditioning Hum  (SFX) | ProSoundEffects | 9114533164, 9125710803 |
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
| `magnet_hum` | 9112889303 | Transformer Hum 2 (SFX) | ProSoundEffects | 9112889082, 9112889325 |
| `metal_clank` | 9116541944 | Metal Clanks 2 (SFX) | ProSoundEffects | 9116673678, 9116617140 |
| `music_escape` | 1836271798 | Spooky Chase | APMOfficial | 9042675817, 9042777725, 1848090337 |
| `music_explore` | 9043067401 | A Curious Case A | APMOfficial | 1837467266, 9043066611, 9043067384 |
| `music_lobby` | 1840096894 | Hotel Lobby (a) | APMOfficial | 1842207993, 9046234388, 1841998269 |
| `music_results_fail` | 1838221720 | Story Time - Comic - Sad | APMOfficial | 1838221912, 1844306643, 1838635121 |
| `music_results_win` | 1837762472 | Victory Dance (sting a) | APMOfficial | 1838221725, 1845466651, 1838686024 |
| `music_tutorial` | 130053244401794 | TutorialMusic_01 | Roblox | 9043066413, 9048586338, 1841928563 |
| `placement_invalid` | 17208214688 | Roblox GUI - Call Decline | Roblox | 17208353912, 17208220181 |
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
| `ui_countdown_go` | 9119643158 | Store Entry Bell 3 (SFX) | ProSoundEffects | 9119642861, 9119642830 |
| `ui_countdown_tick` | 9120917813 | Wood Impacts Soft Impacts On Temple Blocks 6 (SFX) | ProSoundEffects | 9120917438, 9120917609 |
| `ui_error` | 17208353912 | Roblox GUI - Negative | Roblox | 17208214688, 17208220181 |
| `ui_hover` | 17208339919 | Roblox GUI - Hover 01 | Roblox | 17208343514, 10066931761 |
| `ui_notify` | 99437156604053 | PV_ToastNotif | Roblox | 17208372272, 17208361335 |
| `ui_open` | 15675024286 | Roblox_UI_Whoosh_01 | Roblox | 17208405682, 17208204604 |
| `ui_ready` | 17208361335 | Roblox GUI - Notification High | Roblox | 9125485659, 9114058995 |
| `ui_reward` | 12222253 | victory.wav | Roblox | 1844442542, 1844692556 |
| `ui_success` | 17208209318 | Roblox GUI - Call Accept | Roblox | 10128760939, 99366249808641 |
| `ui_toggle` | 17208408337 | Roblox GUI - Tab | Roblox | 12222183, 9119717523 |
| `vine_grow` | 9112747580 | Beanstalk Growth 1 (SFX) | ProSoundEffects | 9114514963, 9120261928 |
| `water_fill` | 365203457 | FaucetTurnOn | Roblox | 365551014, 9120575856 |
| `water_loop` | 9114492495 | Flood Bubbling Water 1 (SFX) | ProSoundEffects | 9120606720, 365551014 |
| `wind_loop` | 9118747525 | Rumble Ambience Interior Wind Turbo Shaft 1 (SFX) | ProSoundEffects | 9114057128, 15675021174 |
<!-- /audio-table -->

## Before every release

1. Run `python3 tools/content/gen_audio.py` and `tools/check.sh` (the generator rejects community audio).
2. Play each music and loop cue once in a published test place; replace any id that fails to load (the
   runtime falls back to the alternates and logs a warning, so check the server and client logs).
3. Search `src/` for `rbxassetid://` and `rbxasset://` and confirm every hit is listed above.
4. Start a published test server and read the `[Assets]` line in the server log: it says how many props
   loaded and which keys kept their procedural fallback. Replace any id that no longer loads.
5. Confirm no `Model`, `MeshPart`, `Decal`, `Texture` or package has been inserted into the place by hand
   (the place is built entirely by Rojo from this repository).
