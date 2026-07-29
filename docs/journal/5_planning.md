# Planning — decompose a goal, plan with a strong model, execute with Haiku

> **Status:** pre-registration (design before build). The third and last table-stakes
> ability (**navigation → combat → planning**); it stands on the tools built in
> [3_combat](./3_combat.md) / [4_seek](./4_seek.md).

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
