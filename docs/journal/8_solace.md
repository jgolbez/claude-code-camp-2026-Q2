# Solace — a second cold start, and where the fragility actually lives

> **Status:** complete. The regression test for [7_hectic](./7_hectic.md): a *second*
> brand-new character on the repaired harness, to find out whether those fixes
> generalised or were merely overfitted to the character that produced them. Result:
> **the tool layer never failed her once.** Every new defect — seven of them — was in
> the **planning layer**, a layer Hectic's simpler goals never exercised hard enough
> to break. She finished **four of five goal parts with zero deaths**.

## Where this picks up

Hectic proved the harness lied in eight places, and we fixed all eight. But every one
of those fixes was *found on him and written for him*, which is exactly the setup where
repairs get shaped to one character's path. The open question was blunt: **could a new
player now succeed, or did we just pave Hectic's particular road?**

## Technical Goal

A second control, chosen to differ on the axes that matter:

- **A Cleric**, not a Warrior. Only `thief` has class-specific tools, so a caster runs
  entirely on the generic set — the hardest test of the "character-agnostic" claim —
  and carries spells (`armor`, `cure light`) nothing had ever exercised.
- **18 HP**, three fewer than Hectic: the thinnest survival margin yet run.
- **A compound, five-part goal**: *get equipped, find the newbie zone, earn some money,
  provision with food and water, buy a teleporter.* Hectic's goals were "go kill
  things". A provisioning chain forces the planner to sequence dependencies, express
  money as money, and verify acquisitions — three things it had never been asked to do.

The measure was **interventions**, not success: how many times must a human stop and fix
something before the loop can finish?

## Technical Uncertainty

- Do Hectic's fixes hold for a different class, or were they character-shaped?
- Can the planner handle a goal with real dependencies (earn → then buy)?
- Where is the *remaining* fragility — the tools, or the layer above them?

## The seven defects — all in planning

| # | Defect | Why Hectic never hit it |
|---|---|---|
| 1 | Planner inherited the executor's **1024-token cap**; a 5-milestone plan truncated mid-JSON | His plans were 1–3 milestones and fit |
| 2 | **`has_item` hardcoded `false`** — 5 of 9 milestones unsatisfiable by construction | His plans only used xp/level/at_place |
| 3 | Planner **blind to gold and inventory** — planned purchases for a broke character, re-scheduled gear she was wearing | He was never asked to buy anything |
| 4 | **Greedy JSON extraction** (`/\[.*\]/m`) started mid-object on any bracket in prose | Only bit when a reply happened to contain one |
| 5 | **`progressed?` ignored `gold_at_least`** — wandering counted as earning | The check type didn't exist yet |
| 6 | **Flat `MAX_REPLANS = 3`** — a 5-part goal exhausted it on things the planner couldn't know | 1-part goals rarely replanned |
| 7 | **`has_item` matched too literally** — she bought water and the check couldn't see it | — |

Number 7 is the one worth dwelling on, because it is the sharpest failure of the day:

> The planner wrote `has_item "water"`. Solace walked to the shops, spent **37 of her
> 44 gold**, and came back with **four cups and two danish pastries**. "a cup" does not
> contain the substring "water". The milestone ran four times, never ticked, and the
> plan **aborted on a goal she had already achieved.**

A planner naming an item it has never seen must guess the in-game noun. `has_item` now
tries the literal first, then the *category* the word names — deliberately generous, on
the reasoning that a false "yes" costs one skipped milestone while a false "no" burns
the whole run budget on something already done.

Two structural fixes came out of the same run:

- **Run-budget exhaustion now replans** rather than aborting. "Failed four times" is a
  blocker report like any other; discarding the remaining milestones (with five replans
  unused) threw away a working plan.
- **The replan budget scales with the plan** — `max(milestones, 3)`, capped at 8. A
  five-part goal legitimately needs more corrections than "go kill things".

## What held

Nothing in the tool layer broke. Across seven runs a fragile 18-HP Cleric:

- got **outfitted for free** at the donation room — the planner said "buy a weapon at
  the Weapon Shop", the executor knew better from its briefing and went where it was
  free, and `has_item` verified the **outcome** rather than the route;
- **mapped and walked out of the sewer unaided**, the trap that stranded two characters;
- provisioned **entirely off the housekeeping notes** — nothing in the goal mentioned
  shopping, and she bought food and water off an injected `[upkeep]` line;
