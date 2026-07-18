# Observations of Different Agent Creation Frameworks

## 01_plain_agent: Just a Claude.md with instructions

### Details

Using the Haiku model and the basic CLAUDE.md as instructed, Haiku became immediately trapped in a loop of inability to log into ythe MUD. It had no tool to invoke and tried to use bash scripting but every line that came echoes back required more script commands
Worse, the Haiku model was incapable of reasoning through why this was never going to be an effective way to handle the goal, logging into the MUD and looking at the bakery menu. I asked Haiku to explain its problem to me, and it explained itself thusly:

```
You're absolutely right - I'm stuck in a loop trying variations without understanding the actual problem. Let me step back:

The core issue: The MUD's login prompt is interactive and more complex than a simple scripted pipeline can handle. Specifically:

1. When I send "dummy" as the character name, the MUD responds with "Did I get that right, Helloworld (Y/N)?" - which is odd. It's not confirming "dummy", it's saying "Helloworld"
2. This suggests either:
  - "dummy" isn't being received/parsed correctly
  - "Helloworld" might actually be the character name I should use
  - The login protocol is more complex than I'm handling

Better approach: Before blindly trying more connection attempts, I should:

1. Check the data files you mentioned in CLAUDE.md (data/player.md and data/world.md) - these might have the actual character state/info
2. Ask you for clarification: Are the credentials "dummy" (username) and "helloworld" (password), or is there a different login format I'm missing?
3. Consider if there's a character already created that I should be logging into, or if I need to create one first

Can you help clarify:
- Is there a data/player.md or data/world.md I should look at first?
- Are the credentials formatted as username/password, or something else?
- Is there an existing character I should be logging in as, or do I need to create one?
```

This indicates that Haiku at least understood it was ill equipped to handle an interactive prompt with its own native (lack of) tooling, nor did it know how to reason through creating a tool capable to doing this part of the process.
I stopped it on the 6th iteration and asked it to explain the problem it was having. The lack of understanding about hwo to interpret the feedback from the MUD was also clear. It's obvious that a simple CLAUDE.md with basic instructions is insufficient for the comoplexity of even an interactive login, without us adding explicit handling or creating a tool that the agent could reach for that is already built to handle the login process.

## 02_agent_skills: An agent with access to skills for some of the interaction

### Details

I started this thinking I'd need a skll to handle logging in cleanly after which an agent could use a different skill to actually play, forgetting the most important thing: 1 connection per character. There's no way for the agent to use a different skill, the mud-login skill would habve to carry the entire play loop as well, so that was a dead end. I restarted and fovcused on defininhg the goal itself, the LLM adapted the new skill to also handle logging in but added all the extra play loop. Interestingly it asked me whether we should use boukensha or just work from Claude code. Since I didnt write boukensha I didnt know what we could do. and because thiref skills are not implemented (as of this moment) I had actually copied boukensha to a new mud manager that I built that includes thief skills. After pointing this out to Claude it built the skill using that as the loop manager and ran tests.
But actually it seems the LLM chose to creatre a unix socket that allows multiple tool uses, including updating the player.md and world.md as it goes.

I'm still not sure we are where we need to be. Gonna run a live test with  new character and ask it to go to the bakery.

In summary:



Session summary — building MUD-playing skills for 02_agent_skills

Context. Continuing the agent-architecture exploration. 01_plain_agent showed a bare CLAUDE.md fails (Haiku got stuck on the interactive login). 02_agent_skills tests the next idea: give the agent skills to handle what it couldn't do alone.

First attempt — mud-login skill (dead end). Built a dependency-free Python MudClient that drives the full tbaMUD login handshake — telnet negotiation, ANSI, the MOTD press-return, the numbered menu, and the linkdead-reconnect path. Tested live: it logged in, entered the game, ran commands, handled wrong-password and unknown-character cases cleanly. Then I ran skill-creator's description-optimization loop on it: five very different descriptions all scored identically (perfect precision, ~0–33% recall). The lesson wasn't about wording — it's that Claude only reaches for a skill on tasks it thinks it can't do alone, and "log into a MUD" doesn't clear that bar. Recall is capped by model behavior; deterministic invocation (slash command / instructing the consuming agent) is the real lever.

The realization that killed it. CircleMUD permits one connection per character, and a telnet session can't survive across an agent's separate tool calls. So whatever logs in must stay connected and be the same thing that sends commands. A login-only skill can't hand its socket to anything else — it's useless in isolation. Removed it.

