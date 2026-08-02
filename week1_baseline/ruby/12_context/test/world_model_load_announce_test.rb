require_relative "test_helper"
require "boukensha/world_model"
require "json"

# The load-time announce is the observability half of the stray-map fix: one
# stderr line naming the resolved map + room count, and a louder note when a
# fresh (empty) map is created — the in-the-moment signal that would have broken
# the "why is nav broken?" misdiagnosis loop.
class WorldModelLoadAnnounceTest < Minitest::Test
  def test_announces_resolved_path_and_room_count_for_an_existing_map
    with_isolated_env do |dir|
      path = File.join(dir, "world.json")
      File.write(path, JSON.generate(
        "next_id" => 2,
        "rooms" => {
          "a" => { "id" => 1, "name" => "The Temple Of Midgaard", "exits" => {} },
          "b" => { "id" => 2, "name" => "A Nexus", "exits" => {} }
        }
      ))

      _out, err = capture_io { Boukensha::WorldModel.new(path: path) }
      assert_match(/world map: #{Regexp.escape(path)} \(2 rooms\)/, err)
      refute_match(/starting a fresh one/i, err)
    end
  end

  def test_warns_loudly_when_no_map_exists_and_a_fresh_one_is_started
    with_isolated_env do |dir|
      path = File.join(dir, "nope", "world.json") # does not exist
      _out, err = capture_io { Boukensha::WorldModel.new(path: path) }
      assert_match(/\(0 rooms\)/, err)
      assert_match(/starting a fresh one/i, err)
      assert_match(/BOUKENSHA_DIR/, err) # points at the likely cause
    end
  end

  def test_announce_can_be_silenced
    with_isolated_env do |dir|
      path = File.join(dir, "world.json")
      _out, err = capture_io { Boukensha::WorldModel.new(path: path, announce: false) }
      assert_empty err
    end
  end
end
