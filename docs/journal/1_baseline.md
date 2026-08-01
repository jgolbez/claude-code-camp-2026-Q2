# Week 1: Baseline

## Technical Goal
Build an application (boukensha) capable of bounding an agentic loop and
delivering results back to a user — a harness that wraps an LLM, lets it call
tools, and turns that into a useful answer, using the live MUD as the concrete
test case (playing as my character, Perry). I understood the *goal* clearly, but
needed help understanding the *architecture* — how the pieces (config, tools,
the loop, the REPL) actually fit together.

I am on the Ruby track with the tools built directly into boukensha
(`12_context/lib/boukensha/tools/mud.rb`) rather than the MCP route, and I am
not porting to Python — the course notes allow treating Ruby as the main
implementation.

## Technical Uncertainty
- I was uncertain how the architecture actually connects together — how config,
  tools, the agentic loop, and the REPL fit into one working application, since I
  did not write it myself.
- I was uncertain what result to even expect from using the boukensha harness to
  drive the agentic loop — what "delivering results to a user" would look like in
  practice.
- I was uncertain whether there was value in porting boukensha to Python, a
  language I understand better than Ruby, versus keeping it in Ruby as-is.
- (Related, and tested below:) whether a cheap/fast model (Haiku) with only the
  baseline's tools could accomplish an open-ended goal like navigating to a named
  location, and whether I could even tell what the agent was doing under the hood.

## Technical Hypotheses
My hypothesis was that even with a working agentic loop, the agent would fail to
adequately understand and execute on commands — because the boukensha harness
does not solve the largest problems facing an agent trying to navigate and
advance inside the MUD. It gives the agent a loop and tools, but not a world
model, a map, or memory across turns, which are the actual hard parts of playing
the game. So I expected the loop to run but the *gameplay* to fall short.

## Technical Observations
- Setup was already in place: MUD up on `localhost:4000`, Ruby 3.4.10, API key in
  `.boukensha/.env`. Launched with
  `mise exec -- ruby week1_baseline/ruby/12_context/examples/play_mud.rb`. The
  character comes entirely from config (`settings.yaml` + `prompts/system.md`),
  not from code — pointing at a different config dir plays a different character.

- **Read-only turn worked, and it was genuinely agentic.** Goal: "look around and
  describe the room." Off one instruction it chose *two* tools on its own —
  `look` and `check where`. The session log shows raw MUD output going in and a
  clean summary coming out:

  ```
  TOOL CALL ▶  look          → "[0;33mThe Bakery[0m ... [ Exits: s ] The baker looks..."
  TOOL CALL ▶  check (where)  → "Players in Northern Midgaard. --------------------"
  ```

  The tidy "you're in the Bakery, the baker is an NPC, only exit is south" answer
  was the LLM reading that ANSI-coded mess and cleaning it up. Raw game text in,
  reasoned answer out — that gap is the whole point of the harness.

- **Open-ended navigation failed.** Goal: "go find the thieves guild and train a
  skill." The move sequence in the log was `west, west, south, south, east, east,
  south, north` — visibly going in circles. It never found the guild and ended on
  `limit_reached` → `turn_end`: it hit the 40 tool-call safety cap
  (`agent.max_iterations: 40`) and gave up.

- **Plain mode is silent mid-turn.** In `tui: false` mode the harness does not
  print tool calls as they happen, so a long turn looks frozen but isn't. The
  reliable "working vs. hung" tell is watching the live session file grow
  (`.boukensha/sessions/<ts>.jsonl`); its last event is `turn_end` once the agent
  is actually done and waiting at the prompt.

- **Adding higher-level knowledge did not fix the low-level problems.** I had
  previously added thief-skill knowledge directly into my harness
  (`tools/mud.rb`), but it did not make a sufficient difference. The most basic
  problems — navigating the world and remembering where it has been — are still
  unsolved, and layering domain knowledge on top of an agent that can't reliably
  get around does not help. The foundation has to come first.

## Technical Conclusions
- On the Python question: I decided against porting. Even though I understand
  Python better, going that route forces boukensha to reach the Ruby MudManager
  through MCP, and that extra layer is more complexity than just keeping the whole
  stack in one language. Staying in Ruby was the simpler, lower-risk path.
- My hypothesis largely held, with one refinement. As predicted, the loop ran
  fine but the *gameplay* fell short exactly where I expected — open-ended
  navigation and advancement — because the harness gives no world model, map, or
  cross-turn memory. The refinement: it was *better* than a blanket "it will
  fail." It executed explicit, single commands ("look", "go south") reliably and
  even chained a couple of sensible tool calls on its own. So the failure is
  specifically at self-directed navigation, not at understanding commands. This
  confirms the Preweek conclusion that the use-case needs specialized memory and
  map navigation — precisely the Week 2 problem: perception, a world model / map,
  and memory across turns so it stops re-walking the same rooms.
- New consideration set aside for later: the 40-iteration cap combined with the
  silent plain REPL makes for a slow feedback loop while experimenting. Lowering
  `max_iterations` or tailing the log mitigates it, but a live view of tool calls
  (the TUI, or the log_viz web viewer) would be a real quality-of-life gain.
- Next step / biggest realization: solving the basic problems will require a much
  greater level of understanding of what the agentic loop is actually doing when I
  issue a direction — which tools it picks, what it sees back, and why it makes
  the moves it makes. Better observability into the loop is a prerequisite to
  fixing navigation and memory, not a side quest. This is where my Week 2 focus
  needs to start.

## Key Takeaway
Domain knowledge like thief skills is worthless until the agent can reliably
navigate and remember — and I can't build that foundation without real
visibility into what the loop actually does when I issue a direction.

---

> **📖 Story thread** — *Prev:* [← 0. Surveying frameworks](./0_preweek.md) · [↑ Overview](./00_summary.md) · *Next:* [2. Navigation →](./2_capable.md)
