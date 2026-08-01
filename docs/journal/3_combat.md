# Week 3: Combat & Leveling — earning the right to train

> **Status:** ✅ **ACCEPTANCE TEST COMPLETE** — Perry reached **level 4** (Obs B7) and
> **trained a skill** at the Thieves' guild. The last blocker (re-finding the guild on
> the reset map) was solved by a new `seek` tool — offloaded place-discovery — which
> found the guild in one call; see [4_seek.md](./4_seek.md). This is the readable review
> (iteration journey, findings, conclusions); the full blow-by-blow — per-slice designs,
> every observation, the navigation-hardening cluster — is in
> [3_combat_detail.md](./3_combat_detail.md).

## At a glance

| Step | What it was | What it taught |
|---|---|---|
| Pre-reg | Combat as **decision-offloading**, not decision-making | Set the bet: the LLM picks the mob, the tools run the fight |
| Obs A — watch | Ran the unchanged build | No combat happened — the budget died in the **search** phase (hand-walking for prey) |
| Slice B — `hunt` | A tool that walks + considers to find safe prey | Turned 20 move-calls into one decision; proved the newbie *dungeon* is too tough |
| Slice C — `fight` | Skill-aware fight-to-completion (backstab opener, class-agnostic) | Skills read from the game + a shared "how to use them" catalog |
| Obs C | `fight` live vs a clueless newbie | One call: backstab → kill → loot → +xp, **zero damage** |
| Obs B — LLM run | Haiku drives hunt→fight | **Thesis proven** (2 decisions = 1 mob), then a `(d)` crash forced a hand-walk fallback |
| Obs B2 | Clean re-run | No crash — but the blocker **moved to prey-finding**; hunt wandered into danger |
| Slice D | Over-level back-out, stop-on-damage, chase timing, safe rest | Made the search safe and the chase actually catch runners |
| Obs B3 | Fully-plugged run | **5 clean kills, no death** — but the budget went to *finding* the grind spot |
| Slice E | Grind-spot **memory** (+ Peacekeeper/town avoidance) | Remember where the hunting is good; don't grind town |
| **Result** | — | **Combat is solved as offload; the last wall was navigation, now addressed** |

## The goal

Make **combat and levelling reliable** enough that a fragile level-1→3 Thief can gain
a level and spend the resulting practice session to train a skill — end to end, from a
live LLM run, without dying. It's the second of three table-stakes abilities
(navigation → **combat** → planning) and stands on the same persistent world-model. The
acceptance test: *"gain a level and train a skill at your guild."* — the exact thing
Obs 12 (week 2) got one game-mechanic short of.

## The thesis

**Combat is a decision-*offloading* problem, not a decision-*making* one.** A real fight
is too fast and text-heavy for an LLM to steer round by round — so push the loop *down*:
to a tool, and below that to the MUD's own auto-combat. The model chooses only *which*
mob and *whether* to keep going; deterministic tools do the considering, the wimpy
safety, the opener, the kill, the looting. Every mechanical action costs zero model
tokens. Everything below tests that bet.

## What happened — the iteration journey

This arc is a story about **chasing the limiter as it moved.** The core thesis was
proven early; each iteration then fixed whatever *new* thing had become the bottleneck.

**Watch first (Obs A).** Handed the unchanged build the task. The agent behaved
*correctly* — set wimpy, considered every mob, used structured tools — and still burned
its whole budget without a single fight, because it **hand-walked 20 rooms hunting for
prey**. The gap wasn't combat discipline; it was that no tool fit *searching for a
fightable mob*. → build `hunt`.

**The two offload tools (Slices B & C).** `hunt` walks room to room, considers each mob,
and stops on safe prey — the search offload. `fight` runs a whole battle to completion:
a `consider` gate, a wimpy floor, a **skill-aware opener** (for a Thief: backstab, using
the piercing weapon, then swap to the main), the kill, the chase, the loot — returning
*one line*. Skills are read from the game (`practice`) and interpreted through a
class-agnostic catalog, so the same code plays a Thief's backstab or a Warrior's bash.
Validated live (Obs C): one call killed a clueless newbie via backstab for zero damage.

