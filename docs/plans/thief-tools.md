# Spec — Perry's Thief Tool Surface (Challenge 0)

**Status:** draft · **Owner:** Perry agent · **Becomes:** Challenge 0 in `CHALLENGES.md`

## Goal

Give Perry — a level-1, 23-HP Thief — the tool surface his class and survival
actually require. The instructor's `Boukensha::Tools::Mud` registers 27 generic
tools but omits the Thief-defining and survival primitives, even though
`MudManager::Primitives` already implements and validates them. This challenge
builds a tool module that owns the full surface (base tools + 7 new ones) so the
agent can hide, steal, pick locks, auto-flee, rent, bank, and read a foe's health.

Success here is a **wiring** goal, not a gameplay one: the tools exist, validate
their arguments, and round-trip to the live MUD. Whether Perry *successfully*
steals or survives is later challenges.

## Why these 7 (evidence, not recall)

Derived from a diff of every method in `primitives.rb` against every primitive
the instructor's `mud.rb` actually calls, then filtered for Thief play. A live
`practice` as Perry confirmed he starts knowing **only `sneak (awful)`** with
**1 practice session** — the class is defined almost entirely by skills he must
acquire, and tools he currently lacks. `backstab` and `track` are already covered
by the instructor's `skill_strike` / `track` and are **not** rebuilt here.

| Tool | Primitive | Tier | Rationale |
|------|-----------|------|-----------|
| `stealth` | `stealth(mode)` | identity | hide before a backstab; sneak to pass mobs unseen — his only starting skill |
| `steal` | `steal(obj, victim)` | identity | the signature Thief skill |
| `door` | `door(verb, target, direction:)` | identity | `pick` a lock (Thief skill); open/close to navigate |
| `set_wimpy` | `set_wimpy(hp)` | survival | auto-flee below an HP threshold — best single lever at 23 HP |
| `rent` | `rent` | survival | persist character + location + gear at an inn |
| `bank` | `bank(op, amount:)` | survival | deposit gold so death doesn't drop it |
| `diagnose` | `diagnose(target)` | survival | read a foe's HP mid-fight: winning, or flee? |

## Architecture

Own the full surface; **never edit instructor files**.

- CircleMUD permits one connection per character, so Perry's tools must share the
  single `MudManager::Session` the base tools use. The instructor's session is
  private to `Tools::Mud.register`'s closure, so we do not reuse `Tools::Mud`.
- We disable the framework's MUD wiring with `Boukensha.repl(mud: false)`, create
  and own the session in a bootstrap, and register everything against the registry
  via the RunDSL block, which closes over our local `session`.

```ruby
# week1_baseline/ruby/adventurer/bin/perry
require "boukensha"
require "mud_manager"
require_relative "../lib/adventurer/tools"

session = MudManager::Session.new(host: "localhost", port: 4000)
session.open
session.login(ENV.fetch("MUD_NAME"), ENV.fetch("MUD_PASSWORD"))

Boukensha.repl(mud: false) do          # self = RunDSL; `session` via closure
  Adventurer::Tools.register(self, session)   # base surface (ported) + 7 new
end
```

