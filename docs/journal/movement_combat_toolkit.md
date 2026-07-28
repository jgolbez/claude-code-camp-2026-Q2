# The Movement & Combat Toolkit — reference

> A synthesis reference for boukensha's navigation + combat tools (built across the
> week-2 navigation arc and the week-3 combat arc). The *iteration journeys* live in
> [2_capable.md](./2_capable.md) and [3_combat.md](./3_combat.md); the `seek` design in
> [4_seek.md](./4_seek.md). A visual version of this page is published as an Artifact.

## The thesis behind every tool

A from-scratch Ruby agent plays CircleMUD as **Perry**, a level-1 Thief. The bet across
the whole build: an LLM is too slow and token-hungry to steer a MUD move by move — so
**every mechanical action is offloaded to a deterministic tool.** The model chooses
*what* and *whether*; the tools do the walking, the fighting, and the finding for **zero
model tokens**. Every tool below is an *aggregator*: one LLM decision in, many
deterministic steps executed, one distilled line back.

## The organizing idea — two axes place every movement tool

Each navigation tool answers where it sits on two questions:

- **Known vs. discover** — is the destination already on the map, or are you finding it?
- **Offloaded vs. per-step** — one call → many deterministic steps, or one call → one move?

|  | **Known destination** (already mapped) | **Discover it** (not mapped yet) |
|---|---|---|
| **Offloaded** (1 call → many steps) | `travel_to` — walk the whole shortest route to a place you've visited | **`seek` ← NEW** — explore until it maps the named room, then stop *(and `hunt` = discover **prey** by property)* |
| **Per-step** (1 call → 1 move) | `move` — one deliberate step | `explore` — grow the map one blind frontier; the agent reads each room and re-decides |

**`seek` filled the empty cell.** Before it, discovering a named place meant hand-calling
`explore` room by room — one LLM iteration each — until the token budget died. `seek` is
`explore` in a deterministic loop with a name-match stop: the "is this it? keep going?"
decision moves out of the model's turn cycle and into the tool.

## The offload tools

### `hunt` — search (find prey)
Walks room to room, **considers every mob**, and stops on one it can safely fight. Two
modes: once grind spots are known it **only cycles them and rests for respawns** — never
wandering into danger; otherwise it explores to find the first spot. It **prioritises by
value** — prefers a stronger mob for the xp (perfect-match > monster > creepy), skips
prey below a **floor** that's not worth the time (and the floor auto-scales as you level),
and *satisfices* across spots. It also **reports what it passed up**, so the choice is legible.
*Was: ~20 hand-walked moves. Now: 1 call.*

### `fight` — combat (kill to completion)
One call runs the **whole battle**: a consider gate, a wimpy safety floor, a
**skill-aware opener** (backstab — wield the piercing weapon, strike, swap back), the
kill, **chasing runners**, and looting. The model never sees a single round — just one
outcome line (result + HP + xp/level delta).

### `seek` — discovery (find a place by name)
**`hunt`, generalized from prey to places.** Loops `explore` (inheriting the over-level
and death-trap guards), checks each new room's name against the target, and stops the
moment it's mapped. Directional "intuition" is kept **deterministic** — room names and
guards carry the signal — and course-correction rides at the *call* level via a shape
summary, never per-room LLM reasoning. Once found, the place is on the map forever;
`travel_to` works after.
*Was: 15 explores + a whole failed run. Now: found the guild in 3.1s, one call.*

### Behind them
- **Skill-aware combat** reads the character's trained skills from the game (`practice`)
  and interprets them through a **class-agnostic catalog** (a Thief's backstab, a
  Warrior's bash — same code). Identity lives in config, not the tool.
- **Grind-spot memory** tags rooms where safe prey was found, so `hunt` returns to
  known-good hunting instead of re-searching.

## The safety stack — keeping a fragile Thief alive

Perry has ~23–44 HP and dies losing his gear. Every guard is deterministic and stacks
under the tools. Result: **zero deaths across nine live runs.**

Consider ladder (the game's own ratings drive engagement): **safe** → fight ·
**even** (perfect match) → fight at full HP · **some luck** → only if topped up ·
**a lot of luck / mad** → skip.

- Consider-gate before every fight
- Deterministic wimpy (auto-flee floor ≈ ⌈maxHP/3⌉)
- Mob-flee vs. Perry-flee reported truthfully (no false "wimpy saved you")
- **Heal to a target** — `rest_until hp:` sleeps to ~85% of max, provisioning as needed
- **Safe sleep** — refuse to rest/sleep with a mob in the room (never heal into an ambush)
- Over-level zones (`"above your recommended level"`) — backed out, exit marked off-limits
- Death-trap rooms (Mid-Air zeroes HP) — teleport out, exit marked forever
- Peacekeeper / town rooms — never grind (guards gang up on alignment drop)
- Poison-safe eating — never auto-eat looted meat
- Stop-on-damage while searching
- Teleporter recovery when stranded

## Results — acceptance test complete

Perry reached **level 4** and **trained a skill** at his guild — the goal set at the
combat arc's start. The chain ran end to end, without pre-positioning him:

```
hunt → fight → hunt → fight → LEVEL 4
seek "Thieves" → guildmaster (The Secret Yard) → practice backstab
```

| Metric | Value |
|---|---|
| Character level reached | **4** (from 1) |
| Live LLM runs / deaths | **7 / 0** |
| hunt→fight cycles to level up | **2** |
| `seek` time to find the guild | **3.1 s**, one call |

**Offload climb** — share of turns spent on high-level offload tools (`hunt` / `fight` /
`travel_to` / `seek`), by observation:

| Run | High-level share |
|---|---|
| Obs A | ~0% (hand-walked everything) |
| Obs B | 18% |
| Obs B3 | 31% |
| Obs B5 | 51% |
| Obs B7 | **60%** |

The mechanics moved into the tools; the decisions stayed with the model.

### Capstone — the whole toolkit, autonomous, on a blank map
A final test wiped the map and gave Perry a bare goal — *find the newbie area, kill 3
monsters* — no seeds, no parking. He **discovered** the newbie zone himself, **killed**
creepies at full HP, **healed** between fights, **refused to sleep next to a mob**, and
**never wandered** into town/sewer/chessboard (dry hunts → "rest for respawns"). It
landed 2 of 3 — blocked only by the game's **respawn clock** (a ~5-min run out-kills the
spawns), not by any tool. Discover → fight → heal → stay safe → don't wander, all on its
own.

## The toolkit, in one line

`move` · `travel_to` · `explore` · `hunt` · `fight` · `seek`, over a survival layer of
wimpy · provision · heal · safe-sleep — a fragile level-1 Thief, driven by an LLM that
makes one choice per mob and one per destination, grinds to level 4, trains, and hunts a
blank map on its own, while the tools and the game do the walking, the fighting, and the
finding. **navigation → combat → planning**; two of three abilities are done.
