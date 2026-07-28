# Week 3: Combat & Leveling — earning the right to train

> **Status:** pre-registration. Plan and predictions recorded *before building*, so
> each can be checked honestly later (same discipline as
> [2_capable](./2_capable.md)). Observations get filled in as we build; the readable
> review comes at the end.

## Where this picks up

Navigation is done: Perry reliably finds the Thieves' Guild and reaches the
guildmaster. Obs 12 ended on the *one* thing navigation couldn't solve — Perry stood
in front of the guildmaster with **0 practice sessions**, and practice sessions come
from **levelling** (killing mobs for XP), not from gold. So "found the guild" is real,
but Perry still can't *do* anything there.

This arc closes that loop: **kill mobs → gain XP → level up → earn a practice
session → train a skill.** It's the second of the three table-stakes abilities
(navigation → **combat** → planning), and it stands on the same persistent
world-model, no redesign.

## Technical Goal

Make **combat and levelling reliable** enough that Perry can gain at least one level
and spend the resulting practice session to train one skill at his guild — end to
end, from a live LLM run, without dying and losing his gear.

**Acceptance test:** a single task — *"Gain a level and train a skill at your
guild."* — completes: Perry fights weak mobs, survives (flees when losing), loots,
hits level 2, walks to the guildmaster, and trains one skill. This is the exact
scenario Obs 12 got *one mechanic* short of.

**Scope discipline (unchanged from week 2):** Ruby track; watch first, fix second,
one slice at a time, minimise LLM tokens (mechanics are deterministic; the LLM
chooses only goals and handles surprises). The navigation follow-ups (maze/sewer
pathing, message-history caching) stay **parked** — pull one in only if it actually
blocks a combat run.

## The method question this arc also answers — tools vs. teaching

Obs 12 exposed *both* ways tool use fails, and we want to measure the ratio rather
than guess:

- **Missing-tool failures** — the agent fell back to `send_raw` **×12**. Each raw
  fallback marks a spot where a structured tool *should* exist. → **build the tool**
  (and write its usage line in the same change).
- **Knowledge failures** — the agent believed gold bought practice sessions. No new
  tool fixes that; a prompt line does. → **teach it** (system-prompt policy).

So the first move is **observation, not construction**: run a combat task and tag
every stumble as **tool gap** (→ build) or **misuse** (→ teach). We only build a tool
once the run shows the agent reaching for one that isn't there. A cheap, general
nudge rides along regardless of arc: *"if you're about to type a raw command, that's
a signal a structured tool is missing — prefer the structured tool,"* which also
turns the agent into a sensor for our own tool gaps.

## Technical Uncertainty

- **Does the existing combat loop survive a real fight?** Obs 12 had Perry beat bats
  for gold, but only incidentally. `consider` → `set_wimpy` → attack →
  `diagnose`/`flee` → loot is *specified* in the prompt; is it *reliable* under an
  actual HP-pressure fight, or does the agent freeze, over-commit, or forget to loot?
- **Flee/wimpy discipline** — will the agent set wimpy and actually bail when losing,
  or will a fragile ~23-HP Thief die and drop his gear (the expensive failure)?
- **Does the world-model need combat state?** Navigation state lives in the map. XP,
  level, HP trend, "this room has a killable mob" — do these need first-class storage,
  or is reading `score`/`consider` each time enough? (Guess: minimal state; avoid a
  redesign — the whole bet is the store already suffices.)
- **Tool-gap ratio** — how many of Obs 12's 12 raw fallbacks were combat-shaped
  (target selection, corpse looting, XP/level check) vs. incidental? Unknown until we
  watch.
- **Where to grind** — the prompt says fight north of the Temple (newbie area). Is
  that reachable + survivable for a level-1 Thief, and are the mobs there weak enough
  to `consider` as safe?

## Design decisions locked before building

The core realisation (from the user): **combat is too fast and too text-heavy for the
LLM to make round-by-round decisions.** So we push the decision loop *down* — to our
tool, and below that to the MUD's own auto-combat — and keep the LLM out of the fight
entirely. It picks the *goal* ("level up"); the tool and the game run the fight.

