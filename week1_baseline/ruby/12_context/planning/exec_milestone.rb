# Executor subprocess: run ONE milestone task via Haiku, print the final reply.
# Its own process = its own MUD session, released on exit (no collision with the
# orchestrator's state reads).  argv: <task-file> [model]
ENV["BOUKENSHA_DIR"] ||= "/home/tim/claude-codecamp/.boukensha"
$LOAD_PATH.unshift File.expand_path("/home/tim/claude-codecamp/week1_baseline/ruby/12_context/lib")
require "boukensha"
task  = File.read(ARGV[0])
model = ARGV[1] || "claude-haiku-4-5"
reply = Boukensha.run(task: task, model: model, working_dir: false)
puts "===REPLY==="
puts reply
