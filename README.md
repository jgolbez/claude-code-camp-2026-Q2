# Claude Code Camp
This is the official repo for the Claude Code Camp operated by [ExamPro](https://www.exampro.co)

## 📋 Project journal — start here

**→ [docs/journal/00_summary.md](docs/journal/00_summary.md)** — a high-level technical
summary of **boukensha**, a from-scratch Ruby harness in which an LLM plays CircleMUD/tbaMUD,
built toward one goal the bootcamp set: **hunt down and kill the minotaur in the newbie
zone**. Written in the standard journal format, it opens with an ordered chapter list — the
whole journey, from the baseline harness through navigation, combat, planning, the capstone,
and the cold-start control experiment — so you can read the story top-to-bottom or dig into
any detailed entry; every chapter links forward and back.

**Headline results:**

- 🏆 **The capstone goal was met** — the agent located the minotaur, was ambushed by it
  mid-hunt, and out-meleed it to **Level 5, zero deaths, gear intact**
  ([ch. 6](docs/journal/6_minotaur.md)).
- **Memory killed the circling** — a persistent world-model turned an agent that wandered
  and burned its token budget into one that finds its guild on a blank map in a single tool
  call ([ch. 2](docs/journal/2_capable.md) · [ch. 4](docs/journal/4_seek.md)).
- **Offload extends to the model tier** — Sonnet plans sparsely, Haiku executes, and a
  persistent orchestrator judges completion against live game state
  ([ch. 5](docs/journal/5_planning.md)).
- **It generalises.** Strip the hand-written world knowledge and the map, and brand-new
  characters still play: **four cold starts, ~30 autonomous runs, 0 deaths**, one of them
  completing a four-part compound goal with **zero human interventions**. That experiment
  surfaced **24 defects** the warm start had been hiding — and their distribution is the most
  interesting result in the repo ([ch. 9](docs/journal/9_cold_start.md)).

*New reader in a hurry?* Read [ch. 9](docs/journal/9_cold_start.md) for the lessons, then
[the toolkit reference](docs/journal/movement_combat_toolkit.md) for what the agent can
actually do.
