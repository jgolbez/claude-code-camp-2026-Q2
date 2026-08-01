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
