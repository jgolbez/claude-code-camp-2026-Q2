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

- **The sewer is a tar pit.** Three characters have fallen in. It is adjacent to the
  newbie zone, the obvious frontier once that zone thins, one-way in four places, and
  expensive to escape on foot. `seek` is already leashed out of dangerous zones;
  **`explore` is not**, and that is the single highest-value remaining fix.
- **`at_place` names are unvalidated** — the planner repeatedly targeted a room called
  "Teleporter", which does not exist and can never tick.
- **Alignment is still invisible** (`score_stats` never parsed it) — the only open item
  that can still get a character killed.
- `hunt`'s guarded-room check still cannot fire before the kill that summons guards;
  `known_places` still truncates at 40 rooms; fountain refills are still not preferred
  over purchases.

## Result

**723 xp, 57 gold, fully equipped, fed, watered, zero deaths** — four of five goal parts
done. The fifth needed 12 of her 57 gold; she simply could not get out of the sewer to
spend it.

Seven interventions, seven new defects, **none of them Hectic's, and none of them in the
tools**. The character-facing harness is solid. The plumbing above it — the layer that
turns a sentence into checkable milestones — is where the work now is.
