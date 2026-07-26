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
_To be filled in as the slices are built and tested (proof of work: log_viz
screenshots, store dumps, token/benchmark comparisons)._

## Technical Conclusions
_To be filled in — reflecting the hypotheses above against what actually
happened, plus any new uncertainty set aside and next steps._

## Key Takeaway
_One sentence, at the end of the week._
