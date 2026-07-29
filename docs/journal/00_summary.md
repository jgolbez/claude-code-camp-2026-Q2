# boukensha — a from-scratch LLM MUD agent: technical summary

> **Read this first.** A high-level summary of the project in the standard journal
> format; each section links to the detailed entry for deeper reading. The subject:
> **boukensha**, a from-scratch Ruby harness in which an LLM plays CircleMUD/tbaMUD as
> **Perry**, a level-1 Thief.

## At a glance — where to dig in

| Arc | Detailed entry | Outcome |
|---|---|---|
| **Navigation** (make movement reliable) | [2_capable.md](./2_capable.md) · [detail](./2_capable_detail.md) | Persistent world-model + pathfinding; the week-1 task (find the Thieves' guild) solved |
| **Combat & leveling** | [3_combat.md](./3_combat.md) · [detail](./3_combat_detail.md) | Perry reached **level 4** and **trained a skill** — acceptance test complete |
| **Completing the toolkit** (seek · survival · capstone · prioritization) | [4_seek.md](./4_seek.md) | `seek` place-discovery, heal + safe-sleep, autonomous blank-map validation, prey prioritization |
| **Reference** (matrix · tools · safety · results) | [movement_combat_toolkit.md](./movement_combat_toolkit.md) | The toolkit as a single page (also a visual [Artifact](https://claude.ai/code/artifact/f6b4ad90-7ad6-46e4-9a80-f19a29e06167)) |

## Technical Goal

Build an LLM agent that plays a MUD *reliably* as a fragile character — reaching a
destination without circling, fighting without dying, and gaining a level. Structured as
three table-stakes abilities in dependency order — **navigation → combat → planning** —
all standing on one shared, persistent **world-model**. The deeper goal is to prove a
**design pattern**: an LLM is too slow and token-hungry to drive a MUD move by move, so
**every mechanical action is offloaded to a deterministic tool** — the model chooses
*what* and *whether*, the tools do the walking, fighting, and finding for zero model
tokens. *(Ruby track; reused the `log_viz` viewer; skipped the instructor's heavier
detours — a trained room-parser, OpenTelemetry.)*

## Technical Uncertainty

- Could an LLM drive a MUD at all, or would it circle and burn its token budget (as the
  week-1 baseline did)?
- **Room identity** — can rooms get a stable id from content when some are near-identical?
- **Token economics** — is per-turn spend, not context-window pressure, the real limiter?
- **Survival** — can a ~23-HP Thief be kept alive across many autonomous runs?
- **Discovery** — can the agent *find* places and prey it hasn't mapped, affordably?

## Technical Hypotheses

- **Offload is the unlock.** Move the mechanics (pathfinding, considering, fighting,
  searching) out of the model into deterministic tools; reliability and affordability
  follow.
- **Navigation is a *memory* problem, not a loop problem** — give it a persistent
  world-model and it stops circling.
- **Combat is a *decision-offloading* problem, not a decision-making one** — a fight is
  too fast/text-heavy to steer round by round.
- The **same world-model** carries all three abilities without a redesign.

## Technical Observations

- **Navigation** ([2_capable](./2_capable.md)) — rooms fingerprinted to stable ids, a
  directed adjacency graph on confirmed moves, BFS `travel_to`/`explore`, room-text
  distillation, prompt caching. **Memory killed the circling** (the core thesis), and the
  agent found the Thieves' guild. The limiter was per-turn *token spend*, fixed by
  distillation + caching — not context-window pressure (peaked <3%).
- **Combat & leveling** ([3_combat](./3_combat.md)) — the offload proven: **`hunt`** (find
  prey) + **`fight`** (kill to completion: consider-gate, deterministic wimpy, skill-aware
  backstab opener, chase runners, auto-loot). Skill handling is **class-agnostic** (read
  from the game, interpreted via a shared catalog). Perry went **1 → level 4 → trained
  backstab**. The recurring surprise: *every* limiter downstream of working combat was a
  **navigation** problem in disguise — a parsing crash, prey scarcity, then grind-spot
  *rediscovery* — which drove a burst of **navigation hardening** (reverse-edge inference,
  door-stable room identity, grind-spot memory, a two-mode never-wander `hunt`).
- **Completing the toolkit** ([4_seek](./4_seek.md)) — **`seek`** (offloaded discovery of a
  place by name) filled the last cell of the movement matrix and found the guild in **one
  call (3.1s)** where hand-`explore` had failed for a whole run. A **survival layer** was
  added (heal to a target via sleep; refuse to sleep next to a mob), and **prey
  prioritization** (prefer the strongest safe mob, skip prey below an auto-scaling floor,
  satisfice across spots — with the decision reported for observability).
- **Validation** — the whole toolkit was tested end-to-end on a **wiped map**: Perry
  discovered the newbie zone, fought, healed, and stayed safe **on his own**. Across
  **nine live LLM runs, zero deaths.** The share of turns spent on high-level offload
  tools climbed **~0% → 60%** from the first watch run to the last.

## Technical Conclusions

The core bet held: **offloading the mechanics to deterministic tools makes an LLM a
reliable MUD player.** A fragile Thief that circled aimlessly and hit the token wall in
week 1 now navigates, grinds to level 4, trains a skill, and hunts a blank map for one
model decision per mob and one per destination — surviving nine runs without dying. Each
supporting hypothesis held (content fingerprints give stable ids; an adjacency list on
confirmed moves suffices; combat is offloadable; the one world-model carried navigation,
combat, survival, and discovery). The persistent surprise is that **the limiter was
almost always navigation** — even the combat arc kept reaching back into it — which is
why the toolkit's final shape (`move · travel_to · explore · hunt · fight · seek` over a
survival layer of wimpy · provision · heal · safe-sleep) is as much a navigation result
as a combat one. **Navigation → combat is done and proven; the third ability, planning,
is the next thread.** Parked follow-ups (in the detail entries): the parse_room
parens/fingerprint migration is superseded by door-stable identity; a bounded nearby
explore so a single grind spot isn't respawn-bound; richer directional biasing for `seek`.

## Key Takeaway

Give an LLM a memory and move every mechanic — walking, fighting, healing, finding — into
deterministic tools, and a level-1 Thief that once wandered in circles will grind to
level 4, train at its guild, and explore a blank map on its own; **what's left to build
is rarely the fighting — it's remembering, and finding, where the fighting is good.**
