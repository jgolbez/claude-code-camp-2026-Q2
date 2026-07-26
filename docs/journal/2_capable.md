# Week 2: Capable

> Status: in progress. Goal, Uncertainty, and Hypotheses are recorded up front as
> our starting assumptions. Observations, Conclusions, and the Key Takeaway are
> filled in as the work proceeds.

## Technical Goal
Make **navigation reliable** — the agent should be able to reach an intended
destination without re-walking rooms or giving up on the iteration cap. This is
the first of three table-stakes abilities a MUD agent needs, in dependency order:

1. **Navigation** — reach where you intend to go. (This week.)
2. **Combat** — survive and win fights once you're there.
3. **Goal planning & execution** — multi-step campaigns (gain a level, get gear).

Combat and planning both stand on navigation, and all three read and write the
same persistent world-model. So navigation is the proving ground, but the real
deliverable is that **world-model / knowledge store**, built so combat and
planning plug into it later rather than becoming new systems.

Concretely, the plan is three small slices:
- **Slice 1 — Recognition + visits:** a `world_model` that gives each room a
  stable id and counts visits; `move`/`look` update it and append a `[memory]`
  line to the tool result.
- **Slice 2 — Record the graph:** on each confirmed move, write the adjacency
  edge `rooms[from].exits[dir] = to_id` (nil target = unexplored "frontier").
- **Slice 3 — `plan_route` tool:** BFS over the graph returns the list of
  directions to a known destination, or routes to the nearest frontier when the
  destination hasn't been found yet.

Scope discipline: I stay on the **Ruby track**, reuse the existing `log_viz`
viewer for observability instead of building a monitor, and skip the instructor's
heavier detours (a trained BERT room-parser, OpenTelemetry/Grafana tracing).

## Technical Uncertainty
- **Room identity.** Can rooms be given a stable id when a few rooms in this MUD
  are near-identical? Specifically two rooms in the center of Midgaard share the
  same name, description, and exit list (n s e w). If identity is wrong, the map
  is corrupted and navigation gets *worse*, not better.
- **Does injected memory change behavior?** Will feeding a compact `[memory]` /
  `[here]` line back into the loop actually stop the wandering, or will the model
  ignore it?
- **Is the lightweight injection enough?** I plan to append the memory line to the
  tool result rather than modifying the agent loop. Uncertain whether that seam is
  sufficient or whether real loop surgery becomes necessary.
- **Parsing reliability.** Room text arrives with ANSI colour codes and possible
  async ticks; uncertain how cleanly name/description/exits parse in practice.
- **Store technology boundary.** Starting with a plain JSON file; uncertain when
  that stops being enough and forces a move to SQLite (likely when a live viewer
  needs to read the memory while the agent runs).

## Technical Hypotheses
My core hypothesis: **navigation fails because the agent has no memory and is
doing pathfinding in its own head — not because the loop is broken.** Give it a
persistent world-model and take pathfinding out of the model, and navigation
becomes reliable. Supporting assumptions:

