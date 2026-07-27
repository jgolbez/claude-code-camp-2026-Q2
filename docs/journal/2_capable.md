# Week 2: Capable — reliable navigation

> **Status:** navigation ability complete — the week-1 task (find the Thieves' Guild)
> is solved. This is the readable review. The full blow-by-blow — per-slice
> predictions, token tables, test details — lives in
> [2_capable_detail.md](./2_capable_detail.md).

## At a glance

| Slice | Outcome |
|---|---|
| 1–2 — Memory + graph | Rooms fingerprinted with stable ids; moves record a directed map |
| 3–4 — Pathfinding | BFS `travel_to` walks a whole route in one call; connectivity read from the game's own `exits` |
| 5–6 — Movement + survival | Move-cost budgeting with shortfall escalation; eat/drink reflex |
| 7 — `explore` + prompt + distill | A tool to step into the *unknown*, a prompt policy for which tool to use, and cheaper room text |
| 8 — Prompt caching | Tool schema + system prompt served from cache, not re-billed every call |
| 9 — Sane token bound | Removed the artificial per-turn cap; restored a real one after tuning |
| **Result** | **Agent found the guild + guildmaster, fought for gold; the only miss (training) is a leveling mechanic → next ability** |

## The goal

Make **navigation reliable** — reach a destination without re-walking or hitting the
iteration cap. It's the first of three table-stakes abilities (**navigation → combat
→ planning**), and all three share one persistent **world-model**. Navigation is the
proving ground; the world-model is the real deliverable, built so combat and planning
plug into it later. (Ruby track; reused the `log_viz` viewer; skipped the heavier
instructor detours like a trained room-parser and OpenTelemetry.)

## The thesis

Navigation failed in week 1 because the agent had **no memory** and did pathfinding in
its head — not because the loop was broken. Give it a persistent world-model, move
pathfinding out of the model, and let the **LLM choose only goals while deterministic
tools handle the mechanics**. Everything below tests that bet.

## What happened — the arc

**Built the world-model (slices 1–6).** Rooms get a stable id from their content
(name + description + exits); confirmed moves record a directed graph; BFS plans
routes. `travel_to` walks a whole route in one call for **zero model tokens**.
Acceptance test: from the Temple it reached the Bakery in one call — the instructor's
benchmark, where the week-1 baseline burned ~65K tokens and gave up. Movement-cost
budgeting and a survival (eat/drink) reflex layer on top.

**First live test — "failed better" (Obs 8).** Handed Haiku the exact week-1 task. It
didn't find the guild, but the **circling was gone** — it explored purposefully, used
its memory, and stopped with a real hypothesis. It ran out of **token budget** at
iteration 10, not sense. Two gaps surfaced: no way to step into the *unknown* (only
`travel_to` over known ground), and room text was too expensive (~7K tokens/turn).

**Made the agent use the tools, cheaply (slices 7–9).**
- **`explore`** — steps *through* an unmapped exit, the one thing `travel_to` can't do.
- **Navigation policy in the system prompt** — when to reach for which tool.
- **Room-text distillation** — strip colour codes; drop descriptions on revisits (−65%).
- **Prompt caching** — the 38-tool schema + system prompt were re-billed every call; caching serves them from cache.

Each change was measured. The agent's reach grew **9 → 22 → past 60 iterations**, and
it went from stuck in a dead-end inn → the guild district → the guild itself.

**The payoff (Obs 12).** The agent **found the Thieves' Guild**, reached the
guildmaster, and fought bats for gold along the way. The week-1 task — solved. The
only thing it couldn't do was *train*, and that's a game mechanic (practice sessions
come from **leveling**, not gold) — a job for the next ability, not a navigation
failure.

## Key findings

- **Memory kills the circling.** The single biggest change, and the core thesis
  confirmed.
- **Right division of labor:** record and plan deterministically; let the LLM choose
  goals and handle surprises. Every mechanical move costs zero model tokens.
- **Room identity from content works** — even the near-identical center-Midgaard
  "twins" separated cleanly, because their descriptions differ.
- **Distillation + caching are what make an LLM agent affordable** — together they
  took the run from a 10-iteration wall to a completed task.
- **The token "budget" was mis-shaped** — a cumulative per-turn *spend* cap, not real
  context pressure (window use peaked under 3%). Worth bounding, not worshipping.
- **An agent needs to know when to stop.** Obs 12 thrashed ~30 turns after it was
  effectively blocked; a "report the blocker and stop" rule now covers that.

## Conclusions

The core hypothesis held: **navigation is a memory problem, not a loop problem.** A
persistent world-model plus deterministic pathfinding turned week-1 circling into a
completed, goal-directed run. The supporting bets held too — content fingerprints give
stable ids, an adjacency list on confirmed moves is enough, plain BFS suffices, and the
same store carried movement, survival, and (in Obs 12) combat without a redesign. The
surprises were all *downstream of success*: once memory and tools worked, the limiter
became **token economics** (fixed by distillation + caching), then **agent discipline**
(knowing when it's blocked). The world-model deliverable is proven and ready for the
combat and planning abilities to build on.

## Key takeaway

Give the agent a memory and move the mechanics out of the model, and an LLM that
wandered in circles will find a guild it has never seen — and fight its way there.

## What's next

Leveling / combat (the next table-stakes ability) so Perry can actually train. Smaller
follow-ups are logged in the detail file: maze-area navigation (it got lost in the
sewer), a few missing structured tools (it fell back to raw commands), and caching the
message history to tighten the token bound.
