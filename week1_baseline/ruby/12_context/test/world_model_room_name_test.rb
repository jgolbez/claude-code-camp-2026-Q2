require_relative "test_helper"
require "boukensha/world_model"

# The room NAME is the first non-empty line of a room block — which makes it easy
# to poison, because the MUD prepends its own lines to that block. A global
# broadcast was already filtered; the MUD's over-level warning was not, and it
# produced a map room literally named "This zone is above your recommended
# level." whose description began with the real name it had displaced.
class WorldModelRoomNameTest < Minitest::Test
  def world(dir)
    w = nil
    capture_io { w = Boukensha::WorldModel.new(path: File.join(dir, "world.json")) }
    w
  end

  OVERLEVEL = <<~ROOM
    This zone is above your recommended level.
    The City Entrance
       You stand on the outskirts of a large city - Midgaard; the capital of this
    land.
    [ Exits: e w ]

    21H 100M 84V (news) (motd) >
  ROOM

  BROADCAST = <<~ROOM
    A booming voice announces, 'Welcome Hectic to the realm!'
    The Temple Of Midgaard
       You are in the southern end of the temple hall.
    [ Exits: n e s w d ]

    21H 100M 84V (news) (motd) >
  ROOM

  def test_overlevel_warning_is_not_taken_as_the_room_name
    with_isolated_env do |dir|
      w = world(dir)
      room = w.parse_room(OVERLEVEL)
      assert_equal "The City Entrance", room[:name]
      refute_match(/recommended level/i, room[:description],
                   "the warning must be dropped, not shoved into the description")
    end
  end

  def test_overlevel_room_maps_under_its_real_name
    with_isolated_env do |dir|
      w = world(dir)
      w.observe(OVERLEVEL)
      assert_equal ["The City Entrance"], w.rooms.values.map { |r| r["name"] }
    end
  end

  def test_the_same_room_has_one_identity_with_or_without_the_warning
    with_isolated_env do |dir|
      w = world(dir)
      w.observe(OVERLEVEL)
      w.observe(OVERLEVEL.sub("This zone is above your recommended level.\n", ""))
      assert_equal 1, w.rooms.size, "the warning must not fork a room into two identities"
      assert_equal 2, w.rooms.values.first["visits"]
    end
  end

  def test_broadcast_filter_still_works
    with_isolated_env do |dir|
      w = world(dir)
      assert_equal "The Temple Of Midgaard", w.parse_room(BROADCAST)[:name]
    end
  end
end
