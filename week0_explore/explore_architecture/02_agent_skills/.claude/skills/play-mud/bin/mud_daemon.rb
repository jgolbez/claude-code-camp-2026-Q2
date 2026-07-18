#!/usr/bin/env ruby
# frozen_string_literal: true
#
# play-mud session daemon — the ONE live connection to the MUD.
#
# CircleMUD/tbaMUD permits a single connection per character, and a telnet
# session cannot survive across an agent's separate tool calls (each is a fresh
# process). So this daemon holds the connection: it logs in once via the
# mud_manager gem, then listens on a Unix domain socket. The agent sends one
# command per call through bin/mud (mud_client.rb); the daemon relays it to the
# live session and returns the MUD's response. It is the single owner of the
# connection — do not open a second one (mud-login, nc, another daemon) while it
# runs, or the MUD will kick one of them.
#
# Env (all optional; defaults suit the local dev MUD):
#   MUD_HOST=localhost  MUD_PORT=4000
#   MUD_NAME=dummy      MUD_PASSWORD=helloworld
#   MUD_SOCK=/tmp/play-mud.sock

require "socket"
require "mud_manager"

HOST = ENV.fetch("MUD_HOST", "localhost")
PORT = Integer(ENV.fetch("MUD_PORT", "4000"))
NAME = ENV.fetch("MUD_NAME", "dummy")
PASS = ENV.fetch("MUD_PASSWORD", "helloworld")
SOCK = ENV.fetch("MUD_SOCK", "/tmp/play-mud.sock")

$stdout.sync = true
$stderr.sync = true

def log(msg)
  warn "[mud-daemon #{Time.now.strftime('%H:%M:%S')}] #{msg}"
end

session = MudManager::Session.new(host: HOST, port: PORT)
begin
  session.open
  log "connected #{HOST}:#{PORT}; logging in as #{NAME}"
  session.login(NAME, PASS)
  # login() already reads through to the game prompt. Grab whatever entry-room
  # text is buffered without blocking on a prompt that may already be consumed
  # (a long read_until_prompt here would just stall ~8s and warn).
  entry = (session.read_until_quiet(0.5) rescue (session.drain rescue ""))
  log "logged in. entry room:\n#{entry.gsub(/\e\[[0-9;?]*[ -\/]*[@-~]/, '')}"
rescue => e
  log "FATAL login failed: #{e.class}: #{e.message}"
  session.close rescue nil
  exit 1
end

File.delete(SOCK) if File.exist?(SOCK)
server = UNIXServer.new(SOCK)
File.chmod(0o600, SOCK)
log "listening on #{SOCK} — ready for commands"

shutdown = lambda do
  session.close rescue nil
  File.delete(SOCK) if File.exist?(SOCK)
  log "shutdown"
  exit 0
end
trap("TERM") { shutdown.call }
trap("INT")  { shutdown.call }

# Send a command and return its response. Critically, we DRAIN first: any
# async output buffered since the last turn (a mob wandering in, combat rounds,
# a `tell`) carries its OWN prompt, and read_until_prompt would otherwise stop
# at that stale prompt and hand back the async text instead of this command's
# actual result. Draining first clears that, so read_until_prompt reads a clean
# response — and the drained events are prepended as labeled context so nothing
# is lost. This is the mud_manager-prescribed drain → send → read pattern.
send_and_read = lambda do |send_arg|
  pending = (session.drain rescue "")
  session.send_command(send_arg)
  resp = session.read_until_prompt(timeout: 10)
  if pending.strip.empty?
    resp
  else
    "[async events since your last command]\n#{pending.strip}\n--- (response below) ---\n#{resp}"
  end
end

# Control tokens (prefixed to avoid colliding with MUD verbs):
#   /ping    — liveness check
#   /status  — is the session still open?
#   /poll    — return async output that arrived since the last read, without
#              sending anything (useful mid-combat / to catch room events)
#   /raw X   — send X literally (escape hatch; identical to sending X directly)
#   /quit    — quit the character cleanly, then stop the daemon
# Anything else is sent to the MUD verbatim as a command line.
running = true
while running
  client = server.accept
  req = (client.gets&.chomp).to_s
  begin
    case req
    when "/ping"
      client.write "pong\n"
    when "/status"
      client.write(session.open? ? "open #{HOST}:#{PORT} as #{NAME}\n" : "closed\n")
    when "/poll"
      client.write(session.drain)
    when "/quit"
      (session.send_command(MudManager::Primitives.quit) rescue nil)
      client.write "quitting\n"
      running = false
    when ""
      client.write(send_and_read.call(:return)) # bare carriage return (menus/prompts)
    else
      cmd = req.start_with?("/raw ") ? req.sub("/raw ", "") : req
      client.write(send_and_read.call(cmd))
    end
  rescue => e
    client.write("ERROR: #{e.class}: #{e.message}\n")
    log "error handling #{req.inspect}: #{e.class}: #{e.message}"
  ensure
    client.close
  end
end

session.close rescue nil
File.delete(SOCK) if File.exist?(SOCK)
log "stopped"
