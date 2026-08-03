require_relative "test_helper"
require "boukensha/world_model"

# Brittleness guard: the navigation layer must NOT assume a populated world.
# On a brand-new/empty map (0 rooms), every routing query must degrade to a nil
# "I don't know a route yet" answer — never raise. This is the unit-level twin of
# the live blank-map explore run: wipe the map, and the tools still behave.
# See [[boukensha-stray-map-trap]].
class WorldModelEmptyMapTest < Minitest::Test
  # A world model over a path that has no world.json at all -> genuinely empty.
  def empty_world(dir)
    world = nil
    capture_io do # swallow the loud fresh-start announce
      world = Boukensha::WorldModel.new(path: File.join(dir, "world.json"))
    end
    world
  end

  def test_fresh_model_has_zero_rooms
    with_isolated_env do |dir|
      assert_equal 0, empty_world(dir).rooms.size
    end
  end

  def test_route_to_returns_nil_instead_of_raising
    with_isolated_env do |dir|
      w = empty_world(dir)
      assert_nil w.route_to(5, from_fp: nil),        "no rooms -> no route, not a crash"
      assert_nil w.route_to(5, from_fp: "deadbeef"), "bogus origin fp must not raise"
    end
  end

  def test_resolve_destination_returns_nil_by_name_and_by_id
    with_isolated_env do |dir|
      w = empty_world(dir)
      assert_nil w.resolve_destination("Temple", from_fp: nil), "name lookup on empty map -> nil"
      assert_nil w.resolve_destination("#2",     from_fp: nil), "id lookup on empty map -> nil"
    end
  end

  def test_fp_for_id_returns_nil_on_empty_map
    with_isolated_env do |dir|
      assert_nil empty_world(dir).fp_for_id(2)
    end
  end
end
