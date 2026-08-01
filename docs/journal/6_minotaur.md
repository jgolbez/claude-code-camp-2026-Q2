# The capstone goal — hunt and kill the minotaur (with SCAN + WHERE)

> **Status:** pre-registration → build in progress (2026-08-01). This is the actual
> **bootcamp goal**: have the agent play Perry and **kill the minotaur in the newbie
> zone**. It sits on the whole toolkit ([3_combat](./3_combat.md) / [4_seek](./4_seek.md))
> and the planning arc ([5_planning](./5_planning.md)).

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

---

> **📖 Story thread** — *Prev:* [← 5. Planning](./5_planning.md) · [↑ Overview](./00_summary.md) · *Next:* — **the live edge of the story** (the capstone is in progress)