The stock `boukensha` global executable / `boukensha_loader` cannot run this: its
`load_and_start_repl` calls `Boukensha.repl(**opts)` with **no block** and a
hardcoded `Tools::Mud`, so there is no hook to inject our module. `bin/perry` is
our own entry point (the analogue of the instructor's `examples/example.rb`),
calling `repl` directly with our block. Run it with `BOUKENSHA_DIR` pointing at
the repo's `.boukensha/` so `Config` finds `settings.yaml`, `.env` (keys + MUD
creds), and `prompts/system.md` (Perry's loaded doctrine):

```sh
BOUKENSHA_DIR=<repo>/.boukensha mise exec -- ruby week1_baseline/ruby/adventurer/bin/perry
```

We `require "boukensha"` (the installed 0.12.0 gem), so `BOUKENSHA_PATH` is not
needed. If a hand-implemented week1 step should be used instead, that becomes a
one-line `require` change.

Registration reuses the instructor's exact template — a shared `send_cmd` lambda
(`drain` → `send_command` → `read_until_prompt`), a `guard` lambda, and one
`registry.tool` call per tool with an `ArgumentError` rescue that returns
`"error: <msg>"`. Base-tool bodies are copied verbatim from `mud.rb`; their
descriptions are ours to tune later. The ported base surface includes
`mud_connect` / `mud_disconnect` / `mud_status`, now wired to *our* session — that
is our link-loss recovery; `bin/perry` performs the initial login.

## The 7 new tools

Parameters are the JSON-schema shapes the agent sees. Descriptions are the
behavior lever — written to steer a fragile Thief, not just name the command.

### `stealth`
- **params:** `mode` — `hide | sneak | visible`
- **desc:** "Hide or sneak to act and move unseen — core to a fragile Thief.
  Use `hide` before a backstab so the first blow lands from concealment; `sneak`
  to cross rooms without waking mobs; `visible` to drop concealment. Hiding can
  fail silently — do not assume it worked."
- **calls:** `p.stealth(mode)`

### `steal`
- **params:** `item` (name, or `coins`/`gold` for money), `victim`
- **desc:** "Steal an item or gold from a target with no fight — the Thief's
  signature skill. RISKY: on failure the victim notices and may attack, which at
  your HP is often fatal. Consider the mark first; prefer sleeping or weak
  targets. Use `coins` as the item to take money."
- **calls:** `p.steal(item, victim)`

### `door`
- **params:** `action` — `open | close | lock | unlock | pick`; `target`;
  `direction` (optional: north/east/south/west/up/down)
- **desc:** "Operate a door or container: open/close to pass, lock/unlock with a
  held key, or `pick` a lock (a Thief skill). Give `direction` when several exits
  have doors (e.g. the north door)."
- **calls:** `p.door(action, target, direction: direction)`

### `set_wimpy`
- **params:** `hp` (non-negative integer)
- **desc:** "Set an auto-flee threshold: when your hit points fall below this in
  combat, you flee automatically. Your most important survival setting — you have
  very few HP. Set it to roughly a third of your max before fighting; `0`
  disables it."
- **calls:** `p.set_wimpy(hp)`

### `rent`
- **params:** none
- **desc:** "Rent a room at an inn to log out safely: character, equipment, and
  location are saved and you resume here. Without renting, quitting sends you back
  to the temple altar and risks losing carried items. Works only at an inn
  receptionist."
- **calls:** `p.rent`

### `bank`
- **params:** `operation` — `balance | deposit | withdraw`; `amount` (optional integer)
- **desc:** "Use a bank: check balance, deposit, or withdraw. Deposit gold before
  adventuring — carried coins drop when you die, banked gold is safe. Works only
  at a banker."
- **calls:** `p.bank(operation, amount: amount)`

### `diagnose`
- **params:** `target` (optional)
- **desc:** "Assess how wounded someone is as a condition phrase, not exact HP.
  Diagnose your opponent mid-fight to judge whether you're winning or should flee;
  omit the target to diagnose yourself."
- **calls:** `p.diagnose(target)`

## Verification (observable pass/fail)

Tool-level acceptance = **wiring**, checked two ways. Game-state success (actually
renting, actually stealing) belongs to later challenges.

**1. Argument validation (offline, no MUD).** For each enum tool, an invalid value
returns a string beginning `error:` rather than raising. e.g.
`stealth(mode: "bogus")` → `"error: invalid mode: ..."`. `set_wimpy(hp: -1)` →
`"error: ..."`.

**2. Round-trip (live, as Perry at the temple).** Each tool invoked with valid
args returns the MUD's response text — not a Ruby exception, not the `guard`
string. Named observables:

| Tool call | Passing observable in the response |
|-----------|-----------------------------------|
| `set_wimpy(hp: 8)` | confirms a wimpy threshold (e.g. "wimpy" / "flee when … below 8") |
| `diagnose()` | a self condition phrase |
| `stealth(mode: "hide")` | a hide acknowledgement |
| `door(action: "open", target: <a visible door>)` | any open/"already open"/"no such" door reply |
| `rent` / `bank(operation: "balance")` / `steal(...)` | the MUD's "can't do that here / no one here" reply — still proves the command round-trips |

Evidence source per the project's verification model: grep the boukensha session
log (`.boukensha/sessions/<id>.jsonl`) for the `tool_result` line, or drive the
tools directly from a Ruby harness. Independent referee (admin `stat Perry`) is
available but unnecessary at wiring level.

## Out of scope

- Every other unregistered primitive (grouping, mail, aliases, titles, socials,
  house admin, split, transfer_liquid, write_note, order, insult, quit). Not
  needed for solo Thief leveling.
- Tier-3 polish (`toggle_pref` autoexit/brief, `enter`/`leave`) — add when a
  navigation challenge first needs them.
- Programmatic character creation (`Session#login` only logs in existing chars).
- Any gameplay outcome. This challenge ends when the tools are wired and validated.

## Resolved decisions

1. **Location.** One self-contained folder under week1, matching the instructor's
   `lib/` + `bin/` convention:
   ```
   week1_baseline/ruby/adventurer/
     lib/adventurer/tools.rb   # Adventurer::Tools — base surface + 7 Thief tools
     bin/perry                 # bootstrap: login Perry, repl with our block
     README.md                 # how to run
   ```
   Reusable tools (`lib/`) are separate from the character-specific entry
   (`bin/perry`); a second character is just another `bin/` script. Self-contained
   so realigning with the instructor later means moving one folder.
2. **Module name.** `Adventurer::Tools` — generic, not welded to Perry.
3. **Reconnect.** Handled by porting `mud_connect`/`mud_disconnect`/`mud_status`
   onto our session; `bin/perry` does the initial login.

## Note: ahead of the instructor

This challenge runs ahead of where the course material currently sits. Everything
is confined to `adventurer/` (code) + `docs/plans/thief-tools.md` (spec) so a
later realignment is a contained move, not scattered edits.
