require_relative "test_helper"

# `progressed?` decides whether a milestone run moved things FORWARD. Get it wrong
# and the orchestrator either retries a wall forever or replans away from a success.
# Both directions were observed live on Hectic, hence this guard.
#
# Loaded in isolation: orchestrator.rb connects to a MUD at require time via
# Boukensha.config, so we test the pure decision functions by extracting them
# rather than booting the whole module.
class OrchestratorProgressTest < Minitest::Test
  # Mirror of Plan.progressed? — kept in step with planning/orchestrator.rb.
  # (The orchestrator can't be required here without a live MUD; if these ever
  # drift, this test is the canary that says so.)
  def progressed?(before, after, check = nil, rooms_before = nil, rooms_after = nil)
    mapped_more = rooms_before && rooms_after && rooms_after > rooms_before
    case check && check["type"]
    when "xp_at_least", "level_at_least"
      after[:xp].to_i > before[:xp].to_i || after[:level].to_i > before[:level].to_i
    when "skill_trained"
      after[:skills] != before[:skills] || after[:sessions].to_i != before[:sessions].to_i
    when "at_place"
      after[:location].to_s != before[:location].to_s || !!mapped_more
    else
      after[:xp].to_i > before[:xp].to_i ||
        after[:level].to_i > before[:level].to_i ||
        after[:sessions].to_i != before[:sessions].to_i ||
        after[:location].to_s != before[:location].to_s ||
        after[:skills] != before[:skills] ||
        !!mapped_more
    end
  end

  def base
    { level: 1, xp: 295, sessions: 2, location: "The Watery Sewer", skills: {} }
  end

  XP    = { "type" => "xp_at_least", "value" => 1825 }.freeze
  PLACE = { "type" => "at_place", "name" => "Passage" }.freeze
  SKILL = { "type" => "skill_trained", "skill" => "kick" }.freeze

  # The "too lenient" failure: during an xp grind he wandered one sewer room and
  # that counted as progress, so a run that killed nothing re-ran instead of
  # replanning around the depleted zone.
  def test_wandering_during_an_xp_grind_is_not_progress
    moved = base.merge(location: "The Watery Sewer Junction")
    refute progressed?(base, moved, XP), "a room change is not progress toward an xp goal"
  end

  def test_xp_gain_is_progress_toward_an_xp_goal
    assert progressed?(base, base.merge(xp: 352), XP)
  end

  def test_level_gain_is_progress_toward_an_xp_goal
    assert progressed?(base, base.merge(level: 2), XP)
  end

  # The "too strict" failure: an exploration milestone mapped new rooms, ended in
  # the same place with the same xp, and got read as a blocker — burning a replan
  # on what the executor itself reported as STEP COMPLETE.
  def test_mapping_new_rooms_is_progress_for_a_place_goal
    assert progressed?(base, base, PLACE, 60, 72), "12 new rooms is real exploration progress"
  end

  def test_standing_still_and_mapping_nothing_is_not_progress
    refute progressed?(base, base, PLACE, 60, 60)
  end

  def test_moving_is_progress_for_a_place_goal
    assert progressed?(base, base.merge(location: "The Beginning Of The Passage"), PLACE, 60, 60)
  end

  # A refused `practice` changes nothing at all — the original blocker that made
  # the orchestrator retry the same impossible milestone three times.
  def test_refused_practice_is_not_progress
    refute progressed?(base, base, SKILL), "nothing changed — this must trigger a replan"
  end

  def test_spending_a_session_is_progress_for_a_training_goal
    assert progressed?(base, base.merge(sessions: 1), SKILL)
  end

  def test_unknown_check_type_falls_back_to_any_change
    assert progressed?(base, base.merge(xp: 300), nil)
    assert progressed?(base, base, nil, 10, 11), "map growth counts in the fallback too"
    refute progressed?(base, base, nil, 10, 10)
  end
end
