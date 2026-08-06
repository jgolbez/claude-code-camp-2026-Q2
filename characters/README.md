# Cold-start characters

Everything through [chapter 6](../docs/journal/6_minotaur.md) was measured on **Perry**,
who carries weeks of hand-written world knowledge and a 141-room map. That confounds the
result: how much of the competence is the agent, and how much is the prompt?

These characters are the control. Same harness, same tools, knowledge removed — a blank
map, a system prompt that teaches tool discipline and no geography, and empty pockets.
Identity lives in config, so no code change is needed to play any of them:

```bash
BOUKENSHA_DIR=$PWD/characters/<name>/.boukensha \
  mise exec -- ruby week1_baseline/ruby/12_context/planning/run.rb "<goal>"
```

| Character | Class | Goal | Interventions | Outcome |
|---|---|---|---|---|
| [hectic](./hectic/) | Warrior | reach level 2 | 8 | level 2 — found **8 tool-layer defects** |
| [solace](./solace/) | Cleric | 5-part compound | 9 | level 2 + teleporter — found **7 planning defects**, zero tool regressions |
| tarn | Warrior | 4-part compound | **0** | **goal complete** |
| rell | Warrior | 4-part compound | **0** | level 2, all 4 parts; replan budget lost to the sewer |

**~30 autonomous runs, four characters, zero deaths.**

Each directory holds only source — `settings.yaml`, `prompts/system.md`, `.env.example`.
The runtime state (`world.json`, `plan.json`, session logs, `.env`) is gitignored, so a
character starts blank unless it has walked the map itself.

The full account and the lessons learned are in
[docs/journal/9_cold_start.md](../docs/journal/9_cold_start.md).