**The thesis, proven — then a bug (Obs B).** The LLM drove it, and for two glorious
iterations it was exactly the dream: `hunt` → *"found prey"* → `fight` → *"killed,
backstab landed, +203 xp, looted"* — **one decision per mob, no round spam.** Then
`hunt` crashed on a `(d)` closed-door token, the agent fell back to hand-walking, and
the budget died. The *thesis held*; a parsing bug didn't. Fixed the crash.

**The limiter moves — prey-finding (Obs B2 → Slice D).** With the crash gone, a *new*
bottleneck surfaced: hunting was unsafe. `hunt` wandered into over-level zones (Perry
bled 37→11 HP), and the chase never caught runners (a timing bug). Slice D made the
search safe — back out of *"above your recommended level"* zones, stop on damage, fix
the chase timing — and made resting safety- and hunger/thirst-aware.

**Combat is solved; navigation is the wall (Obs B3).** The fully-plugged run nailed the
combat: **5 clean backstab kills, full HP throughout, no death**, and the runners now
died (chase fixed). But it spent its first ~19 iterations *wandering to find a grind
spot*, leaving only enough budget for 5 kills, not the ~16 for a level. The map was
*intact* (110 rooms, all connected) — the agent remembered the terrain but **not where
the good hunting was**, and `hunt` preferred unexplored frontiers over known-good rooms.

**Remember where the hunting is good (Slice E).** Added grind-spot *memory*: `hunt` tags
rooms where it finds safe prey and, on its next call, routes to the nearest known spot
before exploring blind. A user correction sharpened it — Main Street's "Easy" janitors
are a *trap* (Peacekeepers gang up as your alignment slips; `consider` only sees the
1v1). So `hunt` now skips guarded rooms, and the grind ladder is recorded: **newbie zone
(1–5) → sewer (with teleporter + light) → never town.**

## Key findings

- **The offload works, and it's cheap.** When the tools run, one LLM decision covers
  one whole mob — search, backstab, kill, chase, loot — with zero combat tokens.
- **Skill-awareness can stay class-agnostic.** Read what's trained from the game; keep a
  shared catalog of *how* each skill is used. No "Thief" hardcoding.
- **Safety is a stack, and it held.** Consider-gate + deterministic wimpy + accurate
  flee attribution + over-level back-out + stop-on-damage + teleporter recovery kept a
  fragile Thief alive across three full LLM runs — including a Black-Knight zone.
- **`consider` rates a duel, not a room.** It called town scavengers "Easy" while blind
  to the Peacekeepers that make town a death trap — a real limit of the signal.
- **The map remembers terrain; it needed to remember *value*.** Grind-spot memory was
  the difference between re-searching every run and going straight to the kill.
- **The token wall was never combat** — it was navigation flailing (hand-walks, blind
  searches) inflating the per-turn spend. Fix the navigation, free the budget.

## Conclusions

The core bet held: **combat is a decision-offloading problem.** A fragile Thief, driven
by an LLM that makes one choice per mob, grinds clean backstab kills while the tools and
the game do the fighting. The supporting bets held too — the fight degrades gracefully
when a precondition fails, skills stay class-agnostic, and the same world-model that
carried navigation now carries prey knowledge. The striking pattern is that **every
surprise was downstream of *working* combat**: the limiter kept moving — a parsing
crash, then prey scarcity, then unsafe searching, then grind-spot rediscovery — and each
was a *navigation* problem wearing a combat costume. The acceptance test (level 4 +
train) now waits only on the next run confirming the grind-spot memory routes the whole
budget into the proven loop. New uncertainty parked: the parse_room parens/fingerprint
migration, a `move`-level over-level guard, and the sewer as a second grind ladder.

## Key takeaway

Make the tools own the *whole* fight — search, opener, kill, chase, loot, and safety —
and an LLM playing a fragile Thief will grind clean kills for one decision each; what's
left to solve isn't the fighting, it's **remembering where the fighting is good.**

## What's next

Obs B4 — the payoff run — to confirm grind-spot memory closes the level-4 + train test.
Then the third ability (**goal planning**), and the parked follow-ups (parens/fingerprint
migration, sewer grind ladder, a move-level over-level guard).

---

> **📖 Story thread** — *Prev:* [← 2. Navigation](./2_capable.md) · [↑ Overview](./00_summary.md) · *Next:* [4. Completing the toolkit →](./4_seek.md)
