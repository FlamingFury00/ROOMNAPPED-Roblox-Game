# ROOMNAPPED — Project Design

**Version:** 0.1 · 14 October 2026 · Proposed design for a small team.

**Promise:** Steal the room. Build your escape.

**Phases:** P0 = prototype; P1 = limited public test; P2 = expansion after validation.

**Scope:** 87 component specifications: 50 P0, 29 P1, and 8 P2. All P0/P1 components are Planned; P2 components are Deferred.

## 1. Product decisions

| Decision | Design |
| --- | --- |
| Core loop | Equip two rooms → explore → combine effects → capture a room → extract → keep the reward. |
| Players & platform | Mobile-first + keyboard/mouse. P0 tests solo/two-player; P1 supports one squad of up to four per server. |
| Retention hypothesis | Rooms must create new solutions and memorable team mistakes. Repeated play—not catalogue size—decides expansion. |
| Deliberately excluded | Free building, trading, PvP, stamina, paid power and chat-dependent puzzles. Showroom and paid cosmetics wait for P2. |

## 2. Build order

| Gate | Deliverable | Decision |
| --- | --- | --- |
| G1 • P0 | One corridor, three room tools and one complete capture/escape loop. | Do players invent a combo and retry? |
| G2 • P1 | Reliable multiplayer, saved rewards, onboarding and six tested layouts. | Do solo/group, save and failure tests pass? |
| G3 • P1 | Limited public test with event tracking and unfamiliar players. | Record results; iterate or approve expansion. |
| G4 • P2 | More functional rooms, showroom and cosmetic monetization. | Expand only after evidence from G3. |

## 3. Starting defaults

These are proposed starting values to tune after playtests, not Roblox benchmarks.

| Parameter | Value | Unit | Intent / measurement |
| --- | --- | --- | --- |
| Equipped room slots | 2 | per player | Enough for a solo combination; lock loadout during a run. |
| Active room limit | 2 | per player | One instance per equipped slot; free safe reclaim. |
| Active room limit | 4 | per team | Shared cap to contain visual and simulation complexity. |
| Starting health | 3 | hearts | Readable damage state; no numeric combat statistics. |
| Capture hold | 3 | seconds | Cancelable hold; server verifies duration and location. |
| Damage grace | 1.5 | seconds | Brief invulnerability after a hit; prevents instant repeated damage. |
| Revive hold | 3 | seconds | A nearby active teammate must finish the hold. |
| Downed window | 20 | seconds | After expiry, spectate; all downed with no recovery available ends the run. |
| Escape window | 90 | seconds | Starts after capture; adjust against observed route-completion times. |
| Solo self-recovery | 1 | per run | Automatic recovery at the last safe checkpoint, once only. |
| First useful room action | 60 | seconds max | Proposed onboarding goal; measure from first controllable spawn. |
| Mobile frame-rate floor | 30 | FPS target | Record the physical test-device model; no claim of universal performance. |
| Normal expedition minimum | 6 | minutes target | Exclude the shorter first-time tutorial. |
| Normal expedition maximum | 10 | minutes target | Target range, not a hard forced session duration. |

## 4. Component specifications

Related IDs are cross-references, not a strict dependency schedule. P0 interfaces gain P1-only states when those systems are implemented. Mark a component Done only after its acceptance test passes.

### Systems

