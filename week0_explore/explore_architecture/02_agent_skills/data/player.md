# Player — character knowledge base

> Maintained by the `play-mud` skill. Refresh after any `score`, `inventory`,
> `equipment`, or `practice`. This is the agent's durable memory of the
> character — keep it current, don't rely on cross-turn recall.

## Goal
- **Previous goal:** Find the bakery and list its wares — ✅ done (danish 7g,
  bread 14g, waybread 70g; Perry has 0 gold so no purchase).
- **Current goal:** Practice a skill, then find and kill a safe mob (out of town,
  in the newbie area north of Midgaard).
- **Status:**
  - Practice: ⚠️ blocked — can only practice at the Thieves' guild ("You can
    only practice skills in your guild"), which hasn't been located yet.
  - Kill: ✅ killed a creepy crawler in the newbie zone (+33 XP, took no damage).

## Identity
- **Name:** Perry the Pilferer
- **Class/rank:** Thief — level 1
- **Age:** 17
- **Login:** `MUD_NAME=perry` (password via `MUD_PASSWORD`)

## Vitals (last `score`)
- **HP:** 23 / 23   ·   **Mana:** 100 / 100   ·   **Move:** 83 / 83
- **Armor class:** 80/10 (poor — no armor worn)
- **Alignment:** 15 (slightly good)
- **XP:** ~93 (58 + 35 from a 2nd creepy crawler)
- **Gold:** 10 (looted `get all corpse` from a creepy crawler)
- **Wimpy:** auto-flee below **8** HP (set via `toggle wimpy 8`).

## Skills / spells (last `practice`)
- **Practice sessions available:** 1
- **Skills known:** `sneak` (awful) — his only starting skill. Everything else
  (backstab, steal, hide, pick, etc.) must still be learned at a guildmaster.

## Equipment (last `equipment`)
- Nothing worn. **Fragile:** no armor, no weapon.

## Inventory (last `inventory`)
- Nothing carried. **No gold** — cannot buy anything yet.

## Location
- **Current room:** The General Store (north off Main Street, Midgaard).

## Provisioning gap (key finding)
Perry spawned with **nothing** — no light, food, water, weapon, or armor — and
this bites hard:
- **Hungry & thirsty** already, with no food/water and no gold to buy any.
- The deeper newbie zone (guard's glowing helm, grated well) is behind **pitch-
  black passages** that need a **light** Perry lacks.
- Cheapest light (torch) costs **15g**; one looted crawler gives ~10g, so he
  **can't afford even a torch** yet ("You can't afford it!").
- Thief route to the guard's key/helm (`steal`) is blocked: steal is
  **unpracticed** and the **Thieves' guild hasn't been found** in town.
- Net: a fresh thief must grind several lit-room crawlers just to buy a torch,
  then explore. Rough onboarding — argues for granting minimal starter gear
  (light + basic weapon) at character creation. See [[thief-tools]] plan.

## Progress log
- Found the bakery, listed wares (danish 7g / bread 14g / waybread 70g).
- Set `toggle wimpy 8` (note: syntax is `toggle wimpy [#hp]`, NOT `wimpy 8`).
- Tried to `practice sneak` in the Magic Shop → "You can only practice skills in
  your guild." Thieves' guild not yet located — practice still pending.
- Traveled to the newbie area: out the **back of the temple** (Temple → north
  through the altar → countryside) → Great Field → Newbie Zone entrance.
- `consider` newbie monster = "you would need some luck!" (risky, skipped);
  creepy crawler = "the perfect match!" (even) → chose the crawler.
- Killed the creepy crawler bare-handed, took no damage, +33 XP → 58 total.
