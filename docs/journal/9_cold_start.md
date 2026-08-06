# Cold starts — four characters, what broke, and what it taught

> **Status:** complete, and a good place to stop. Chapters [7](./7_hectic.md) and
> [8](./8_solace.md) tell the first two characters' stories in detail; this one covers
> the last two — **Tarn**, who finished a four-part compound goal with **zero human
> interventions**, and **Rell**, who did the same work but died on a hole in a fix —
> and then synthesises the whole arc.
>
> **Headline:** four brand-new characters, ~30 autonomous runs, **zero deaths**, and
> **24 defects** the warm-start character (Perry) had been quietly papering over.

## Why cold starts at all

Every result up to chapter 6 was measured on **Perry**, who by then carried weeks of
hand-written world knowledge — a zone index, shop locations, grind-spot rules — and a
141-room `world.json`. That confounds the measurement: *how much of the competence is
the agent, and how much is the prompt?*

A cold start answers it by subtraction. Same harness, same tools, knowledge removed:
a blank map, a system prompt that teaches tool discipline and no geography, and nothing
in the character's pockets. Anything such a character achieves, the loop achieved.

The measure was never "did it win" — it was **how many times must a human stop and fix
something before the loop can finish.**

## The four characters

| | Class | HP | Goal | Runs | Interventions | Outcome |
|---|---|---|---|---|---|---|
| **Hectic** | Warrior | 21 | reach level 2 | 10 | 8 | level 2, 2120 xp |
| **Solace** | Cleric | 18 | 5-part compound | 9 | 9 | level 2, 2582 xp, teleporter |
| **Tarn** | Warrior | 20 | 4-part compound | ~15 | **0** | **goal complete** |
| **Rell** | Warrior | 26 | 4-part compound | ~20 | **0** | level 2, all 4 parts, escalated one check short |

Zero deaths across every one.

## Tarn — the acceptance test

The first genuinely fair test: a brand-new character, a four-part compound goal
(*get equipped, travel to the newbie zone, earn enough gold to buy a teleporter and buy
one, provision with food and water*), and a commitment not to touch anything.

He finished it.

```
== ALL MILESTONES DONE — goal complete ==
1. [done] Get equipped with a weapon and armour
2. [done] Buy food provisions to prevent hunger
3. [done] Buy water provisions to prevent thirst
4. [done] Grind newbie zone mobs for xp and gold
5. [done] Continue hunting until enough gold for the teleporter
6. [done] Locate the shop selling teleporters and buy one
```

Final: 462 xp, 39 gold, `the teleporter` in his pack, standing in the Reading Room.

**What it cost:** five replans and roughly fifteen executor runs, because the planner
**oscillated on the buy-versus-earn dependency** — inverted at replan 1, corrected at 2,
regressed at 4 — reaching the right order by attrition rather than reasoning.

## Rell — the same work, undone by a hole in a fix

Rell got further and finished worse. The planning fixes made from Tarn's run worked
exactly as intended: **not one of his replans went to the buy/earn confusion.** The
money precondition got the first plan right, so the deterministic repair never fired.
The executor even **geared up unprompted** when the planner omitted equipping entirely —
the planner names outcomes, the executor knows the donation room is free and one room
east.

He reached level 2, 2321 xp, 345 gold, food, water, a teleporter — **all four goal
parts** — and then his plan escalated with the teleporter milestone still `pending`,
because the replan budget ran out one check short of confirming work already done.

What burned that budget was the sewer, for the **fourth** time. And that was a hole in a
fix made three hours earlier: `explore` had been leashed out of dangerous zones and the
problem declared solved. But **`hunt` had no leash at all** — its Mode 1 walks a *known*
route back to a remembered grind spot, and prey gets marked wherever it was killed,
including inside the sewer. One entrance closed, three still open.

## The 24 defects, by layer

The distribution is the most useful thing the cold starts produced.

**Tool layer — 8, all from Hectic, none ever recurred**

`recall` reporting success it never had · unlit rooms read as failed moves · a MUD
warning parsed as a room name · provisioning deadlocking combat · `consider` misread
during combat · **equipment unreadable** (the prompt sentinel matched `<used as light>`)
· loot asserted instead of reported · an API 529 misdiagnosed as a game blocker.

Solace — a different class, fewer HP, a goal type never run — hit **zero** of them.
That is the strongest single result of the exercise: the tool layer generalised, on a
fair test it did not know was coming.

**Planning layer — 13, from Solace, Tarn and Rell**

Planner inheriting the executor's token cap · `has_item` hardcoded `false` · planner
blind to gold and inventory · greedy JSON extraction · `gold_at_least` missing from the
progress signal · a flat replan budget · `has_item` matching too literally ("a cup" is
not "water") · unvalidated `done_check`s · finding-as-a-milestone · no failure memory ·
the buy-before-earn inversion · no money precondition · oversized invented targets.

**World-model / safety — 3, and mine**

