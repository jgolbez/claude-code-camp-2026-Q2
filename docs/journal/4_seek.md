# seek — an offloaded "find a place by name" tool

> **Status:** pre-registration (design before build), per the project discipline.
> Emerged from the Obs B7 gap: Perry reached level 4 but couldn't train because the
> **Thieves' guild wasn't on the (reset) map**, and finding it by hand-`explore`
> burned a whole run's token budget without success.

## The goal

A `seek "<place name>"` tool: deterministically explore until it maps a room whose
name matches the target, then stop and report where it is — **one LLM decision, zero
model tokens for the walking.** This is `hunt`, generalised from *prey* to *places*.

## The gap it fills

The movement toolkit sits on two axes — *destination known vs. discovering it* × *offloaded
vs. per-step*:

| | known destination | discovering it |
|---|---|---|
| **offloaded** (1 call → many steps) | `travel_to` | **`seek` ← missing** |
| **per-step** (1 call → 1 move) | `move` | `explore` |

`travel_to` reaches a **known** place; `explore` expands the map **blindly, one frontier
per LLM call**; `hunt` finds **prey**. Nothing does *offloaded discovery of a named
place* — so the agent is forced to hand-`explore`, reading each room and re-deciding,
one token-costing iteration per room, until the budget dies (B7: 15 explores, no guild).

**`seek` = `explore` in a deterministic loop with a name-match stop condition.** The
"is this it? keep going?" decision moves from the LLM's turn cycle into the tool.

## The design (cheap intuition, expensive intuition avoided)

The temptation is to have the agent *reason about room descriptions* to tell if it's
headed the right way (like a human). That's **expensive** — one model call per room
defeats the offload. Instead:

- **Bounded blind search** — loop `explore` up to `max_rooms` (~25), inheriting its
  guards (over-level back-out, death-trap detection) so it can't wander into the
  chessboard/sewer. It CAN enter town (unlike `hunt`) — city landmarks live there.
- **Deterministic name match** — after each step, check `resolve_destination(target)`;
  stop the moment the named room is mapped. Zero tokens (string match).
- **Course-correction at the CALL level, not the room level** — on failure, return a
  *shape summary* of the areas it passed ("went market → temple → north wilderness"),
  so the agent can redirect *once* ("drifting north, seek again biased south") — the
  same one-decision-per-call redirection `hunt` already uses. No per-room LLM reasoning.
- Provision (eat/drink) first so hunger doesn't stall the walk.

Once `seek` finds a place, the map remembers it → `travel_to` works forever. Discovery
is a **one-time cost per place**; after that, no more parking Perry.

## Technical uncertainty

- Will a bounded blind search actually *find* a city landmark, or wander past it?
  (Bet: yes for a bounded city like Midgaard ~60 rooms; the guards prune the wrong
  zones and 25 rooms covers a lot of a small map.)
- Is `resolve_destination`'s name match robust enough (exact-then-substring) without
  matching the *wrong* guild? (Agent passes a specific name; exact match wins.)
- Does the shape-summary give the agent enough to redirect usefully?

## Hypothesis

Naive-bounded `seek` finds the guild in **1–2 calls** with **no** LLM
description-reasoning — the deterministic guards + name match capture the human
"wrong-direction" intuition cheaply. If it wanders on bigger targets later, add cheap
name-proximity biasing; never per-room LLM.

## Plan

1. Build `seek` (loop `explore` + `resolve_destination` check + shape-summary + guard
   handling), register the tool.
2. Test deterministically: from the Temple, `seek "Thieves"` → should map the guild.
3. Then the agent can `seek` → `travel_to` → `practice`, closing the train step
   without pre-positioning.

## Observations

### Built + validated live (deterministic) — 2026-07-28
`seek` = `explore` looped deterministically with a `resolve_destination` name-match
stop + a shape-summary on failure. Registered (41 tools). **First live test nailed the
hypothesis:** from Wall Road, `seek "Thieves"` found and walked into *The Entrance Hall
To The Guild Of Thieves* (#58) in **3.1s, one tool call, zero model tokens** — the exact
guild that took **15 hand-`explore`s and a whole failed run (B7)** to *not* find. No
LLM description-reasoning needed; the bounded blind search + guards + name match were
enough for a city landmark, exactly as predicted.

**It closed the combat-arc acceptance test.** With the guild now mapped, a short hop
(entrance → Thieves' Bar → The Secret Yard, guildmaster) + `practice backstab`
("You practice for a while...", sessions 2→1) means **Perry is level 4 AND has trained
a skill** — the whole level-4 + train goal, achieved *without pre-positioning Perry*.

**The navigation toolkit is now complete:** `move` (one step), `travel_to` (known
place), `explore` (blind map growth), `hunt` (find prey), **`seek` (find a place)** —
the two-axis grid (known/discover × offloaded/per-step) has no empty cells.

## Conclusion

The hypothesis held exactly: discovery of a named place is a *deterministic search*, not
an LLM-reasoning problem — moving the "is this it? keep going?" loop from the model's
turn cycle into the tool made finding the guild ~15× cheaper and instant. The
directional-intuition worry (reasoning over room descriptions) was correctly avoided:
the room *name* + existing guards carry the signal for free, and course-correction rides
at the call level (shape summary), never per room. `seek` is the last piece that lets the
agent *reach anywhere it's heard of* on its own — no more parking Perry.
