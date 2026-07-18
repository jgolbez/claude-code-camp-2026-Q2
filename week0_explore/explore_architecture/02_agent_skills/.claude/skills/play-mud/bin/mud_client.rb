#!/usr/bin/env ruby
# frozen_string_literal: true
#
# play-mud client — send ONE command to the running daemon and print the reply.
# Stateless: the agent calls this once per turn. The live connection lives in
# the daemon (mud_daemon.rb), not here.
#
#   bin/mud look
#   bin/mud "backstab rat"
#   bin/mud /status
#   bin/mud /quit
#
# Env: MUD_SOCK (default /tmp/play-mud.sock)

require "socket"

SOCK = ENV.fetch("MUD_SOCK", "/tmp/play-mud.sock")
ANSI = /\e\[[0-9;?]*[ -\/]*[@-~]/

cmd = ARGV.join(" ")
if cmd.empty? && !$stdin.tty?
  cmd = $stdin.read.strip
end

begin
  sock = UNIXSocket.new(SOCK)
rescue Errno::ENOENT, Errno::ECONNREFUSED
  warn "play-mud: no daemon at #{SOCK}. Start it first, e.g.:"
  warn "  bin/mud-daemon &   # (or run via your background-task tool)"
  exit 2
end

sock.write(cmd + "\n")
sock.close_write
out = sock.read.to_s
sock.close

# Strip ANSI colour codes for a clean read; the MUD's layout is preserved.
print out.gsub(ANSI, "")
print "\n" unless out.end_with?("\n")
