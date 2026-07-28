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
| ~~**Obs A — watch**~~ ✅ | Ran the unchanged build. **Verdict:** discipline is fine (0 raw fallbacks, wimpy set, consider obeyed); the budget died in the **search phase** (`move` ×20 hunting for prey). No combat — all newbie-dungeon mobs too tough. | Reordered the slices below: the search offload is now the urgent one. |
| **B — `hunt` tool** (was C) | Deterministic: from here, step to the next unexplored room → auto-`consider` the mob → repeat until it finds a `consider`-safe target *or* exhausts a bounded range; return "killable X in room N" (or "no safe prey found"). Fixes the `explore` blocked-frontier bug along the way (drop a frontier after a blocked move). | **The thing that actually blew the budget.** Turns 20 LLM iterations into one decision. |
| **C — `fight` tool** (fight-to-completion) | `consider`-gate → engage → poll MUD auto-rounds until death/flee → auto-loot → one distilled line (outcome + vitals + XP/level delta). LLM calls it once per fight. | The pre-registered core offload; keeps round spam out of the model. |
| D — deterministic wimpy | Harness hard-sets wimpy = ⌈max_hp/3⌉ on connect and level-up. (Agent already set it correctly in Obs A, so this is belt-and-suspenders, low priority.) | Removes the deadliest per-fight decision entirely. |
| E — thin policy + XP reporter + grind spot | Prompt: "use `hunt`/`fight`, don't hand-walk; stop at the target level." Point the agent at a **known safe grind spot** (sewer bats?) since the newbie dungeon is too tough. Add "raw command = missing tool" nudge. | Minimal teaching, only where the watch proved it's needed. |
| F — minimal combat state | Only if B–E show the agent needs persistent XP/level/HP-trend to decide. | Guard the "no redesign" bet. |
| **Result** | Acceptance test passes: level 2 + one skill trained, no death, near-zero combat tokens. | Closes the Obs 12 loop. |

## Technical Observations

### Baseline (pre-Obs A, 2026-07-28) — Perry rerolled + geared
The old Perry got stranded off-map in the sewer/abyss maze (hungry, thirsty, no
route back — `explore` even fixated on a closed rock, retrying a named-but-blocked
exit forever; logged as a parked nav bug). The user **rerolled him** into a fresh,
fully newbie-geared level-1 and bought a **teleporter** (`teleport MIDGAARD` = no-move
recall to the Temple; see [[perry-teleporter-recovery]]).

Real starting state (this replaces the prompt's old "naked, fists, weak-mobs-only"
description, which was corrected in `prompts/system.md`):
- **~21 HP, level 1, 536 exp → 714 to level 2** (the grind target).
- **Armed + armored:** wields a small sword; full newbie leather + shield; a lit
  **candle** (light — dark rooms no longer block him); spare newbie dagger.
