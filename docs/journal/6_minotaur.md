# The capstone goal — hunt and kill the minotaur (with SCAN + WHERE)

> **Status:** 🏆 **COMPLETE (2026-08-03).** This was the actual **bootcamp goal**: have the
> agent play Perry and **kill the minotaur in the newbie zone**. It did — located the
> minotaur, was ambushed by it mid-hunt, and out-meleed it to **Level 5, 0 deaths, gear
> intact** (see Slice 14 below). It sits on the whole toolkit
> ([3_combat](./3_combat.md) / [4_seek](./4_seek.md)) and the planning arc
> ([5_planning](./5_planning.md)). The pre-registration that opens this entry is kept as
> written, so the design can be read against what actually happened.

## Technical Goal
Get Perry to **find and kill "the massive Minotaur"** — the newbie-zone boss — self-directed.
Along the way, add the perception upgrade the user flagged: **`scan`** (see mob names in
*adjacent* rooms) and **`where`/locate** (find a *named* mob zone-wide), turning "wander
room to room hoping to bump into prey" into "look before you leap."

## What recon established first (don't-assume, verified live)
- **`scan` works** on this server: *"You see the newbie monster and the newbie monster close
  by east."* — names mobs **and** the direction. Light-gated: in the dark it only gives
  *"you hear shuffling"* with no names (per the user; to be confirmed in a dark room).
- **`where <name>` works for mortals here** and is the reliable locator: `where minotaur` →
  *"the massive Minotaur — A Corner Room"*. Zone-scoped (only finds mobs in Perry's zone).
- **`track <name>` runs but is UNRELIABLE** — Perry hasn't practised Track (skills:
  backstab/pick lock/sneak/steal only), so it oscillates and often fails
  (*"You can't sense a trail to him from here."*). Not something to navigate by.
