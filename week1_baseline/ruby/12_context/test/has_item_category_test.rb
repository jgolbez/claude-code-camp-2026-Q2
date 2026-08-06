require_relative "test_helper"

# The planner has to NAME an item it has never seen, so it guesses the category —
# "water", "food" — while the game hands you "a cup" and "a danish pastry". A literal
# substring match then fails a milestone the character actually completed.
#
# That is not hypothetical: Solace walked to the shops, spent 37 of her 44 gold on
# four cups and two pastries, and the plan ABORTED on `has_item "water"` because
# "a cup" does not contain "water". Fully provisioned, marked blocked.
#
# So has_item tries the literal first, then the category the word names. Deliberately
# generous: a false "yes" costs one skipped milestone; a false "no" burns the entire
# run budget on something already done.
#
# Mirrors Plan::ITEM_CATEGORIES / Plan.has_item? — kept in step with
# planning/orchestrator.rb, which can't be required here without a live MUD.
class HasItemCategoryTest < Minitest::Test
  CATEGORIES = {
    /\A(?:water|drink|liquid|waterskin|canteen|bottle|flask|jug|cup)\z/ => /waterskin|flask|canteen|bottle|jug|cup|skin\b/,
    /\A(?:food|rations?|provisions?|bread)\z/ => /bread|loaf|waybread|ration|biscuit|hardtack|cheese|apple|banana|fruit|pastry|danish|pie|cake/,
    /\A(?:light|lamp|torch|candle)\z/ => /candle|torch|lantern|lamp|glowing/,
    /\A(?:weapon|blade)\z/ => /sword|dagger|mace|club|axe|spear|staff|blade|hammer|flail|knife|whip/,
    /\A(?:armou?r|armour)\z/ => /armou?r|plate|mail|shield|helm|cap\b|leggings|boots|gloves|sleeves|gorget|vest|wristguard/
  }.freeze

  def has_item?(items, name)
    want = name.to_s.downcase.strip
    return false if want.empty?
    return true if items.include?(want)
    _, pattern = CATEGORIES.find { |word_re, _| want =~ word_re }
    pattern ? !!(items =~ pattern) : false
  end

  # Solace's actual inventory at the moment the plan aborted.
  SOLACE = <<~TXT.downcase.freeze
    You are carrying:
    ( 4) a cup
    ( 2) a danish pastry
    a shiny newbie dagger
    You are using:
    <used as light>      a candle
    <worn on body>       a breast plate
  TXT

  # The exact regression: she HAD water, in cups.
  def test_water_matches_a_cup
    assert has_item?(SOLACE, "water"), "four cups is water — this abort must not recur"
  end

  def test_food_matches_a_danish_pastry
    assert has_item?(SOLACE, "food")
    assert has_item?(SOLACE, "bread"), "the planner's guess 'bread' must accept a pastry"
  end

  def test_a_specific_container_noun_also_counts_as_water
    assert has_item?(SOLACE, "canteen"), "planner guessed canteen; shop sold a cup"
    assert has_item?(SOLACE, "bottle")
  end

  def test_light_matches_a_candle
    assert has_item?(SOLACE, "light")
    assert has_item?(SOLACE, "torch"), "she has a working light; don't send her shopping"
  end

  def test_armour_matches_a_breast_plate
    assert has_item?(SOLACE, "armor")
    assert has_item?(SOLACE, "armour")
  end

  def test_weapon_matches_a_dagger
    assert has_item?(SOLACE, "weapon")
  end

  # Literal names must still work, and must stay honest.
  def test_exact_names_still_match
    assert has_item?(SOLACE, "cup")
    assert has_item?(SOLACE, "danish pastry")
  end

  def test_something_not_owned_is_still_false
    refute has_item?(SOLACE, "teleporter"), "she never bought one — must not false-positive"
  end

  # "sword" is a specific noun, not a category word: a dagger is not a sword.
  def test_specific_nouns_are_not_widened
    refute has_item?(SOLACE, "sword")
  end

  def test_empty_name_is_false
    refute has_item?(SOLACE, "")
    refute has_item?(SOLACE, nil)
  end
end
