# Week 2: Capable

> **Status:** in progress. Goal / Uncertainty / Hypotheses are pre-registered up
> front; Observations are added per slice as work proceeds; each records its
> prediction *before building* so it can be checked honestly. Conclusions and Key
> Takeaway close out the week.

## At a glance

| Slice | Status | Outcome |
|---|---|---|
| 1 — Recognition + visits | ✅ | Rooms fingerprinted, visits counted; recognition holds live |
| 2 — Record the graph | ✅ | Directed edges on confirmed moves; frontier tracked |
| 3 — `plan_route` / `travel_to` | ✅ | One-call deterministic travel; **reached the Bakery** |
| 4 — Connectivity from `exits` | ✅ | Named edges incl. the way back; no longer stranded one-way |
| 5 — Movement economy | ✅ built\* | Move-cost graph + shortfall escalation (live rest/regen pending) |
| 6 — Survival / upkeep | 🔜 candidate | Keep Perry fed/watered/healed so stats regen; escalate when supplies missing |

## Technical Goal
Make **navigation reliable** — reach an intended destination without re-walking or
hitting the iteration cap. It's the first of three table-stakes abilities
(**navigation → combat → goal planning**), in dependency order: combat and planning
both stand on navigation and share one persistent world-model. So navigation is the
proving ground, but the real deliverable is that **world-model / knowledge store**,
built so combat and planning plug into it later.

**Scope discipline:** Ruby track; reuse the existing `log_viz` viewer instead of
building a monitor; skip the instructor's heavier detours (trained BERT
room-parser, OpenTelemetry/Grafana). Per-slice plan is the table above.

## Technical Uncertainty
- **Room identity** — can rooms get a stable id when a few are near-identical (the
  center-Midgaard look-alikes)? A wrong id corrupts the map and makes navigation
  *worse*.
- **Does injected memory change behavior** — will a `[memory]` line fed back into
  the loop curb the wandering, or get ignored?
- **Is the lightweight seam enough** — appending to the tool result instead of
  editing the agent loop: sufficient, or will loop surgery be needed?
- **Parsing reliability** — ANSI codes and async ticks in room text.
- **Store tech boundary** — plain JSON now; when does it force SQLite (likely when a
  live viewer must read memory mid-run)?

## Technical Hypotheses
**Core:** navigation fails because the agent has no memory and does pathfinding in
its head — not because the loop is broken. Give it a persistent world-model and move
pathfinding out of the model, and navigation becomes reliable. Supporting:
- Identity is resolvable from content (name + description + exits), with neighbour
  names + arrival edge as a tiebreaker for look-alikes.
- An adjacency list recorded on *confirmed* moves is enough to represent the map.
- BFS suffices for pathing (unweighted); no Dijkstra/A* yet.
- Right division of labour: **record and plan deterministically; the LLM only
  chooses goals and handles surprises.**
- The same store will later serve combat and planning without a redesign.

## Technical Observations