- **Teleporter** escape hatch (reusable), 2 bread, ~30 gold.
- Positioned deterministically at **The Temple of Midgaard (#1)**, rested, 85/85 move.

Two findings already, before the LLM runs: (1) survival had **no stranded-recovery**
— the teleporter now fills that gap and should become a structured tool; (2) the
`explore` frontier picker retries **named-but-blocked** exits forever — needs to drop
a frontier after a blocked attempt.

### Obs A — watch run (the unchanged build, corrected baseline) — 2026-07-28
Task: *"reach level 2, then train a skill."* Perry started at the Temple, geared.
Ran 34 iterations, stopped on **`max_tokens` (124K > 120K cap)**. **No combat
happened** — and *that is the finding*.

**What the agent did right (discipline is not the problem):**
- Set **wimpy = 7** (1/3 max HP) unprompted; used **structured tools throughout**
  (`equip_item`, `consider`, `check`) — **0 `send_raw` fallbacks.**
- `consider`ed 5 mobs and correctly refused every one — the whole newbie *dungeon*
  north of the Temple rated "too tough" / "would need a lot of luck" for a fresh
  level-1 (newbie monsters, a pet dragon, zombie newbies, quasits, an alchemist).
- So it never broke the "only fight `consider`-safe mobs" rule. The combat *mechanics*
  the prompt teaches were followed faithfully.

**Where it burned out — the real gap is the SEARCH phase, not the fight:**
- Tool histogram: **`move` ×20**, consider ×5, check ×4, equip ×2, look/examine/
  set_position/set_wimpy ×1. It **hand-walked the dungeon room-by-room with 20 single
  `move` calls** — the exact anti-pattern the nav policy warns against — instead of
  `explore`. Those 20 LLM iterations drove the token cap.
- **Why it didn't `explore`:** searching *for prey* needs to stop in each room, look at
  the mob, `consider` it, and decide — a per-room consider loop. `explore` barrels to
  the next frontier with **no consider**; raw `move` gives control but costs a full LLM
  iteration per step. **Neither tool fits "hunt for a fightable mob."** So this reads as
  a **high-level tool gap**, not misuse — there is no primitive for the search loop.
- **Token cap = same cumulative-per-turn sum** (input grew 361→8193/response, ~130K
  summed; caching worked, `cache_read` 5963/call). 20 hand-walk iterations each
  re-counted the growing history → the O(n²) wall at iter 34.

**Grind-location finding:** the "newbie dungeon north of the Temple" (what the prompt
points at) is **too tough for a fresh level-1**. The mobs Perry actually beat last
reroll were the **sewer bats** (Obs 12) — the irony being the maze we teleported him
*out* of held the killable prey. The agent needs a known safe grind spot, or a hunt
tool that ranges until it finds `consider`-safe prey.

**Tool-gap vs. misuse tally (the pre-registered question):** 0 raw fallbacks →
low-level verbs are fine. The gap is **two high-level aggregating tools** that keep the
LLM out of the loop:
1. **`hunt`** — explore one room → auto-`consider` the mob there → repeat until it finds
   a `consider`-safe target (or exhausts range), returning "found a killable X in
   room N." One LLM decision instead of 20 `move`s. *(This is the urgent one — it's
   what actually blew the budget.)*
2. **`fight`** (fight-to-completion) — the pre-registered wrapper: `consider`-gate →
   engage → poll MUD auto-rounds → auto-loot → one distilled line.

Both confirm the core hypothesis (combat is decision-*offloading*), and Obs A sharpens
it: the offload must cover the **search** phase first, because that is where a
correctly-behaving agent still burns its whole budget.

### Slice B — `hunt` tool + `explore` blocked-frontier fix (built, validated live) — 2026-07-28
**Built** (deterministic, zero model tokens):
- **`hunt`** — walks room by room; in each, extracts mob keywords from the live
  occupant lines and `consider`s them; stops the instant one rates **safe/even**
  (returns "prey X in room N → call fight"), or reports "only-too-strong / none" and
  suggests relocating. Also hands back on an aggressive-mob attack mid-search.
- **Mob-keyword extraction** (`world_model#mob_keyword_sets`): parenthetical species
  hints → capitalized proper nouns → longest content words, with `consider` itself
  validating the match. Unit-tested against real lines: `(a quasit perhaps?)`→quasit,
  `The Great Minotaur`→minotaur, `a small bat`→bat; corpses/objects skipped.
- **`explore` blocked-frontier fix:** a bounced step (closed door/rock, non-direction)
  now `mark_blocked`s that exit (sentinel neighbour, no longer a frontier) instead of
  retrying it forever — the bug that trapped the old Perry on the ledge.

**Validated live (no LLM):** two `hunt` runs searched 6 and 7 distinct rooms with no
fixation, correctly rated every newbie-dungeon mob unsafe (`minotaur "Are you mad!?"`,
`quasit "a lot of luck"`, `zombiefied newbie "…great equipment"`), and returned clean
reports in ~4s. Bugs found & fixed in the pass: a `/x`-flag regex swallowing the spaces
in "has been installed" (objects leaked as prey); an aggressive mob's attack line
mistaken for a consider rating.

