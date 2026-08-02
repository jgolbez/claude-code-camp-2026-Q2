# Tools & reasoning — how the tools work, and how the agent decides which to use

> A companion to the [toolkit reference](./movement_combat_toolkit.md) and the
> [overview](./00_summary.md). The reference lists *what* the tools are; this doc explains
> *how each works* and — the interesting part — *how the agent reasons about which to use,
> and when*. It's the "decision frameworks" view of boukensha.

## The core idea: offload, and a division of labor

An LLM is too slow and token-hungry to drive a MUD one raw command at a time (the week-1
baseline circled and burned its budget doing exactly that). So boukensha splits every
in-game action into two layers:

- **The model decides *what* and *whether*** — the strategic choices that need judgment:
  *which* mob to fight, *whether* to keep grinding or move on, *where* to go next, whether the
  goal is done or blocked.
- **The tools do the *how*** — the mechanical execution (walking a route, running a fight
  round-by-round, healing) — **and they embed the tactical safety decisions** so the model
  can't get them wrong: is this fight survivable? is it safe to sleep here? is this prey worth
  my time?

That second half is the key insight. The tools aren't dumb effectors; each "smart" tool is a
little decision procedure that runs deterministically, for **zero model tokens**, and hands
the model back a single distilled line to reason over. The model reasons at the *altitude* of
goals because the tools handle the tactics beneath it.

| The **model** decides (judgment, per turn) | The **tool** decides (deterministic, embedded) |
|---|---|
| Which mob to hunt; whether to fight it | Whether the fight is survivable (consider-gate); when to auto-flee (wimpy) |
| Whether to keep grinding vs. move on | Which mob in a room is the best value; which prey is below the "not worth it" floor |
| Where to go; what to look for | The shortest route there; backing out of over-level zones; escaping death-traps |
| When to heal vs. push on | Whether a room is safe to sleep in; eating/drinking so regen isn't blocked |
| When the goal is achieved or blocked | Saving + parking the character safely on exit (never left link-dead in a dangerous zone) |

## The agent's turn loop

The system prompt (`prompts/system.md`) tells Perry to spend its reasoning on *choices, not
motion*. Each turn is:

1. **Read** the last tool result (one distilled line — outcome, vitals, a `[memory]` note).
2. **Decide** the single next action that advances the goal.
3. **Call** one tool.
4. Repeat.

There is deliberately *nothing to steer* below that: the agent never walks room-by-room, never
drives a fight round-by-round, never loots by hand. If it finds itself wanting to, that's a
signal it's using the wrong (too-low-level) tool.

## The tools, by job — what they do and the decisions they embed

Of the 44 registered tools, most are thin command wrappers (`get_item`, `say`, `door`,
`equip_item`, …). The ones below carry the real logic — they're where offload lives.

### Perception & scouting — *look before you leap*
- **`check` / `look`** — read your own state (`score`, inventory, exits) or the current room.
  The source of truth; the agent is told to **read, not assume** (level, HP, and skills change
  as it plays).
- **`scan`** — look into the **adjacent** rooms without moving and report mobs **by
  direction** ("south → the massive Minotaur"). *Embedded decision:* it's **light-gated** — in
  the dark it returns only vague "shuffling" with no names, so the agent knows it's blind and
  needs a light source. This is the reconnaissance that lets the agent see prey *before*
  stepping into a room.
- **`locate "<name>"`** — find a **named** mob's room anywhere in the current zone (via the
  game's `where`). *Embedded decision:* it's **zone-scoped** and reports "not around" for a
  roaming/unspawned mob — so the agent learns whether a target is even present, and where,
  instead of wandering.

### Movement — *let the tools walk for you*
- **`travel_to "<room>"` / `#id`** — BFS the shortest route over **already-mapped** rooms and
  walk the whole way in one call, stopping only for a real decision (combat, a closed door).
  *Embedded decision:* it plans the route; the agent just names the destination. (It prefers an
  `#id` because **room names repeat** — see the reasoning notes below.)
- **`explore`** — walk to the nearest **unmapped** exit and step into new territory, one
  frontier per call. The tool for "I don't know where it is yet."
- **`seek "<place>"`** — offloaded *discovery* of an unmapped place **by name** (a bounded
  search). It found the Thieves' guild in one 3-second call where hand-`explore` had failed for
  a whole run.
- **`move <dir>`** — a single deliberate step (a last resort). *Embedded decisions:* it **backs
  you out** of a zone above your level (lethal terrain for a fragile Thief) and **escapes
  death-traps** (marks the exit blocked, teleports to safety) automatically.

