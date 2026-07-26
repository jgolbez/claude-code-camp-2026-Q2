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

## Technical Conclusions
_To be filled in — reflecting the hypotheses above against what actually
happened, plus any new uncertainty set aside and next steps._

## Key Takeaway
_One sentence, at the end of the week._
