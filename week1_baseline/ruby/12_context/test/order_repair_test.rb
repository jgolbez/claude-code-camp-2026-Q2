require_relative "test_helper"

# The planner reaches the right dependency order by ATTRITION. On Tarn's acceptance
# run it inverted "buy before earn" at replan 1, corrected at replan 2, and then
# re-proposed the SAME inversion at replan 4 — three of five replans spent cycling
# through an approach it had already abandoned.
#
# Two fixes, both aimed at that waste:
#   * the replanner is now told what has already been tried and failed (it had no
#     memory of its own previous plans, hence the cycling);
#   * and the ordering is repaired DETERMINISTICALLY here — we know the gold and we
#     know which milestones acquire versus earn, so a broke character's plan gets its
#     earning milestone hoisted without asking the planner again.
#
# Mirrors Plan.repair_order — kept in step with planning/orchestrator.rb, which cannot
# be required here without a live MUD.
class OrderRepairTest < Minitest::Test
  BROKE_BELOW = 15

  # A newcomer is outfitted FREE at the donation room, so weapon/armour/light are not
  # purchases and must never be pushed behind an earning milestone.
  FREE_KIT = /\A(?:weapon|blade|sword|dagger|mace|club|axe|armou?r|plate|mail|shield|helm|light|lamp|torch|candle)\z/i

  def purchase?(m)
    c = m["done_check"] || {}
    c["type"] == "has_item" && c["name"].to_s.strip !~ FREE_KIT
  end

  def repair_order(milestones, state)
    gold = state[:gold].to_i
    return [milestones, nil] if gold >= BROKE_BELOW

    acquire_at = milestones.index { |m| purchase?(m) }
    earn_at    = milestones.index { |m| m.dig("done_check", "type") == "gold_at_least" }
    return [milestones, nil] unless acquire_at && earn_at && earn_at > acquire_at

    earner = milestones[earn_at]
    [[earner] + (milestones - [earner]),
     "reordered: #{earner['milestone'].inspect} moved ahead of #{milestones[acquire_at]['milestone'].inspect}"]
  end

  def ms(name, check) = { "milestone" => name, "done_check" => check }
  def names(list) = list.map { |m| m["milestone"] }

  # The exact plan replan 4 produced, for a character holding nothing.
  def inverted
    [ms("Buy food provisions",  { "type" => "has_item", "name" => "food" }),
     ms("Buy water provisions", { "type" => "has_item", "name" => "water" }),
     ms("Grind gold",           { "type" => "gold_at_least", "value" => 12 }),
     ms("Buy a teleporter",     { "type" => "has_item", "name" => "teleporter" })]
  end

  def test_a_broke_character_earns_before_buying
    out, note = repair_order(inverted, { gold: 0 })
    assert_equal "Grind gold", names(out).first, "earning must be hoisted to the front"
    refute_nil note
  end

  def test_the_rest_of_the_order_is_preserved
    out, = repair_order(inverted, { gold: 0 })
    assert_equal ["Grind gold", "Buy food provisions", "Buy water provisions", "Buy a teleporter"],
                 names(out), "only the earner moves; everything else keeps its relative order"
  end

  # A solvent character may legitimately buy first — don't meddle.
  def test_a_solvent_character_is_left_alone
    out, note = repair_order(inverted, { gold: 200 })
    assert_equal names(inverted), names(out)
    assert_nil note
  end

  def test_the_threshold_is_respected
    _, poor = repair_order(inverted, { gold: BROKE_BELOW - 1 })
    _, rich = repair_order(inverted, { gold: BROKE_BELOW })
    refute_nil poor, "below the threshold, repair"
    assert_nil rich, "at the threshold, leave it"
  end

  def test_an_already_correct_order_is_untouched
    good = [ms("Grind gold", { "type" => "gold_at_least", "value" => 12 }),
            ms("Buy a teleporter", { "type" => "has_item", "name" => "teleporter" })]
    out, note = repair_order(good, { gold: 0 })
    assert_equal names(good), names(out)
    assert_nil note
  end

  def test_a_plan_with_no_purchases_is_untouched
    plan = [ms("Hunt", { "type" => "xp_at_least", "value" => 500 })]
    _, note = repair_order(plan, { gold: 0 })
    assert_nil note
  end

  def test_a_plan_with_no_earning_milestone_is_untouched
    # Nothing to hoist — the free donation room covers this case, so don't invent work.
    plan = [ms("Get equipped", { "type" => "has_item", "name" => "sword" })]
    out, note = repair_order(plan, { gold: 0 })
    assert_equal names(plan), names(out)
    assert_nil note
  end

  def test_missing_gold_reading_is_treated_as_broke
    _, note = repair_order(inverted, { gold: nil })
    refute_nil note, "an unreadable purse must fail safe, not assume wealth"
  end

  def test_empty_plan_does_not_crash
    out, note = repair_order([], { gold: 0 })
    assert_empty out
    assert_nil note
  end

  # ---- free kit must NOT be treated as a purchase --------------------------
  #
  # The first version of this repair treated every has_item milestone as something
  # you buy, so it hoisted "hunt for gold" ahead of "get equipped with a weapon" and
  # sent an unarmed 26-HP character out to fight — precisely what the gear-up-first
  # rule exists to prevent. Equipment is FREE at the donation room.

  def free_kit_plan
    [ms("Get equipped with a basic weapon", { "type" => "has_item", "name" => "sword" }),
     ms("Get equipped with basic armor",    { "type" => "has_item", "name" => "armor" }),
     ms("Hunt to earn gold",                { "type" => "gold_at_least", "value" => 100 }),
     ms("Buy food",                         { "type" => "has_item", "name" => "food" }),
     ms("Buy a teleporter",                 { "type" => "has_item", "name" => "teleporter" })]
  end

  def test_free_gear_is_never_pushed_behind_earning
    out, note = repair_order(free_kit_plan, { gold: 0 })
    assert_equal "Get equipped with a basic weapon", names(out).first,
                 "a naked character must gear up first — the donation room is free"
    assert_nil note
  end

  def test_weapon_and_armour_and_light_are_not_purchases
    %w[sword weapon armor armour shield helm light torch candle dagger mace].each do |n|
      refute purchase?(ms("Get #{n}", { "type" => "has_item", "name" => n })),
             "#{n.inspect} comes free from the donation room"
    end
  end

  def test_consumables_and_gadgets_are_purchases
    %w[food water bread canteen teleporter].each do |n|
      assert purchase?(ms("Buy #{n}", { "type" => "has_item", "name" => n })),
             "#{n.inspect} must be bought, so money comes first"
    end
  end

  # The real inversion must still be caught even when free gear sits in the plan.
  def test_a_purchase_behind_free_gear_is_still_repaired
    plan = [ms("Get equipped", { "type" => "has_item", "name" => "sword" }),
            ms("Buy food",     { "type" => "has_item", "name" => "food" }),
            ms("Hunt for gold",{ "type" => "gold_at_least", "value" => 12 })]
    out, note = repair_order(plan, { gold: 0 })
    assert_equal "Hunt for gold", names(out).first
    refute_nil note
  end
end