### Obs 1 — Slice 1: recognition works (2026-07-26)
- **Built:** `WorldModel` fingerprints each room (name + description + exits;
  mobs/objects excluded so wandering NPCs don't change identity), assigns a stable
  id + visit count, persists to `.boukensha/world.json`, and appends a `[memory]`
  line via the tool-result seam — no agent-loop change. Failed moves / item-looks
  record nothing.
- **Result (live):** revisits recognised both ways — look-again and walk-out-back:

  | Step | Room | `[memory]` |
  |---|---|---|
  | look | Temple | #1 first visit |
  | look again | Temple | #1 visited 2× |
  | move north | Altar | #2 first visit |
  | move south | Temple | #1 visited 3× |

  Fingerprint stable despite NPCs; `world.json` correct.
- **Next:** test the hard case — do the center-Midgaard "twins" collide?

### Obs 2 — the "twins" did NOT collide (2026-07-26)
- **Tested:** walked to Market Square, into its west/east flanking rooms.
- **Result:** both are named **"Main Street"** with identical exits, but got
  **distinct** ids — their **descriptions differ** (Armory/bakery vs. general
  store/Pet Shop), and the fingerprint includes the description. My collision
  hypothesis was wrong, in a good way.
- **Refined:** real collision risk is only **byte-identical description + same
  name/exits** (maze/forest filler, if any). Slice 1b tiebreaker → **deferred
  insurance**. Stable ids proven; build slice 2 on them.

### Obs 3 — Slice 2: the graph records itself (2026-07-26)
- **Built:** exits became a map `direction → neighbour id` (nil = frontier); each
  confirmed move writes the directed edge `prev --dir--> here` (reverse never
  assumed). `[memory]` shows targets + unexplored count; a `frontier` helper lists
  untried exits. Load-time migration upgrades slice-1 stores.
- **Result:** 8-move central-Midgaard loop → all **8 edges** correct, **13 frontier**
  exits; directedness verified (independent forward/back edges); graph filled
  incrementally across revisits.
- **Known limit:** first move of a fresh session (before any `look`) records no edge
  — minor, the agent looks on arrival.
- **Next:** slice 3 BFS; `[memory]` now carries guidance worth a real-LLM test.

### Obs 4 — Slice 3: deterministic navigation, reached the Bakery (2026-07-26)
- **Built:** BFS `route_to`, `nearest_frontier_route`, `resolve_destination`
  (#id / exact name / nearest substring). Tools **`plan_route`** (show) and
  **`travel_to`** (plan + walk the whole route in one call), returning control only
  on a compelling event — combat, blocked exit, or off-map. **LLM picks the
  destination; every move is deterministic at zero tokens.**
- **Result (live):** multi-step routes walked in one call ("… via north → north (2
  rooms). No decisions needed en route."); `#id` + exact-name resolution work (exact
  match fixed a "Temple" ambiguity). BFS unit-tested incl. directed-edge behaviour.
  **Not live-verified:** the combat/blocked interrupt (needs an aggro mob).
- **Acceptance test:** from the Temple, `travel_to "The Bakery"` walked all 4 rooms
  (`s,s,w,n`) in one call — the instructor's benchmark, where the baseline burned
  ~65K tokens and gave up.
- **Learned (directed-edge corollary):** you can only auto-travel paths already
  walked in that direction — a destination must be **discovered first**, and a
  one-way trip leaves no mapped way back until the return is walked (→ slice 4).
  Also: Perry's MUD position **persists between runs** (repeatable tests want a
  reset-to-start).

### Obs 5 — Slice 4: connectivity from `exits` (2026-07-26)
- **Predicted (before building):** reading the game's own exit *destinations* via
  the `exits` command lets us record the way back without *assuming*
  bidirectionality; named edges are safe because `travel_to` self-corrects on
  traversal; duplicate names must not create wrong certain edges.
- **Built:** on each arrival, one `exits` command (no LLM tokens) records **named
  edges** — resolved to a known room by unambiguous name (`named`), else `ambiguous`
  or `named-frontier`. `walked` edges stay authoritative and traversal self-corrects.
  Every exit now shows its destination name in `[memory]`.
- **Result (the payoff):** after a pure one-way Temple → Bakery walk, the reverse
  chain filled in as `named` edges and `travel_to` home worked in **one call, no
  walk-back** — the exact slice-3 failure, now solved. Prediction confirmed.
- **Fixed:** a false **self-loop** — Main Street's west exit names "Main Street" and
  resolved to itself. Guard: drop the self-match when the exit name equals the
  current room's name → it becomes `named-frontier`. Unit-tested (4 cases: self/twin
  cases, unambiguous, ambiguous).
- **Finding — movement is a resource:** heavy testing drained Perry to `0/83`
  movement ("too exhausted"); moves then silently fail → repeatable tests need a
  rest/reset step, and it raises the feasibility question below.
