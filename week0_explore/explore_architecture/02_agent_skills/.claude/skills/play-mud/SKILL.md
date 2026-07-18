---
name: play-mud
metadata:
  label: claude-code-camp
  note: "Experimental skill from claude-code-camp — safe to delete .claude/skills/play-mud/."
description: >-
  Play the tbaMUD / CircleMUD game turn-by-turn to accomplish a goal the player
  gives you — explore, fight, shop, steal, quest — while maintaining a living
  knowledge base of the character (data/player.md) and the world (world/) as you
  discover it. Use this whenever the task is to actually PLAY, run, drive, or
  "pursue a goal in" the MUD (not merely log in): e.g. "get Perry to the bakery",
  "explore north and map it", "level up", "buy a weapon", "find and kill X". It
  owns the single live connection (login + commands) via a session daemon built
  on the mud_manager gem, so you can act, observe, and update your notes between
  turns. Prefer this over hand-driving nc/telnet or the old login-only skill.
---

# Play MUD

You are a Player Journey Agent. The player gives you a **goal**; you accomplish
it by playing tbaMUD (a CircleMUD descendant on `localhost:4000`) one command at
a time, and you keep two living records as you go:

- **`data/player.md`** — everything you learn about your character.
- **`world/`** — everything you learn about the world (rooms, map, entities).

## The one rule that shapes everything

**CircleMUD permits a single connection per character, and a telnet session
can't survive across your separate tool calls.** So a background **daemon** owns
the one connection: it logs in once and stays connected. You talk to it with the
stateless `bin/mud` client — one command per call. **Never open a second
connection** (no `nc`, no telnet, no other login) while the daemon runs, or the
MUD will kick one of them.

Paths below are relative to `02_agent_skills/` (run everything from there).

## 1. Start the daemon (once per session)

Launch it in the **background** (use your background-task tool; it must outlive
individual calls). Credentials default to `dummy`/`helloworld`; override with
env vars.

```bash
MUD_NAME=dummy MUD_PASSWORD=helloworld \
  .claude/skills/play-mud/bin/mud-daemon > /tmp/play-mud.log 2>&1 &
```

Wait for it to be ready (socket appears + "logged in" in the log):

```bash
until [ -S /tmp/play-mud.sock ] || grep -q FATAL /tmp/play-mud.log; do sleep 1; done
grep -q FATAL /tmp/play-mud.log && cat /tmp/play-mud.log   # login failed
```

Ruby is only available via mise — the wrappers already call `mise exec --`.

## 2. Play, one turn at a time

**`look` first.** Your starting room is wherever you last `quit`/`save`d, not
always the Temple — CircleMUD persists your location. Orient before you navigate;
don't blind-replay an old route.

Then: send a command, read the response, think, update your notes, send the next:

```bash
.claude/skills/play-mud/bin/mud look
.claude/skills/play-mud/bin/mud score
.claude/skills/play-mud/bin/mud north
.claude/skills/play-mud/bin/mud "consider rat"
.claude/skills/play-mud/bin/mud "backstab rat"
```

Output is ANSI-stripped. The trailing `NNH NNNM NNV ... >` is the prompt (your
current Hit / Mana / Move points — watch HP in combat). The daemon drains stale
buffer before each command, so what you get back is *this* command's result —
you do **not** need to `/poll` after a normal move. If events happened between
your turns (a mob wandered in, a `tell`), they arrive prepended under
`[async events since your last command]`, above the actual response.

**Command vocabulary:** read `references/commands.md` for the validated command
surface (movement, combat, stealth/steal, shops, survival). It mirrors
`MudManager::Primitives`, so those forms won't waste a turn on "Huh?!". Anything
not listed can still be sent verbatim.

**Control tokens** (not MUD commands): `bin/mud /status`, `bin/mud /poll` (grab
async combat/room output without acting), `bin/mud /ping`.

## 3. The play loop