### Combat — *pick the mob; the tool runs the fight*
- **`hunt`** — walk room to room and stop when it finds prey you can **safely and profitably**
  fight. *Embedded decisions (this is the richest one):*
  - It `consider`s every mob and sorts them into a **value band** — from a *perfect-match*
    fight (best xp for the risk) down through *fairly-easy* and *easy*, to a **trivial FLOOR**
    it refuses to bother with (killing worthless mobs wastes real time). The floor
    **auto-scales with level** — what's worth killing at L1 is trivial at L4.
  - Risky *"some luck"* fights are **opt-in only when topped up** (full HP + movement +
    supplies).
  - It **satisfices across known grind spots** (takes a high-value mob immediately, otherwise
    remembers the best and keeps checking other spots) and **never wanders into the unknown**.
  - It **skips guarded rooms** (Peacekeepers/Cityguards gang up and kill you).
  - It reports *what it chose and what it passed up* — the decision is legible in the output.
- **`fight "<mob>"`** — kill one mob **start to finish** in a single call. *Embedded
  decisions:* re-`consider`s the target and **refuses if it's too dangerous** (unless
  `force:true`); sets a **wimpy auto-flee** floor (~⅓ max HP) so a fight that turns bad pulls
  you out before a lethal hit; leads with your best **trained opener** when it applies (a
  Thief's backstab: wields a dagger, strikes, swaps back); runs the auto-rounds to the kill;
  **chases** a fleeing quarry (bounded — wimpy still guards HP); **loots** the corpse; and
  returns **one line** (outcome + HP + xp). One `fight` call per mob — the agent never drives
  rounds.
- **`consider`** — the raw strength assessment the two tools above are built on; the agent uses
  it directly only to *assess* a target it isn't going to auto-hunt (e.g. sizing up a boss).

### Survival — *don't fight wounded, don't die idle*
- **`rest_until hp: / movement:`** — recover by sleeping (HP) or resting (movement). *Embedded
  decisions:* it **refuses to sleep into danger** (won't rest with a mob in the room, under
  attack, or in an over-level zone), **eats/drinks first** so hunger/thirst don't block regen,
  and **wakes if a fight starts**.
- **Upkeep reflex** — the harness auto-eats/drinks when it sees a hunger/thirst tick, so the
  agent never has to babysit food and water.
- **`teleport MIDGAARD` (the teleporter)** — the escape hatch: an instant, no-cost, reusable
  recall to the safe Temple. The agent is told to use it when stranded rather than starve in a
  maze.
- **Safe-park on exit** — when the agent (or the harness) leaves the game, `quit` **saves and
  extracts** the character so it's never left *link-dead* (a disconnected body aggressive mobs
  can beat to death). *Embedded decision:* if it's quitting from a **dangerous zone** (the
  sewer), it **recalls to the Temple first**, so the character never re-enters a maze.

