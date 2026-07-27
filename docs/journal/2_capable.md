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
| 6 — Survival / upkeep | ✅ built\* | Text-triggered eat/drink reflex + tagged-source escalation (auto-consume live-pending) |
| 7a/7b — `explore` tool + nav policy | ✅ done (Obs 9) | First-class `explore` (steps *through* a frontier exit) + a `prompts/system.md` policy for which movement tool to use |
| 7c — distill room text | ✅ done (Obs 10) | ANSI/vitals stripped; description dropped on revisit-move (−65% B), kept on explicit `look`; occupants always kept. **Obs 10: context growth ~7K→~250 tok/iter, window use 4%** |
| 8 — prompt caching | 🔜 next | Obs 10's new bottleneck: 38-tool schema + system prompt (~5.8K) re-billed **uncached** every call (`cache_read=0`) trips `max_turn_tokens`. Cache the fixed prefix |

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

### Obs 7 — Slice 6: survival / upkeep (predicted, before building, 2026-07-26)

- **The problem.** Hunger/thirst throttle *all* regen (HP, mana, movement), so a
  starving Perry can't recover movement and everything downstream stalls — the
  exhaustion that blocked slice 5's live test was really an **upkeep failure**, not
  a navigation one. Upkeep is a *foundation* beneath navigation, but architecturally
  it's a **peer capability that composes navigation, not a subset**: *sensing*
  condition and *consuming* are their own thing; only *acquiring* supplies when
  empty is a navigation query. All of it reads/writes the one shared world-model
  (status fields + resource-source tags), same as combat and planning will.
- **The approach (predicted), in two layers:**
  - *Reflex — deterministic, ~99% of cases:* watch tool-result text for
    **"You are hungry" / "You are thirsty"** (the MUD *pushes* these each tick, so
    we scan the stream we already read — no `score` polling) and `eat`/`drink` one
    held item in response. Self-correcting: if still not sated, the next tick
    re-fires. Zero tokens.
  - *Escalate-with-suggestion — the ~1%:* when there's nothing to consume, hand the
    LLM a **pre-solved** option — nearest known source (tag the **Bakery = food** and
    **Temple fountain = water** as fixed world-model landmarks) + route +
    affordability (reusing the slice-5 movement pre-flight) — and let it decide.
    Same escalation shape as the movement shortfall.
- **Mechanism decision.** A **hook/trigger** — *not* an LLM tool (the model would
  forget and waste tokens) and *not* a wall-clock cron (the agent is turn-based).
  Start by **piggybacking the existing move/look tool seam** (no agent-loop surgery,
  matches `[memory]`/`exits`); graduate to a **generic lifecycle-hook registry** in
  the agent loop once a *second* automatic behaviour wants a "before every turn"
  slot (upkeep + room-auto-survey + HP-based auto-flee).
- **Assumptions.** The MUD reliably emits the hunger/thirst text each tick while
  in-state; eating one item per trigger + re-fire avoids over-eating; the Bakery and
  Temple fountain are stable Midgaard sources; food is `eat <item>`, but **drink
  needs a filled container or a fountain**.
- **Future problems to solve (flagged now, not this slice):**
  - *Drink needs a container/fountain* — the reflex only covers "have a filled drink
    container"; an empty-handed thirst is already the acquire case.
  - *Starvation deadlock* — hungry → no movement regen → may not afford the trip to
    food. A real survival crisis (beg/gossip for help, find a closer source, or
    accept a death-respawn at the Temple) that needs reasoning — which is exactly why
    the empty case **escalates** rather than auto-walking.
  - *Buying food costs gold* — shop interaction + a gold check.
  - *Safety en route*; being *far from Midgaard* (sources distant/unknown);
    *deduping* the escalation so it doesn't nag every tick.
- **Will test.** Trigger hunger/thirst; confirm the reflex eats/drinks from
  inventory silently; confirm that with an empty inventory it escalates a concrete
  suggestion (source + route + affordability) instead of acting blindly.
- **Built:** the reflex lives on the move/look seam. `send_cmd` now **keeps the
  bytes it drains**, so the reflex can see async hunger/thirst pushes that arrive
  while idle (drain used to discard them). On "You are hungry"/"You are thirsty" it
  reads inventory and `eat`/`drink`s a keyword-matched held item; with nothing on
  hand it escalates. Resource **tagging** added — a room showing a fountain →
  `water`, a bakery → `food` — and the hint routes to the nearest *tagged* source
  (or honestly says none is known yet).
