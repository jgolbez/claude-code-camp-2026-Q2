#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Play the MUD with boukensha, using the LOCAL 12_context source (which carries
# the thief tools + combat distillation). The CHARACTER is not defined here — it
# comes entirely from the config dir (settings.yaml `mud:` block + prompts/
# system.md). Point at a different config dir to play a different character.
#
#   # put ANTHROPIC_API_KEY in <config-dir>/.env, then:
#   mise exec -- ruby week1_baseline/ruby/12_context/examples/play_mud.rb
#
#   # or an explicit config dir (one dir per character):
#   BOUKENSHA_DIR=/path/to/.boukensha mise exec -- ruby .../play_mud.rb
#
# Then give it a goal at the prompt, e.g.
#   "get to the newbie area north of Midgaard and reach level 2".

# Default config dir = repo-root .boukensha (…/claude-codecamp/.boukensha).
ENV["BOUKENSHA_DIR"] ||= File.expand_path("../../../../.boukensha", __dir__)

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "boukensha"

cfg = Boukensha.config
warn "config dir: #{cfg.dir}"
warn "model:      #{cfg.model}"
warn "character:  #{cfg.mud_username}@#{cfg.mud_host}:#{cfg.mud_port}"
warn "API key:    #{ENV['ANTHROPIC_API_KEY'].to_s.strip.empty? ? '✗ NOT SET' : '✓ set'}"
warn ""

Boukensha.repl(
  working_dir: false,   # MUD play only — no filesystem/shell tools
  tui:         false     # plain REPL; set true for the fullscreen TUI
)