- **Wimpy is deterministic, not a decision.** The harness hard-sets wimpy on connect
  and re-sets it on level-up (max HP changes) to **⌈max_hp / 3⌉**. The LLM never
  touches it. *(Not 10% of max HP: CircleMUD checks wimpy* after *each hit and only
  auto-flees if you survive below the threshold. With ~23 HP and 5–10-damage newbie
  mobs, a 10% threshold (~2 HP) is skipped straight over — you die through it without
  fleeing. ~1/3 is above the biggest plausible single hit, so it actually fires. This
  matches the existing `set_wimpy ~1/3` prompt guidance.)*
- **Combat is a fight-to-completion tool, not a round loop.** The LLM calls "fight the
  safe mob here" **once**. The tool does `consider` (bail if not safe) → engage → let
  the MUD's auto-rounds run → poll until death / flee / wimpy-trigger → auto-loot the
  corpse (items + coins) → return **one distilled line** (outcome + vitals + XP/level
  delta). Round-by-round text never reaches the model.
- **Lean on the game's own automation.** Wimpy auto-flees; auto-attack runs each round
  with no command from us. Most of a fight is already the MUD deciding — our tool just
  wraps *start → poll → loot* and compresses the result.

## Technical Hypotheses

**Core:** levelling is a **decision-offloading problem, not a discipline problem.** The
combat verbs already exist and the MUD already auto-runs the rounds; the win is to
spend *near-zero LLM tokens* on combat — the model chooses a target class and a stop
condition, the tool + game do everything else. Get the offload right and a level-1
Thief grinds to level 2 and trains, the same way moving pathfinding out of the model
turned week-1 circling into a solved task.

Supporting bets:
- The world-model needs **little or no new state** — reading `score`/`consider` on
  demand covers combat decisions; at most we cache "level / XP-to-next" so the agent
  knows when it's close to the goal and can stop.
- The **tool-gap ratio is low but real** — combat needs ~1–2 new structured tools (the
  fight-to-completion wrapper above, maybe an XP/level reporter); the rest is the
  deterministic wimpy hard-set + a thin prompt policy. Most Obs 12 raw fallbacks were
  navigation-era gaps.
- **Flee/target safety is deterministic, not taught** — wimpy is hard-set by the
  harness, and target safety is enforced *inside* the fight tool's `consider` gate, not
  by asking the LLM to remember a rule mid-fight.
- The same **early-stop rule** from navigation applies: if the tool can't find a safe
  mob or Perry keeps getting driven off, report the blocker and stop rather than grind
  into a corpse.

## Plan — slices (watch first)

| Slice | What | Why |
|---|---|---|
| **Obs A — watch** | Run *"Gain a level and train a skill"* on the current build, unchanged. Tag every stumble **tool gap** vs **misuse**, and note how much combat text the LLM has to read per fight. | Measures the offload gap + the tool/teach ratio before we build anything. |
| B — deterministic wimpy | Harness hard-sets wimpy = ⌈max_hp/3⌉ on connect and on level-up. No LLM involvement. | Removes the deadliest per-fight decision from the model entirely. |
| C — fight-to-completion tool | One structured tool: `consider`-gate → engage → poll MUD auto-rounds until death/flee → auto-loot → return one distilled line (outcome + vitals + XP/level delta). LLM calls it once per fight. | Keeps round spam out of the model; the core offload. |
| D — thin combat policy + XP reporter | Prompt: "call the fight tool, don't hand-type combat; stop when you hit the target level." Add an XP/level reporter only if Obs A showed the agent flying blind on progress. Include the general "raw command = missing tool" nudge. | Minimal teaching, only where the watch proved it's needed. |
| E — minimal combat state | Only if B–D show the agent needs persistent XP/level/HP-trend to decide. | Guard the "no redesign" bet. |
| **Result** | Acceptance test passes: level 2 + one skill trained, no death, near-zero combat tokens. | Closes the Obs 12 loop. |

## Technical Observations

_(to be filled as we build — Obs A first: the unchanged watch run.)_

## Technical Conclusions

_(pending)_

## Key Takeaway

_(pending)_