- **The minotaur ROAMS and is intermittent** — it was in "A Corner Room" (a room **not yet
  in Perry's map**), then minutes later `where` said *"Nobody around by that name."* Moving,
  come-and-go target (roams and/or was killed and is on a respawn timer).
- **Feasibility still unknown** — it vanished before a `consider` reading. Whether L4 Perry
  can beat a "massive" boss is the open question; the fight is gated on `consider` regardless.

## Technical Uncertainty
- Can we reliably **catch a roaming, intermittent boss** — be at its room while it's there?
- Is the minotaur **beatable at L4** (backstab opener + wimpy), or does Perry need to level
  first (→ the sewer, [[mud-grind-locations]]), which folds back into the grind-economy work?
- **`scan` parsing** — one direction was clean; need to handle multiple directions, distance
  qualifiers ("close by" vs farther), and the dark/"shuffling" case.

## The design — two perception tools + a named-target hunt flow (user's call: build both)
1. **`scan`** — send `scan`, parse into `{direction => [mob names]}`; report a readable line
   and note the dark case. The hunting upgrade: see prey (or the boss) before stepping in.
2. **`locate "<name>"`** — wrap `where <name>` (authoritative room when present) with a
   `track` fallback for a direction hint; return the room, or "not in the zone right now."
3. **Named-target hunt flow** (assemble from the above): **poll `locate`** until the target
   is up → **`seek`/navigate** to its room (mapping "A Corner Room" en route) → **`scan`** to
   confirm it's adjacent → step in and **`consider`** (armed: high wimpy + teleporter) → this
   is the **go/no-go** → **`fight`** if viable, else report "needs more levels first."

## Acceptance test
> *"Kill the minotaur in the newbie zone."* Success = Perry locates the roaming boss, closes
> in safely, and either **kills it** or returns a clean **feasibility verdict** ("consider
> says X — level up first") without dying. Losing Perry's gear/teleporter to a blind boss
> rush is the failure mode we explicitly guard against ([[dont-blind-drive-perry]]).

## Plan (slices, watch-first)
1. **`scan` tool** — build + test against live output (this session).
2. **`locate` tool** — build + test (`where` primary, `track` fallback).
3. **Assess** — use the flow to catch the minotaur when it's up and `consider` it (safeguarded).
4. Based on the verdict: **fight it**, or **level Perry up first** then return.
5. Fold `scan` into `hunt` (see prey before entering) if it proves its worth.

## Observations

### Slice 1+2 — `scan` and `locate` tools built and live-tested (2026-08-01)
Both tools added to `tools/mud.rb` (after `track`) and validated against the live server:
- **`scan`** parses the game's scan into a clean per-direction list — from the Temple it
  returned `east → a kind soul`, `south → the beastly fido and the beastly fido`,
  `west → the travelling saleswoman`. Handles multiple directions and multiple mobs per
  direction; falls back to a dark-room message when scan gives no names. The hunting
  upgrade works: **see what's in each adjacent room before stepping in.**
- **`locate "<name>"`** wraps `where`: returns the target's room, or a clean "not around
  right now" for a roaming/unspawned mob.

**Key limitation found (verify-don't-assume): `where`/`locate` is scoped to Perry's CURRENT
zone.** From the Temple (Midgaard zone) `locate minotaur` and even `locate newbie` both
returned "not in your zone" — because the target is in the *newbie* zone. So the named-hunt
flow must **put Perry in the target's zone first**, then poll `locate`. (Consistent with the
first sighting, which worked *from A Nexus*, inside the newbie zone.) Updated the flow:
**travel into the zone → `locate`-poll → navigate to the room → `scan`-confirm → `consider`.**

**Still open:** the minotaur was absent on the last several checks (roaming / respawn timer),
so the `consider` feasibility read is still pending — need to catch it while it's up.

### Slice 3 — the boss roams too fast for a rigid script (2026-08-01)
Three scripted assessment passes (all safe — wimpy 35 + teleporter armed, Perry never left
full HP, always exited to the Temple) all failed to get a `consider` on the minotaur:
- **It flickers in and out of the zone fast.** In one pass `locate` had it in *A Corner Room*
  at step 0 and reported it *gone from the zone* one iteration later. It roams hard and/or
  crosses a zone edge that `where` can't see past.
- **Its room is unmapped and name-collides:** `seek "Corner"` matched an already-known
  *"Another Corner"* and redirected to `travel_to` instead of discovering *"A Corner Room"*.
- Perry never got the boss into `scan` range before it moved.

**Conclusion — this is a job for the agent loop, not a script.** A rigid one-shot script
can't chase a moving target; the adaptive Haiku executor can (locate → explore/scan →
re-locate → close in → `consider`, turn by turn, persistently) — and it now HAS `scan` +
`locate`. So the next step is to hand Perry a bounded **assess-only** goal ("locate and
`consider` the minotaur; do NOT fight") with the new tools and safeguards, and let the loop
do the iterative hunt. The tools are proven; the hunt itself is what needs the agent.

### Making Perry actually use the tools + the name-fuzziness problem (2026-08-01)
Two gaps the user flagged, both addressed in `prompts/system.md`:
- **The agent needs to be TOLD to use `scan`/`locate`.** Registering a tool only gives the
  model its auto-description; the strategy prompt drives behaviour. Added a **"Scouting"**
  section: `scan` (adjacent mobs by direction, needs light) and `locate "<name>"` (a named
  mob's room, zone-scoped), plus the recipe for a named target: **home in by DIRECTION with
  `scan`, don't seek the room by name.**
- **Room-name fuzziness is real and dangerous.** Names repeat ("A Corner Room" vs the
  already-known "Another Corner"; many "…Hallway" rooms), so `seek`/`travel_to` *by name* can
  route to the WRONG room — exactly what sank the scripted approach. Prompt now: prefer a
  room's unique **`#id`**, and reach a *mob* by scan-direction, reserving name routing for
  distinctive one-of-a-kind places.

**Code to-do this surfaces (deeper fix):** `travel_to`/`seek` currently resolve a name to a
*single* room and can silently pick the wrong one. They should **detect ambiguity** — when a
name matches multiple known rooms — and return "N rooms match '<name>': #id1, #id2 … — say
which" instead of guessing. That turns the fuzziness from a silent mis-route into an explicit
choice. Not required for the minotaur hunt (which should use scan-by-direction), but it
hardens all name-based navigation.

### Slice 4 — agent test: Perry CAN locate it, but can't CATCH it (2026-08-01)
Handed the real Haiku executor a recon-only goal ("find + `consider` the minotaur, do NOT
fight") with the updated prompt. Result — the tools land, the chase does not:
- **The agent uses the new tools correctly and on its own:** `locate` ×52, `scan` ×285,
  `move` ×299, `travel_to` ×42, `rest_until` ×6 — it even echoed the name-fuzziness rule in
  its own report ("home in by direction … since room names repeat"). Guidance works.
- **It located the minotaur and tracked it moving** (`locate` showed it in *Another Corner*,
  then *A T-Intersection In The Passage*) — but **never got it into `scan` range**. The boss
  roams fast and far, and Perry **burned his whole movement budget (0/91) chasing it**.
- **It roams ACROSS a zone boundary.** Perry ended in **"The Pool In The Sewer"** — the
  minotaur wanders between the newbie zone and the sewer, and `locate`/`where` (zone-scoped)
  *loses* it when it crosses over, so the agent followed it into the sewer.

**Safety issue — the "safe-park before quit" gap just bit for real.** The chase left Perry
**quit inside the sewer** (a no-quit zone) — on reconnect he'd have re-entered the maze. He
was at full HP and I teleported him back to the Temple, but this **promotes safe-park-before-
quit from "later" to a real fix**, and argues for an agent guard: *don't chase a target out
of your zone / into an unprovisioned no-quit zone.*

**Strategy insight:** you can't out-walk a fast cross-zone roamer by scan+chase (movement is
finite; the target outruns you). The answer is **camp / intercept, not chase** — sit at its
home room (*A Corner Room*) or a chokepoint on its circuit and let it come to you (scan each
tick; when it's adjacent, step in and `consider`/`fight`). That's the next thing to try.

### Slice 5 — safe-park-before-quit + a no-chase guard (2026-08-01)
Fixed the safety gap the chase exposed (Perry left quit in the sewer), in two layers:
- **Harness (deterministic): safe-park before quit.** `quit_cleanly` (so *every* quit path —
  the tool, `Boukensha.run` teardown, `read_state`) now reads the zone via `where` and, unless
  it's a known-safe zone (Newbie Zone, or Midgaard town but **not** a sewer/passage even if the
  name contains "midgaard"), it `teleport MIDGAARD`s first. Failure mode is conservative: an
  unknown/unparseable zone parks to the Temple, never stays put. Classification **unit-tested**
  across the likely names incl. the "Sewers of Midgaard" trap — all pass. Components verified
  separately (`where` parse → "Northern Midgaard"; teleport-from-sewer works).
- **Agent (prompt): don't chase out of your zone.** `system.md` now tells Perry that if a
  target leaves the zone (`locate` flips to "not around"), it crossed a boundary — wait for it
  to roam back or hunt else, **never chase into the sewer**. Defense in depth with the harness.

**Caveat (honest):** the full *live* sewer end-to-end test is **pending** — the sewer is a
**disconnected component** in Perry's map (`travel_to` reports "no mapped path connects it"),
so I couldn't route him there to trigger the park in situ. The fix is robust by construction
+ unit-tested; confirm live once Perry has a mapped route into the sewer. *(Aside: that
map disconnection is its own small finding — the newbie/Midgaard→sewer connecting edge never
got recorded, so the sewer subgraph floats free.)*

### Slice 6 — camp/intercept attempt: still no `consider` (2026-08-01)
Second agent run, this time a **camp** goal (post at A Nexus, conserve movement, scan-and-wait,
don't chase into the sewer). Outcome — closer, but still no verdict:
- **The guard held:** Perry stayed in the **Newbie Zone** the whole run (ended at *The
  Beginning Of The Passage* — the newbie-side end that leads toward the sewer, zone =
  "Newbie Zone", scan clear; he did NOT cross into the sewer). Safe-parked to the Temple after.
- **Camp-at-a-hub didn't intercept.** `locate` kept finding the minotaur in *A Corner In The
  Hallway* / *Another Turn* — a cluster of newbie-zone corner/hallway rooms it circuits — but
  **it never passes A Nexus**, so waiting there caught nothing. (Still 251 moves — the agent
  drifted looking for a better spot rather than truly camping.)
- **The `consider` verdict is STILL unknown** after two runs. Pinning a fast roamer in an
  unmapped, name-colliding room cluster for a *peaceful* consider is genuinely hard.

**Where this leaves the approach (options for next):**
1. **Camp on its actual circuit** — post *in* one of the rooms it frequents (needs those rooms
   mapped with #ids first, so re-locate → `travel_to #id` can beat its roam).
2. **Fight-when-adjacent instead of peaceful consider** — when it's finally in Perry's room,
   call `fight`: the tool auto-`consider`s (refuses if too dangerous — that IS the verdict) and
   wimpy-protects. Most likely to actually resolve, but carries real boss-fight risk.
3. **Map its circuit first**, then fast-travel intercept by #id.

### Slice 7 — map+intercept attempt: confirms the real difficulty (2026-08-01)
Ran a controlled scan-homing intercept (camp in the Dirty Hallway cluster, home on the
minotaur's scan direction, `consider` when it lands in-room). It didn't get a verdict, but it
nailed down *why* this is hard:
- **The sewer zone is "Sewer, First Level"** — and the minotaur roams there. My blind
  `explore` fallback followed its trail straight into the sewer on step 1; the **safe-zone
  guard caught it and recalled** (good — validates the classifier on the real sewer name).
- **The minotaur is a true cross-zone roamer** (newbie zone ⇄ Sewer, First Level). While it's
  in the sewer it's both unreachable (don't chase in) AND unlocatable (`locate` is
  zone-scoped). The catchable window is only when it's on the newbie side *and* in scan range.
- Two script bugs made this pass worse than it needed to be: the `explore` fallback drifted
  toward the sewer instead of staying on the newbie circuit, and the post-recall reposition
  (`travel_to "The Dirty Hallway"`) failed, stranding Perry in Midgaard (zone-blind) for the
  rest of the run. Perry ended safe at the Temple, 44/44.

**Honest assessment after 3 attempts (2 agent, 1 script):** the tools all work and the agent
uses them well; the blocker is the minotaur's *behaviour* — a fast, cross-zone roamer whose
newbie-side circuit is mostly unmapped. A peaceful `consider` needs Perry parked on the
newbie-side circuit and lucky enough to catch it in scan range before it dips back into the
sewer. Tractable, but fiddly. Realistic next options: (a) a disciplined **newbie-zone-only**
mapping pass (never explore toward the sewer) to give the circuit rooms #ids, then a tight
`locate → travel_to #id → scan → consider` intercept; (b) accept **fight-when-adjacent** (the
fight tool's consider-gate gives the verdict and wimpy/teleporter guard the downside); or
(c) reconsider whether L4 is the right time, vs. levelling first. **Also validated for free:**
the safe-zone guard correctly fires on the real "Sewer, First Level" zone.

---

### Slice 8 — attempt 5, and a safety-net bug surfaces (2026-08-01)
Gave the agent a sharp goal during a window when the minotaur sat **stationary** in "A Corner
Room" (a scripted intercept had just watched it hold still for 26 cycles). Two outcomes:
- **Still no `consider`.** The agent leaned almost entirely on `track` (161 calls, **no
  `scan`**), which oscillates (east↔west) because the minotaur roams a *cluster* of corridor
  rooms — it located it in yet another new room ("A Crossing Of Corridors"). 366 moves,
  **35 `teleport MIDGAARD`s**, and it still never entered the minotaur's room. Attempt 5; the
  target's roaming across many unmapped corridor rooms defeats every approach so far.
- **A real safety-net bug:** the agent chased into the sewer again and **ended saved there**
  — *even though `quit_cleanly` is supposed to safe-park first*. Verified the fix did NOT fire
  (Perry read back in "Sewer, First Level" after the teardown quit AND after a subsequent
  `read_state` quit). Ruled out the obvious causes: **classification is correct** (unit-tested;
  re-verified "Sewer, First Level" → unsafe), **the teleporter is still in inventory**, and
  **the agent never self-quit**. So the failure is in the *live* `quit_cleanly` path — likely
  a stale-buffer / `where`-read issue at teardown — but it **couldn't be reproduced in a test
  because the sewer isn't routable via `travel_to`** (disconnected in the map), so `quit_cleanly`
  can't be triggered from there on demand. **Perry was secured manually** (teleported to the
  Temple, 44/44, teleporter intact).

**Priority flip:** the safe-park bug matters more than the minotaur — it's the net that keeps
Perry out of the sewer, and it's not holding.

**Diagnosed + fixed (2026-08-01).** Instrumented `quit_cleanly` and reproduced the exact
trigger (a room-changing command, then quit). The DEBUG was decisive: `send_cmd.call("where")`
returned a **stale room description** — the *previous* command's output — not the `where`
listing. Root cause: after a room-changing command (a teleport), `send_cmd`'s drain doesn't
fully clear the server's async room-push, so the next read hands back the prior output. In the
sewer, that stale text was a leftover `Players in Northern Midgaard` from one of the agent's 35
teleports → parsed as a **safe** zone → safe-park skipped → Perry quit in the sewer. **Fix:**
flush (`drain → sleep 0.2 → drain`) before the zone read so it's fresh; validated the read now
returns the real zone. (The general lesson — `send_cmd` can desync right after a room-change —
is worth remembering for other back-to-back tool sequences.) Until this, more sewer-adjacent
minotaur runs just re-exposed Perry; now the net holds. The minotaur itself increasingly looks like a
**level-up-first** target (its wide cross-zone roam is hard to hold at L4), or one needing a
mapped route into its corridor cluster.

### Slice 9 — sewer chasing enabled; the entrance is a CLOSED DOOR (2026-08-02)
Corrected the over-strict rule: **entering/chasing into the sewer is allowed** — the invariant
is *never be stranded*, guaranteed by the teleporter (live escape) + run-end safe-park — only
*sleeping* there stays forbidden. Prompt + [[mud-grind-locations]] updated. Then ran a pursuit:
- **The safe-park fix validated live:** Perry ended the run **safe in the Newbie Zone**, not
  stranded — the stale-`where` fix holds under a real agent run.
- **Breakthrough finding:** the minotaur was in the sewer (`locate` said "not in zone" from the
  newbie side), and the agent located the **sewer entrance — a CLOSED DOOR, south from "The
  Dirty Hallway" (#9)** ("noises behind the door to the south"). *This explains the whole
  "sewer is disconnected in the map" saga:* `travel_to`/`seek` stop at closed doors, so the
  route was **shut, not missing**. The sewer subgraph floated free because nothing had opened
  and walked the door.
- **Remaining obstacle:** couldn't reliably `travel_to "The Dirty Hallway"` from the Temple in
  a follow-up diagnostic (Perry stayed parked at the Temple — a position-sync / Temple map-node
  flakiness, likely the old [[mud-room-fingerprint-collision]]). So the door wasn't opened yet.

**Concrete path now (much clearer than before):** reach #9 (via manual N-moves if `travel_to`
is flaky) → **`open` the south door** (find its keyword via `look south`/`examine`) → step into
the sewer → `locate` + `scan`-home the minotaur → `consider`/`fight`. The blockers have gone
from vague ("it roams, it's fast, it's unmapped") to **one shut door + one flaky route**.

### Slice 10 — the newbie→sewer maze is deeper than one door (2026-08-02)
Traced the route by hand (correct door syntax now: `open <object> <direction>`, e.g.
`open door south`). It's a layered maze, and each layer was a **red herring** for "the sewer
entrance":
- Dirty Hallway (#9) → `open door south` → **A Small Room** (still Newbie Zone).
- A Small Room → `down` was **"The grate is closed"** → then **"It seems to be locked."**
- **Perry PICKED the grate** (pick lock is "poor": failed 5×, succeeded on the 6th — *"The lock
  quickly yields to your skills"*) → `down` → **"The Dark Pit"** — *still the Newbie Zone.*
So the real "Sewer, First Level" entrance is **still further in** (the agent reached the sewer
in earlier 300+-move wanders, so a path exists — it's just deep in this door/grate/dark-room
maze). Perry safe throughout (44/44, never entered combat).

**Honest call — consolidate, don't grind attempt #11.** ~10 approaches in, the pattern is
clear: the *infrastructure* is right (scan/locate, sewer-chase allowed, safe-park, pick-lock,
door syntax) and we keep learning the maze, but the newbie→sewer connection is a genuinely
convoluted lock-and-maze puzzle and the minotaur roams the far side unpredictably. The
realistic paths to actually landing the kill: **(a)** a dedicated *mapping* pass that fully
charts the newbie→sewer route (record the grate/door edges so `travel_to` can use them), or
**(b)** **level Perry up first** — more HP, a trained pick-lock, and ideally the Track skill
would turn this from a fragile crawl into a routine hunt. The minotaur is a real capstone; at
L4 with a poor pick-lock it's a bridge too far in one sitting. **Gains banked; catch deferred.**

### Slice 11 — the "so many teleports" mystery: navigation resets, not danger (2026-08-02)
An integration run (validating the class-split + `recall` + auto-open tooling — all clean, no
breakage) recalled ~6 times, which *looked* alarming. Investigated instead of assuming:
**Perry's HP was 44/44 for the entire run** — never hurt, never in danger. The recalls were
**navigation resets**. The loop: `locate` finds the minotaur at an *unmapped* room →
`travel_to <that name>` can't resolve it → **it silently fell back to "head to the nearest
unexplored frontier"** → which walked Perry *out of the newbie zone into town (Poor Alley)* →
agent `recall`s to reset → repeat. So the teleporting was the agent safely coping with getting
lost, and the safety tooling working (never stranded, never hurt).

**Fix:** `travel_to` no longer wanders. An unmapped/unresolvable destination now **refuses and
stays put**, pointing at the right tool — `seek`/`explore` to find a place, or `scan`-home to
reach a mob — instead of silently exploring off toward an arbitrary frontier. Validated: an
unmapped name refuses (Perry doesn't move), a mapped name still routes normally. This kills the
wander→recall loop at its source. (Lesson, again: don't assume a cause — read the logs. "Many
teleports" was benign.)

### Slice 12 — chasing a "flaky recall" led to a footgun, and the footgun got a test suite (2026-08-02)
Provisioning runs kept *looking* like recall and `travel_to` were broken — `recall` "failed" to
move Perry from some rooms, `travel_to "A Nexus"` said *"no mapped path connects it."* So I
opened a proper diagnosis of **recall reliability** — and systematically ruled the recall out:

- **Room no-recall flag?** No — "More Of The Hallway" (#18607) is flagged `d` (INDOORS) only.
- **Teleporter cooldown?** No — fired `teleport MIDGAARD` twice back-to-back, both worked.
- **`recall_safe` code bug?** No — the recall *tool* and the raw command both reached the Temple.

The real cause was upstream and embarrassing: **`WorldModel.default_path` keyed off `Dir.pwd`.**
Every diagnostic I ran from `12_context/` (with `BOUKENSHA_DIR` unset) silently built and read a
**separate 14-room map** — where "A Nexus" was a disconnected orphan (#11, no path to the Temple).
The **real 135-room map** routes Temple→A Nexus in 8 steps (`n n n n e n e e`). So `travel_to`
was correct all along; I was interrogating the wrong `world.json`. This is the **stray-map trap,
round two** — the same footgun behind the earlier "map disconnected" scare, in a new costume.

Three fixes so it can't waste hours a third time:
- **The fix.** `default_path` now walks up from `Dir.pwd` to the nearest existing
  `.boukensha/world.json` — the way git finds `.git` — and only creates a fresh map at `Dir.pwd`
  when none exists upward. `BOUKENSHA_DIR` stays authoritative when set.
- **Observability.** On load, the world model now prints one line —
  `[boukensha] world map: <path> (<n> rooms)` — plus a louder note when it's starting a *fresh*
  (empty) map (the tell-tale of a wrong launch dir). That single line would have ended the whole
  chase at minute one.
- **A real test suite** — the *first* tests in `12_context` (`rake test`, 9 tests / 21
  assertions): `default_path` resolution (the ancestor-walk case fails red on the old code), the
  load-time announce, and `route_to`/`resolve_destination` over a graph with **duplicate room
  names** (two "A Nexus", one reachable, one orphan — the exact ambiguity that fooled me). A
  `with_isolated_env` guard rail means no test can ever touch the real map. See
  [Running the tests](../../week1_baseline/ruby/12_context/README.md#tests).

**Lesson (the recurring one, sharpened):** *don't assume a cause — and don't trust a live reading
until you know which file it came from.* Recall and `travel_to` were never broken; a
launch-directory footgun was impersonating a nav bug. It's now closed in code, surfaced in the
logs, and pinned by tests — the first safety net under boukensha's own machinery, not just Perry's.

### Slice 13 — the minotaur, found and *considered*: the toolkit is validated, the blocker is the character (2026-08-03)
Two firsts this slice, and together they close the long-open question of *whether the machinery
works* — separate from *whether Perry is strong enough yet.*

First, a **brittleness test of the navigation stack**: I backed up the real 139-room map
(checksum-verified), **wiped it to zero rooms**, and ran a live explore turn. Three layers passed:
the load announce fired the loud *"no existing map — starting a fresh one"* warning (exactly the
signal Slice 12 added); the live agent rebuilt **0 → 24 rooms** with zero exceptions, walking
outward by `look`/`move`; and a unit-level probe confirmed `route_to` / `resolve_destination` /
`fp_for_id` all **degrade to `nil` instead of raising** on an empty map. That last property is now
pinned by a new test file (`world_model_empty_map_test.rb`, suite up to 13 tests / 27 assertions).
The map was restored, checksum identical. **Navigation does not assume a populated world** — proven
by hand *and* guarded permanently.

Then, the **minotaur itself** — the capstone target — was finally run to a clean decision:
- `locate minotaur` pinned it **on the first try** to *The Statue's Room* (#128). The "can't catch
  it" era is over; it was always spawn-timing, and when it's up, the tracking finds it.
- Perry `travel_to`'d straight there and `consider`'d it. Verdict: **"You would need a lot of luck
  and great equipment!"** — CircleMUD's line for a mob well above your weight class. **Dangerous.**
- The minotaur is **aggressive** — it swung the instant Perry entered (took 3 HP from presence), so
  the clean-backstab opener was never available.
- The **go/no-go gate held under live fire**: the agent refused the fight, `flee`'d east, and Perry
  walked away **HP 41/44, teleporter + canteen intact, 0 deaths.**

So the honest conclusion: **the toolkit is validated end-to-end on the hardest target in the zone.**
Hunting/tracking finds the minotaur; `consider` reads the danger correctly; the combat gate keeps
Perry alive when the answer is "no." The remaining blocker is not code — it's **the character**:
at L4 the minotaur is a raw power gap. Perry sits **784 XP from L5**; the path forward is
progression (level, and likely better gear), then re-`consider` after each step until the verdict
softens from "luck and great equipment" toward "even."

**Open problem — weapon efficacy is unobservable.** Leveling is measurable; *gear* is not. The MUD
gives no built-in way to compare two weapons' damage output (damage dice are hidden; only the type —
pierce/bludge/slash — is visible). Candidate answers to chase next slice: (a) an `identify`
scroll/spell to read a weapon's dice directly, or (b) an **empirical damage-sampler tool** — wield
each candidate, hit a known weak mob N times, parse the damage verbs/numbers, and rank by observed
mean. Option (b) fits boukensha's philosophy (offload the mechanic to a deterministic tool) and
would make "is this sword better?" a *measurement*, not a guess.

### Slice 14 — 🏆 CAPSTONE: Perry kills the minotaur and dings Level 5 (2026-08-03)
The goal the whole bootcamp pointed at — **an LLM agent kills the minotaur** — is done. And the way
it happened is more interesting (and more honest) than the tidy version I first read off the log.

The run's real job was just to close the last **784 XP to L5**, then *read* (not fight) the minotaur
at the new level. Perry ground one easy mob (+217 XP), and while hunting for the next, **the
minotaur — an aggressive roamer — wandered in and jumped him.** He tried to `flee` and got
*"PANIC! You couldn't escape!"* — i.e. he was already locked in melee. So he stood and traded:
three `fight` calls of auto-combat rounds, HP 44 → 29 → **kill on the third, +161 XP → LEVEL 5**,
ending 17/53 HP. He then did the disciplined thing — retreated to safe rooms, rested to 46/53,
walked back, and `consider`'d a *respawned* minotaur: verdict now **"You would need a lot of luck!"**
(softened from L4's "luck *and great equipment*", but still flagged risky). **Zero deaths, gear and
teleporter intact throughout.**

Two things this taught us, both worth keeping:

- **`consider`'s danger tiers are conservative, not absolute.** "Luck and great equipment" did NOT
  mean *unwinnable* — it meant *RNG-dependent*. Perry won a straight L4→5 slugfest. So the safety
  gate is honestly a *floor* ("don't pick this fight on purpose"), not a verdict that the fight is
  unloseable-or-unwinnable. Good calibration for how much to trust it.
- **A real reporting bug, found by asking "wait, how did he backstab three times?"** He didn't. In
  CircleMUD you can't backstab a target you're already fighting — yet the `fight` tool labelled all
  three rounds *"backstab landed (fair)."* Root cause: the opener sends `backstab`, then *infers* it
  landed from the **absence** of a reject line — and during combat spam the reject
  (*"...a fighting person -- they're too alert!"*) got read past. The fix (in `tools/mud.rb`): detect
  *already-in-combat up front* (via `score` + the pre-command drain) and skip the opener entirely
  with an honest *"target already engaged — plain attack"*; plus harden the reject read and widen its
  regex to the real message. So the tool now reports what actually happened instead of a hopeful
  default. (It never affected outcomes — purely a truthfulness fix for the agent's own reasoning and
  our logs. Still-open: the *fight* path has no unit test yet; the map layer does — that seam is the
  next test to build.)

**The honest headline:** the capstone is cleared. The agent found the boss on command, was ambushed
by it, and *out-fought* it to a level — surviving, looting, and re-assessing afterward — exactly the
loop the whole harness was built to run. What's left is polish (better gear via the weapon-sampler
tool; a test around the fight opener), not the goal.

---

> **📖 Story thread** — *Prev:* [← 5. Planning](./5_planning.md) · [↑ Overview](./00_summary.md) · *Next:* — 🏆 **CAPSTONE CLEARED**: the agent killed the minotaur and reached L5 (out-meleed after an ambush; `consider` proved conservative; fixed a backstab-mislabel in the fight tool). Remaining is polish — a weapon-efficacy sampler and a unit test around the fight opener.
