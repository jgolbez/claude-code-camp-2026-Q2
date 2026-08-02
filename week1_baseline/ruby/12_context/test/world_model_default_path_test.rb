require_relative "test_helper"
require "boukensha/world_model"

# Regression guard for the "stray map" footgun: launching from a subdirectory
# with BOUKENSHA_DIR unset used to fork a SEPARATE world.json under that dir,
# which looked like "travel_to / recall is broken" but was really a different,
# near-empty map. default_path now walks up to the nearest existing map, the way
# git finds its .git. These three cases pin that resolution order.
class WorldModelDefaultPathTest < Minitest::Test
  def test_boukensha_dir_is_authoritative_regardless_of_cwd
    with_isolated_env do
      ENV["BOUKENSHA_DIR"] = "/some/explicit/boukensha"
      # Even standing in an unrelated tmpdir, the explicit dir wins outright.
      assert_equal "/some/explicit/boukensha/world.json",
                   Boukensha::WorldModel.default_path
    end
  end

  def test_walks_up_to_the_nearest_ancestor_map
    with_isolated_env do |root|
      # A map lives at the top of the tree...
      map = File.join(root, ".boukensha", "world.json")
      FileUtils.mkdir_p(File.dirname(map))
      File.write(map, "{}")

      # ...and we launch from several directories deeper, with no map in between.
      deep = File.join(root, "week1", "ruby", "12_context")
      FileUtils.mkdir_p(deep)
      Dir.chdir(deep) do
        assert_equal File.realpath(map),
                     File.realpath(Boukensha::WorldModel.default_path),
                     "should resolve to the ancestor map, not fork a new one here"
      end
    end
  end

  def test_falls_back_to_cwd_when_no_map_exists_upward
    with_isolated_env do |tmp|
      # No .boukensha anywhere up to the filesystem root: create one right here.
      expected = File.join(Dir.pwd, ".boukensha", "world.json")
      assert_equal expected, Boukensha::WorldModel.default_path
      refute File.exist?(expected), "resolving a path must not create the file"
    end
  end
end
