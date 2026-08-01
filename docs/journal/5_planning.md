# Planning — decompose a goal, plan with a strong model, execute with Haiku

> **Status:** in progress, **paused at a validated checkpoint.** The third and last
> table-stakes ability (**navigation → combat → planning**); it stands on the tools built
> in [3_combat](./3_combat.md) / [4_seek](./4_seek.md). Slices 1–4 are done and validated
> (planner + executor + orchestrator + persistence); one architecture bug is isolated and
> the remaining work is scoped — see **Where we paused** at the bottom. The design was
> pre-registered first (below); observations follow.

## Where this picks up

The agent can now *execute* single goals a human hands it ("find the guild", "kill 3
monsters"). It cannot yet take a **high-level** goal and figure out the steps itself.
Planning is that: decompose a goal into ordered, actionable **milestones** that map to the
tools/loops we already have, run them, and **replan** when blocked.

## Technical Goal

Give the agent goal decomposition + execution over a longer horizon, on a **two-tier model
architecture** (the user's call): a **stronger model plans**, **Haiku executes**. This is
the offload principle applied to *models* — don't run the expensive model in the tight
loop; spend it only on the sparse, high-value cognition (breaking down the goal, replanning
when stuck), and let cheap/fast Haiku drive the tool loop it's already proven at.

## The design — planner / executor

- **Planner** (strong model, e.g. `claude-sonnet-5`): goal → an ordered list of
  **milestones**, each `{ description, suggested tools, done-condition }`. Called *rarely*
  — once at the start, and again only to **replan** on a block or a completed milestone.
- **Executor** (Haiku): runs **one milestone** as a bounded agent loop over the existing
  tools (`hunt · fight · seek · travel_to · rest_until · practice …`) and reports back
  **done | blocked | progress** with a short status.
- **Orchestrator**: plan → for each milestone, hand it to the executor → advance on *done*,
  escalate back to the planner on *blocked*. The **plan + progress persist** (like
  `world.json`) so a long goal survives across runs (leveling is respawn-paced and spans
  sessions).

## Technical Uncertainty

- Can a strong model decompose a *fuzzy* MUD goal into steps that actually **map to the
  tools we have**, not vague prose ("get stronger")?
- **Plan representation** — structured enough for Haiku to execute and the planner to
  revise, without being brittle.
- **The handoff** — does Haiku reliably run a milestone and report *done/blocked* cleanly,
  so the orchestrator can advance or replan?
- **Cost** — is the planner called rarely enough to stay affordable (the whole point of the
  split)?
- **Harness support** — does boukensha's task/provider config cleanly allow **two models**
  in one run? *(First build step: verify.)*
- **Replan triggers** — blocked, milestone done, or new information; and avoiding
  replan-thrash.

## Technical Hypotheses

- **Offload extends to models:** a strong planner called sparsely + Haiku in the loop gives
  good plans at bounded cost — the same "expensive cognition is rare, mechanics are cheap"
  bet that carried navigation and combat.
- **Most milestones map to EXISTING loops** (grind to level, travel, seek a place, train a
  skill). The planner *sequences* proven capabilities; the executor *reuses* them — little
  new execution code.
- A **persistent, structured plan** lets the two tiers coordinate and lets a goal survive
  across the multiple runs leveling requires.

## Acceptance test (proposed)

> *"Become a level-5 Thief with backstab trained."* The planner decomposes it (e.g.
> `[reach level 5, train backstab at the guild]`, with sub-steps); the executor runs each —
> grind/heal cycles, then travel-to-guild + practice — across the multiple grind-and-recover
> cycles the respawn clock forces. **Success = the agent self-directs to the goal without a
> human specifying each step.**

## Plan (slices, watch-first as usual)

1. **Harness check** — confirm/enable a second model (a `planner` task alongside `player`).
2. **Planner** — goal → structured milestones with the strong model. Test decomposition on
   a couple of goals *before* wiring execution; check the steps map to real tools.
3. **Executor wrapper** — run one milestone through the existing Haiku agent loop; report
   done/blocked.
4. **Orchestrator + plan persistence** — sequence milestones, replan on block, persist.
5. **Validate** on the acceptance test; flow-trace the planner/executor handoffs.

## Decisions (confirmed)

Planner model: **`claude-sonnet-5`**. Acceptance test: **reach level 5 + train backstab**.

## Observations

### Slice 1+2 — two models work; the planner decomposes cleanly (2026-07-29)
**Harness supports two models with no new plumbing:** `Boukensha.run(model:, mud: false,
working_dir: false)` gives a **tool-less reasoning call** with any model — exactly the
planner (Sonnet-5, no MUD loop); the executor stays the Haiku+MUD run. (One gap: the
backend's model allowlist didn't know the Claude 5 IDs — added `claude-sonnet-5` /
`claude-opus-5` to `backends/anthropic.rb` + `models.rb`.)

**Sonnet-5's decomposition was excellent** — fed the goal + Perry's real state (level 4,
+4457 xp to 5, 1 practice session, backstab fair) and a description of the executor's
tools, it returned a **valid JSON milestone plan**: assess → **heal to full** → **grind
(hunt/fight/rest) until level 5** → confirm level-up → **travel to the Thieves' guild
(seek/travel_to)** → **train backstab (practice)** → verify. Correct sequencing
(dependencies first), every milestone mapped to real tools, checkable `done_when`
conditions, and it knew the mechanics (leveling grants the practice session; a Thief
trains at the guild). Both core hypotheses confirmed: **offload extends to models**
(strong planner, cheap executor) and **milestones map to existing loops**.

Next: the executor wrapper (run one milestone via Haiku, report done/blocked) and the
orchestrator (sequence + replan + persist). Note the *grind to level 5* milestone needs
~+4457 xp (~20+ kills) and is respawn-paced across many runs — so the plumbing will be
validated on a short goal first, with the full level-5 grind as the real (long) run.

### Slices 3+4 — orchestrator + persistence validated (2026-07-29)
Built the three-tier loop: **planner** (Sonnet-5) → coarse machine-checkable milestones
(`done_check` = `xp_at_least` / `at_place` / `skill_trained` …); **`plan.json`** persists
goal + milestones-with-status + current + a progress log + a state baseline; **executor**
runs one milestone via Haiku **in its own subprocess** (own MUD session, no collision with
the orchestrator's `read_state`); the **orchestrator** picks the active milestone, runs the
executor with the goal + milestone + progress, **deterministically checks the `done_check`
against live state**, and advances / re-runs / escalates-on-block, persisting each step.
(Refined the planner first: milestones must be *checkpoints*, not tool-calls — it had
over-decomposed into a trivial "find a mob" step and a "rest" step with a bogus xp check.)

**The mechanism worked end-to-end** on the short goal (*grind to 5700 xp → guild → train*):
milestone 1 executed, the orchestrator saw xp 5543→5973 cross the `xp_at_least 5700` check
and **advanced on its own**; milestone 2 was checked, not met, **re-run**, and after the cap
**escalated to `blocked`** — all persisted. The handoff + "judge completion against the
goal, not the loop" + persistence are proven.

**Real finding — an ARCHITECTURE bug, not a combat one (corrected after checking the
logs; the first read was wrong):** the grind was clean — `hunt` picked a proper monster
(`'newbie'`, Fairly easy, +430 xp), `fight` backstabbed it, and Perry ended at **43/44 HP,
full**. He hit 0 HP with **no combat in any session log**. Cause: the orchestrator's
**subprocess-per-milestone model leaves Perry LINK-DEAD between runs** — his idle body sat
in the aggressive-mob newbie zone and got beaten to 0 HP in the gap between the executor
subprocess ending and the next connection. Same class as [[dont-blind-drive-perry]] ("never
disconnect Perry in an unsafe room"), re-introduced by the orchestration. *(Lesson: don't
assume a cause — read the logs. The prioritization did NOT raise risk; it worked and left
Perry healthy.)*

**Secondary finding (and its fix, validated):** nothing recovered from the resulting stun
in-run. A recovery watcher — **wait out the stun → heal → teleport to safety** — brought
Perry back cleanly (0 → 13 HP as the stun lifted → 44/44 at the Temple). That's the
recovery pattern the executor/orchestrator should own.

Next (fixes before the long level-5 run):
- **Don't leave Perry link-dead in an unsafe room between runs** — the root bug. Options: one
  persistent connection across the orchestration, or safe-park (teleport to Temple) at the
  end of each executor run / between milestones.
- **Stun/hurt recovery** in-loop (the watcher pattern), and **escalate blocks to the planner**
  for a replan (currently escalation only stops).
- Then integrate the orchestrator into the lib and run the full level-5 goal.

## Where we paused (2026-07-29)

**Goal:** give the agent **planning** — take a high-level goal, decompose it into
actionable milestones that map to milestones + tools, execute them, and replan when
blocked — on a **two-tier model split**: **`claude-sonnet-5` plans** (sparse, high-value
cognition), **Haiku executes** (the tight tool loop). Acceptance test: **become a level-5
Thief with backstab trained**, self-directed.

**Done & validated (slices 1–4):**
- The harness runs two models with no new plumbing (`Boukensha.run(model:, mud: false)` =
  a tool-less planner call). Registered the Claude 5 model IDs.
- Sonnet-5 decomposes a fuzzy goal into a clean, correctly-ordered, **machine-checkable**
  milestone plan (once told milestones are *checkpoints*, not tool-calls).
- The **orchestrator** works end-to-end: `plan.json` persists goal + milestones + progress
  + baseline across runs; the executor runs one milestone per subprocess; the orchestrator
  judges completion by checking each milestone's `done_check` against **live game state**,
  and advances / re-runs / escalates. Proven on a short goal.

**Open (scoped for the next sitting):**
1. ~~**Root bug — link-dead between runs.**~~ **FIXED (2026-08-01, below).**
2. **In-loop stun recovery — DEFERRED (2026-08-01), fix-if-observed.** See the decision note
   below. **Block → planner replan** (escalation currently just stops) — still open.
3. The full level-5 run — a long, respawn-paced, multi-run grind.

### Decision — defer stun recovery until it actually shows up (2026-08-01)
The *hurt* half of recovery is already deterministic and covers the common case: `fight` sets
a **wimpy floor (~⅓ max HP)** so Perry auto-flees before a lethal hit, and **`rest_until hp:`**
sleeps him back up behind a full safety gate (won't sleep near a mob / under attack / in an
over-level zone; eats/drinks so regen isn't blocked). The uncovered case is **stun** — while
stunned Perry can't act, so wimpy can't flee *and* `rest_until` (which does wake→stand→look
first) can't run; the only handler is the manual watcher (poll until the stun lifts → heal →
safe-park), which isn't owned by a tool yet. **But the catastrophic stun in the incident was
the link-dead mauling, now fixed** — the remaining in-combat stun is rarer (wimpy usually
flees first) and non-catastrophic (Perry is connected and recovers as it wears off). So rather
than build speculative machinery, **we run the level-5 acceptance test and only build the
owned stun-recovery routine if a stun actually bites in practice.** If it does, the fix is
known: a `recover` routine (wait-out-stun → `rest_until hp:` → safe-park) plus a deterministic
"ensure healthy + safe between milestones" guard in the orchestrator.

**Artifacts:** design in this file; the orchestrator + executor now live in the repo at
`week1_baseline/ruby/12_context/planning/` (they had been only in the session scratchpad,
which was wiped between sittings — recovered verbatim and committed).

### Fix — link-dead between runs (2026-08-01)
**The bug, precisely:** ending a run or a state read just **dropped the socket**. CircleMUD
keeps a disconnected character's body in the world (link-dead), so Perry's idle body sat in
the aggressive newbie zone and got beaten to 0 HP in the gap between runs. Two code paths
did the bare close: the executor subprocess exiting, and the orchestrator's `read_state`
(which runs *often* — before/after every milestone).

**The fix — quit cleanly, everywhere.** The in-game `quit` command **saves the character and
extracts it from the world**, so there's no attackable body left behind.
- New **`mud_quit`** tool: sends `quit` *without* waiting for the `> ` prompt (quit drops the
  connection, so the normal read-until-prompt would hang), briefly drains the goodbye, closes.
- **`mud_disconnect` now aliases the clean quit** — a bare socket-close is never the right
  thing for a stateful character, so the link-dead path is removed at the tool layer.
- **`Boukensha.run` quits the MUD on teardown** (in `ensure`) — fixes the executor subprocess
  path for *every* run, not just the orchestrator's.
- **`read_state` quits** instead of disconnecting.

**Verified before building on it (the "don't assume" lesson, applied):** a probe moved Perry
one room, quit, reconnected — and he **re-entered the room he quit in**, not a reset load
room. So quit-on-exit **preserves position**: the grind-spot and any `at_place` progress
survive across runs, at no re-travel cost. Then validated end-to-end — a real executor
subprocess (exit 0, reply intact, teardown clean) and `read_state` both leave Perry **safe at
44/44**. Link-dead is now structurally impossible through the tools.

**Design note this surfaced:** milestones should be checkpoints on **persistent character
state** (xp, level, skills, items) — all of which survive a quit — rather than transient
world state. Location happens to survive here too, but the planner prompt already steers
toward xp/level/skill checks, which is the robust choice.

### Validation run — the fix holds; a new bottleneck appears (2026-08-01)
Re-ran the orchestrator end-to-end on a short goal (*gain ~500 xp → travel to the guild*)
to prove the link-dead fix under real load. Sonnet-5 planned it cleanly (grind to
`xp_at_least 6473`, then `at_place "Thieves' Guild"`), and:

**What passed (the point of the run):**
- **Perry survived the entire run** — 4 executor subprocesses + 5 state-reads, each a full
  connect → fight → quit cycle (the exact motion that killed him last session). **Zero
  deaths, no stun, no 0-HP; the logs show he never dropped below 44/44.** Link-dead is fixed.
- Position **persisted across quits** (Temple → Dirty Hallway → Armory — he stayed in the
  zone, not reset to a load room), and the orchestrator ran clean: plan → execute → re-check
  → persist → escalate at the run cap.

**What it exposed (a real new bottleneck, read from the logs — not assumed):** the grind
**stalled 156 xp short** and hit the 4-run cap. Cause: **Perry has outgrown the newbie
zone.** He's L4; the logs are full of *"all clear"* / *"too trivial"* / *"respawn"*, and two
of the four runs landed **zero kills → zero xp**. The prey-prioritization **floor we built is
now the binding constraint** — correctly refusing trivial mobs, but at L4 the *whole* newbie
zone is trivial and quickly depleted, so Perry finds nothing worth killing and waits on
respawns. (Ironic and on-theme: every downstream limiter keeps turning out to be
navigation/prey-economy, [[mud-grind-locations]].)

**Second, smaller finding — executor thrash:** when prey is scarce the executor calls `hunt`
**140–270×** in a single run (hunt → "all clear" → `rest_until` → hunt …) instead of
recognizing depletion and reporting back. Wasteful; it should give up after N empty hunts and
report *"zone depleted, waiting on respawns"* so the orchestrator can wait or replan.

**Not yet validated:** milestone 2 (`at_place` guild) never ran — M1 blocked first. The
quit-preserves-`at_place` path is proven by the earlier probe but not yet through the loop.

**Options (for when we pick grind economy up):** graduate Perry to a higher-level ground for
L4→5 (the sewer is the noted step up — needs teleporter + light, [[mud-grind-locations]]);
and/or let `hunt` relax the floor when a zone is *depleted* (take trivial prey rather than
stall); and/or raise `MAX_RUNS_PER_MILESTONE` for genuine grind milestones. None needed to
call the link-dead fix validated — that was the run's job, and it passed.

**Zone index added (2026-08-01).** Perry's system prompt now carries a structured **Zone
index by level** (`.boukensha/prompts/system.md`) — newbie zone (L1–5, outgrown ~L4), the
Sewer (~L4–7, the next step up) with a 4-item entry checklist (light, teleporter, food,
water) and hard-rules, town banned. Mirrored in [[mud-grind-locations]].

**New code to-do this surfaces — safe-park before quit in "no-quit" zones.** The clean-quit
fix quits on run teardown, and login *restores the quit room*. That's fine in the safe newbie
zone, but the sewer's hard-rule is "never quit inside" (you'd re-enter in the maze). So when
Perry grinds the sewer, the orchestrator/executor teardown must **`teleport MIDGAARD` before
quitting** whenever the current room is a no-quit zone (i.e. the general "safe-park then quit"
combo, applied conditionally). Not needed until sewer-grinding starts — noted so it isn't
forgotten. **(Done 2026-08-01)** Perry's identity block in `system.md` was rewritten off
stale hard-coded stats (level-1, ~21 HP, specific gear) and onto what stays true: he's a
**Thief**, his edge is **thief skills** (backstab/sneak/hide/steal/pick lock, improved by
practice at the guild), and he should **read level/HP via `check score` and skills/sessions
via `practice`** rather than assume them.

---

> **📖 Story thread** — *Prev:* [← 4. Completing the toolkit](./4_seek.md) · [↑ Overview](./00_summary.md) · *Next:* [6. The capstone — hunt the minotaur →](./6_minotaur.md)
