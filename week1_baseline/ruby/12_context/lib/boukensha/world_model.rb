# frozen_string_literal: true

require "digest"
require "json"
require "time"
require "fileutils"

module Boukensha
  # WorldModel is the agent's persistent memory of the rooms it has visited.
  #
  # Slice 1 (this file) does exactly one thing: recognition + visit counting.
  # Every time the agent looks at or moves into a room, `observe` parses the raw
  # MUD text, gives the room a stable identity (a content FINGERPRINT), assigns a
  # small integer id the first time it's seen, counts the visit, and returns a
  # one-line `[memory]` summary that the caller appends to the tool result so the
  # agent is reminded "you've been here before".
  #
  # Deliberately NOT in slice 1 (they slot into this same structure later):
  #   - edges between rooms (slice 2): the graph / adjacency list
  #   - plan_route / BFS pathfinding (slice 3)
  #   - neighbour-name + arrival-edge disambiguation for near-identical rooms.
  #
  # Identity note: slice 1 uses the PLAIN content fingerprint on purpose. A few
  # rooms in this MUD (the two centre-of-Midgaard "twins") share name +
  # description + exits and WILL collide onto one id. That collision is the first
  # experiment — we want to see it before we fix it with the topological
  # tiebreaker in slice 1b.
  class WorldModel
    ANSI = /\e\[[0-9;?]*[ -\/]*[@-~]/.freeze

    # Normalise a movement direction (full word or short form) to its short form,
    # matching the letters CircleMUD prints in the "[ Exits: ... ]" line.
    SHORT = {
      "north" => "n", "south" => "s", "east" => "e", "west" => "w",
      "up" => "u", "down" => "d",
      "n" => "n", "s" => "s", "e" => "e", "w" => "w", "u" => "u", "d" => "d"
    }.freeze

    attr_reader :rooms, :current_fp, :path

    # Resolve the store path from the boukensha working dir (set by the launcher)
    # so world.json sits next to the session logs.
    def self.default_path
      dir = ENV["BOUKENSHA_DIR"] || File.join(Dir.pwd, ".boukensha")
      File.join(dir, "world.json")
    end

    def initialize(path: self.class.default_path)
      @path       = path
      @rooms      = {}   # fingerprint => room hash
      @next_id    = 0
      @current_fp = nil
      load
    end

    # Observe a room from raw MUD text. Returns a one-line `[memory]` summary, or
    # nil when the text is not a room block (e.g. a failed move or a look at an
    # item) — in which case the caller appends nothing and nothing is recorded.
    #
    # arrived_via is accepted now but unused until slice 2 (edge recording).
    def observe(raw, arrived_via: nil)
      room = parse_room(raw)
      return nil unless room

      fp      = fingerprint(room)
      prev_fp = @current_fp
      entry   = @rooms[fp]

      if entry
        entry["visits"] += 1
        status = "known"
      else
        entry = {
          "id"         => (@next_id += 1),
          "name"       => room[:name],
          "exits"      => {},   # direction => neighbour id (nil = unexplored frontier)
          "visits"     => 1,
          "first_seen" => now
        }
        @rooms[fp] = entry
        status = "new"
      end

      # Every exit the room advertises becomes a key; an unwalked one keeps a nil
      # target and is therefore part of the frontier.
      room[:exits].each { |d| entry["exits"][d] = nil unless entry["exits"].key?(d) }

      # Record the directed edge we just traversed: prev --arrived_via--> here.
      # Only on a real transition from a known previous room (slice 2). Directed
      # on purpose — we never assume the reverse edge until we walk it.
      if arrived_via && prev_fp && prev_fp != fp && (prev = @rooms[prev_fp])
        d = SHORT[arrived_via.to_s.strip.downcase]
        prev["exits"][d] = entry["id"] if d
      end

      entry["last_seen"] = now
      @current_fp = fp
      save

      times = entry["visits"] == 1 ? "first visit" : "visited #{entry['visits']}×"
      %([memory] Room ##{entry['id']} "#{room[:name]}" — #{times} (#{status}). #{exits_summary(entry)})
    end

    # Parse raw MUD room text into { name:, description:, exits: [sorted dirs] }.
    # Returns nil if there is no room block (no "[ Exits: ... ]" line).
    def parse_room(raw)
      text  = raw.to_s.gsub(ANSI, "").gsub("\r\n", "\n").gsub("\r", "\n")
      lines = text.split("\n")

      exits_idx = lines.index { |l| l =~ /\[\s*Exits:/i }
      return nil unless exits_idx

      name_idx = lines.index { |l| !l.strip.empty? }
      return nil unless name_idx && name_idx < exits_idx

      name = lines[name_idx].strip
      desc = lines[(name_idx + 1)...exits_idx]
             .map(&:strip).reject(&:empty?).join(" ")

      raw_exits = lines[exits_idx][/\[\s*Exits:\s*([^\]]*)\]/i, 1].to_s.strip
      dirs = raw_exits =~ /none/i ? [] : raw_exits.split(/\s+/)

      { name: name, description: desc, exits: dirs.sort }
    end

    # Stable content identity: name + description + exit directions. Mobs and
    # objects are excluded by construction (parse_room drops them), so a room's
    # fingerprint does not change when NPCs move around.
    def fingerprint(room)
      src = [room[:name], room[:description], room[:exits].join(",")].join("|")
      Digest::SHA256.hexdigest(src)[0, 12]
    end

    def room_count = @rooms.size

    # Human-readable exit summary: known neighbours as "dir→#id", unwalked exits
    # as "dir→? (unexplored)", plus a count of how many are still frontier.
    def exits_summary(entry)
      ex = entry["exits"] || {}
      return "Exits: none." if ex.empty?

      parts = ex.keys.sort.map do |d|
        tgt = ex[d]
        tgt ? "#{d}→##{tgt}" : "#{d}→? (unexplored)"
      end
      open = ex.values.count(&:nil?)
      "Exits: #{parts.join(', ')}." + (open.positive? ? " [#{open} unexplored]" : "")
    end

    # The exploration frontier: every room that still has at least one unwalked
    # exit. Slice 3's plan_route uses this when the destination isn't known yet.
    def frontier
      @rooms.values.select { |r| (r["exits"] || {}).values.any?(&:nil?) }
    end

    private

    def now = Time.now.utc.iso8601

    def load
      return unless File.exist?(@path)

      data     = JSON.parse(File.read(@path))
      @rooms   = data["rooms"] || {}
      # Migrate slice-1 stores: exits saved as a plain array of directions become
      # the slice-2 map { direction => neighbour id | nil }.
      @rooms.each_value do |r|
        r["exits"] = r["exits"].to_h { |d| [d, nil] } if r["exits"].is_a?(Array)
      end
      @next_id = data["next_id"] || @rooms.values.map { |r| r["id"].to_i }.max || 0
    rescue JSON::ParserError, Errno::ENOENT => e
      warn "[boukensha] world_model load failed (#{e.message}); starting empty"
      @rooms   = {}
      @next_id = 0
    end

    def save
      FileUtils.mkdir_p(File.dirname(@path))
      File.write(@path, JSON.pretty_generate("next_id" => @next_id, "rooms" => @rooms))
    rescue StandardError => e
      warn "[boukensha] world_model save failed: #{e.message}"
    end
  end
end
