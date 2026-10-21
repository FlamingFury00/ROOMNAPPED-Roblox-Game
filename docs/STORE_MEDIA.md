# Store media plan (A09)

Everything on the store page must show something a new player can actually do in this build. The
"Proof" column names where each shown moment happens, so the media can be re-checked before every release.

## Copy

**Name:** ROOMNAPPED

**Short description (first two lines matter most):**
> Steal the room. Build your escape. Unfold hotel rooms out of suitcases to freeze floods, blow away
> danger and grow bridges — then grab the target room and run before the Caretaker wakes up!

**Long description:**
> 🧳 Carry rooms in your suitcase and unfold them into any glowing doorway.
> ❄️ Freezer turns a flooded hall into an ice bridge. 💨 Fan blows crates, carts and even the Caretaker.
> 🫧 Laundry floods basins and douses fires. 🌿 Greenhouse grows vine bridges. 🧲 Magnet drags metal crates.
> 🔑 Combine rooms for combos, find golden keys and finish bonus challenges.
> 🏃 Fold up the target room, carry the suitcase back to the elevator and escape before time runs out.
> 👥 Play solo or with up to 4 friends — revive each other, ping the way and share the loot.
> 🎨 Earn credits to unlock room skins and suitcases. No paid items.
> Works on computer, phone, tablet and controller.

**Genre:** Adventure (alternatively Puzzle). **Max players:** 4.

## Icon (512 × 512)

A closed brown suitcase in three-quarter view, lid cracked open, with a tiny glowing hotel room spilling out
of it: frosted blue floor, an ice-bridge sparkle and the gold room-number plate. Gold rim light on a deep
purple background (the interface colours). No text — it must read at 150 px. Build it in Studio from the
real suitcase prop (`SkinDefs` default suitcase) and the Freezer prefab, then capture with the camera
looking slightly down.

## Thumbnails (1920 × 1080)

| # | Concept | Shot | Proof |
| --- | --- | --- | --- |
| 1 | **"STEAL THE ROOM."** The core trick. | Over-the-shoulder: a player holds the Freezer suitcase at a glowing door; the flooded hall beyond is half water, half fresh ice with mist rolling off it. Big caption top-left. | Check-In (M0): Freezer at S1 freezes flood B1. |
| 2 | **"BUILD YOUR ESCAPE."** The payoff and the threat. | A squad of three runs toward the elevator carrying the stolen suitcase down an ice bridge; the Caretaker looms behind with its lantern; the HUD escape clock reads 0:20 in red. Caption bottom-right. | Any mission after the capture: Escape phase with the Caretaker chasing (`Escape 90s` / `Caretaker on` test tools speed up the setup). |

Optional extras once the first two are live: the Fan blowing a crate into a broken floor (Luggage Line,
crate bridge combo) and the vine bridge over the great chasm (Greenhouse Atrium).

## Gameplay clip (≤ 30 s)

| Time | Shot | Proof |
| --- | --- | --- |
| 0–3 s | Lobby elevator doors open on the flooded hall; objective pill "Find the Laundry Room down the hall". | M0 start |
| 3–8 s | Press 1, walk to the glowing door, the Freezer unfolds from the suitcase, the flood freezes with a crackle. | M0, S1 |
| 8–13 s | Ice launch: Fan blowing forward across the ice throws the player over the broken floor (combo stamp "Ice launch"). | Frostbite Floor (M2), S1 + S2, gap G1 |
| 13–19 s | Hold to steal the target room: the ring fills, the room folds into the suitcase with the capture burst. | Any capture point |
| 19–27 s | The Caretaker wakes ("The Caretaker woke up!"), the alarm lights pulse, the squad sprints back across the ice and dives into the elevator. | Escape phase |
| 27–30 s | "ROOM STOLEN!" results with the new room blueprint. End card: ROOMNAPPED logo. | Results screen |

The hook must work without sound: every beat above has a visual (ice forming, combo stamp, hold ring,
alarm lights, results headline).

## Capturing

- Use the **test** place with an admin account so the Test tools are available (Escape 90s, Caretaker on,
  TP target, TP checkpoint).
- Studio: graphics quality 10, *Settings → Display & comfort*: reduced motion **off**, low effects **off**.
  Hide the Roblox top bar for clean plates (`StarterGui:SetCore("TopbarEnabled", false)` from the command
  bar in a local test) but keep the game's own HUD where it tells the story (objective, escape clock).
- Record at 1920 × 1080, 60 fps. Do not add effects in editing that the game does not render.

## Truthfulness check (before each upload)

- [ ] Every room, combo, hazard and screen shown exists in the current build (see the Proof column).
- [ ] Player count, devices and "no paid items" still match the experience settings.
- [ ] The description mentions nothing that is disabled in `RoomnappedConfig` for live.