| ID | Component | Phase | Minimum design | Done when | Related IDs | Status | Source |
| --- | --- | --- | --- | --- | --- | --- | --- |
| S01 | Project structure | P0 | Separate server services, client controllers, shared config and assets; use stable IDs. | A room can be added through config without editing unrelated systems. | — | Planned | Design |
| S02 | Run state machine | P0 | Prep → Explore → Capture → Escape → Results → Prep; one active expedition per server. | Success, failure and retry always return to a clean Prep state. | S01 | Planned | Design |
| S03 | Movement & camera | P0 | Third-person move/jump; touch + keyboard/mouse; no combat, stamina or precision aiming. | Solo and two-player corridor are traversable on a phone. | S01 | Planned | Design |
| S04 | Context interactions | P0 | One action handles sockets, capture, pickup and revive; show valid target and hold progress. | A player cannot act through walls or outside interaction range. | S03, S20 | Planned | DOC02 |
| S05 | Loadout | P0 | Equip two owned room types before a run; each equipped room can have one active instance. | Changing loadout is blocked during a run; solo can deploy both slots. | S01 | Planned | Design |
| S06 | Sockets & placement | P0 | Snap rooms to reserved side-door footprints; preview effect direction; no free placement. | Two simultaneous placement requests cannot claim the same socket. | S04, S20 | Planned | DOC02 |
| S07 | Fold & reclaim | P0 | Owner can reclaim a room only when empty of players and cargo; recovery is free. | Occupied rooms never vanish; blocked recall explains how to resolve it. | S06 | Planned | Design |
| S08 | Room effect engine | P0 | Use tagged zones and explicit interactions, not real fluid simulation; gameplay state is server-owned. | All clients agree on water, ice and enabled hazards after room changes. | S01, S20 | Planned | DOC02 |
| S09 | Combo resolution | P0 | Resolve water/cold before wind movement; effects do not stack without a defined rule. | R07–R09 pass in either deployment order; add R10 tests in P1; recall restores valid states. | S08 | Planned | Design |
| S10 | Level assembly | P0 | One authored route with reserved sockets, safe bypasses, cargo target and extraction elevator. | Either starter loadout can finish; placement never blocks the only exit. | S06, S08 | Planned | Design |
| S11 | Hazards | P0 | Tagged flood/gap, fire and moving obstacle; add electrified water only in P1. | Each hazard communicates its effect and has a recoverable solution. | S08, R07–R10 | Planned | Design |
| S12 | Room capture | P0 | Hold interaction at an intact target; fold it into shared cargo and start the escape phase. | Canceling grants nothing; a successful capture produces one cargo item. | S02, S04 | Planned | Design |
| S13 | Shared cargo | P0 | One carried suitcase per team; any player can pick it up; new room stays unusable until banked. | Downing/disconnect drops cargo safely; out-of-bounds cargo returns to a checkpoint. | S12 | Planned | Design |
| S14 | Extraction & rewards | P0 | Cargo reaching the elevator ends the run; connected members of the starting roster get the blueprint. | Reward occurs once per run; banked rooms are never lost on a later failure. | S02, S13 | Planned | Design |
| S15 | Caretaker enemy | P0 | Patrol, investigate, chase, search; capture raises alert; cold slows it but wind cannot stun-lock it. | It pursues around deployed rooms and recovers from a blocked path. | S08, S10 | Planned | Design |
| S16 | Damage & recovery | P0 | Three hearts; damage grace; downed players can be revived. Solo gets one free self-recovery per run. | Team wipe or expired escape fails safely; replay needs no payment. | S02, S15 | Planned | Design |
| S17 | Session & friends | P1 | One 1–4-player squad per server; ready in Prep; arrivals mid-run wait in a safe lobby. | Friend joins cannot alter an active mission or inherit its reward eligibility. | S02, S18 | Planned | Design |
| S18 | Solo & group scaling | P1 | Keep all objectives solo-solvable; tune enemy pressure, not required simultaneous switches. | One-, two- and four-player groups complete the same mission family. | S10, S15, S16 | Planned | Design |
| S19 | Anti-grief & disconnect | P1 | No PvP or player-body blocking; orphaned rooms recall only after empty; protect exit sockets. | A departing player cannot trap the squad or permanently strand cargo. | S07, S13, S17 | Planned | Design |
| S20 | Network authority | P0 | Server checks IDs, ownership, range, phase and request rate; client only previews input. | Spoofed capture, placement and reward requests are rejected without breaking the run. | S01 | Planned | DOC02 |
| S21 | Save profile | P1 | Versioned room IDs, skins, credits, loadout and settings; UpdateAsync, retries and session ownership. | Rejoin restores data; load failure blocks writes instead of replacing progress. | S14, S20 | Planned | DOC03 |
| S22 | Reward persistence | P1 | Use unique run IDs and durable per-player grants; retry idempotently; show Saving until confirmed. | Duplicate grant calls and reconnect tests never award twice or show a false Saved state. | S14, S21 | Planned | DOC03 |
| S23 | Progression & missions | P1 | Start Freezer + Fan; first extraction earns Laundry. Later runs earn skins or credits spent on collection skins. | Players see a chosen reward before starting; duplicate blueprints give a fixed cosmetic credit. | S14, S21 | Planned | Design |
| S24 | Onboarding | P0 | Walk → select → unfold Freezer → cross water → capture Laundry → escape; contextual prompts only. | An unfamiliar tester uses a room within the proposed 60-second target. | S03–S14 | Planned | Design |
| S25 | Lobby & collection | P1 | Small elevator lobby with mission board, loadout and room collection; no large town. | Play Again is one clear action; players can inspect and equip owned rooms. | S05, S17, S23 | Planned | Design |
| S26 | Analytics & feedback | P1 | Server funnel: spawn, deploy, combo, capture, extract, replay. Log room pair, device and version. | Published test events appear once; a short post-run feedback prompt can be skipped. | S02, S22 | Planned | DOC04, DOC05 |
| S27 | Performance budget | P0 | Cap active rooms; use simple collisions, pooled visuals and low-effects mode; test on a real phone. | Target ≥30 FPS on the recorded test device; no growing instance count after 10 runs. | S06, S08 | Planned | Design |
| S28 | Debug & regression tools | P0 | Private test commands: force phase, spawn room, simulate down/disconnect; log run IDs. | A non-developer can repeat every P0 acceptance test; public users cannot invoke tools. | S01, S20 | Planned | Design |
| S29 | Accessibility & settings | P1 | Separate sound sliders; reduce motion; readable text; icons + labels; play without chat or audio. | Entire mission remains understandable muted; settings survive rejoin. | S21, U01, U19 | Planned | DOC01 |
| S30 | Localization readiness | P1 | Store UI strings in a catalog; avoid text baked into images; ship English first. | Longer test strings fit; timers and prompts remain readable on mobile. | U01 | Planned | Design |
| S31 | Repeat-play content | P1 | Six tested layouts using the same rooms; optional combination challenges and visible reward targets. | Each layout has a valid solo route and at least two useful room solutions. | S10, S23 | Planned | Design |
| S32 | Release & rollback | P1 | Separate test/live configuration; checklist for audience eligibility, metadata, saves and feature flags. | A bad room or mission can be disabled without wiping profiles. | S21, S26, A13 | Planned | DOC06 |
| S33 | Home display | P2 | Small fixed-slot showroom for recovered rooms; visitors can safely try effects. | Display never grants expedition rewards or permits permanent visitor edits. | S21, S23 | Deferred | Design |
| S34 | Cosmetic monetization | P2 | Room themes, suitcase skins and capture effects only; show price/preview; no paid revive or power. | Canceled purchase grants nothing; retried developer-product receipts cannot double-grant. | S21, S22, U21 | Deferred | DOC07 |
| S35 | Live content pipeline | P2 | Add rooms through tags, compatible encounters and regression tests; ship one useful interaction at a time. | Every new room has a demo, a test matrix and a disable flag. | S28, S31, S32 | Deferred | Design |

