require_relative "test_helper"
require "json"

# A plan is a set of ASSERTIONS about what is verifiable, and nothing tested those
# assertions before runs were spent on them. The planner asked three separate times to
# reach a room called "Teleporter" — no such room exists (the vendor is in the Reading
# Room) — and once for `gold_at_least 57` from a character holding exactly 57.
#
# That is the tool layer's failure one storey up: asserting without checking. Every
# done_check must now be EVALUABLE NOW and NOT ALREADY TRUE before the plan is accepted.
#
# The deeper rule this encodes: FINDING SOMEWHERE IS NOT A CHECKPOINT. "Find the shop
# that sells teleporters" is HOW you accomplish "own a teleporter" — the executor has
# seek/explore for that. An at_place naming an unmapped room is the planner expressing
# an instrumental step as a terminal one, so it is dropped and the next milestone's real
# check carries the goal with the search folded inside.
#
# Mirrors Plan.validate_plan — kept in step with planning/orchestrator.rb, which cannot
# be required here without a live MUD.
class PlanValidationTest < Minitest::Test
  MAPPED = ["The Temple Of Midgaard", "The Temple Square", "Ye Olde Water Shoppe",
            "The Entrance To The Newbie Zone", "A Nexus"].freeze

  def done?(check, state)
    case check["type"]
    when "xp_at_least"    then state[:xp].to_i    >= check["value"].to_i
    when "level_at_least" then state[:level].to_i >= check["value"].to_i
    when "gold_at_least"  then state[:gold].to_i  >= check["value"].to_i
    when "at_place"       then state[:location].to_s.downcase.include?(check["name"].to_s.downcase)
    when "has_item"       then state[:items].to_s.include?(check["name"].to_s.downcase.strip)
    when "skill_trained"  then false
    else false
    end
  end

  def validate_plan(milestones, state)
    kept = []
    notes = []
    milestones.each do |m|
      check = m["done_check"] || {}
      if done?(check, state)
        notes << "already true: #{m['milestone']}"
        next
      end
      case check["type"]
      when "at_place"
        name = check["name"].to_s.downcase.strip
        if name.empty? || MAPPED.none? { |p| p.downcase.include?(name) }
          notes << "unmapped place: #{m['milestone']}"
          next
        end
      when "skill_trained"
        unless state[:skills].key?(check["skill"].to_s.downcase)
          notes << "unknown skill: #{m['milestone']}"
          next
        end
      when "xp_at_least", "level_at_least", "gold_at_least", "has_item"
        # evaluable by construction
      else
        notes << "unknown type: #{m['milestone']}"
        next
      end
      kept << m
    end
    [kept, notes]
  end

  # Solace's real state when the offending plan was produced.
  def state
    { level: 1, xp: 723, gold: 57, location: "The Temple Of Midgaard", sessions: 3,
      skills: { "armor" => "not learned", "cure light" => "not learned" },
      items: "( 4) a cup\n( 2) a danish pastry\na shiny newbie dagger" }
  end

  def ms(name, check) = { "milestone" => name, "done_check" => check }

  # The exact plan from run 8.
  def test_the_real_failing_plan_reduces_to_its_two_real_milestones
    plan = [
      ms("Find the shop that sells teleporters", { "type" => "at_place", "name" => "Teleporter" }),
      ms("Earn enough gold to afford a teleporter", { "type" => "gold_at_least", "value" => 57 }),
      ms("Buy a teleporter", { "type" => "has_item", "name" => "teleporter" }),
      ms("Travel to the Newbie Zone and hunt", { "type" => "xp_at_least", "value" => 1500 })
    ]
    kept, = validate_plan(plan, state)
    assert_equal ["Buy a teleporter", "Travel to the Newbie Zone and hunt"],
                 kept.map { |m| m["milestone"] },
                 "the run should have STARTED at 'buy a teleporter'"
  end

  def test_unmapped_at_place_is_dropped
    kept, notes = validate_plan([ms("Find it", { "type" => "at_place", "name" => "Teleporter" })], state)
    assert_empty kept
    assert_includes notes.join, "unmapped place"
  end

  def test_mapped_at_place_is_kept
    kept, = validate_plan([ms("Go to the water shop", { "type" => "at_place", "name" => "Ye Olde Water Shoppe" })], state)
    assert_equal 1, kept.size, "a room actually on the map is a legitimate destination"
  end

  def test_already_true_place_is_dropped
    kept, notes = validate_plan([ms("Go to the Temple", { "type" => "at_place", "name" => "Temple Of Midgaard" })], state)
    assert_empty kept, "she is standing there"
    assert_includes notes.join, "already true"
  end

  def test_already_satisfied_threshold_is_dropped
    kept, = validate_plan([ms("Earn 57 gold", { "type" => "gold_at_least", "value" => 57 })], state)
    assert_empty kept, "she holds exactly 57"
  end

  def test_a_real_threshold_survives
    kept, = validate_plan([ms("Earn 200 gold", { "type" => "gold_at_least", "value" => 200 })], state)
    assert_equal 1, kept.size
  end

  def test_unknown_skill_is_dropped
    kept, notes = validate_plan([ms("Train fireball", { "type" => "skill_trained", "skill" => "fireball" })], state)
    assert_empty kept, "a Cleric cannot train a spell she has no line for"
    assert_includes notes.join, "unknown skill"
  end

  def test_known_skill_survives
    kept, = validate_plan([ms("Train cure light", { "type" => "skill_trained", "skill" => "cure light" })], state)
    assert_equal 1, kept.size
  end

  def test_unknown_check_type_is_dropped
    kept, notes = validate_plan([ms("Vibes", { "type" => "vibes" })], state)
    assert_empty kept
    assert_includes notes.join, "unknown type"
  end

  def test_a_wholly_unverifiable_plan_yields_nothing
    plan = [
      ms("Find X", { "type" => "at_place", "name" => "Nowhere" }),
      ms("Vibes",  { "type" => "vibes" })
    ]
    kept, = validate_plan(plan, state)
    assert_empty kept, "caller must bounce back to the planner rather than run this"
  end
end
