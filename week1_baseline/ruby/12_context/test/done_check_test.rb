require_relative "test_helper"

# `done?` decides when a milestone is complete. Two of its advertised check types were
# broken in ways that made whole plans unsatisfiable:
#
#   * has_item was hardcoded `false` with the comment "(executor-reported; not read
#     here)" — but the PLANNER's contract offers has_item as a valid done_check. A
#     provisioning goal ("buy armour, a weapon, food, water, a teleporter") produced
#     five milestones that could NEVER tick. The character could own every item and
#     the plan would still run to MAX_RUNS and abort.
#   * there was no gold_at_least at all, so "earn some money" got expressed as
#     "reach level 5" to afford a 12-coin teleporter.
#
# Mirrors Plan.done? — kept in step with planning/orchestrator.rb, which can't be
# required here without a live MUD.
class DoneCheckTest < Minitest::Test
  def done?(check, state, baseline)
    case check["type"]
    when "xp_at_least"    then state[:xp] && state[:xp] >= check["value"].to_i
    when "level_at_least" then state[:level] && state[:level] >= check["value"].to_i
    when "at_place"       then state[:location].to_s.downcase.include?(check["name"].to_s.downcase)
    when "gold_at_least"  then state[:gold].to_i >= check["value"].to_i
    when "has_item"       then state[:items].to_s.include?(check["name"].to_s.downcase.strip)
    else false
    end
  end

  # Real `inventory` + `equipment` output, lowercased as read_state stores it.
  ITEMS = <<~TXT.downcase.freeze
    You are carrying:
    ( 3) a piece of meat
    the teleporter
    You are using:
    <used as light>      a candle
    <worn on body>       a breast plate
    <wielded>            a small sword
  TXT

  def state
    { level: 1, xp: 0, gold: 30, location: "The Temple Of Midgaard",
      sessions: 3, skills: {}, items: ITEMS }
  end

  def base = { skills: {}, sessions: 3 }

  def test_has_item_finds_a_carried_item
    assert done?({ "type" => "has_item", "name" => "teleporter" }, state, base)
  end

  # The subtle one: "buy a sword" is satisfied by a sword IN HAND, not just in the pack.
  def test_has_item_finds_a_wielded_item
    assert done?({ "type" => "has_item", "name" => "sword" }, state, base)
  end

  def test_has_item_finds_worn_armour
    assert done?({ "type" => "has_item", "name" => "breast plate" }, state, base)
  end

  def test_has_item_is_false_for_something_not_owned
    refute done?({ "type" => "has_item", "name" => "canteen" }, state, base)
  end

  def test_has_item_is_case_insensitive_and_trims
    assert done?({ "type" => "has_item", "name" => "  Teleporter " }, state, base)
  end

  def test_gold_at_least_meets_a_real_price
    assert done?({ "type" => "gold_at_least", "value" => 12 }, state, base),
           "30 coins must satisfy the 12-coin teleporter price"
  end

  def test_gold_at_least_is_false_when_short
    refute done?({ "type" => "gold_at_least", "value" => 100 }, state, base)
  end

  def test_gold_at_least_handles_a_missing_reading
    refute done?({ "type" => "gold_at_least", "value" => 1 }, state.merge(gold: nil), base)
  end

  # Guard the regression directly: has_item must not be unconditionally false.
  def test_has_item_is_not_hardcoded_false
    owned = %w[teleporter sword candle meat]
    assert owned.all? { |i| done?({ "type" => "has_item", "name" => i }, state, base) },
           "every owned item must satisfy has_item — this branch used to return false always"
  end

  def test_unknown_check_type_is_false
    refute done?({ "type" => "vibes" }, state, base)
  end
end