### HUD & Screens

| ID | HUD / screen | Phase | Position & behavior | Done when | Related IDs | Status | Source |
| --- | --- | --- | --- | --- | --- | --- | --- |
| U01 | UI foundation | P0 | Safe-area anchored HUD; clear type, large touch targets, icon + label states; keep center open. | No clipping or overlap with Roblox controls at tested phone/tablet/desktop sizes. | S03 | Planned | DOC01 |
| U02 | Objective & phase | P0 | Top center: one short objective; Capture/Escape change the wording immediately. | Player always knows the next action; no stale text after replay. | S02, U01 | Planned | Design |
| U03 | Hearts & damage | P0 | Top left below platform UI: three hearts; brief hit cue; downed state replaces hearts. | Damage and recovery match server state; reduced-motion mode removes shake. | S16, U01 | Planned | Design |
| U04 | Room quickbar | P0 | Bottom center: two large slots with room icon/name, selected state and deployed marker. | Tap or keys 1/2 select; occupied slots and disabled states are unambiguous. | S05, U01 | Planned | Design |
| U05 | Placement preview | P0 | World-space socket outline + transparent room; effect arrows; check/cross and reason text. | Valid, occupied, cap-reached and out-of-range states cannot be confused. | S06, U04 | Planned | Design |
| U06 | Context action | P0 | Near target + right-thumb action button; desktop E; hold ring for capture/revive. | One action is offered at a time; walking away cancels the hold. | S04, U01 | Planned | Design |
| U07 | Recall & cancel | P0 | Selected room card: Recall; placement mode: Cancel. Hide irrelevant actions. | Player can exit placement immediately; occupied recall explains who/what must leave. | S07, U04 | Planned | Design |
| U08 | Threat & escape timer | P0 | Upper center beneath objective: caretaker alert icon; escape countdown appears after capture. | Danger uses text/shape as well as color/audio; timer agrees across clients. | S02, S15 | Planned | Design |
| U09 | Cargo status | P0 | Upper right: No cargo / Carried by name / Dropped / Saving / Banked. | Carrier changes and lost-cargo recovery update correctly; unbanked risk is explicit. | S13, S14 | Planned | Design |
| U10 | Team status | P1 | Left side: up to four compact player cards with downed/escaped/disconnected states. | No stale teammate card; local player is clearly marked. | S16, S17 | Planned | Design |
| U11 | Ping system | P1 | World marker + small right-side ping control; desktop Q; Help / Here / Use room. | Players coordinate a basic combo without chat; rapid ping spam is throttled. | S17, S20 | Planned | Design |
| U12 | Revive & spectate | P0 | Downed overlay: countdown and help cue; spectator buttons after elimination. | Downed players understand rescue options; solo recovery is shown once only. | S16 | Planned | Design |
| U13 | Onboarding hints | P0 | One short prompt beside the relevant control; dismiss after the action succeeds. | No wall of text; experienced players can skip or reopen controls help. | S24, U01 | Planned | Design |
| U14 | Toast & error states | P0 | Short message above quickbar for blocked placement, save/load error and earned item. | Messages do not stack over controls; persistent failures offer a safe retry action. | S06, S21 | Planned | Design |
| U15 | Lobby / Play screen | P1 | Mission board: Solo/Group, selected reward, ready state and one primary Play action. | Players cannot launch with unloaded data or an invalid loadout. | S17, S21, S25 | Planned | Design |
| U16 | Collection & loadout | P1 | Owned/locked grid, effect preview, acquisition path, two equip slots; show credits and earnable skin prices. | Locked rooms explain unlocks; equip changes persist; skin purchases deduct credits once. | S05, S21, S23 | Planned | Design |
| U17 | Mission select | P1 | Choose target skin/challenge; show hazards, estimated run length and reward before Ready. | The displayed mission/reward matches the mission the server starts. | S23, S31 | Planned | Design |
| U18 | Results & replay | P0 | Center panel: success/failure, recovered item, saving status, useful combo; Replay / Lobby. | Failed runs never imply a reward; replay cannot duplicate a payout. | S14, S22 | Planned | Design |
| U19 | Settings & help | P1 | Top-right menu: audio, reduced motion, low effects, controls help and Leave Run confirmation. | Closing restores controls; settings do not pause multiplayer or hide the world permanently. | S29, U01 | Planned | Design |
| U20 | Loading & reconnect | P1 | Full screen before spawn: loading/retry state; mid-run disconnect gives clear unbanked-loss messaging. | No blank frozen screen; unloaded profiles cannot interact or purchase. | S21, S22 | Planned | Design |
| U21 | Cosmetic shop | P2 | Lobby-only preview, owned state, price and platform purchase flow; never interrupt a chase. | Canceled/pending/confirmed states differ; no sale changes room mechanics. | S34 | Deferred | DOC07 |
| U22 | Showroom editor | P2 | Simple fixed-slot picker with place/remove; no free three-dimensional dragging. | Placement cannot overlap doors; visitors are read-only. | S33 | Deferred | Design |

