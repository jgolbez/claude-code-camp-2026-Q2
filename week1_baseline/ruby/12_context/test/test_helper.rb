# Shared test setup for the boukensha suite.
#
# Guard rail baked in once: any test that constructs a WorldModel (which SAVES
# on observe) must point it at a throwaway path, never the real .boukensha map.
# `with_isolated_env` also snapshots/restores ENV["BOUKENSHA_DIR"] and cwd so a
# test that chdirs or sets the boukensha dir can't leak into the next one.
require "minitest/autorun"
require "tmpdir"
require "fileutils"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

module BoukenshaTestHelpers
  # Run the block in a fresh tmpdir with BOUKENSHA_DIR cleared, restoring both
  # the working directory and the env var afterwards. Yields the tmpdir path.
  def with_isolated_env
    saved_dir = ENV["BOUKENSHA_DIR"]
    ENV.delete("BOUKENSHA_DIR")
    Dir.mktmpdir do |tmp|
      Dir.chdir(tmp) { yield tmp }
    end
  ensure
    if saved_dir.nil?
      ENV.delete("BOUKENSHA_DIR")
    else
      ENV["BOUKENSHA_DIR"] = saved_dir
    end
  end
end

module Minitest
  class Test
    include BoukenshaTestHelpers
  end
end
