require_relative "test_helper"
require "boukensha/world_model"
require "json"

# Pure-logic guard for the ambiguity at the heart of the stray-map confusion:
# duplicate room NAMES. Two rooms are both "A Nexus"; only one is connected to
# the Temple. resolve_destination must pick the REACHABLE twin, and route_to must
# path to it — never to the orphan. Builds a tiny in-memory graph, no MUD needed.
class WorldModelRoutingTest < Minitest::Test
  # temple --n--> nexusA (connected)      nexusB is an unreachable orphan
  #        <--s--
  MAP = {
    "next_id" => 3,
    "rooms" => {
      "temple" => { "id" => 1, "name" => "The Temple Of Midgaard",
                    "description" => "", "exits" => { "n" => 2 }, "visits" => 1 },
      "nexusA" => { "id" => 2, "name" => "A Nexus",
                    "description" => "one", "exits" => { "s" => 1 }, "visits" => 1 },
      "nexusB" => { "id" => 3, "name" => "A Nexus",
                    "description" => "two", "exits" => {}, "visits" => 1 }
    }
  }.freeze

  def build_world(dir)
    path = File.join(dir, "world.json")
    File.write(path, JSON.generate(MAP))
    world = nil
    capture_io { world = Boukensha::WorldModel.new(path: path) } # swallow announce
    world
  end

  def test_route_to_paths_to_the_connected_room_and_is_nil_for_the_orphan
    with_isolated_env do |dir|
      w = build_world(dir)
      assert_equal ["n"], w.route_to(2, from_fp: "temple")
      assert_nil        w.route_to(3, from_fp: "temple")
    end
  end

  def test_resolve_destination_picks_the_reachable_duplicate
    with_isolated_env do |dir|
      w = build_world(dir)
      assert_equal 2, w.resolve_destination("A Nexus", from_fp: "temple"),
                   "ambiguous name must resolve to the twin we can actually reach"
    end
  end

  def test_resolve_destination_by_id_is_exact
    with_isolated_env do |dir|
      w = build_world(dir)
      assert_equal 3, w.resolve_destination("#3", from_fp: "temple")
      assert_nil      w.resolve_destination("#999", from_fp: "temple")
    end
  end
end
