# Runner for the planning orchestrator. WHO plays comes from BOUKENSHA_DIR (identity
# in config); WHAT they're asked to do comes from argv.
#
#   BOUKENSHA_DIR=<repo>/characters/hectic/.boukensha \
#     mise exec -- ruby week1_baseline/ruby/12_context/planning/run.rb "reach level 2"
#
# Pass --resume to continue an existing plan.json instead of replanning from scratch.
require_relative "orchestrator"

args  = ARGV.dup
fresh = !args.delete("--resume")
goal  = args.join(" ").strip

if goal.empty?
  abort "usage: run.rb [--resume] \"<goal>\"   (BOUKENSHA_DIR selects the character)"
end

puts "character: #{Plan::CHAR_NAME} the #{Plan::CHAR_CLASS} " \
     "(#{Plan::MUD[:name]}@#{Plan::MUD[:host]}:#{Plan::MUD[:port]})"
puts "config:    #{ENV['BOUKENSHA_DIR']}"
puts "goal:      #{goal}"
puts

Plan.orchestrate(goal, fresh: fresh)