**Hardened Obs A's grind-location finding:** `hunt` *proves* the newbie dungeon north
of the Temple is too tough for a fresh level-1 — there is **no safe prey there.** The
only mobs this Perry has beaten are the **sewer bats** (Obs 12). Slice C (the `fight`
tool) can't be validated end-to-end until we point Perry at weak prey → the grind-spot
question is now on the critical path.

### Slice C design — skill-aware, class-agnostic combat (2026-07-28)
Perry was rerolled again (died in the chessboard during a blind scout — see
[[dont-blind-drive-perry]]); the user levelled him to **3 ("the Filcher")** and trained
**backstab (fair)**, **pick lock (poor)**, **sneak (awful)**. This forced the real
question: **how does combat account for what the character has actually trained**,
given skills and proficiency differ per class and per character?

**Answer — two data sources, kept separate to stay character-agnostic** (identity in
config, per [[boukensha-generic-thief-tools]]):

1. **Trained skills, read from the GAME** (`practice` → `{skill => proficiency_word}`).
   Authoritative and class-agnostic — the game tells us what *this* character knows.
   Proficiency ladder (this MUD): `awful < bad < poor < average < fair < good <
   very good < superb`. Refresh on connect and after training/levelling. Stored in
   character state.

2. **A skill-capability catalog (shared static knowledge)** — maps a skill NAME to how
   the harness *uses* it: its **role** + **preconditions** + **on-fail**. This is the
   class-agnostic "how to play" knowledge, not tied to Perry:
   - `backstab` → role: **opener**; requires: initiating (target not already fighting)
     + **piercing weapon** wielded; effect: big first-strike multiplier; on-fail: lose
     surprise but still engage.
   - `bash`/`kick` (warrior) → role: **combat-move** (per round).
   - `pick lock` → role: **utility:lock** (navigation — locked door/gate/chest).
   - `sneak`/`hide` → role: **utility:stealth** (approach; sets up a backstab).
   - `steal` → role: **utility:theft**.

**The `fight` tool consults both:** from the character's trained skills, pick the
best-available **opener** whose preconditions hold, use it, then run normal auto-attack
rounds (+ any per-round combat-moves), then auto-loot. Proficiency gates reliability —
an `awful`/`poor` skill is unreliable, so the opener is used only above a floor (or
tried opportunistically when a failure is cheap). Everything degrades gracefully: if no
opener qualifies, plain attack.

**Immediate consequence for Perry:** his best skill (backstab, *fair*) is **inert** —
he wields a small sword (slashing), and backstab needs a **piercing** weapon (dagger).
The catalog precondition "piercing weapon" fails → `fight` correctly skips backstab and
plain-attacks. So backstab stays unused until Perry wields a dagger. This is the design
working (graceful degradation), but it means: **to exercise backstab, give Perry a
dagger.**

**Utility skills wire elsewhere, not into `fight`:** `pick lock` → navigation (when
travel/explore hits a *locked* door, if pick lock is trained, try it); `sneak`/`hide` →
approach-for-backstab; `steal` → its own tool. Slice C ships the combat half (skill
discovery + catalog + `fight` opener logic); the utility wiring is a follow-up.

**Slice C build order:** (C1) skill discovery — parse `practice` into character state;
(C2) the capability catalog (a plain data map, extensible per class); (C3) `fight` —
`consider`-gate → optional skill opener → auto-attack rounds → auto-loot → one distilled
line (outcome + vitals + XP/level delta). Validate against a real crawler/clueless
newbie once Perry is armed.

### Slice C — skill-aware `fight` tool (built + unit-tested; live validation pending) — 2026-07-28
**Built:**
- **`Boukensha::Skills`** (`lib/boukensha/skills.rb`, class-agnostic): `parse_practice`
  → `{sessions, skills:{name=>prof}}`; `PROFICIENCY` ladder + `proficiency_rank`; the
  `CATALOG` (skill → role/preconditions/on-fail); `openers` (best-first). Unit-tested
  against Perry's real `practice` **and** a synthetic Warrior list (bash/kick =
  combat_move, no opener) — all pass.
