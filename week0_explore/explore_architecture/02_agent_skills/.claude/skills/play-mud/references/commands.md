# MUD command reference

Every command below is a line you pass to `bin/mud`. They mirror
`MudManager::Primitives` (the validated command surface) — the *forms* here are
the ones the MUD accepts, so preferring them avoids wasted "Huh?!" turns. You
send them as plain strings: `bin/mud "backstab rat"`.

Enum-valued slots show the allowed values. Anything not listed here can still be
sent verbatim (raw passthrough) — the reference is a guide, not a fence.

## Movement & posture
- `north` / `east` / `south` / `west` / `up` / `down` — move.
- `enter <keyword>` / `leave` — use a special exit (portal, gate).
- `stand` / `sit` / `rest` / `sleep` / `wake` — posture (rest/sleep regen faster).
- `follow <name>` / `flee` / `track <name>`.

## Perception & info (read-only — cheap, use liberally)
- `look` — the room. `look <target>`, `look in <container>`, `look <dir>`.
- `examine <target>` — closer detail on an object/mob.
- `exits` — list exits. `score` — full character sheet. `inventory` — carried.
- `equipment` — worn/wielded. `gold` / `time` / `weather` / `where` / `wimpy`.
- `consider <mob>` — how dangerous a fight looks (do this BEFORE attacking).
- `diagnose <mob>` — read a target's remaining HP mid-fight.
- `who` / `help <topic>` / `commands` / `socials` — world/meta info.

## Combat
- `hit <target>` / `kill <target>` / `murder <target>` — start a fight.
- `backstab <target>` — Thief opener (must be hidden / unseen for the bonus).
- `bash` / `kick` / `rescue <ally>` / `assist <ally>` `<target>` — skill strikes.
- `flee` — escape (may fail; costs a round).

## Thief / stealth (this character's identity)
- `hide` / `sneak` / `visible` — concealment. Hiding can fail silently.
- `steal <item> <victim>` — signature skill; use `coins` for money. RISKY: on
  failure the victim notices and may attack — often fatal at low HP.
- `pick <door> [dir]` — pick a lock (`open`/`close`/`lock`/`unlock` also valid).

## Inventory & objects
- `get <obj>` / `get <obj> <container>` / `get all` .
- **`get all corpse`** — loot a fresh kill (then `get coins corpse` for gold).
  Do this the instant a mob dies; corpses decay and get scavenged fast.
- `drop <obj>` / `donate <obj>` / `junk <obj>`.
- `put <obj> <container>` / `give <obj> <target>`.
- `wear <obj>` / `wield <weapon>` / `hold <obj>` / `grab <obj>` / `remove <obj>`.
- `eat <food>` / `drink <container>` / `taste` / `sip`.

## Communication
- `say <text>` / `emote <text>` — local room.
- `tell <who> <text>` / `whisper <who> <text>` / `ask <who> <text>`.
- `shout` / `gossip` / `auction` `<text>` — channels.

## Character / survival / lifecycle
- `practice [skill]` — see or learn skills. `practice <skill>` only works while
  standing in **your own class's guild** ("You can only practice skills in your
  guild"); elsewhere it just lists what you know.
- `toggle wimpy <hp>` — auto-flee below this HP. **Set this before fighting**
  (~1/3 max). Note: the verb is `toggle wimpy`, NOT bare `wimpy` (that's "Huh?!").
  `toggle wimpy 0` turns it off; `toggle wimpy` shows current status.
- `title <text>` / `display <tokens>` / `color <off|sparse|normal|complete>`.
- `save` — persist the character. `quit` — leave the game (use `bin/mud /quit`).

## Shops / bank / mail (only in rooms with the right NPC)
- `list` / `buy <item>` / `sell <item>` / `value <item>` — shop.
- `balance` / `deposit <amt>` / `withdraw <amt>` — bank.
- `rent` — store character + gear at an inn (survival: gold/gear survive death).

## Daemon control tokens (not MUD commands)
- `bin/mud /status` — is the session still open?
- `bin/mud /poll` — grab async output (combat spam, someone entering) without
  sending a command.
- `bin/mud /ping` — daemon liveness.
- `bin/mud /quit` — quit the character and stop the daemon.
