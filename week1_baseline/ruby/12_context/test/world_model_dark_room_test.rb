require_relative "test_helper"
require "boukensha/world_model"

# Regression guard for the unlit-room trap that stranded Hectic in the sewer.
#
# An unlit room prints ONLY "It is pitch black..." — no name, no exits line. Two
# separate things went wrong with that text, and both are covered here:
#
#   1. It parsed as "not a room block", which the caller read as "the move was
#      blocked" — so a working exit (the well down out of the practice yard) got
#      marked BLOCKED even though the step had succeeded.
#   2. `current_memory_line` kept naming the room we had LEFT, so every tool
#      result told the agent it was still standing in the practice yard while it
#      wandered the sewer. Position must go explicitly unknown instead.
#
# See [[mud-sewer-one-way-trap]].
class WorldModelDarkRoomTest < Minitest::Test
  LIT = <<~ROOM
    The Tournament And Practice Yard
       This is the practice yard of the fighters.  To the north is the bar.
    A well leads down into darkness.
    [ Exits: n d ]

    21H 100M 84V (news) (motd) >
  ROOM

  DARK = "It is pitch black...\n\n21H 100M 83V (news) (motd) > "

  def world(dir)
    w = nil
    capture_io { w = Boukensha::WorldModel.new(path: File.join(dir, "world.json")) }
    w
  end

  def test_dark_text_is_recognised_as_unreadable
    with_isolated_env do |dir|
      w = world(dir)
      assert w.unreadable?(DARK), "pitch-black text with no exits line is unreadable"
    end
  end

  def test_lit_room_mentioning_darkness_is_still_mapped
    with_isolated_env do |dir|
      w = world(dir)
      # The description literally says "leads down into darkness" — it must not trip
      # the darkness check, or every room with atmospheric prose stops being mapped.
      refute w.unreadable?(LIT), "a lit room whose prose mentions darkness is readable"
      w.observe(LIT)
      assert_equal 1, w.rooms.size
      assert_equal "The Tournament And Practice Yard", w.rooms.values.first["name"]
    end
  end

  def test_entering_the_dark_drops_position_instead_of_keeping_the_old_room
    with_isolated_env do |dir|
      w = world(dir)
      w.observe(LIT)
      lit_id = w.current_id
      refute_nil lit_id

      line = w.observe(DARK, arrived_via: "down")

      assert w.dark?,        "must know it is somewhere unreadable"
      assert_nil w.current_id, "position is UNKNOWN in the dark, not the room we left"
      refute_includes line.to_s, "Tournament", "must not name the room we left"
      assert_match(/UNLIT|UNKNOWN/i, line.to_s, "must say position is unknown")
      assert_equal 1, w.rooms.size, "an unreadable room is never added to the map"
    end
  end

  def test_dark_room_is_not_recorded_even_on_repeated_moves
    with_isolated_env do |dir|
      w = world(dir)
      w.observe(LIT)
      3.times { w.observe(DARK, arrived_via: "south") }
      assert_equal 1, w.rooms.size, "wandering blind must not invent rooms"
      assert w.dark?
    end
  end

  def test_memory_line_keeps_reporting_unknown_while_dark
    with_isolated_env do |dir|
      w = world(dir)
      w.observe(LIT)
      w.observe(DARK, arrived_via: "down")
      assert_match(/UNKNOWN/i, w.current_memory_line.to_s)
      assert_match(/step u\b/i, w.current_memory_line.to_s, "should offer the way back out")
    end
  end

  # Nightfall in an OUTDOOR room we are standing in. We have not moved, so we know
  # exactly where we are — only mapping pauses. Throwing position away here would
  # blind a lightless agent across the whole outdoor map every dusk.
  def test_lights_going_out_in_place_keeps_position
    with_isolated_env do |dir|
      w = world(dir)
      w.observe(LIT)
      known = w.current_id

      line = w.observe(DARK) # a plain look — no arrived_via, so we did not move

      assert w.dark?, "still knows it cannot see"
      assert_equal known, w.current_id, "standing still in the dark must not lose position"
      refute_match(/UNKNOWN/i, line.to_s, "we know where we are; don't cry unknown")
      assert_match(/too dark to see/i, line.to_s)
    end
  end

  def test_routing_still_works_when_only_the_lights_went_out
    with_isolated_env do |dir|
      w = world(dir)
      w.observe(LIT)
      target = w.current_id
      w.observe(DARK)
      assert_equal [], w.route_to(target), "already there — still routable in the dark"
    end
  end

  # An explicit `moved:` overrides the arrived_via inference — this is how a
  # teleport re-orient reports that position changed even though it was a `look`.
  def test_moved_flag_forces_position_unknown_without_a_direction
    with_isolated_env do |dir|
      w = world(dir)
      w.observe(LIT)
      w.observe(DARK, moved: true)
      assert_nil w.current_id, "a teleport into the dark loses position"
      assert_match(/UNKNOWN/i, w.current_memory_line.to_s)
    end
  end

  def test_seeing_a_lit_room_again_restores_position
    with_isolated_env do |dir|
      w = world(dir)
      w.observe(LIT)
      w.observe(DARK, arrived_via: "down")
      assert w.dark?

      w.observe(LIT)
      refute w.dark?, "readable room clears the unknown-position state"
      refute_nil w.current_id
      assert_equal 1, w.rooms.size, "returning to a known room does not duplicate it"
    end
  end

  def test_no_edge_is_invented_out_of_the_dark
    with_isolated_env do |dir|
      w = world(dir)
      w.observe(LIT)
      w.observe(DARK, arrived_via: "down")
      # Coming back into a lit room from an unknown position must not record an
      # edge — we genuinely do not know what we walked through.
      other = LIT.sub("The Tournament And Practice Yard", "The Bar Of Swordsmen")
                 .sub("[ Exits: n d ]", "[ Exits: s w ]")
      w.observe(other, arrived_via: "up")
      yard = w.rooms.values.find { |r| r["name"] =~ /Practice Yard/ }
      assert_nil yard["exits"]["d"], "the dark exit stays an unwalked frontier, not a false edge"
    end
  end

  def test_routing_degrades_safely_while_position_is_unknown
    with_isolated_env do |dir|
      w = world(dir)
      w.observe(LIT)
      target = w.current_id
      w.observe(DARK, arrived_via: "down")

      assert_nil w.route_to(target),   "cannot plan a route from an unknown position"
      assert_empty w.unexplored_dirs,  "no frontier while we don't know where we are"
      assert_nil w.nearest_frontier_route, "explore must not pretend it can plan"
    end
  end
end