- **New uncertainty → slice 5 (movement economy):** knowing the route ≠ being able
  to complete it. Measure each move's cost (V-before − V-after, driven by sector
  type), weight the graph, and compare a route's total against current movement so
  `plan_route`/`travel_to` can say "≈N needed, you have M — rest first". Upgrades
  BFS → Dijkstra when cheapest ≠ shortest; matters for combat/planning too.

### Obs 6 — Slice 5: movement economy (2026-07-26)
- **Predicted (before building):** split the responsibility — **tooling owns the
  facts and mechanics; the LLM owns policy when short.**
  - *Deterministic tooling:* measure each move's cost (`V`-before − `V`-after),
    store per edge; estimate a route's total cost; feasibility check (cost vs
    current `V`); execute `rest_until(V ≥ N)` and (later) partial travel.
  - *LLM judgment:* when a trip is unaffordable, decide **rest / go-partway-then-
    rest / reroute-cheaper / abandon** — this needs safety, urgency and
    alternatives the tool doesn't have.
  - *Escalation rule (mirrors the combat interrupt):* affordable → `travel_to`
    walks silently, no LLM; short → the **pre-flight stops before wasting a move**
    and returns the facts + options for the model to choose, then deterministic
    tools execute the choice. **Decision: always escalate shortfalls to the LLM;
    never silently auto-rest** (resting spends in-game time and can be unsafe).
    Safe-room auto-rest is deferred until we track room threat.
- **Assumptions:** move cost = `V` drop (sector-driven small integers; central
  Midgaard ≈ 1/move); cost is roughly stable per edge, so cache the (conservative)
  observed value; current `V` is readable from vitals; resting/sleeping regenerates
  `V`. Unknown-cost edges use a nominal default and are flagged so the estimate's
  confidence is visible.
- **Will test:** per-edge cost recorded on walked moves; `route_cost` sums
  correctly; `travel_to` pre-flight escalates a shortfall (does NOT walk into
  exhaustion) with options; `rest_until` regenerates, then travel completes.
- **Built:** per-move cost measurement (`V`-before − after → per-edge `edge_cost`,
  keeping the conservative **max** so tick-regen noise can't understate it);
  `route_cost` (sums edge costs, nominal default for uncosted legs, counts
  unknowns); `travel_to` **pre-flight** that escalates a shortfall with options
  instead of walking into exhaustion; a `rest_until` tool (rest → poll across ticks
  → stand). Affordable trips still walk silently — the fast path is unchanged.
- **Result:** `route_cost` unit-tested — correct totals, the conservative max
  survives a regen-noised re-observation, and uncosted legs fall back to the
  default and are counted. The escalation sits on that proven estimate.
- **Learned (live):** `rest_until` runs mechanically but Perry recovered **0
  movement** in the poll window — CircleMUD regen is tick-based (~75s) *and*
  throttled hard by **hunger/thirst** (Perry is both). So resource recovery is a
  multi-step problem — **eat/drink → rest → travel** — not a simple auto-rest,
  which reinforces escalating to the LLM. Tuned `rest_until` to poll across ticks
  and to report "regen blocked — check hunger/thirst" when nothing recovers.
- **Pending (not a code gap):** live verification of real-move cost capture and the
  escalation actually firing — both blocked until Perry has movement, which needs
  sustenance + a full rest.
- **Next → slice 6 (survival / upkeep):** keep Perry fed/watered/healed so stats
  regen and he can act — it sits *beneath* navigation in the ability stack. Detect
  condition (hungry/thirsty/HP/position from `score`) and act (reuse the existing
  `consume_item` eat/drink) deterministically; escalate to the LLM only when
  supplies are missing (buy/find — needs food-source knowledge in the world-model).
  Same escalation pattern; feeds the shared status the store already owes combat
  and planning.

## Technical Conclusions
_To be filled in at week's end — hypotheses vs. outcomes, new uncertainties set
aside, next steps._

## Key Takeaway
_One sentence, at the end of the week._
