require_relative "test_helper"

# Two limits that stranded a character mid-goal:
#
#   * MAX_REPLANS was a flat 3. A five-part compound goal ("get equipped, find the
#     zone, earn money, provision, buy a teleporter") legitimately needs more course
#     corrections than "go kill things" — Solace exhausted all three on things the
#     planner could not have known (a price, a light she already owned) and escalated
#     with 44 gold in hand and two milestones left.
#   * progressed? had no gold_at_least branch, so it fell through to the permissive
#     one where mapping a room counted as progress on a MONEY milestone. A character
#     could wander for four runs earning nothing and never trigger the replan that
#     would have sent it somewhere with coin.
#
# Mirrors Plan.replan_budget / Plan.progressed? — kept in step with
# planning/orchestrator.rb, which can't be required here without a live MUD.
class ReplanBudgetTest < Minitest::Test
  MIN_REPLANS = 3
  MAX_REPLANS_CAP = 8

  def replan_budget(plan)
    n = (plan["milestones"] || []).size
    [[n, MIN_REPLANS].max, MAX_REPLANS_CAP].min
  end

  def progressed?(before, after, check = nil, rooms_before = nil, rooms_after = nil)
    mapped_more = rooms_before && rooms_after && rooms_after > rooms_before
    case check && check["type"]
    when "xp_at_least", "level_at_least"
      after[:xp].to_i > before[:xp].to_i || after[:level].to_i > before[:level].to_i
    when "gold_at_least"
      after[:gold].to_i > before[:gold].to_i
    when "skill_trained"
      after[:skills] != before[:skills] || after[:sessions].to_i != before[:sessions].to_i
    when "at_place"
      after[:location].to_s != before[:location].to_s || !!mapped_more
    else
      after[:xp].to_i > before[:xp].to_i || after[:level].to_i > before[:level].to_i ||
        after[:sessions].to_i != before[:sessions].to_i ||
        after[:location].to_s != before[:location].to_s ||
        after[:skills] != before[:skills] || !!mapped_more
    end
  end

  def plan(n) = { "milestones" => Array.new(n) { {} } }

  def test_small_plans_keep_the_floor
    assert_equal 3, replan_budget(plan(1))
    assert_equal 3, replan_budget(plan(3))
  end

  # The case that stranded Solace: five milestones deserve five corrections.
  def test_budget_scales_with_plan_size
    assert_equal 5, replan_budget(plan(5))
    assert_equal 6, replan_budget(plan(6))
  end

  def test_budget_is_capped
    assert_equal MAX_REPLANS_CAP, replan_budget(plan(9))
    assert_equal MAX_REPLANS_CAP, replan_budget(plan(30))
  end

  def test_empty_plan_does_not_crash
    assert_equal 3, replan_budget({})
  end

  # ---- gold progress -------------------------------------------------------

  def base
    { level: 1, xp: 100, gold: 10, location: "A Nexus", sessions: 1, skills: {} }
  end

  GOLD = { "type" => "gold_at_least", "value" => 50 }.freeze

  def test_wandering_is_not_progress_on_a_money_milestone
    moved = base.merge(location: "More Of The Hallway")
    refute progressed?(base, moved, GOLD, 10, 20),
           "moving and mapping earns no coin — this must trigger a replan"
  end

  def test_earning_gold_is_progress
    assert progressed?(base, base.merge(gold: 15), GOLD, 10, 10)
  end

  def test_xp_without_gold_is_not_progress_on_a_money_milestone
    refute progressed?(base, base.merge(xp: 400), GOLD, 10, 10),
           "xp is not money — a zone with empty corpses must not read as earning"
  end

  def test_losing_gold_is_not_progress
    refute progressed?(base, base.merge(gold: 2), GOLD, 10, 10)
  end
end