Second attempt — play-mud skill (the real deliverable). Reused the project's existing Ruby mud_manager gem (validated Primitives command surface + Session with login/IAC-stripping/prompt-reading) instead of duplicating it. Architecture:
- A background daemon owns the single connection: logs in once, listens on a Unix socket, stays alive across tool calls.
- A stateless bin/mud client sends one command per turn and prints the response.
- The agent plays the loop observe → record → consult → act, maintaining data/player.md (character) and world/ (rooms, map, entities) as durable memory toward a player-given goal.

Proven live. Ran the whole loop against the real MUD: persistent session across separate calls (move points ticking down proved it), a real combat encounter (a sewer rat attacked — killed it, +1152 XP, leveled 2→3), the async-lag /poll path flushing queued output, and clean /quit shutdown. Seed files were populated from that actual session.

Decisions. Claude Code plays via the skill (this directory's architecture), not boukensha — that's the separate week1 autonomous-Ruby-agent path, and its MUD agent (the perry/thief-tools plan) isn't wired up yet. Both skills are tagged claude-code-camp for easy removal.

Open thread. Haven't done a full goal-driven playthrough yet.




###What I built

The skill — .claude/skills/play-mud/
- bin/mud_daemon.rb — the single live connection. Built on the mud_manager gem: opens the socket, logs in once, then listens on a Unix socket and stays alive across your stateless tool calls. This is the one owner of the connection.
- bin/mud_client.rb (bin/mud) — sends one command per call, prints the ANSI-stripped response. What the agent calls each turn.
- bin/mud-daemon / bin/mud — bash wrappers that run the Ruby under mise exec -- (the only Ruby available).
- SKILL.md — the play loop (observe → record → consult → act), the one-connection rule, start/stop, gotchas.
- references/commands.md — the validated command vocabulary (mirrors MudManager::Primitives) so the agent doesn't waste turns on "Huh?!".

The living records (at 02_agent_skills/, per your spec)
- data/player.md — character sheet + goal + progress.
- world/rooms.md, world/map.md, world/entities.md — the world as discovered.

Proven live (not just written)

The whole loop ran against the real MUD this session: daemon login → turn-by-turn look/score/inventory/north on one persistent session (movement points ticked down across separate calls). A sewer rat attacked mid-session — combat worked, the character killed it, gained 1152 XP, and leveled 2→3, and the queued command output flushed via /poll (the async-lag path). Then /quit shut it down cleanly. The seed files are populated from that real state.

Key decisions we landed on

- Claude Code plays via the skill (the 02_agent_skills architecture), not boukensha (that's the separate week1 autonomous-agent path, and its MUD agent isn't wired up yet).
- One connection = one daemon. Login and commands are unavoidably the same live session, so play-mud owns login. That's why the old mud-login skill was a dead end — I removed it.
- Built on your existing mud_manager command surface rather than duplicating it.

Both skills carry the claude-code-camp label, so grep -rn claude-code-camp finds anything removable.



###After Test:

Live playthrough summary

Character loaded (Perry): level-1 Thief "Perry the Pilferer", 23 HP, knows only sneak (awful), 1 practice session, no gear, no gold. Started in the Temple of Midgaard. All recorded to data/player.md.

Navigation (self-directed, mapping as it went):
Temple of Midgaard → down → Temple Square → south → Market Square
  → west → Main St (Armory/Bakery junction) → north → The Bakery
The agent explored the east main street first (found general store, pet shop, weapon shop, swordsmen guild → town gate), recognized that was a dead end for the goal, backtracked west, and found the bakery north of the Armory junction.

Goal — bakery wares (list):

┌─────┬─────────────────┬─────────┐
│  #  │      Item       │  Cost   │
├─────┼─────────────────┼─────────┤
│ 1   │ A danish pastry │ 7 gold  │
├─────┼─────────────────┼─────────┤
│ 2   │ A bread         │ 14 gold │
├─────┼─────────────────┼─────────┤
│ 3   │ A waybread      │ 70 gold │
└─────┴─────────────────┴─────────┘

Files updated live: data/player.md (goal ✅ complete, full character sheet, progress log), world/rooms.md (7 rooms), world/map.md (verified route + unexplored leads), world/entities.md (the baker + wares, plus mobs/guilds seen).

Skill behaviors exercised: persistent session across ~20 separate tool calls, the one-turn async lag (handled with /poll), and avoiding fights (Perry's too fragile — noted the blob/fido/cityguards without engaging).

Perry is standing safely in the bakery, and the daemon is still running. Want me to keep it up for more play, or /quit cleanly (he'll leave the game)?


###Afterward

I examined how inefficient this all is and realized the agent was burning tokens at every possible level, reasoning through every round of combat and ingesting every description, etc. I leaned back toward the boukensha framework that was already built and just had claude add the tooling for a Thief, so the agent could focus on the decisions and not on interpreting everything.



### Where we Ended Up:

The journey

1. Skill-creator, not run-skill-generator. You swapped tools at the start — we were building reusable skills, not a one-off run harness.

2. mud-login skill — built, then deliberately killed. A dependency-free Python MudClient that drove the whole tbaMUD login dance (telnet negotiation, ANSI, MOTD, menu, linkdead reconnect). It worked live. We ran skill-creator's description-optimization loop and learned something real: triggering is model-capped, not wording-capped — five different descriptions scored identically, recall stuck at 0–33%, because the model only reaches for a skill on tasks it can't already do. Then the decisive realization: CircleMUD allows one connection per character, so a login-only skill that can't hand its socket to anything else is useless. Decision: delete it.

3. play-mud skill — the real deliverable.
- Decision: Claude Code plays via a skill (the 02_agent_skills architecture), not the boukensha autonomous agent — and build on the existing mud_manager gem rather than duplicating its validated command surface.
- Decision: a session daemon owns the single connection (logs in once, Unix socket), because a telnet session can't survive across stateless tool calls. A thin bin/mud client drives it turn-by-turn; data/player.md + world/ are the durable memory.
- Tested live end-to-end, and hardened from real play: drain-before-send (fixed async lag), toggle wimpy (the primitive's bare wimpy N returns "Huh!?!"), and loot-immediately (we watched a mob grab the corpse gold while I dawdled).

4. Live play as Perry — found the bakery, killed mobs in the newbie zone using consider, and surfaced a genuine finding: Perry spawns unprovisioned (no light/weapon/armor, can't even afford a torch), with gear gated behind a quest/steal in the newbie zone. Good demonstration that "thief starts with nothing" is a real onboarding gap, not a bug.

5. Permissions. Consolidated ~70 overfitted Bash(...) entries into a single Bash(*) in settings.local.json.

6. The strategy conversation (the pivot):
- Efficiency principle: offload execution (navigation, combat rounds, parsing) to code; keep decisions in the agent.
- Observability vs. efficiency isn't a real tradeoff — the trap was using the agent's context as the observation log. Separate channels: lean hot path, rich out-of-band trace, metrics not transcripts.
- Decision-schema design: decisions ≠ actions; capture options + evidence + prediction ↔ outcome.match — the prediction/outcome pair is what measures decision quality.
- Checked boukensha before building: its Logger already has the plumbing (tool calls, token usage, compaction, pub/sub) — only the decision-quality schema is missing.
- The unifying insight: the "boukensha lacks thief tools" gap and the "play-mud lacks observability" gap are the same raw-passthrough-vs-structured-tools tradeoff. Decision: move to boukensha — pay the (cheap, one-time) structure cost and get thief support and observability.

7. Boukensha work — what we shipped:
- 7 generic thief/survival tools added to the standard Tools::Mud (stealth, steal, door, set_wimpy, diagnose, rent, bank) — with the toggle wimpy fix. Live-tested. This obsoletes the adventurer/bin/perry workaround — stock boukensha plays a thief now.
- Combat distiller (mud_text.rb) — collapses round spam to outcome + vitals; unit-tested on real transcripts, confirmed live.
- Decision: keep the framework character-agnostic — you confirmed there's zero "Perry" in the code; identity lives in config (settings.yaml + prompts/system.md). Added an example .boukensha/ config + a generic play_mud.rb runner.
- Ran it with the real model — full loop worked, the agent used set_wimpy, gave a coherent in-character report, and produced a trace: ~15.8k input tokens / 5 tool calls / 3 model turns, with per-call token usage logged automatically.

Decisions ledger (the short version)

- Skill-creator over run-skill-generator.
- Login-only skill is a dead end under one-connection → deleted.
- play-mud = Claude Code + session daemon, built on mud_manager.
- Keep the original skill description (recall is model-capped).
- Broad Bash(*) permission.
- Offload execution to code, keep decisions in the agent.
- Observability goes out-of-band (trace + metrics), never in-context narration.
- Move the runtime to boukensha; structure buys thief tools and observability.
- boukensha stays generic; character lives in config.
- Haiku to validate the loop; bump to Sonnet for real play.

Where we stopped

Everything is built, tested, and committed to disk (memory updated too). Deferred to next week of the bootcamp: the decision frameworks — the decision event schema (options + prediction) on boukensha's Logger, plus a review pass for outcome.match. You're right that that's exactly the "decision frameworks" theme, and the trace plumbing is already in place to receive it.