- **`fight` tool** (fight-to-completion): re-`consider` gate (refuse unsafe unless
  `force`) → wimpy floor `⌈maxhp/3⌉` → **skill-aware opener** (backstab: capture main
  weapon → wield a carried dagger → `backstab` → re-wield main; detects "need piercing
  weapon"/miss and degrades) → `kill` → **poll `read_until_quiet` to the outcome** →
  auto-loot corpse (items + coins) → ONE distilled line (killed/leveled/fled/died +
  HP + xp delta + "train at your guild" on level-up). `attack`/`skill_strike` demoted
  to low-level fallbacks in their tool docs.
- Registry loads clean at **40 tools**; `fight` + `hunt` present.

**Refinement (from a user test):** this small sword's damage type is **piercing**, so
backstab works with it directly. The opener was rewritten to **try backstab with the
currently-wielded weapon first**, and only swap in a carried dagger if the game rejects
the weapon type (a weapon-type rejection aborts before combat, so the retry is safe).
Handles the piercing-sword case with no pointless swap.

### Obs C — `fight` validated live (deterministic, no LLM) — 2026-07-28
User parked Perry at a **clueless newbie** (*"A newbie is here annoying the hell out of
you"*, `consider` = "Fairly easy") and I ran one `fight`:

> **Killed 'annoying' — backstab landed (fair). +207 xp (1543 to next level). Looted
> corpse. HP 37/37.**

Every piece of the chain fired in a single call: consider-gate (safe) → wimpy floor →
**backstab landed with the small sword** (piercing confirmed, no swap) → poll-to-kill →
auto-loot (gold 96→116, +20) → xp delta (+207) → one distilled line, **no round spam**.
Perry took **zero damage** (backstab + weak mob = one-shot). Slice C works end to end.

**Minor note (not a bug):** the chosen target keyword was `annoying` (longest word won
over `newbie`); `consider`/`kill` matched it fine, but preferring the mob-noun would read
cleaner — a small `mob_keyword_sets` refinement for later.

**Where this leaves the arc:** the two offloads (`hunt` search + `fight` kill) are both
built and proven. Remaining to close the acceptance test: run them together under the
LLM (**Obs B**) so the agent grinds clueless-newbies/crawlers to level 4 and trains a
skill — the end-to-end the whole arc is for.

### Obs B — LLM drives hunt+fight; the offload is proven, one bug broke it — 2026-07-28
Ran Haiku on *"reach level 4, then train."* Perry survived (no death — the safety
discipline held). **A decision-flow trace** (`scratchpad/flow_trace.rb`, reconstructs
DECIDE→call→result→cost per iteration; the observability the run was for) told the whole
story:

**The thesis is PROVEN — when the tools ran (iters 3–4):**
```
iter 3  ★ hunt   ⇒ Found prey: 'monster' (#91) "Fairly easy" → call fight
iter 4  ★ fight  ⇒ Killed 'monster' — backstab landed (fair). +203 xp. Looted. HP 37/37.
```
**Two LLM decisions = one mob found and killed, backstab and all, zero round spam.** The
entire combat-as-offload bet, demonstrated end to end.

**One bug detonated the rest (iter 5):** `hunt` **crashed** with
`ArgumentError: invalid direction "(d)"`. Root cause: `parse_room` keeps a closed-door
token `(d)` as an exit; when `hunt`'s internal `explore` stepped through that frontier,
`p.move("(d)")` raised (the `mark_blocked` fix never fired — the crash precedes the
blocked-check). Earlier live tests never landed in a `(d)` room.

**The crash caused the bad numbers:** with `hunt` broken, the agent **fell back to
hand-walking** — `move ×20` (iters 15–35), the Obs A anti-pattern — which drove the
token cap (120K at iter 35). Offload ratio looked poor (7 high / 31 low) but that is
**entirely the crash's fallback**; pre-crash it was ideal.

**Fixed:** `explore` now normalises the frontier token (`(d)` → `down`) before moving
and marks anything non-directional blocked; `hunt` gained a defensive rescue so no
internal error can ever crash the loop again. Verified by construction + registry loads
clean (40 tools). *(Proper follow-up: normalise parens in `parse_room` itself, with a
fingerprint migration — deferred to avoid re-mapping door rooms.)*

**Two things that held up well:**
- **Safety.** The agent engaged a "perfect match" quasit; the `fight` wimpy floor
  auto-fled it at no HP loss (37/37), and later it fled a "some luck" zombie cleanly.
  Consider-gate + wimpy + flee = Perry survived a run that the blind script would have
  killed him in.
- **Observability.** The flow-trace made "is the loop offloading?" answerable at a
  glance — exactly the week-2 discipline.

**Still open:** prey scarcity. Even with working tools, "Fairly easy" prey is sparse;
the agent drifted off the clueless-newbie spot into perfect-match quasits / tough
zombies. Needs grind-location guidance (or hunt ranging wider). Minor: `travel_to
"Midgaard Temple"` didn't resolve (room is "The Temple Of Midgaard") → fell back to
nearest frontier; a name-resolution nicety.

**Post-Obs-B fixes (user-spotted, from the log viewer):**
1. **`fight` misreported a mob's retreat as Perry fleeing.** The quasit fight ended
   with Perry at 37/37 yet `fight` said *"Fled… wimpy saved you"* — wrong. Cause:
   `/PANIC/i` matched the **mob's** *"panics, and attempts to flee"*. Fixed: detect
   first-person (Perry) vs third-person (mob) flees separately, and only claim "wimpy
   pulled you out" when Perry's HP is actually near the floor. Now a mob escaping reads
   *"'quasit' panicked and fled — no kill, you're unhurt."* Unit-tested.
2. **The agent manually fled at high HP instead of trusting wimpy.** The combat prompt
   was stale (told it to `consider`/`set_wimpy`/`loot`/`flee` by hand — all now done by
   `fight`). Rewrote it: *use `hunt` then `fight`; the tool runs consider/wimpy/opener/
   kill/loot; trust the outcome; never manually `flee` at healthy HP — wimpy auto-flees
   only when a fight truly turns.* This removes the second-guessing the user saw.
3. **`fight` now CHASES a fleeing mob** (user request). A mob only flees when it's
   losing, so it's low-HP — free xp if caught. `fight` parses the flee direction from
   the round text (*"flees east!"*), follows, and finishes the kill; bounded to 3 rooms
   (so a mob can't march Perry into danger) with wimpy still guarding HP. Reports
   *"Killed 'quasit' (chased it down 2 rooms)…"* or, if it outran him, *"outran you
   after N rooms of chase."* Direction-parse + loop unit-tested.

### Obs B2 — clean re-run: no crash, but the blocker moved to PREY-FINDING — 2026-07-28
All four fixes held: **no `(d)` crash**, accurate flee reporting, teleporter escape from
the Black Knight zone, **no death**. But the agent still didn't reach level 4 — and the
flow-trace shows *why*, and it isn't combat:

- **hunt from the grind spot found nothing** (iter 2: "no mobs at all" at #91 — the
  clueless newbie had despawned/moved; only its corpse remained). The safe prey is
  **sparse and mobile**; there's no reliable standing target.
- **hunt wanders INTO danger.** Searching for prey (iter 6) it explored 10 rooms of the
  adjacent too-tough zone and Perry came out at **11/37 HP** — aggressive mobs chipped
  him *as hunt walked through*. hunt's blind frontier-following has no "this hurts, back
  out" reflex, and the newbie zone connects upward into Black-Knight/chessboard zones the
  MUD flags **"This zone is above your recommended level."**
- **Combat itself worked** where it got a shot: found a fido "Easy", but **the chase
  didn't fire** — *"panicked and fled before you could pin it"* (chased=0). Bug: the
  round-poll breaks the moment it sees *"panics"* (mob_fled), **before** the *"flees
  east"* direction line arrives, so there's no direction to chase. (Fidos are town
  scavengers anyway — wrong prey, and Main Street has Cityguards.)
- **Token cap again (122K)** — driven by navigation flailing (move ×10, look ×5) and a
  big final `travel_to` (the map is now large; one call cost 8K tokens).

**Diagnosis:** the combat-offload thesis is *proven* (Obs B iters 3–4 + the live fight
test); what's left is a **navigation / prey-availability** problem — the agent can't
reliably *find and hold* safe prey, and hunt actively drifts into over-level zones. Three
fixes, in leverage order: (1) hunt/explore **respect the MUD's "above your recommended
level" signal** — refuse to search there, back out; (2) hunt **stops if Perry takes
damage** mid-search; (3) fix the **chase-direction timing** (read the "flees <dir>" line
before parsing). A deeper fix: **remember safe grind spots** (tag rooms where consider-
safe prey was found) so the agent returns instead of re-exploring blind.

### Slice D — prey-finding safety + rest discipline (built, unit-tested) — 2026-07-28
Built the fixes Obs B2 demanded, all deterministic:
1. **`explore` backs out of over-level zones.** The MUD hides an over-level zone by
   replacing every room name with *"This zone is above your recommended level."* —
   `explore` now detects that, steps back the way it came, and marks the exit off-limits.
   So `hunt` can't wander Perry into Black-Knight territory.
2. **`hunt` stops if Perry takes damage while searching.** It tracks HP each room and
   halts if HP falls to ≤10 or ≤half of where it started (the 37→11 bleed) — "this area
   isn't safe to wander, rest somewhere safe."
3. **Chase-direction timing fixed.** When a mob's *"panics"* line breaks the poll before
   the *"flees <dir>"* line arrives, `fight` now reads a beat more to catch the
   direction before giving up the chase — so runners actually get chased.
4. **`rest_until` is now safety- and upkeep-aware** (the user's rest concern): it refuses
   to rest in an over-level zone or under attack (telling you to reach safety / teleport
   first), proactively eats/drinks so hunger/thirst don't block regen, and bails if a
   fight starts mid-rest. Resting now depends explicitly on **safe location + supplies**,
   not luck.

Unit-tested the pure pieces (over-level detect, HP parse, opposite-dir, damage-stop
threshold, chase-dir parse); registry loads at 40 tools. Live validation is the next
run (Obs B3).

**Condition-gated risk (user request, to widen the prey pool for testing):** added a
`:risky` consider tier for *"you would need some luck!"* (the band just above perfect
match; *"a lot of luck"* and worse stay `:unsafe`). `hunt` and `fight` now engage `:even`
and `:risky` prey **only when Perry is in top condition** — full-ish HP (≥90%), movement
in hand, and carrying food+water — so a "some luck" fight is winnable and wimpy still
guards the downside; when hurt/low, they're skipped as before. This makes the abundant
quasits/zombies grindable when healthy instead of leaving only the sparse "Fairly easy"
newbies. Tier + condition-parse unit-tested.

### Obs B3 — the combat loop is proven end-to-end; the wall is finding the grind spot — 2026-07-28
The fully-plugged run. Once on prey, the loop was textbook: **5 clean backstab kills**
(2 janitors, 3 fidos), each *"Killed — backstab landed (fair). +~60 xp. Looted. HP
37/37"* — full HP throughout, **no death, no over-level bleed**, and the **fidos (runners
that were uncatchable in Obs B2) now die** — the chase fix landed. When the agent
*manually* stepped into the chessboard it recognised it and **teleported out**.

**But the meta-problem repeats:** `move ×19` in the histogram were iterations **1–~19
spent wandering to FIND a grind spot** (Great Field → chessboard → teleport → city).
Only once it hit **Main Street janitors/fidos (#10, East Gate #108, all "Easy")** did the
clean hunt→fight loop begin — with ~15 iterations left, enough for 5 kills, not the ~16
level-4 needs. Token cap at iter 34. Every run **re-discovers the grind spot from
scratch**, and that search eats the budget the combat loop needs.

Secondary note: the over-level back-out protects `hunt`/`explore` but **not manual agent
`move`s** — the agent hand-walked into the chessboard (then self-recovered via
teleporter). Fine for now; a `move` guard could close it later.

**Diagnosis:** combat is *solved* — offload proven, chase works, safety perfect across
three runs (no death). The one remaining wall is **navigation efficiency**: remember
where safe prey was found so the agent `travel_to`s a known grind spot instead of
re-searching. That's the closing piece.

## Technical Conclusions

The combat arc's core bet — **combat is a decision-offloading problem** — is proven. The
LLM makes one decision per mob (`hunt` → `fight`); the tools run consider, wimpy, the
backstab opener, the kill, the chase, and the loot with zero model tokens (Obs B iters
3–4, Obs C, Obs B3's 5-kill streak). Skill-awareness stayed class-agnostic (skills read
from the game, a shared catalog for how to use them). Safety held across three full LLM
runs — the consider-gate + wimpy floor + flee-attribution + over-level back-out +
stop-on-damage kept a fragile Thief alive through fights, aggressive mobs, and even the
Black-Knight zone (teleporter recovery). The surprises were all **downstream of working
combat**: the limiter became *navigation* — first the `(d)` crash, then prey scarcity,
now grind-spot *rediscovery*. The acceptance test (level 4 + train) is one navigation
fix — **grind-spot memory** — from closing. New uncertainty parked for later: the
parse_room parens/fingerprint migration, and a `move`-level over-level guard.

### Slice E — grind-spot memory (built, unit-tested) — 2026-07-28
The closing piece from the Obs B3 diagnosis. The map remembered *terrain* but not its
*value*, and `hunt` preferred unexplored frontiers over known-good rooms — so it walked
away from proven prey into the chessboard. Fixed:
- **Tag** (`world.mark_prey`): when `hunt` confirms `:safe`/`:even`/`:risky` prey, the room
  is tagged as a grind spot (persisted in `world.json` beside the resource tags).
- **Prefer** (`world.nearest_prey_route` + hunt): at the start of every `hunt`, if a known
  grind spot is reachable and affordable, walk there *first* (deterministically) before
  any blind exploration. Already-there → empty route → no reposition.
- **Surface**: the "no safe prey" report now names the top known grind spots so the LLM
  can `travel_to` them too.

Unit-tested the tag/route/already-there cases; registry loads at 40 tools. This should
put the *whole* budget into the proven hunt→fight loop instead of re-discovering the
grind spot each run — the last thing between Obs B3's 5-kill streak and the level-4
acceptance test.

**Correction (user domain knowledge):** Obs B3's "grind spot" (Main Street janitors/fidos)
is actually a **bad** place to grind — `consider` rates the 1v1 "Easy" but **Peacekeepers/
Cityguards gang in and can kill you** once alignment slips from killing; `consider` can't
see bystander threats. Fixes: (1) `hunt` now **skips any room with a Peacekeeper/Cityguard**
(won't offer or tag prey there); (2) the real grind ladder is recorded in prompt + memory
([[mud-grind-locations]]): **newbie zone = levels 1–5** primary, **sewer** secondary (needs
teleporter + light), **town = never**; (3) seeded the grind-spot tags on the **newbie
zone** (#89 "A Bright Hallway", #91) instead of Main Street, so `hunt` anchors to the right
ladder.

## Key Takeaway

Make the tools own the whole fight — search, opener, kill, chase, loot, and safety — and
an LLM playing a fragile Thief will grind clean backstab kills for one decision each; what's
left to solve isn't the fighting, it's *remembering where the fighting is good*.

## Key Takeaway

_(pending)_
