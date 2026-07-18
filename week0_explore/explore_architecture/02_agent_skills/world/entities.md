# World — entities (mobs, NPCs, shops)

> Maintained by the `play-mud` skill. Record mobs (with danger read from
> `consider`/`diagnose`), NPCs, shopkeepers and their wares, and quest-givers.
> This is how you decide what to fight, buy, steal, or talk to.

## Shops
### The Grocer — The General Store (north off Main Street, east of Market Square)
- **Sells** (`list`): cashcard 1500 · box 75 · bag 30 · **lantern 75** · **torch 15**.
- Cheapest light is the **torch at 15 gold**. Perry (10g) **can't afford it** —
  "You can't afford it!" (and the grocer pukes on you). Needs ~2 mob kills of
  gold before he can buy even a basic light.

### The Baker — The Bakery (north off the Armory/Bakery junction)
- **Sells** (`list`):
  | # | Item | Cost (gold) |
  |---|------|-------------|
  | 1 | A danish pastry | 7 |
  | 2 | A bread | 14 |
  | 3 | A waybread | 70 |
- All "Unlimited" stock. `buy <item>` to purchase (Perry has 0 gold — can't yet).
- Waybread is the premium item (restores more; worth it once Perry has coin).

## Mobs — Newbie Zone (north of Midgaard; safe to fight, no peacekeepers)
### Creepy crawler ("a creepy little crawling thing")
- **Keyword:** `creepy` (not "crawling").
- **`consider`:** "The perfect match!" (nominally even) — but in practice a
  pushover for bare-handed Perry: killed it taking **no damage**, +33 XP.
- **Verdict:** safe, repeatable newbie kill.

### Newbie monster ("stands here looking confused. Kill him!")
- **Keyword:** `newbie`.
- **`consider`:** "You would need some luck!" (tougher than even) — **skipped**;
  too risky for an unarmed, unarmored level-1. Revisit once Perry has a weapon.

### Baby dragon (the Alchemist's missing pet — quest target)
- Wandered through the newbie corridor and left east. This is the dragon the
  **Newbie Guard** is looking for (see Quest-givers). Danger unknown — `consider`
  before engaging; likely a capture/return quest, not a kill.

## Mobs (seen in town, not fought — Perry is too fragile at 23 HP)
- **Oozing green gelatinous blob** — Market Square. Passive (sucking debris).
- **Beastly fido** — east Main Street. Harmless scavenger.
- **Cityguards / Peacekeepers** — patrol the squares/streets; keep order (do
  NOT provoke — they punish troublemakers, relevant for a Thief who might steal).
- **Janitor** — Temple Square, cleans up (picks up dropped items).

## NPCs / Guilds (locations noted, not entered)
- Clerics' Guild (Temple Square west), Guild of Swordsmen (east Main Street).
- Grunting Boar Inn (Temple Square east) — inns are where you `rent`.

## Quest-givers
### The Newbie Guard — "A Small Room" (S door off the Dirty Hallway, newbie zone)
- Tends the Alchemist's pet dragon and has **lost it**: *"Have you seen that
  dragon? Master will have my head if I don't find him."* → the wandering baby
  dragon is his; find/return it for a reward.
- **Wears "a bright newbie helm" — glowing aura = a LIGHT SOURCE + head armor.**
  Exactly what Perry needs: both deeper passages (N/E from the Nexus) are
  **pitch black** and impassable without a light.
- **Carries "a wee little key"** (seen via a thief peek on `look`) — likely opens
  the **grated well** (`down`) in his room, or a locked door.
- **Two routes to the helm/key:** (a) complete the dragon quest for a reward, or
  (b) `steal` it — Perry's signature move, but risky and *unpracticed* (only
  knows `sneak`); a failed steal on a guard likely starts a fight.
- **Learned:** he is NOT an `ask`/`tell` quest-giver — no scripted dialogue
  response ("You ask the Newbie Guard, 'dragon'" and nothing back). The quest is
  ambient flavor; progressing likely needs an *action* (the key → the grated
  well `down`, or bringing/handling the dragon), not conversation.