- never once received a lie: no false recall, no successful move called blocked, no
  bare-handed report while armed;
- **died zero times.**

## The lesson

Every constraint given to the planner gets over-applied unless it is paired with a way
to check itself:

- *"Don't assume you know where places are"* → phantom guild milestones, until it was
  given the map.
- *"Don't plan purchases you can't afford"* → a **200-gold** target for a **12-gold**
  teleporter, because nothing told it prices. (Failed purchases now report the cost.)
- *"Use has_item"* → nouns the game never uses, until matching learned categories.

The planner reasons well over facts it is given and confabulates over facts it is not.
That is the same failure the tool layer had — `recall` claiming success, `explore`
calling a successful move blocked — one storey up.

## Where we paused

- ~~**The sewer is a tar pit.**~~ **FIXED.** Three characters fell in before
  `explore` got the same danger leash `seek` already had: a blind step that crosses
  into an unsafe zone now backs out, marks that exit off the frontier, and says so.
  Entering deliberately with `move` is still allowed.
- **`at_place` names are unvalidated** — the planner repeatedly targeted a room called
  "Teleporter", which does not exist and can never tick.
- ~~**Alignment is invisible.**~~ **FIXED.** `score_stats` now parses it and `fight`
  reports the drift whenever it moves, warning as it falls toward zero and loudly once
  it turns negative — the state that makes city guards hostile.
- `hunt`'s guarded-room check still cannot fire before the kill that summons guards;
  `known_places` still truncates at 40 rooms; fountain refills are still not preferred
  over purchases.

## Postscript — plan validation, and an honest accounting

Two more defects surfaced after the main run, both the same shape: the planner asserting
a checkpoint nothing could evaluate. It asked three separate times to reach a room called
**"Teleporter"** (no such room — the vendor is in the Reading Room), and once for
`gold_at_least 57` from a character holding exactly 57.

The fix is the tool layer's lesson one storey up — **verify at the boundary**. Every
`done_check` must now be *evaluable now* and *not already true* before a plan is accepted;
anything else is dropped, and an empty result bounces back to the planner. The deeper rule
went into the planner's contract: **finding somewhere is not a milestone.** "Find the shop
that sells X" is *how* you accomplish "own X" — the executor has `seek`/`explore` for that.
Write the milestone that owns the outcome and let the search happen inside it.

That worked as prevention rather than repair: the next plan came back as two terminal,
verifiable milestones with nothing for the validator to drop, and completed with **zero
interventions** — Solace reached **level 2 (2582 xp, 157 gold, 25 HP)** and bought the
teleporter.

**But that run does not prove much, and it should not be read as an acceptance test.**
She began it already equipped, fed, watered, solvent, on a map she had built, with a goal
that amounted to "buy something you can afford" and "hunt where you have already hunted".
It was an easy run from an advantaged position.

The honest accounting across both characters:

| | Runs | Interventions |
|---|---|---|
| Hectic | 10 | 8 |
| Solace | 9 | 9 |

**The intervention rate did not fall.** What changed was *where* the defects live, not how
many there are. That is worth something — eight tool-layer defects found on a Warrior, and
**zero of them recurred** for a Cleric with a different combat profile, fewer hit points,
and a goal type never run before. The tool layer generalised, on a fair test it did not
know was coming.

What is **not** established is that a character can go from nothing to a compound goal
without a human in the loop. Neither character did that. The only thing that would settle
it is a third cold start, untouched, judged pass/fail — and the reasonable expectation is
that it finds more planning defects, because that layer has had one session of exposure
against the tool layer's several weeks.

## Result

**723 xp → level 2, 2582 xp, 157 gold, a teleporter, zero deaths.** Four of five parts of
the original compound goal, then the fifth closed in a follow-up run.

Seven interventions during the main run, nine in total, **none of them Hectic's and none
of them in the tools**. The character-facing harness held. The plumbing above it — the
layer that turns a sentence into checkable milestones — is where the work now is, and it
has not yet been tested by anything that did not have a human watching it.

> **Follow-up:** it was, twice. See [9_cold_start](./9_cold_start.md) — **Tarn** completed a
> four-part compound goal from a genuine cold start with **zero interventions**, and **Rell**
> matched the work but lost his replan budget to a hole in the `explore` leash (`hunt` had
> none). That chapter also synthesises the lessons across all four cold-start characters.
