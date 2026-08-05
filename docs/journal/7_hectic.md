# Hectic — a cold-start character, and the eight bugs he found

> **Status:** complete and validated. A **control experiment**: everything before this
> chapter was measured on **Perry**, who carries weeks of hand-written world knowledge and a
> 141-room map. Hectic is the same harness with that knowledge removed. He reached
> **level 2 from a blank map with zero deaths** — but the value of the chapter is the
> **eight defects** the cold start exposed, seven of which had been invisible because Perry's
> briefing papered over them.

## Where this picks up

By [6_minotaur](./6_minotaur.md) the toolkit looked finished: navigation, combat, planning,
and a capstone kill. But a fair reading of those results has to admit a confound — **how much
of Perry's competence is the agent, and how much is the prompt?** His `system.md` hands him a
zone index, shop locations, a teleporter, and grind-spot rules; his `world.json` holds 141
rooms he has already walked. Strip that away and what remains?

## Technical Goal

Build a **control character** to separate the loop from the briefing, and use the difference
as a bug-finding instrument. A cold start should fail in places a warm start never touches.

**Hectic**: male Warrior, level 1, 21 HP. No gear, no gold, no light, no food, no water, no
teleporter. Empty `world.json`. A `system.md` that teaches **tool discipline and nothing
about geography**. Identity lives in config (`characters/hectic/.boukensha`), per the
project's standing rule — so the same harness plays him with no code change.

## Technical Uncertainty

- Is the tooling genuinely **character-agnostic**, or is it Perry-shaped in ways nobody noticed?
- Does the agent **use the tools properly** without a briefing telling it where to go?
- What does the loop do when its instruments are **wrong** rather than merely uninformative?
- How much world knowledge does a new player actually need — and which parts are legitimately
  "read the manual" rather than "we solved it for him"?

## What happened — ten runs

| Run | Outcome | What it exposed |
|---|---|---|
| 1 | 0 xp, stranded in the sewer | `recall` lied; unlit rooms mis-read as blocked moves; a MUD warning became a room name |
| 2–3 | 0 xp, planner stalled | Planner blind to the map; blockers triggered retries, not replans |
| 4 | 1 → 295 xp | **Combat deadlock fixed**; replan loop fired correctly twice |
| 5 | 295 → 427 xp | `consider` misread mid-combat; town grinding tanked alignment |
| 6 | 427 → 1082 xp | Goal shape steered him out of town; hunger blocked regen all run |
| 7–8 | 1082 → 1901 xp | Housekeeping cadence hooked to the wrong path; loot reported blind |
| 9 | crash | **API 529 misdiagnosed as a game blocker** |
| 10 | **level 2**, 2120 xp | Goal complete; he provisioned himself unprompted |

## The eight defects

Each is the same shape: **a tool asserting something it never verified.** That is the through
line of this chapter, and the reason a cold start found them when a warm start could not —
Perry's briefing routed him around every one.

### 1. `recall` reported success it never had
`teleport MIDGAARD` comes from a **teleporter item**, not a class power. Without one the MUD
answers `Huh!?!`. The tool teleported, re-oriented, and reported *"Recalled to \<the room you
never left\>. Safe — standing by."* Hectic called it while blind and stranded in the sewer.
**Fix:** verify arrival at the Temple; report an explicit failure otherwise. Same for the
death-trap escape and the pre-quit safe-park.

> A false negative nearly shipped with the fix: `teleport` replies *"You attempt to
> manipulate space and time."* and ends its prompt **there** — the destination room arrives
> async a moment later. The verifying `look` read stale bytes and failed even for Perry, who
> has a teleporter. **Any read after a teleport must flush first.**

### 2. An unlit room read as a failed move
Unlit rooms print only `It is pitch black...` — no exits line, so `parse_room` returned nil,
which the caller took as *"the move was blocked"*. A working well got marked `BLOCKED` and
`@current_fp` stayed pinned to the room he had **left**, so every tool result insisted he was
in the practice yard while he wandered the sewer. **Fix:** moving into an unreadable room sets
position explicitly UNKNOWN; standing still while night falls does **not** (that distinction
matters for every outdoor room).

### 3. A MUD warning became a room
Entering an over-level zone prefixes the room block with *"This zone is above your recommended
level."* — taken as the room NAME, demoting the real name into the description and minting map
room `#13`. **Fix:** filtered, alongside the existing broadcast filter.

### 4. Provisioning deadlocked combat
`good_condition` gated every non-trivial fight on `hp ≥ 90% && movement > 0 && food AND drink
carried`. With 0 gold Hectic could never carry food, so every `:even` and `:risky` mob was
refused — and in the newbie zone that is all of them. **Can't fight → can't earn gold → can't
buy food → can't fight.** The gate assumed a provisioned character; Perry always is.
**Fix:** split readiness (a real veto — resting fixes it) from supplies (a *goal*, reported as
a warning riding along with the fight outcome). This single change unblocked all progress.

### 5. `consider` misread during combat
Mid-fight, round spam lands where the rating should be, so `"You pierce the sewer rat."` fell
through to the conservative `:unsafe` default and `fight` **refused a mob already attacking
him**. The only remaining move was `flee` — which in tbaMUD costs experience
(`do_flee → gain_exp(ch, -loss)`), so the misread actively **drained** xp.
**Fix:** the complete set of `do_consider` replies was read out of the running server's
`act.informative.c`; the tool now finds the first line that *is* a rating, and when already
engaged it presses the attack rather than refusing.