### Rooms & Rules

| ID | Room / rule | Phase | Exact behavior | Done when | Related IDs | Status | Source |
| --- | --- | --- | --- | --- | --- | --- | --- |
| R01 | Freezer Room | P0 | Cold reaches tagged connected water zones; creates walkable slippery ice and slows the caretaker. | A flooded route becomes usable; ice fades only after occupants have safe footing. | S08 | Planned | Design |
| R02 | Fan Room | P0 | Directional wind moves tagged crates and gives capped player pushes; arrows show direction. | Wind + ice enables a shortcut; speed stays bounded and cargo cannot leave the map. | S08 | Planned | Design |
| R03 | Laundry Room | P0 | Adds water to one connected tagged basin; water extinguishes tagged fire and activates water switches. | Water spreads only across authored links; a visible drain restores the basin. | S08 | Planned | Design |
| R04 | Greenhouse Room | P2 | Water grows a tagged vine bridge; cold pauses growth; drain resets it safely. | Adds a new route using existing water/cold rules without arbitrary procedural vines. | S35, R03 | Deferred | Design |
| R05 | Magnet Room | P2 | Pulls tagged metal crates toward a fixed anchor; wind can compete at a bounded force. | Players can move a metal switch weight without trapping cargo or avatars. | S35, R02 | Deferred | Design |
| R06 | Deployment limits | P0 | Two equipped slots; one active instance per slot; max two active per player and four per team. | Excess request fails cleanly; reclaim frees capacity; no deployment consumes currency. | S05, S06 | Planned | Design |
| R07 | Water + cold | P0 | Resolve wet + cold as ice; water returns when cold ends; occupied ice gets a safe exit grace. | Order-independent result; recall cannot drop a standing player into an unavoidable hazard. | R01, R03 | Planned | Design |
| R08 | Ice + wind | P0 | Wind boosts sliding only in tagged zones; clamp speed and provide a safe landing/bypass. | The intended launch route works repeatedly on both keyboard and touch controls. | R01, R02 | Planned | Design |
| R09 | Water + fire | P0 | Water disables connected fire; dry state can re-enable it only after a visible warning. | Players can tell wet/safe from dry/danger; no instant unseen damage. | R03 | Planned | Design |
| R10 | Water + electricity | P1 | Exposed powered basin becomes hazardous while wet; frozen basin is treated as safe; power switch is reachable. | Power state is visible; cold/water order gives the same result; no required electrified crossing. | R01, R03 | Planned | Design |
| R11 | Geometry contract | P0 | All room prefabs share a socket origin, reserved bounds, effect outlet and occupancy zone. | Every prefab snaps correctly without covering the hallway or breaking the enemy route. | S06, S10 | Planned | Design |
| R12 | Unlocks & duplicates | P1 | Own Freezer/Fan at start; first saved Laundry capture unlocks it. Later duplicates grant fixed cosmetic credit. | No lost ability on failure; same-run captures never deploy; reward rules are visible beforehand. | S21–S23 | Planned | Design |
| R13 | Deterministic cleanup | P0 | Room removal reverses its source effects; shared zones recompute from remaining sources; no stacking multipliers. | Repeated deploy/recall cycles leave no invisible forces, orphaned collisions or stuck hazards. | S07–S09 | Planned | Design |