The `explore` leash covering one door of four · `repair_order` treating free donation
gear as a purchase (it sent an unarmed 26-HP character to hunt) · `light_kw` matching
the slot label `<used as light>`, so every character read as carrying a lamp.

## The lessons

### 1. Tools must verify what they assert

This is the thread through every tool-layer defect. `recall` said "Safe — standing by"
to a stranded, blind character. `explore` called a successful move "blocked". `fight`
printed "Looted corpse" whether or not anything was taken. A housekeeping check
announced a sword-wielding character was BARE-HANDED. Each was a tool reporting an
outcome it had never checked.

The fix is always the same shape: **read back the result before claiming it.** And the
trap that comes with it — `teleport` replies before the destination room arrives, so a
verifying read must **flush first**, or the check fails for a character that succeeded.

### 2. The loop invents world-explanations for broken instruments

When a tool lies, the agent does not detect the lie — it constructs a story consistent
with it. An API outage became "a depleted hunting ground" and got replanned around. A
successful step into darkness became "the exit is blocked". This is why silent
misreporting is so expensive: the model's competence works *against* you, rationalising
bad data into plausible action.

### 3. The planner reasons well over facts it is given and confabulates over facts it is not

Every planning defect reduces to a missing fact. It scheduled purchases for a character
with no money — it could not see gold. It re-scheduled armour already worn — it could
not see inventory. It sent a character to train at a guild never found — it could not
see the map. It targeted a room named "Teleporter" that does not exist — nothing
validated place names. Give it the fact and the behaviour corrects immediately.

### 4. Every constraint needs a grounded predicate, or it over-applies

The most-repeated mistake of the session, and three of them were mine:

- *"Don't assume you know where places are"* → phantom guild milestones, until it had the map.
- *"Don't plan purchases you can't afford"* → a **200-gold** target for a **12-gold** item, because nothing knew prices.
- *"Earn before you buy"* → hoisted hunting ahead of **free** equipment, because "acquired" was conflated with "bought".
- *"Require a light"* → every character passed, because the equipment listing contains the word "light".

A rule is only as good as the thing it tests. Where the predicate can be made
deterministic, prefer that to a prompt instruction — `repair_order` fixes the ordering
without a planner call at all.

### 5. Safety is a property of the character, not the map

The gate began as a hardcoded allowlist of two zones — and worse, it was
`safe_to_quit_here`, a predicate written to answer *"can this body log out here safely"*.
Reused as a travel gate, it banned the sewer permanently for everyone regardless of
level or kit.

A safe zone is one the character can **reasonably expect to survive**, and that changes
as it levels and equips. The gate now asks about readiness — a lit light, food, water, a
way home — and **names what is missing** rather than refusing:

> *"MISSING: a lit light source, food. … this is not a permanent ban: get what's missing
> and it opens up."*

### 6. Goal shape drives behaviour more than any prompt line

Under *"reach 500 xp"*, the nearest respawning janitor was optimal, and Hectic ground the
town until his alignment fell 114 → 4. Naming the **place** — *"hunt in the newbie zone,
not in Midgaard town"* — fixed it instantly. Milestones are incentives; write them as the
outcome you actually want.

### 7. Checkpoints verify outcomes, not routes

The planner told Tarn to buy a weapon at the Weapon Shop. He had no money — so the
executor went to the **free** donation room instead, and `has_item "sword"` ticked
anyway. That is the offload principle paying off: the planner names *what*, the executor
decides *how*, and the check cares only about the result. Which is also why *"find the
shop"* should never be a milestone — it is a route, and the executor already has
`seek`/`explore`.

## Where we left it

**Characters** (all alive, all parked cleanly):

- **Hectic** — Warrior, level 2, 2120 xp, at the Temple.
- **Solace** — Cleric, level 2, 2582 xp, 157 gold, teleporter, 4 practice sessions unspent.
- **Tarn** — Warrior, 462 xp, 39 gold, teleporter, goal complete.
- **Rell** — Warrior, level 2, 2321 xp, 345 gold, teleporter, parked in the sewer.

**Open, none blocking:**

- The **readiness gate is unproven live** — it has unit tests but has not yet run a full
  session. Rell is the natural subject: he now owns a teleporter, so `recall` works, and
  `hunt` should skip the sewer grind spots that previously drew him back in.
- `known_places` truncates the planner's map view at 40 rooms.
- `hunt`'s guarded-room check only sees guards already present, so it cannot fire before
  the kill that summons them.
- Fountain-first provisioning: a canteen refills free forever and cost 12 coins; waybread
  cost 74. `upkeep` refills only if already standing at a fountain, and never routes there.
- `hunt` cannot use `N.<name>` targeting to pick a specific one of several identical mobs.

**What would settle the remaining question.** Tarn's zero-intervention completion is one
data point, from an advantaged-but-fair start. A second clean pass — ideally Rell, on the
readiness gate — would make it a pattern rather than an anecdote. What is *not* worth
doing is another cold start purely to see what breaks: four have converged on the same
layer, and a fifth would mostly re-measure what Tarn and Rell already showed.