- **Result (live):** the async text was caught (drained-bytes fix works), inventory
  read, and the escalation fired. Tagging verified — Temple Square's fountain
  tagged it `water`; the Temple Of Midgaard has **no** fountain, which exposed and
  corrected a bug: v1 guessed the source from the room *name* and confidently but
  wrongly said "drink here". It now tags **observed** sources only and routes to
  the real one (Temple Square, `s`, ≈1 movement).
- **Not yet live-verified:** auto-eat/drink of a HELD item — Perry's pack is empty;
  same detection path plus a consume call.
- **Fixed / learned:** (1) `session.drain` silently dropped async pushes → capture
  the drained bytes so the reflex sees them; (2) never guess a source from a room
  name (Temple ≠ fountain) → tag sources actually seen. Also: movement *does* trickle
  back even while hungry (0 → 10 over the session), just very slowly.
- **Next:** tag more sources as Perry explores; optionally auto-drink when standing
  at a tagged water source (currently escalates); the starvation deadlock and
  buying-food-with-gold stay LLM-reasoning cases, as pre-registered.

### Obs 8 — Real-LLM run: the week-1 task, retested (2026-07-26)

The test we deferred all along: the **exact** week-1 task ("find the thieves'
guild and train a skill"), Haiku in the loop, from the Temple (rested, fed,
watered). First run to exercise the model + the full navigation stack, and the
first session log in log_viz.

- **Result — failed the task, but *failed far better* than week 1.** It did not
  find the guild or train, but:

  | | Week 1 (baseline) | Week 2 (this run) |
  |---|---|---|
  | Moves | `w,w,s,s,e,e,s,n` — **circling** | `down,s,w,w,w,s,s` — coherent, **no re-walking** |
  | Ended on | 40-iteration cap, aimless | **token cap (69.6K) at 10 iterations**, with a plan |
  | Memory | none | **7 `[memory]` notes**; never re-entered a room |
  | Close | wandered | reasoned to *"go to the Poor Alley — that's where a guild hides"* |

  The circling is **gone**. It explored purposefully, remembered where it had
  been, and stopped with a real hypothesis. It ran out of **budget**, not sense —
  with more tokens it would likely have reached the guild.

- **Gaps this exposed.** (1) It **never used `travel_to`/`plan_route`** — for an
  *unmapped* target it hand-stepped with `move`. Root cause: `travel_to`'s frontier
  fallback routes *to* a frontier room but never steps *through* an unexplored
  exit, so there is **no first-class explore action**; manual `move` is the only
  thing that advances into the unknown. (2) **Token cost is high** (~7K/iteration)
  because the full ANSI room description is re-sent every turn — that's *why* it hit
  the cap mid-exploration.

- **Next → slice 7 (direct the model to use the tooling):** (a) add an **`explore`
  tool** — the exploration analog of `travel_to`: step through the nearest
  unexplored exit and keep going a few rooms, so a whole exploration leg is one
  cheap call instead of many LLM turns; (b) **steer via the system prompt** — a
  short navigation policy (travel_to for known, explore for finding new, avoid
  manual `move` chains); (c) **distill room text** — feed a terse summary + the
  `[memory]` line instead of the full description, so the budget lasts far longer.
  Levers (a)+(b) make it *use* the tools; (c) makes each step *cheap*.

### Obs 9 — Slice 7a/7b: `explore` tool + navigation policy (2026-07-26)

Acting on Obs 8's two levers that make the model *use* the tools. Distillation
(7c, the *cheapness* lever) is deferred to its own pass.

- **Predicted (before building):** the reason the LLM hand-stepped with `move`
  toward an unmapped goal is a *missing capability*, not bad judgement —
  `travel_to` only walks KNOWN ground, so nothing steps *through* a frontier exit.
  Adding a first-class `explore` (walk to the nearest unwalked exit, then step
  through it) plus a system-prompt rule for *which* tool to use for *what* should
  eliminate the manual `move` chains.
- **Built (7a):** `explore` tool. Reuses a new shared `walk_route` helper
  (extracted from `travel_to`, so both share combat/blocked interrupts and keep
  `move_pts` current per step). Flow: `nearest_frontier_route` → movement
  pre-flight (need = route + 1 step, escalate a shortfall) → walk the known leg →
  at the frontier, pick an unexplored dir (new `WorldModel#unexplored_dirs`,
  which prefers exits whose destination *name* is already known) → step through
  with the full `remember` treatment (records the walked edge + named neighbours +
  runs upkeep). One frontier step per call; the model calls it repeatedly to search.
