# boukensha — a from-scratch LLM MUD agent: technical summary

> **Read this first.** The high-level story of the project in the standard journal format,
> with each chapter linking to its detailed entry. The subject: **boukensha**, a
> from-scratch Ruby harness in which an LLM plays CircleMUD/tbaMUD as **Perry**, a Thief —
> built toward one concrete goal the bootcamp set: *can an LLM agent play well enough to
> hunt down and kill the minotaur in the newbie zone?*

## The journey, in order

Each row is a chapter of the story; read top-to-bottom for the whole arc, or jump into any
detailed entry. Everything builds on the previous chapter — the thread is continuous.

| # | Chapter | Entry | Where it got to |
|---|---|---|---|
| 0 | **Pre-week — surveying agent frameworks** | [0_preweek.md](./0_preweek.md) | Compared framework styles before committing to a from-scratch harness |
| 1 | **Week 1 — the baseline harness** | [1_baseline.md](./1_baseline.md) | A working agentic loop (LLM + tools + live MUD) — it *played*, but circled and burned tokens |
| 2 | **Navigation — make movement reliable** | [2_capable.md](./2_capable.md) · [detail](./2_capable_detail.md) | Persistent world-model + pathfinding; **memory killed the circling**; the week-1 task (find the guild) solved |
| 3 | **Combat & leveling** | [3_combat.md](./3_combat.md) · [detail](./3_combat_detail.md) | `hunt` + `fight` offloaded; Perry reached **level 4** and **trained backstab** — acceptance test complete |
| 4 | **Completing the toolkit** (seek · survival · prioritization) | [4_seek.md](./4_seek.md) | `seek` place-discovery, heal + safe-sleep, prey prioritization; validated on a **wiped map**, 0 deaths |
| 5 | **Planning — a goal, decomposed** | [5_planning.md](./5_planning.md) | Two-model orchestration (**Sonnet-5 plans, Haiku executes**); validated, one real bug found **and fixed** |
| 6 | **The capstone — hunt the minotaur** | [6_minotaur.md](./6_minotaur.md) | 🏆 **The bootcamp goal, met.** Added `scan`/`locate`; the agent found the minotaur, was ambushed, and **out-meleed it to Level 5 — 0 deaths, gear intact** |
| 7 | **Hectic — a cold-start control character** | [7_hectic.md](./7_hectic.md) | Strip the world knowledge and re-measure: a blank-map L1 Warrior reached **level 2, 0 deaths**, exposing **8 defects** Perry's briefing had hidden |
| 8 | **Solace — a second cold start** | [8_solace.md](./8_solace.md) | Did those fixes generalise? An 18-HP Cleric on a 5-part goal: **the tool layer never failed** (0 of Hectic's 8 recurred); all **9 new defects were in the planning layer**. Reached **level 2, 0 deaths** — but the intervention rate did *not* fall, and autonomy from a cold start is still unproven |
| 9 | **Cold starts — four characters, and what they taught** | [9_cold_start.md](./9_cold_start.md) | Tarn finished a 4-part goal with **ZERO interventions**; Rell matched him but lost his budget to a hole in a fix. The arc: **~30 runs, 0 deaths, 24 defects** — 8 in the tools (none ever recurred), 13 in planning, 3 self-inflicted |
| ★ | **Reference — the toolkit on one page** | [movement_combat_toolkit.md](./movement_combat_toolkit.md) | Every tool + the safety stack (also a visual [Artifact](https://claude.ai/code/artifact/f6b4ad90-7ad6-46e4-9a80-f19a29e06167)) |
| ★ | **Reference — tools & reasoning** | [tools_and_reasoning.md](./tools_and_reasoning.md) | How each tool works and **how the agent decides which to use** (the division of labor: model chooses *what/whether*, tools do the *how* + embed the tactics) |

## Technical Goal

The bootcamp's concrete goal: **an LLM agent that plays a MUD well enough to hunt down and
kill the minotaur** in the newbie zone — as a fragile Thief, reaching places without
circling, fighting without dying, and leveling to earn its skills. We pursued it by building
three table-stakes abilities in dependency order — **navigation → combat → planning** — all
on one shared, persistent **world-model**, then turning that toolkit on the capstone target.
The deeper goal throughout: prove a **design pattern** — an LLM is too slow and token-hungry
to drive a MUD move by move, so **every mechanical action is offloaded to a deterministic
tool**; the model chooses *what* and *whether*, the tools do the walking, fighting, and
finding for zero model tokens. *(Ruby track; reused the `log_viz` viewer; skipped the
instructor's heavier detours — a trained room-parser, OpenTelemetry.)*

## Technical Uncertainty

- Could an LLM drive a MUD at all, or would it circle and burn its token budget (as the
  week-1 baseline did)?
- **Room identity** — can rooms get a stable id from content when some are near-identical?
- **Token economics** — is per-turn spend, not context-window pressure, the real limiter?
- **Survival** — can a fragile ~23-HP Thief be kept alive across many autonomous runs?
- **Discovery** — can the agent *find* places and prey — and a specific named boss — it
  hasn't mapped, affordably?
- **Planning** — can a stronger model decompose a fuzzy goal into steps a cheap model can
  execute, and coordinate progress across the many runs a long goal needs?

## Technical Hypotheses

- **Offload is the unlock.** Move the mechanics (pathfinding, considering, fighting,
  searching) out of the model into deterministic tools; reliability and affordability follow.
- **Navigation is a *memory* problem, not a loop problem** — give it a persistent
  world-model and it stops circling.
- **Combat is a *decision-offloading* problem, not a decision-making one** — a fight is too
  fast/text-heavy to steer round by round.
- The **same world-model** carries every ability without a redesign.
- **Offload extends to the *model* tier** — a strong planner called sparsely, with cheap
  Haiku in the loop, plans well at bounded cost.

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
  satisfice across spots — decision reported for observability). Tested end-to-end on a
  **wiped map**: Perry discovered the newbie zone, fought, healed, and stayed safe **on his
  own** — **nine live LLM runs, zero deaths**, with the share of turns on high-level offload
  tools climbing **~0% → 60%**.
- **Planning** ([5_planning](./5_planning.md)) — the offload carried up to the *model* tier:
  **Sonnet-5 plans sparsely, Haiku executes** the loop. A persistent orchestrator holds
  `plan.json` (goal + milestones + progress across runs), runs one milestone per subprocess,
  **judges completion against live game state**, and advances / re-runs / escalates. Proven
  end-to-end on a short goal. It surfaced a real bug — the subprocess model left Perry
  **link-dead** between runs and aggressive mobs beat his idle body to 0 HP — now **fixed**
  by quitting *cleanly* (save + extract from the world) on every teardown, with login
  restoring his position.
- **The capstone — hunting the minotaur** ([6_minotaur](./6_minotaur.md)) — turning the
  toolkit on the goal. Added two perception tools: **`scan`** (mobs in adjacent rooms, by
  direction; light-gated — dark = just "shuffling") and **`locate`** (a named mob's room,
  zone-scoped). The agent uses them well and reliably *finds* the minotaur — but "the massive
  Minotaur" is a fast **cross-zone roamer** (newbie zone ⇄ *Sewer, First Level*), so pinning
  it in-room for a `consider` is the live challenge. Chasing it once stranded Perry in the
  sewer, which drove a **safe-park-before-quit** fix (never leave him saved inside a
  dangerous zone). Still **zero deaths** — the safety layer held.
- **Cold starts** ([7_hectic](./7_hectic.md) · [8_solace](./8_solace.md) ·
  [9_cold_start](./9_cold_start.md)) — the control experiment for everything above: strip
  Perry's hand-written world knowledge and his 141-room map, and re-measure. **Four
  brand-new characters, ~30 autonomous runs, 0 deaths, 24 defects** that the warm start had
  been papering over. The distribution is the finding: **8 in the tool layer** (all from the
  first character, and **none ever recurred** for the next three — the tools generalised),
  **13 in the planning layer** (untested until a compound provisioning goal loaded it), and
  **3 self-inflicted** by fixes whose predicates weren't grounded. The recurring lesson, in
  both layers: **a component must verify what it asserts** — `recall` claimed a teleport it
  never made, `explore` called a successful move blocked, and one storey up the planner
  asserted checkpoints nothing could evaluate. **Tarn** finished a four-part compound goal
  with **zero human interventions**; safety became a property of the *character* (readiness:
  light, food, water, a way home) rather than a hardcoded list of zones.

## Technical Conclusions

The core bet held: **offloading the mechanics to deterministic tools makes an LLM a reliable
MUD player.** A fragile Thief that circled aimlessly and hit the token wall in week 1 now
navigates, grinds to level 4, trains skills, plans its own goals, and hunts a named boss on a
blank map — one model decision per mob, one per destination — without dying. Every hypothesis
held (content fingerprints give stable ids; an adjacency list on confirmed moves suffices;
combat is offloadable; the one world-model carried navigation, combat, survival, discovery,
and planning; **offload extends to the model tier**). The persistent surprise stayed true to
the end: **the limiter is almost always navigation/finding** — the combat arc kept reaching
back into it, and the capstone reduces to it too (finding and *holding* a fast roamer).
Planning's one real bug (link-dead between runs) is fixed. **🏆 The capstone is cleared: the agent
killed the minotaur and reached Level 5.** The arc went "can we find it?" → "is the character strong
enough?" → *done*: the toolkit `locate`s the boss on the first try and `travel_to`s to it; at L4 the
go/no-go gate correctly refused an *initiated* fight (*"luck and great equipment"* = dangerous) and
Perry fled with full gear; then, closing the last 784 XP to L5, the aggressive minotaur **ambushed**
him mid-hunt and he **out-meleed it to the level** — surviving at 17/53 HP, looting, retreating to
rest, and re-assessing (a respawned minotaur now reads *"a lot of luck"*), all with **zero deaths**.
Two lessons banked: (1) `consider`'s danger tiers are **conservative, not absolute** — "dangerous"
meant *RNG-dependent*, not unwinnable, so the gate is a sane floor rather than an oracle; (2) asking
*"how did he backstab three times?"* surfaced a **reporting bug** — the `fight` tool inferred a
landed backstab from the *absence* of a reject line, and combat spam hid the reject; now fixed
(detect already-in-combat up front, skip the impossible opener, harden the read). What remains is
**polish, not the goal**: the one open mechanic is **weapon efficacy is unobservable** — the MUD
exposes damage *type* but hides damage *dice*, so "is this sword better?" needs an `identify` read or
an empirical damage-sampler tool (wield, hit a weak mob N times, rank by observed mean); and the
*fight* path still wants a unit test (the map layer already has one). Parked follow-ups (in the detail entries): the parse_room
parens/fingerprint migration is superseded by door-stable identity; a bounded nearby explore
so a single grind spot isn't respawn-bound; disambiguating name-based `travel_to`/`seek`
(room names repeat); and camp/intercept tactics for the roaming boss. One more closed en
route: a recurring **stray-map footgun** — a pwd-relative map path that silently loaded a
separate, near-empty `world.json` and *impersonated* broken recall/`travel_to` — is now fixed
at the source (walk up to the real map, like git finds `.git`), surfaced by a load-time
`world map: <path> (<n> rooms)` log line, and pinned by boukensha's **first test suite**
(`rake test`), so it can't masquerade as a nav bug a third time.

## Key Takeaway

Give an LLM a memory and offload every mechanic — walking, fighting, healing, planning,
finding — and a level-1 Thief that once wandered in circles will grind to level 4, train at
its guild, decompose its own goals, and hunt a named boss across a blank map; **what's left to
build is rarely the fighting — it's remembering, and finding, where the fighting is good.**