Each turn:
1. **Observe** — read the MUD's response to your last command.
2. **Record** — if you learned something durable, update `data/player.md` or a
   `world/` file *now* (don't rely on memory across turns).
3. **Consult** — before navigating or fighting, check `world/` (do I know the
   way? is this mob dangerous?) and `data/player.md` (my HP, my skills).
4. **Act** — send the next command that advances the goal.

Bias toward cheap read-only commands (`look`, `exits`, `consider`, `score`)
before committing to risky ones. At low HP, set `toggle wimpy <hp>` and prefer
fleeing to dying — death drops gold and gear.

**Loot every kill immediately.** The instant a mob dies, `get all corpse`
(and `get coins corpse` if gold didn't come with it) *before* anything else —
before checking score, before updating notes. Corpses **decay within a few
turns**, and other mobs or a janitor will loot the gold out of them first. Most
mobs carry a little gold; that is how a broke character funds gear. Dawdling =
watching "the newbie monster gets a tiny pile of gold coins" instead of you.

## 4. The living records

Seed templates exist; keep them current — they are your memory.

**`data/player.md`** — identity (name, class, race, level, age), vitals
(HP/mana/move, AC, alignment), XP & gold, **skills known** (from `practice`),
inventory, equipment, current room, the **goal**, and progress notes. Refresh
after any `score` / `inventory` / `equipment` / `practice`.

**`world/`** — the map as you discover it:
- `world/rooms.md` — one entry per visited room: name, gist, exits, contents
  (items, mobs, NPCs, shops).
- `world/map.md` — connectivity, e.g. `Dark Passageway --north--> Sewer`, so you
  can navigate and backtrack.
- `world/entities.md` — mobs (danger from `consider`), NPCs, shopkeepers + wares,
  quest-givers.

Create more `world/` files if the goal needs them (e.g. `world/quests.md`).

## 5. Stop cleanly

```bash
.claude/skills/play-mud/bin/mud /quit   # quits the character AND stops the daemon
```

If you only pause, leave the daemon running — the character stays in-world.

## Gotchas

- **Never double-connect.** One character, one connection. The daemon is it.
- **Persistence is the daemon's job.** If you `cd` elsewhere or a new shell
  starts, the daemon and socket (`/tmp/play-mud.sock`) are still there — just
  keep calling `bin/mud`. Check with `bin/mud /status`.
- **You resume where you quit.** `quit`/`save` persist your location, gear, and
  XP. On a fresh daemon you are wherever you last were — `look` before moving.
- **Async events surface automatically.** Between-turn events (a mob arriving, a
  `tell`, or the first combat round) are drained and prepended under
  `[async events since your last command]`. You normally don't need `/poll` —
  reserve it for *streaming* combat, where auto-attack rounds keep arriving and
  you want to watch HP without sending a command.
- **Combat interleaves.** While fighting, every command's response is preceded
  by the rounds that landed since your last turn. Read the HP in the prompt
  each time; if it's dropping toward your `wimpy` threshold, `flee`.
- **Update notes as you go, not at the end.** Your reasoning resets between
  turns; the files are the only durable memory. A room you didn't record is a
  room you'll re-explore.
- **Login timing.** The daemon takes a few seconds to clear the client-detection
  delay and MOTD before it's ready — always wait for the socket.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `play-mud: no daemon at /tmp/play-mud.sock` | Daemon not started/ready. Start it (step 1) and wait for the socket. |
| `FATAL login failed` in the log | Bad creds or MUD down. Check `MUD_NAME`/`MUD_PASSWORD`; `nc -z localhost 4000`. |
| `ERROR: ... socket closed` from a command | The MUD dropped the link (idle timeout / duplicate-login kick). Stop the daemon and restart it. |
| Response seems to be missing / cut off mid-combat | Auto-attack rounds are still streaming. Send `bin/mud /poll` to collect them, then continue. |
