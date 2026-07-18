# World — rooms

> Maintained by the `play-mud` skill. One entry per room you have visited:
> name, a gist of the description, its exits, and anything notable in it
> (items, mobs, NPCs, shops). A room you don't record is a room you'll
> re-explore. See `world/map.md` for how rooms connect.

## The Temple Of Midgaard (start)
- **Desc:** Southern end of the temple hall — marble blocks, ancient paintings.
  Steps lead down through the temple gate to the temple square.
- **Exits:** n, e (donation room), s, w (Reading Room), d (temple square).
- **Contents:** an automatic teller machine (ATM).

## Temple Square
- **Desc:** Marble steps up to the temple gate. Clerics' Guild west, the old
  Grunting Boar Inn east, market square to the south.
- **Exits:** n (temple), e (Grunting Boar Inn), s (Market Square), w (Clerics' Guild).
- **Contents:** a fountain; a cityguard; a janitor.

## Market Square (city hub)
- **Desc:** The famous Square of Midgaard, a peculiar statue in the middle.
  Roads in every direction.
- **Exits:** n (Temple Square), s (common square), e (main street east),
  w (main street west).
- **Contents:** an oozing green gelatinous blob; a cityguard; a Peacekeeper.

## Main Street — west branch (Armory / Bakery junction)
- **Desc:** Main street through the city. Armory to the south, **bakery to the
  north**, market square to the east.
- **Exits:** n (**The Bakery**), e (Market Square), s (Armory), w (continues).

## The Bakery  ⭐ (goal)
- **Desc:** Small bakery, sweet scent of danish and fine bread; wares arranged
  on shelves. A sign on the counter.
- **Exits:** s (back to Main Street west branch).
- **Contents:** **the baker** (shopkeeper) — see `world/entities.md` for wares.

## Main Street — east branch, near-square (General store / Pet Shop)
- **Desc:** Main street crossing town. General store to the north, Pet Shop
  (small door) to the south, market place west, continues east.
- **Exits:** n (general store), e (continues), s (Pet Shop), w (Market Square).

## By The Temple Altar (north end of the Temple)
- **Desc:** Temple altar, a 10ft statue of Odin. Steps north lead out the **back
  of the temple toward the countryside** — this is the north way out of the city.
- **Exits:** n (countryside), s (temple hall).

## Behind The Temple Altar → The Great Field Of Midgaard (countryside road)
- **Desc:** A dirt path north from the temple through lush countryside toward the
  Dragonhelm Mountains. Several near-identical "Great Field" rooms run north.
- **Notable junction:** one Great Field room has a path **west** and a "strange
  structure" to the **east** → that east path is the **Newbie Zone entrance**.
- **North dead-ends** at a joke "large plot device" barrier.

## The Entrance To The Newbie Zone
- **Desc:** "The entrance to the newbie zone! ... enter to the north."
- **Exits:** n (into the zone), w (back to the Great Field junction).

## The Beginning Of The Passage (newbie zone)
- **Desc:** A long corridor; you hear creatures roaming.
- **Exits:** e (hallway continues), s (zone entrance).
- **Mobs:** two "newbie monster"s; a "creepy crawler" (killed one). Safe newbie
  hunting ground — no peacekeepers out here. See `world/entities.md`.

## Main Street — east branch, town edge (Weapon shop / Swordsmen Guild)
- **Desc:** Weapon shop to the north, Guild of Swordsmen to the south. **East
  leaves town.**
- **Exits:** n (weapon shop), e (out of town), s (Guild of Swordsmen), w (toward square).
- **Contents:** a beastly fido (harmless scavenger).
