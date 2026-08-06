# Solace — the second cold start

[Hectic](../hectic/README.md) was the first character with no world knowledge, and
debugging him surfaced eight harness defects. **Solace is the regression test for those
fixes**: a brand-new character on the repaired harness, to find out whether they
generalised or were merely shaped to the character that produced them.

She differs on the axes that matter:

- **A Cleric**, not a Warrior — only `thief` has class-specific tools, so she runs
  entirely on the generic set, and carries spells (`armor`, `cure light`) nothing had
  exercised before.
- **18 HP**, three fewer than Hectic — the thinnest margin yet run.
- **A compound five-part goal** — *get equipped, find the newbie zone, earn money,
  provision, buy a teleporter* — which forces the planner to sequence dependencies,
  express money as money, and verify acquisitions.

## Running her

```bash
BOUKENSHA_DIR=$PWD/characters/solace/.boukensha \
  mise exec -- ruby week1_baseline/ruby/12_context/planning/run.rb "<goal>"
```

## What she found

**The tool layer never failed her.** All eight of Hectic's fixes held across seven runs.
Every new defect — seven of them — was in the **planning layer**: the planner inheriting
the executor's token cap, `has_item` hardcoded false, blindness to gold and inventory,
greedy JSON extraction, `gold_at_least` missing from the progress signal, a flat replan
budget, and `has_item` matching too literally to recognise that "a cup" is water.

The full account is in [docs/journal/8_solace.md](../../docs/journal/8_solace.md).

## Result

**723 xp, 57 gold, fully equipped, fed, watered, zero deaths** — four of five goal parts
complete. The fifth needed 12 of her 57 gold; she could not get out of the sewer to spend
it, which is why leashing `explore` out of dangerous zones is the top open item.