- **Identity is resolvable topologically.** Content fingerprint (name +
  description + exit directions) works for most rooms; the Midgaard twins resolve
  via **neighbor names** (from the `exits` command, which gives destination names,
  unlike `look`) plus the **arrival edge** ("the room reached by going north from
  #17"), with a **confidence flag** as the safety net when still ambiguous.
- **An adjacency list is sufficient** to represent the map — exits stored on each
  room, a nil target marking a seen-but-unwalked frontier — recorded only on
  *confirmed* moves (failed moves write no edge).
- **BFS is enough for pathing.** Edges are unweighted (one move = one step), so
  breadth-first search gives the shortest route; no need for weighted algorithms
  (Dijkstra/A*) yet.
- **The right division of labor is: record deterministically, plan
  deterministically, and let the LLM only choose goals and handle surprises.**
  Pushing the mechanical work (map-building, pathfinding) out of the model is what
  fixes the wandering, because it stops asking the model to do what it's worst at.
- **The same store will serve combat and planning** (mob difficulty, HP, level,
  gear) without a redesign.

## Technical Observations

### Observation 1 — Slice 1: room recognition + visit counting (2026-07-26)

**What we implemented.** A new `WorldModel` store (`world_model.rb`) that gives
each room a stable identity from a content **fingerprint** — a hash of its name +
description + exit directions, deliberately excluding the mob/object lines so a
wandering NPC can't change a room's identity. Each room gets a small integer id
and a visit counter, persisted to `.boukensha/world.json`. The `move` and bare
`look` tools now feed the room text to the store and **append a one-line
`[memory]` note** to the tool result the agent sees. Failed moves ("Alas, you
cannot go that way") and looks at a specific item/direction correctly record
nothing. No changes to the agent loop — the memory rides in through the existing
tool-result seam.

**The result.** Verified live against the MUD (driving `look`/`move` directly, no
LLM), starting from The Temple Of Midgaard:

| Step | Room | `[memory]` line |
|---|---|---|
| `look` | The Temple Of Midgaard | Room #1 — **first visit** (new) |
| `look` again | The Temple Of Midgaard | Room #1 — **visited 2×** (known) |
| `move north` | By The Temple Altar | Room #2 — first visit (new) |
| `move south` back | The Temple Of Midgaard | Room #1 — **visited 3×** (known) |

Recognition holds both ways — looking again (no movement) and walking out and
back. The fingerprint stayed stable despite NPCs present in the room. The
persisted `world.json` was correct: Temple visits 3, Altar visits 1, two distinct
ids. The parser was also checked against real captured room text from prior
session logs before going live.

**Expectation for the next phase.** The store passes the easy case. The next
experiment is the hard one we pre-registered: the two **center-of-Midgaard
twins** share name + description + exits, so the *plain* content fingerprint
should **collide** — folding both rooms onto a single id and mis-counting visits.
We expect to observe that collision directly, and to use it to justify **slice 1b**
(the topological tiebreaker: neighbor names via the `exits` command + arrival
edge, with a confidence flag). We also expect **slice 2** (recording edges on
confirmed moves) to attach to these stable ids without reshaping the store — the
id is already the key an edge will point at.

### Observation 2 — the "twins" did NOT collide (2026-07-26)

**What we tested.** The pre-registered hard case: walked Perry Temple → south →
south → **Market Square**, then into the **west** and **east** flanking rooms —
the two rooms I remembered as functionally identical — to see whether the plain
content fingerprint would fold them onto one id.

**The result.** Both rooms are named **"Main Street"** with **identical exits
(`e n s w`)** — but they got **distinct** ids (#6 and #7) and distinct
fingerprints. The reason: their **descriptions differ**. West: *"…the entrance to
the Armory, and the bakery is to the north…"*; East: *"…the general store… a
small door leads into the Pet Shop…"*. Because the fingerprint includes the
description, it separated them for free. **My hypothesis that this pair would
collide was not borne out.**

**Refined expectation for the next phase.** Identity by name + exits *alone* would
have collided here — but name + **description** + exits does not, because this MUD
bakes surrounding landmarks into room prose, so look-alike rooms still read
differently. This narrows the real collision risk to rooms with a **byte-identical
description AND same name/exits** — true filler duplicates (maze/forest tiles), if
any exist here. So **slice 1b** (the arrival-edge / neighbour-name tiebreaker)
drops from *necessary* to *insurance*, deferred until such a room is actually
encountered. The stable ids are proven enough to build on, so the next step is
**slice 2** — recording edges on confirmed moves — on top of them.

### Observation 3 — Slice 2: the graph records itself (2026-07-26)

**What we implemented.** Each room's exits changed from a flat list of directions
to a **map `direction → neighbour id`** (nil = unwalked = frontier). On every
*confirmed* move, the store writes the directed edge `prev --dir--> here`. Edges
are directed on purpose — the reverse is never assumed, only recorded when
actually walked. The `[memory]` line now reports each exit's target, e.g.
`e→#5, n→#2, s→? (unexplored), w→#4`, plus an unexplored count. A `frontier`
helper lists every room that still has an untried exit (what slice 3 will steer
toward when a destination isn't known yet). A load-time migration upgrades any
slice-1 store in place.

**The result.** Walked an 8-move loop through central Midgaard
(Temple → Temple Square → Market Square → left/right Main Street → back). All
**8 edges recorded correctly**, and the **13 remaining exits tracked as
frontier**. Directedness verified — Temple's `s→#2` and Temple Square's `n→#1`
were captured as two independent walked edges, never inferred from each other.
The graph filled in incrementally across revisits (Market Square went
`w→#4` → `w→#4, e→#5` over its three visits). Verified deterministically, no LLM.

**Known limitation.** An edge is only written when the *previous* room is known
(current location established), so the very first move of a fresh session — before
any `look` — records no edge. In practice the agent looks on arrival, so this is
minor; worth revisiting if it bites.

**Expectation for the next phase.** With a real directed graph and a frontier in
place, **slice 3 (`plan_route`)** can now run BFS for a shortest known route, and
fall back to routing toward the nearest frontier for a not-yet-found destination.
It's also finally worth a **real-LLM run**: the `[memory]` line now carries
navigational guidance ("south is unexplored"), so we can honestly test whether
that reduces the re-walking the baseline suffered from.

### Observation 4 — Slice 3: deterministic navigation (2026-07-26)

**What we implemented.** BFS pathfinding in the store — `route_to` (shortest known
route as a list of directions), `nearest_frontier_route` (route to the closest
unexplored exit), and `resolve_destination` (accepts `#id`, an exact name, or a
nearest-match substring). Two tools on top: **`plan_route`** (compute and show a
route, no walking) and **`travel_to`** (plan *and* walk the whole route in a
single tool call). `travel_to` hands control back to the model only on a
**compelling event** — combat (a regex on "…hits you" lines), a blocked/closed
exit, or arriving off-map (arrived id ≠ target). This realises the week's design
goal: **the LLM only picks a destination and makes one call; every mundane
per-room move happens deterministically, at zero model tokens.**

**The result.** Verified live. On a small bidirectional map, `plan_route`
returned `"… s — 1 step."`; `travel_to` walked multi-step routes in one call
(`"Arrived … via north → north (2 rooms). No decisions needed en route."`); `#id`
travel worked; and exact-name resolution removed an ambiguity found in the first
run — "Temple" had matched *both* "The Temple Of Midgaard" and "The Temple
Square", so full names now win by exact match while shorthand falls back to the
nearest. Unmapped destinations correctly fell back to the frontier. BFS was also
unit-tested on a synthetic graph, confirming directed-edge behaviour (forward
path found; reverse correctly unreachable). **Not yet live-verified:** the
combat/blocked interruption — the detection is implemented but needs an aggressive
mob en route to exercise.

**Acceptance test — reach the Bakery.** The instructor's Week 2 benchmark. Once
the Temple↔Bakery route was mapped (walked once each way), `travel_to "The Bakery"`
from the Temple of Midgaard walked all four rooms — `south → south → west → north`
— and arrived in a **single tool call**, "No decisions needed en route"; the
reverse trip did the same. So navigation is reliable and deterministic where the
baseline wandered 65K tokens and gave up. This also surfaced the directed-edge
corollary *in practice*: `travel_to` only routes over paths already walked in that
direction, so a destination must be **discovered first** (explored), and a one-way
exploration leaves no mapped path back until the return is walked. A future
improvement could record **presumed-reverse edges** (verified on first use) so
return trips work without walking both directions — noted for later, not built.

**Caveat learned.** Perry's MUD position **persists between runs**, so a test's
map is built relative to wherever he actually is, not an assumed start. Repeatable
benchmarks would want a reset-to-start (the instructor's
`move_player_to_start_room`); not needed yet, but noted.

**Expectation for the next phase.** The full navigation stack now exists —
recognition, a directed map, a frontier, and one-call deterministic travel. The
honest next test is a **real-LLM run**: give the agent a goal and watch whether it
reaches for `travel_to`/`plan_route`, and whether frontier-aware memory plus
deterministic travel actually eliminates the wandering the baseline suffered. That
would close the loop on the Week 2 hypothesis.

## Technical Conclusions
_To be filled in — reflecting the hypotheses above against what actually
happened, plus any new uncertainty set aside and next steps._

## Key Takeaway
_One sentence, at the end of the week._