### 6. Equipment was unreadable — the sentinel bug
`read_until_prompt` matched a bare `"> "`. The equipment listing renders
`<used as light>      a candle` — that `>` plus space **is** an exact match. Every equipment
read returned **32 bytes** and stopped at the first slot. Nothing in the harness could tell
whether a character was armed, which is why a housekeeping check confidently reported
BARE-HANDED for a character wielding a small sword, and plausibly why the agent abandoned a
perfectly good dagger in run 2. **Fix:** anchor on the vitals prompt (`\d+H \d+M \d+V … > `),
which only the real prompt produces. 32 bytes → 765.

> **Trap:** `mud_manager` loads from an **installed gem**, not `week0_explore/mud_manager/`.
> Repo edits do nothing until `gem build && gem install`.

### 7. Loot was asserted, not reported
`fight` discarded both `get` replies and printed "Looted corpse." on every kill — empty corpse,
failed get, and a dropped sword all read identically, and **nothing ever said what was taken**.
**Fix:** parse the replies and report actual loot (`Looted: a short sword, 23 coins.` /
`Corpse was empty.`), auto-wielding a looted weapon when bare-handed.

### 8. An API 529 was misdiagnosed as a game blocker
`RETRYABLE_STATUS_CODES` omitted **529** (Anthropic's `overloaded_error` — not a standard HTTP
code, so it slipped past a list containing 429 and every 5xx). The executor subprocess died
without printing `===REPLY===`; `run_milestone` returned the stack trace *as the executor's
report*; the orchestrator saw no state change and **replanned around an obstacle that never
existed** — three times, exhausting the replan budget on a network blip.
**Fix:** retry 529; and a missing `===REPLY===` now returns `nil`, so the orchestrator retries
the milestone and says plainly that it was an infrastructure failure, not a blocker.

## Two structural fixes to the planning loop

**Blockers now replan instead of retrying.** Previously a milestone that reported a blocker was
re-run up to four times unchanged, then aborted the plan — the executor's diagnosis was
discarded. Now `progressed?` compares game state before/after; when **nothing moved**, the
executor's own report is fed back to the planner, which routes around the obstacle (usually by
making the missing prerequisite its own `explore`/`seek` milestone). Bounded by `MAX_REPLANS`.

**`progressed?` judges against the milestone.** A single global "did anything change" signal was
wrong in both directions: too lenient (wandering one room counted as grinding), too strict (an
exploration milestone that mapped a dozen rooms and ended where it started read as a blocker,
burning a replan on a success). It now keys off the `done_check` type, and counts **map growth**
for navigation goals.

**The planner was blind to the map.** Its state block held level/xp/skills but nothing about
what had been *found*, so it cheerfully scheduled "train kick at the guild" for a character who
had never located a guild. It now receives the places actually walked.

## What the cold start proved about the agent

Worth stating plainly, because it is the control result:

- **The tooling is character-agnostic.** All 44 generic tools registered for a Warrior; only
  the thief-specific pair was absent. One `Perry` reference remained in shipped code — a comment.
- **The agent used the tools correctly.** Run 1 opened `mud_status → check → look → hunt →
  explore ×6`, finding the water shop, weapon shop, and Guild of Swordsmen on a blank map. The
  later `move`/`send_raw` flailing was a *consequence* of instruments lying, not a cause.
- **Injected actions work.** Housekeeping appends gear/supply notes to results the agent is
  about to read — never gating. Unprompted, off those notes alone, Hectic bought a teleporter,
  then bread, then a bottle, then returned to hunting. The goal mentioned none of it.
- **Goal shape drives behaviour more than any prompt line.** Under *"reach 500 xp"* the nearest
  respawning janitor was optimal, and he ground the town until alignment fell 114 → 4. Naming
  the *place* — *"hunt in the newbie zone, not in Midgaard town"* — fixed it immediately.

## What a new player legitimately knows

The cold start over-corrected at first. A briefing was added covering only what a manual would
tell you, anchored to the Temple: the donation room east (a kind soul kits out any newcomer —
**weapon included**, per trigger `#94`), the teleporter west for 12 gold, the newbie zone north,
that skills need a guildmaster and practice sessions (**not** where it is), and that food and
water are needed (**not** where to buy them). Facts were verified against the running server and
Perry's walked map — not copied from Perry's prompt.

## Where we paused

Open, none blocking:

- **Alignment is invisible.** `score_stats` never parsed it, so the agent cannot see the meter
  driving toward a Peacekeeper death. It ground janitors because nothing told it not to.
- **The guarded-room check can't fire in time.** `hunt` skips a room only if a guard is
  *currently standing in it*; guards respond to the crime, so the check is structurally unable
  to prevent the kill that summons them.
- **Fountain economics.** A canteen costs 12 coins once and refills free forever; waybread cost
  74. `upkeep` refills only if already standing at a fountain, and never routes to one.
- **`known_places` truncates at 40 rooms**, so the planner sees an arbitrary slice of a growing map.

## Result

**Level 2, 2120 xp, 31 max HP, zero deaths across ten runs** — from a naked level-1 warrior with
an empty map. The final run completed on its own: blocker → replan → provision → travel → grind
→ `ALL MILESTONES DONE`.

The through line: **the loop invents world-explanations for broken instruments.** A stranded
agent told it was safe, a successful move called blocked, a swordsman called bare-handed, an API
outage explained as a depleted hunting ground. Every one was a tool asserting something it had
not verified — and a character who knew nothing was the only one who could not compensate.