- **Built (7b):** a **Getting around** section in `prompts/system.md` (the prompt
  was `override: true` but had *no* movement guidance at all — the real root cause
  of the hand-walking). States the policy plainly: visited → `travel_to`; not
  found yet → `explore`; peek → `plan_route`; raw `move` is a last-resort single
  step, never a chain.
- **Result (deterministic live tests, no LLM):**
  - `explore` ×3 from Wall Road discovered **three genuinely new rooms** in three
    calls (#10 Poor Alley → #11 Eastern End → #12 Common Square), each mapped with
    named edges; it correctly took the *named* frontier exit first each time, and
    #12 auto-linked north to the already-known Market Square (#4).
  - `unexplored_dirs` unit test passes (walked exits excluded; named exit ordered
    first).
  - Regression: refactored `travel_to` still plans + walks a **5-step** route
    (Common Square → Wall Road) in one call. `walk_route` refactor is clean.
- **Learned:** the capability gap was exactly the blocker — with `explore` present,
  purposeful map-growth is now a single cheap tool call instead of an LLM
  `move`-chain. The prompt policy is what tells the model to reach for it.
- **Next:** (7c) **distill room text** — the remaining lever, and now the top one:
  the ~7K-tokens/iteration full-ANSI room dumps are what capped Obs 8. Feed a terse
  summary + the `[memory]` line instead. Then re-run the exact week-1 task under the
  LLM (Obs 10) to confirm it now reaches the guild within budget.

### Slice 7c — distill room text (plan, pre-registered before building)

**Problem.** Every room block returned to the model is raw: full of ANSI colour
codes and, on a revisit, the entire multi-line description — which the `[memory]`
line already identifies by name + id + exits. Context is cumulative, so each
turn re-sends the prior blocks too. In Obs 8 this compounded to ~7K tokens/iter
and hit the 69.6K cap at 10 iterations, *before* the model could reach the guild.

**Plan.**
- **Strip ANSI** from all room results (pure colour noise to a text model).
- **Always keep:** room name, the exits line, and the live "who/what is here"
  lines (mobs, items, shopkeepers) — combat / steal / shop / loot decisions ride
  on those and they're *not* in `[memory]`. **Drop** the raw vitals-prompt line
  (`23H 100M 63V …`); HP/movement come from `check score`, combat output, and the
  movement-economy tools.
- **Description:** keep on the **first visit** (it carries navigation clues, e.g.
  "south is the Grubby Inn"); **drop on a revisit** (redundant with `[memory]`).
  **Exception:** an explicit bare `look` keeps the description even on a revisit —
  a `look` is "show me this room", so the model can always re-read on demand;
  a `move`/`explore` arrival into a known room does not.
- **Implementation:** `WorldModel#distill(raw, full:)`, wired through the existing
  `remember` seam. Non-room text (errors, "you can't go that way", shop dialogue)
  is only ANSI-stripped, never distilled — distill fires only on a `parse_room`
  hit, so it can't eat a genuine message.

**Expected outcome.**
- A large drop in tokens per room result — ANSI removal alone is significant, and
  dropping the description on the *common* revisit case removes the biggest block.
- Cumulative context grows much more slowly → the **same** week-1 task should get
  many more iterations before the token cap — enough, we predict, to actually find
  the guild (to be confirmed as **Obs 10**).
- **No loss of decision-relevant info:** occupants/items stay; identity + exits
  stay (in the body on first visit, in `[memory]` always); a description is always
  re-readable via an explicit `look`.

**Risks / watch.**
- If the model relied on re-reading a description mid-navigation, a revisit
  `move` won't show it — mitigated by the explicit-`look` exception.
- Distillation must never swallow a non-room message — guarded by the
  `parse_room`-hit gate; verify with a failed move + a shop interaction.
- **Measure it:** tokens/turn before vs after on an identical short scripted
  sequence, so the win is a number, not a vibe.

**Built + result (deterministic, no LLM).** `WorldModel#distill(raw, full:)` wired
through the `remember` seam; bare `look` passes `full: true`, `move`/`explore`
arrivals don't. Unit test + live check both pass:
- Unit (fabricated block w/ ANSI + vitals): first visit **−16%** bytes (ANSI +
  vitals only, description kept), **revisit −65%** (description dropped). ANSI gone,
  vitals gone, occupants kept in both, `full:` restores the description, non-room
  text → `nil` (falls back to plain ANSI-strip, never distilled).
- Live: `look` on Wall Road stayed full (248 B, description shown); `move` into a
  revisited room dropped the description (126 B for the same room) while keeping
  all occupant lines (e.g. six cityguards at the West Gate — kept, since they're
  combat/steal-relevant).
- Since navigation is **mostly revisits**, the common case is the 65% case. The
  effect compounds across turns because context is cumulative — exactly the Obs-8
  cap driver.
- **Still pending → Obs 10:** the payoff test — re-run the *exact* week-1 task
  under the LLM and confirm it now reaches the guild within the token budget. Held
  until credits are available; deterministic pieces are all green.

### Prep note — auto-orient on connect (found staging Perry for Obs 10)

Staging Perry (reposition to the Temple for Obs-8 parity) surfaced a real bug:
`travel_to`/`explore` route from `current_fp`, which is **nil until the agent
looks** — so a session's *first* navigation call returned "no mapped path". Fixed:
`mud_connect` and the auto-connect block now do one silent look-and-observe after
login to establish "you are here". Verified (Wall Road → Temple in a single
`travel_to`, no prior look). This de-risks Obs 10: the LLM's first move can now be
`explore`/`travel_to` without a wasted orienting turn.

**Perry's Obs-10 starting state:** Temple of Midgaard (#1), 23/23 HP, thirst
buffered at the fountain, 49/83 movement, **no food + 6 gold** (a danish is 7, so
he starts un-provisioned on food — hunger will trip the upkeep escalation mid-run;
worth watching as a real integrated-system test). Map holds 12 rooms; the guild is
still unmapped, so finding it remains the genuine challenge.

### Obs 10 — Reset-map LLM re-run: the fixes work; the bottleneck moved (2026-07-27)

Same week-1 task, Haiku, but now with slice 7 live (explore + nav policy +
distillation), a **reset map** (explore from scratch), and a **clean task prompt
with no tool hints** — to test whether the system prompt *alone* steers tool use.
Perry started at the Temple.

- **Didn't find the guild — but 7b and 7c are both VALIDATED:**
  - **Tool steering (7b) works.** Sequence: `check score` → `check where` →
    `look` → **`explore` ×6** → `travel_to #2`. **Zero manual `move` chains** —
    the system-prompt policy by itself made the model reach for `explore` on the
    unmapped goal, with no hint in the task. (Obs 8 hand-stepped with `move`.)
  - **Distillation (7c) works, dramatically.** Per-iteration context growth fell
    from ~7K tok/iter (Obs 8) to **~250 tok/iter**; context-window usage peaked at
    **8K / 200K = 4%**. Room-text bloat is gone.
- **It still stopped early — but for a NEW reason.** `turn_end reason=max_tokens`
  at iteration 9 (67,639 > the `max_turn_tokens = 60,000` per-turn breaker). This
  is **not** context-window pressure (4% used). It's the *cumulative* per-turn
  budget summing the **fixed per-call overhead**: every call re-sends the
  **38-tool schema + system prompt (~5.8K tokens), uncached (`cache_read = 0`)**, so
  ~7K × 9 calls ≈ 64K. The bottleneck moved from *room text* → *fixed prefix ×
  call count*.
- **Exploration was undirected and rabbit-holed.** `explore` dives into the
  *nearest* frontier; from the Temple that led straight into the dense **Grunting
  Boar Inn** cluster (inn → bar → post office → reception → cryo) — all service
  rooms, away from the alleys/market where the guild actually sits. The model's
  *own* closing reasoning was right ("guilds hide off the main streets / north out
  the back of the Temple") but it ran out of turn-budget before acting on it.
- **Next levers (priority order):**
  1. **Prompt caching — the big one.** `cache_read = 0`: the ~5.8K tool-schema +
     system prefix is re-billed every call. Anthropic prompt caching makes it ~free
     after the first call, directly killing the dominant cost — should multiply the
     reachable iterations several-fold.
  2. **Revisit `max_turn_tokens = 60K`.** It's a cumulative-per-turn breaker that
     cuts off at ~9 calls despite 96% context headroom. Raise it, or reconsider
     whether cumulative turn-tokens is even the right guardrail vs. context-window %.
  3. **Directed exploration.** Let the model bias `explore` by compass/keyword, or
     avoid rabbit-holing in dense clusters, so it heads toward likely-guild areas
     rather than the nearest frontier.
- **Takeaway:** both slice-7 fixes did exactly what we predicted (the model *used*
  the tools; the per-turn token cost *cratered*) — and by removing the room-text
  bottleneck they **revealed** the next one: the uncached fixed per-call overhead
  against a cumulative turn budget. **Caching is now the highest-leverage move.**

## Technical Conclusions
_To be filled in at week's end — hypotheses vs. outcomes, new uncertainties set
aside, next steps._

## Key Takeaway
_One sentence, at the end of the week._