### Class-specific craft (Thief) & generic economy
- **`steal` / `stealth`** — the Thief's signature, and the **only class-specific tools** in
  the set: take gold/items without a fight, move unseen. They're registered **only for a
  Thief** (see [Generic vs class-specific](#generic-vs-class-specific--a-character-agnostic-framework)
  below) — a caster never sees them. Risky and skill-gated (a failed steal makes the mark attack).
- **`practice`** *(generic)* — list your skills + remaining **practice sessions**, or train
  one at a guildmaster. *Embedded truth the agent must respect:* practice is bought with
  **sessions earned by leveling**, never gold — a common trap the prompt calls out.
- **`shop` / `bank` / `rent`** *(generic)* — buy/sell, stash gold so death doesn't drop it,
  persist the character at an inn.

## How the agent reasons — the decision flow

The system prompt encodes the *when*. In plain terms, the agent's decision tree per goal:

| If the agent wants to… | It uses… | …because |
|---|---|---|
| Go somewhere it has been | `travel_to` (prefer `#id`) | the route is already known; the tool walks it for free |
| Reach a place it hasn't mapped | `seek "<name>"` | offloaded discovery beats hand-walking frontiers |
| Explore/expand the map | `explore` | steps into the nearest unknown, one frontier at a time |
| See what's in nearby rooms | `scan` | reveals mobs by direction *before* committing to a room |
| Find a specific named mob | `locate` → then home in with `scan` by **direction** | `locate` says if/where it is; scanning by direction avoids the room-name trap |
| Gain XP / level up | `hunt` → `fight` | hunt picks the best safe prey; fight kills it to completion |
| Recover after a rough fight | `rest_until hp:` in a safe room | never fight wounded — you'll just get wimpy-fled again |
| Decide *where* to grind | the **zone index** (newbie L1–5 → sewer next → town banned) | hunting in the wrong place is how most runs fail |
| Train a skill | `practice` at the guild | needs a session (from leveling), not gold |

Three reasoning rules that repeatedly matter — each learned the hard way (see
[6_minotaur](./6_minotaur.md)):

- **Read state; don't assume it.** Level, HP, and skills change — `check score` / `practice`
  are the source of truth. (The prompt was even rewritten off stale "level-1" stats to teach
  this.)
- **Room names repeat — a name is not a unique address.** "A Corner Room" vs. "Another
  Corner"; several "…Hallway" rooms. To reach a *room*, prefer its unique `#id`; to reach a
  *mob*, home in with `scan` by direction — don't `seek` an ambiguous name.
- **Don't chase a target out of your zone.** A fast roamer that crosses into the sewer will
  strand you; wait for it to come back or hunt elsewhere, never follow it into danger.

## Worked decisions

**Grind to a level.** `hunt` (which considers, prioritizes, and routes to the best safe prey)
→ `fight` (which considers again, arms wimpy, backstabs, kills, loots) → read the one-line
result → if hurt, `rest_until hp:` in the safe spot → `hunt` again. The agent's only decisions
are *keep going?* and *is this spot still worth it?* — everything tactical is inside the tools.

**Reach the guild and train.** `seek "Thieves guild"` (discover it) or `travel_to` (if mapped)
→ `practice` to see sessions → `practice backstab`. The agent reasons about the *prerequisite*
(do I have a session? if not, I'm blocked — report it), not the walking.

**Hunt a named boss (the live capstone).** `locate minotaur` (is it in the zone? which room?)
→ if present, `scan` and step toward the direction it's in → repeat until it's in your room →
`consider` it (assess), then `fight` or back off. If `locate` flips to "not around," the boss
crossed into the sewer — **wait, don't chase.** This is the decision flow the tools were built
to support; the open challenge isn't any single tool but *holding* a fast cross-zone roamer
long enough to engage.

## Where the decisions live (so they're shaped *and* enforced)

Guidance is encoded in **two** places, on purpose:

1. **The system prompt** shapes the *strategic* choice — it tells the agent which tool fits
   which intent, where to grind, when to stop. This steers the model's judgment.
2. **The tool descriptions and internals** enforce the *tactical* choice — the consider-gate,
   the wimpy floor, the prey floor, the rest-safety check, the over-level backout, the
   safe-park. These catch mistakes the model would otherwise make.

The result is an agent that can be *told* the right strategy and *prevented* from the fatal
tactical error — which is what lets a ~44-HP Thief play autonomously across many runs without
dying.

## Generic vs class-specific — a character-agnostic framework

boukensha is a **generic MUD harness**, not a "Perry" program. Identity *and* class live in
**config** (`mud.username`, `mud.class`), never in the tool code — so the same harness can play
a Thief, a Mage, or a Cleric. That discipline is visible in how the tools are organised:

- **The generic tools are class-agnostic** — `move`, `travel_to`, `explore`, `hunt`, `fight`,
  `consider`, `rest_until`, `scan`, `locate`, `recall`, `door`, the economy tools. None of them
  assume what class the character is. A locked door is the tell: the tool does **not** say
  "pick it" (that assumes a Thief); it reports the door is *locked* and points at the `door`
  tool's generic `unlock`/`pick` actions, and the **agent** decides how, per its class. (An
  early leak where `move` hard-coded "you're a Thief" was fixed to exactly this.)
- **Even combat is class-agnostic.** `fight` opens with the character's **best *trained*
  opener**, read from the game through a shared skill catalog — a Thief leads with backstab, a
  Warrior with bash. The same code plays either; nothing is hard-wired to backstab.
- **Class-specific abilities are separated and gated by config.** A Thief's signature tools —
  `steal`, `stealth` — are registered **only for the Thief class**, by a class-tool registration
  keyed on `mud.class`. A Mage never sees them (it leans on the already-generic `cast_spell`).
  Adding a class is a config value plus one small class-tool branch — **the generic tools don't
  change.**

**The line we hold:** never bake a class behaviour into a generic tool. Generic tools describe
*what the game offers*; the character's class (in config) and the agent's persona (in the system
prompt) decide *which of those a given character reaches for*. Point the harness at a different
config and the whole generic toolkit works unchanged, with only that class's signature tools
swapped in.

---

> **📖 Reference doc** — a decision-focused companion to the story, not a chapter itself.
> See also the [toolkit reference](./movement_combat_toolkit.md) · [↑ Overview](./00_summary.md)
