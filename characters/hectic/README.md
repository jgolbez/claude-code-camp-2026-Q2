# Hectic — the cold-start character

Perry has played for weeks: his `world.json` holds ~140 mapped rooms and his system
prompt hands him a zone index, shop locations, and a teleporter. That makes him a
poor test of the *agent* — a lot of what looks like competence is knowledge we wrote
down for him.

**Hectic is the control.** A brand-new male Warrior, created fresh in tbaMUD, with:

- **an empty map** — no `world.json` in this directory until he walks one,
- **a world-knowledge-free system prompt** — `prompts/system.md` teaches him how his
  *tools* work and nothing about where anything *is*,
- **no gear, no gold, no light, no food, and no teleporter** — 21 HP and bare fists.

Everything he ends up knowing, the loop found for him. That's the measurement.

## Running him

Identity comes from this config dir (`BOUKENSHA_DIR`), so both entry points work
unchanged:

```bash
# Interactive REPL — type a goal at the prompt, watch the loop
BOUKENSHA_DIR=$PWD/characters/hectic/.boukensha \
  mise exec -- ruby week1_baseline/ruby/12_context/examples/play_mud.rb

# Autonomous planning run — Sonnet plans milestones, Haiku executes them
BOUKENSHA_DIR=$PWD/characters/hectic/.boukensha \
  mise exec -- ruby week1_baseline/ruby/12_context/planning/run.rb "reach level 2"
```

Add `--resume` to the planning run to continue an existing `plan.json` instead of
replanning from scratch.

## Character sheet (as created)

| | |
|---|---|
| Name / sex / class | Hectic, male, Warrior |
| Level | 1 (needs 2000 exp for level 2) |
| HP / mana / move | 21 / 100 / 84 |
| Inventory & equipment | nothing |
| Gold | 0 |
| Password | in `settings.yaml` |

## What his first run exposed (all now fixed)

Run 1 gained 0 xp and ended with Hectic stranded in the sewer. It was worth far more
than a level:

1. **`recall` claimed success it never had.** `teleport MIDGAARD` comes from the
   teleporter *item*, not the class, so Hectic got `Huh!?!` — while the tool reported
   *"Recalled to …. Safe — standing by."* It now verifies it actually landed in the
   Temple and reports a plain failure otherwise. Same for the death-trap escape and
   the pre-quit safe-park.
2. **An unlit room was read as a failed move.** The step *had* succeeded; the map
   marked the well down out of the practice yard `BLOCKED` and then kept reporting
   the practice yard as his location while he wandered the sewer. Moving into the
   dark now sets position explicitly UNKNOWN. Standing still while night falls does
   *not* — that distinction matters for every outdoor room.
3. **A MUD warning became a room.** Entering an over-level zone prefixes the room
   block with "This zone is above your recommended level.", which was taken as the
   room NAME — map room `#13`, with the real name demoted into its description.
   Filtered now, like the existing broadcast filter.

Regression tests for 2 and 3 live in `test/world_model_dark_room_test.rb` and
`test/world_model_room_name_test.rb`.

**Still true:** he has no teleporter and no light. The sewer remains a one-way trap —
four rooms in Midgaard drop *down* into it and only `7030 → 3030 The Dump` climbs
back out.