### Assets & Launch

| ID | Asset / gate | Phase | Minimum scope | Done when | Related IDs | Status | Source |
| --- | --- | --- | --- | --- | --- | --- | --- |
| A01 | Hotel modular kit | P0 | Corridor, corner, door socket, cargo alcove, elevator and hazard basin; exaggerated readable silhouettes. | All modules match R11 dimensions and preserve a valid main route. | R11 | Planned | Design |
| A02 | Three room prefabs | P0 | Freezer, Fan and Laundry: recognizable prop, shared shell, outlet marker and collision proxy. | All three work in the same socket and remain distinct at phone scale. | R01–R03, R11 | Planned | Design |
| A03 | Caretaker rig | P0 | One non-graphic stylized character; idle, walk, chase, react and search animations. | Threat direction and current behavior are readable without dialogue. | S15 | Planned | Design |
| A04 | Player/cargo animation | P0 | Suitcase equip, room unfold/fold, capture and carry; reuse standard movement where possible. | Gameplay timing matches visuals; animation cancellation never duplicates a room. | S03, S12, S13 | Planned | Design |
| A05 | Gameplay effects | P0 | Placement outline, cold/ice, wind arrows, bounded water, fire, hit cue and capture burst. | Effects show state rather than obscure it; low-effects mode remains playable. | S08, U05 | Planned | Design |
| A06 | Audio pack | P0 | Distinct placement, blocked, capture and success cues; hazard loops; caretaker steps/alert. | Important cues also have visual signals; loops stop when the run resets. | S02, S15, S29 | Planned | Design |
| A07 | UI art kit | P0 | Room icons, hearts, cargo/alert symbols, button states and reusable panels; no embedded body text. | Selected, disabled, pending and error states are distinguishable at small size. | U01–U14 | Planned | Design |
| A08 | Public-test content | P1 | Six compatible encounter layouts, one lobby, mission signs and a small skin reward set. | Each layout passes solo and group route tests; reward previews match actual skins. | S25, S31 | Planned | Design |
| A09 | Store-page media | P1 | One game icon, two truthful thumbnail concepts and one brief room-combo gameplay clip. | The hook is visible without sound; every advertised action exists in the build. | S31 | Planned | Design |
| A10 | Content ownership record | P1 | Track origin and permission for models, audio, fonts and images; use original or cleared assets. | No unverified marketplace scripts or unknown asset permissions remain in release. | A01–A09 | Planned | Design |
| A11 | Input & device QA | P1 | Phone/tablet/desktop; touch and keyboard/mouse; narrow screens; low graphics; network delay. | HUD stays usable; all inputs complete a mission; supported-device list matches tested builds. | U01, S27 | Planned | DOC01 |
| A12 | State & save QA | P1 | Test spam, simultaneous sockets, wipe, disconnect, replay, failed save and duplicate reward delivery. | No profile wipe, duplicate grant, stuck run or unrecoverable cargo in the test set. | S19–S22, S28 | Planned | DOC02, DOC03 |
| A13 | Publishing checklist | P1 | Verify current audience eligibility, content questionnaire, device flags, metadata and private/live settings. | Creator Dashboard checks pass for the intended audience before public promotion. | S32 | Planned | DOC06 |
| G1 | Gate: prove the mechanic | P0 | Build one corridor, three rooms, two hazards and one capture/escape; observe unfamiliar testers. | Players create a useful combo without coaching and ask to retry; otherwise revise before expanding. | S03–S16, U02–U09 | Planned | Design |
| G2 | Gate: complete the loop | P1 | Add one reliable enemy, saved rewards, four-player play, onboarding and the six-layout test set. | Complete runs succeed solo and in groups; disconnect and save tests pass. | G1, S17–S31 | Planned | Design |
| G3 | Gate: limited public test | P1 | Recruit 15–25 unfamiliar testers first; then assess larger cohorts by device and acquisition source. | Review time-to-first-deploy, replay, D1/D7 return and failure reports; make a written iterate/go decision. | G2, A11–A13, S26 | Planned | DOC04, DOC05 |
| G4 | Gate: expand & monetize | P2 | Only after G3: test new functional rooms, showroom and cosmetic purchases; set targets from observed baselines. | Expansion increases useful combinations or repeat play without degrading performance or save reliability. | G3, S33–S35 | Deferred | Design |

