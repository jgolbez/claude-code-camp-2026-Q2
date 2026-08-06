require_relative "test_helper"

# "Safe" was a hardcoded allowlist of two zones — and worse, it was `safe_to_quit_here`,
# a predicate written for a DIFFERENT question (is it safe to LOG OUT here, so an idle
# body isn't eaten). Reusing it as a travel gate banned the sewer permanently for
# everyone regardless of level or kit.
#
# A safe zone is one the character can reasonably expect to SURVIVE, and that changes as
# it levels and equips. So the gate asks about READINESS — light, food, water, a way
# home — and names what is missing instead of refusing outright. Fetch the kit and the
# zone opens.
#
# Four characters were stranded in the sewer before this existed; the last of them,
# Rell, walked in through `hunt` returning to a grind spot it had marked there, because
# the leash only covered `explore`.
#
# Mirrors readiness / missing_kit / zone_gate in lib/boukensha/tools/mud.rb, which can't
# be required here without a live MUD.
class ZoneGateTest < Minitest::Test
  # "light" is absent on purpose: the slot label "<used as light>" contains it.
  LIGHT = /\b(candle|torch|lantern|lamp)\b/i
  FOOD  = /\b(bread|loaf|waybread|ration|biscuit|hardtack|cheese|apple|banana|fruit)\b/i
  DRINK = /\b(waterskin|flask|canteen|bottle|jug)\b/i

  def readiness(inv, eq = "")
    both = "#{inv}\n#{eq}"
    { light:  !!(eq =~ /<used as light>[ \t]*[^\s<]/i || both =~ LIGHT),
      food:   !!(both =~ FOOD),
      water:  !!(both =~ DRINK),
      escape: !!(both =~ /teleport/i) }
  end

  def missing_kit(inv, eq = "")
    r = readiness(inv, eq)
    m = []
    m << "a lit light source"        unless r[:light]
    m << "food"                      unless r[:food]
    m << "water"                     unless r[:water]
    m << "a way home (a teleporter)" unless r[:escape]
    m
  end

  def established?(zone)
    !!(zone =~ /newbie zone/i || (zone =~ /midgaard/i && zone !~ /sewer|passage|cesspit/i))
  end

  def zone_gate(zone, inv, eq = "")
    return [] if zone.nil? || zone.empty?
    return [] if established?(zone)
    missing_kit(inv, eq)
  end

  FULL_KIT_INV = "a waybread\na canteen\nthe teleporter"
  FULL_KIT_EQ  = "<used as light>      a candle"

  # The headline: kit opens the map. This is the whole point.
  def test_a_fully_equipped_character_may_enter_hostile_ground
    assert_empty zone_gate("Sewer, First Level", FULL_KIT_INV, FULL_KIT_EQ),
                 "light + food + water + escape earns the right to go in"
  end

  def test_a_naked_character_is_told_exactly_what_is_missing
    missing = zone_gate("Sewer, First Level", "", "")
    assert_equal ["a lit light source", "food", "water", "a way home (a teleporter)"], missing
  end

  # Rell's actual kit when his run ended: everything but safe food.
  def test_rells_kit_lacks_only_food
    inv = "a bottle\n( 3) a piece of meat\nthe teleporter"
    eq  = "<used as light>      a candle\n<wielded>            a small sword"
    assert_equal ["food"], zone_gate("Sewer, First Level", inv, eq),
                 "meat is deliberately not safe food; everything else he has"
  end

  # Established ground never costs a readiness check.
  def test_the_newbie_zone_is_always_open
    assert_empty zone_gate("Newbie Zone", "", "")
  end

  def test_midgaard_town_is_always_open
    assert_empty zone_gate("Northern Midgaard", "", "")
  end

  # ...but a sewer that merely mentions Midgaard is NOT established ground.
  def test_a_midgaard_sewer_still_requires_the_kit
    refute_empty zone_gate("The Sewers of Midgaard", "", "")
  end

  def test_an_unknown_zone_requires_the_kit
    refute_empty zone_gate("The Shadow Grove", "", ""),
                 "unknown ground fails closed until the character is equipped"
  end

  def test_a_missing_zone_reading_does_not_block
    assert_empty zone_gate(nil, "", "")
    assert_empty zone_gate("", "", "")
  end

  # Each requirement independently gates.
  def test_each_missing_piece_is_named_on_its_own
    assert_equal ["a lit light source"],
                 zone_gate("Sewer", "a waybread\na canteen\nthe teleporter", "")
    assert_equal ["food"],
                 zone_gate("Sewer", "a canteen\nthe teleporter", FULL_KIT_EQ)
    assert_equal ["water"],
                 zone_gate("Sewer", "a waybread\nthe teleporter", FULL_KIT_EQ)
    assert_equal ["a way home (a teleporter)"],
                 zone_gate("Sewer", "a waybread\na canteen", FULL_KIT_EQ)
  end

  # A worn light counts even when the word "light" isn't in the item's name.
  def test_an_equipped_light_slot_counts
    r = readiness("", "<used as light>      a glowing rock")
    assert r[:light]
  end

  def test_an_empty_light_slot_does_not_count
    r = readiness("", "<used as light>\n<worn on body> a breast plate")
    refute r[:light]
  end
end