## 5. Implementation references

Source links and source IDs are retained from the workbook. They support platform implementation, not a prediction of popularity.

| ID | Supports | Official source | Source URL | Checked | Implementation note |
| --- | --- | --- | --- | --- | --- |
| DOC01 | HUD safe areas | On-screen UI containers | https://create.roblox.com/docs/ui/on-screen-containers | 2026-10-14 | Use safe insets; screen positions in this workbook are proposed layouts. |
| DOC02 | Server validation | Securing the client-server boundary | https://create.roblox.com/docs/scripting/security/client-server-boundary | 2026-10-14 | Validate client requests, permissions, values and rate limits on the server. |
| DOC03 | Persistent progress | Data stores | https://create.roblox.com/docs/cloud-services/data-stores | 2026-10-14 | Use protected server-side storage operations; test retries, conflict handling and failures. |
| DOC04 | Progress funnel | Funnel events | https://create.roblox.com/docs/production/analytics/funnel-events | 2026-10-14 | Instrument milestones in the player journey; thresholds in the design are not official benchmarks. |
| DOC05 | Room-combo metrics | Custom events | https://create.roblox.com/docs/production/analytics/custom-events | 2026-10-14 | Validate server-emitted custom events in a published test; do not assume Studio submission. |
| DOC06 | Publishing access | Create and publish games and places | https://create.roblox.com/docs/production/publishing/publish-games-and-places | 2026-10-14 | Recheck audience and publishing requirements at release; no fixed eligibility assumption. |
| DOC07 | Paid item fulfillment | Developer products | https://create.roblox.com/docs/production/monetization/developer-products | 2026-10-14 | Where developer products are used, process server receipts and make grants idempotent. |

## 6. Tracking notes

Start with P0. Statuses are Planned, In Progress, Blocked, Done, or Deferred. Changing this document does not change game configuration automatically.

Design denotes a proposed game-design decision. DOC01–DOC07 identify implementation references above.
