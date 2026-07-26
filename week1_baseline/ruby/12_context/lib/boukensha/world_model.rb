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
    def observe(raw, arrived_via: nil, move_cost: nil)
      room = parse_room(raw)
      return nil unless room

      fp      = fingerprint(room)
      prev_fp = @current_fp
      entry   = @rooms[fp]

      if entry
        entry["visits"] += 1
      else
        entry = {
          "id"         => (@next_id += 1),
          "name"       => room[:name],
          "exits"      => {},   # direction => neighbour id (nil = unexplored frontier)
          "exit_names" => {},   # direction => destination name (from the `exits` cmd)
          "edge_via"   => {},   # direction => how the edge was learned: walked | named
          "edge_cost"  => {},   # direction => observed movement-point cost (slice 5)
          "visits"     => 1,
          "first_seen" => now
        }
        @rooms[fp] = entry
      end
      entry["exit_names"] ||= {}
      entry["edge_via"]   ||= {}
      entry["edge_cost"]  ||= {}

      # Slice 6: tag resource sources actually observed here (a fountain gives
      # water; a bakery sells food) so upkeep can route to a real source rather
      # than guessing from room names. Scan the FULL text — a fountain shows up in
      # the object lines, which the fingerprint description deliberately drops.
      full = raw.to_s.gsub(ANSI, "")
      res  = []
      res << "water" if full =~ /fountain/i
      res << "food"  if entry["name"].to_s =~ /bakery/i
      entry["resource"] = ((entry["resource"] || []) | res) unless res.empty?

      # Every exit the room advertises becomes a key; an unwalked one keeps a nil
      # target and is therefore part of the frontier.
      room[:exits].each { |d| entry["exits"][d] = nil unless entry["exits"].key?(d) }

      # Record the directed edge we just traversed: prev --arrived_via--> here.
      # Only on a real transition from a known previous room (slice 2). Directed
      # on purpose — we never assume the reverse edge until we walk it. A walked
      # edge is authoritative: it overrides any earlier `named` guess.
      if arrived_via && prev_fp && prev_fp != fp && (prev = @rooms[prev_fp])
        d = SHORT[arrived_via.to_s.strip.downcase]
        if d
          prev["exits"][d]              = entry["id"]
          (prev["edge_via"] ||= {})[d]  = "walked"
          # Slice 5: record the movement cost of this edge. Keep the largest
          # observed drop — tick regen only makes a drop look smaller, so the max
          # is the safe (conservative) estimate of the true cost.
          if move_cost && move_cost.positive?
            ec = (prev["edge_cost"] ||= {})
            ec[d] = [ec[d].to_i, move_cost].max
          end
        end
      end

      entry["last_seen"] = now
      @current_fp = fp
      save
      current_memory_line
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

    # The [memory] line for the room the agent is currently in.
    def current_memory_line
      return nil unless @current_fp && (entry = @rooms[@current_fp])
      status = entry["visits"] == 1 ? "new" : "known"
      times  = entry["visits"] == 1 ? "first visit" : "visited #{entry['visits']}×"
      %([memory] Room ##{entry['id']} "#{entry['name']}" — #{times} (#{status}). #{exits_summary(entry)})
    end

    # Human-readable exit summary. A mapped neighbour shows as "dir→#id"; an
    # unwalked exit whose destination NAME we know (from `exits`) shows as
    # "dir→? (Name)"; a truly unknown exit shows as "dir→? (unexplored)".
    def exits_summary(entry)
      ex = entry["exits"] || {}
      return "Exits: none." if ex.empty?
      names = entry["exit_names"] || {}

      parts = ex.keys.sort.map do |d|
        tgt = ex[d]
        if tgt          then "#{d}→##{tgt}"
        elsif names[d]  then "#{d}→? (#{names[d]})"
        else                 "#{d}→? (unexplored)"
        end
      end
      open = ex.values.count(&:nil?)
      "Exits: #{parts.join(', ')}." + (open.positive? ? " [#{open} unexplored]" : "")
    end

    # Parse `exits` command output into { short_dir => destination_name }.
    # Lines look like "south - Main Street" / "north - The Bakery".
    def parse_exits(text)
      out = {}
      text.to_s.gsub(ANSI, "").each_line do |line|
        if line =~ /^\s*(north|south|east|west|up|down)\b\s*[-:]\s*(.+?)\s*$/i
          d  = SHORT[Regexp.last_match(1).downcase]
          nm = Regexp.last_match(2).strip
          out[d] = nm if d && !nm.empty?
        end
      end
      out
    end

    # Slice 4: record NAMED edges for the current room from the game's own exit
    # destinations. This reads connectivity rather than *assuming* the reverse
    # edge exists. A named edge resolves to a known room only on an unambiguous
    # exact-name match, never overwrites a walked edge, and self-corrects when the
    # exit is actually traversed (observe then records the true walked edge).
    def record_named_edges(exits_map)
      return unless @current_fp && (room = @rooms[@current_fp])
      room["exit_names"] ||= {}
      room["edge_via"]   ||= {}

      exits_map.each do |dir, name|
        next if name.nil? || name =~ /too\s+dark/i
        room["exits"][dir] = nil unless room["exits"].key?(dir)
        room["exit_names"][dir] = name
        next if room["edge_via"][dir] == "walked" # keep authoritative edges

        matches = @rooms.values.select { |r| r["name"].to_s.casecmp?(name) }
        # An exit whose destination name matches the CURRENT room is almost always
        # a duplicate-named neighbour (e.g. the "Main Street" corridor), not a real
        # self-loop — drop the self-match so we don't fabricate one.
        matches = matches.reject { |r| r["id"] == room["id"] } if name.casecmp?(room["name"].to_s)

        if matches.size == 1
          room["exits"][dir]    = matches.first["id"]
          room["edge_via"][dir] = "named"
        elsif matches.size > 1
          room["edge_via"][dir] = "ambiguous"      # leave as frontier; resolve on walk
        else
          room["edge_via"][dir] = "named-frontier" # know the name, room not yet mapped
        end
      end
      save
    end

    # The exploration frontier: every room that still has at least one unwalked
    # exit. Slice 3's plan_route uses this when the destination isn't known yet.
    def frontier
      @rooms.values.select { |r| (r["exits"] || {}).values.any?(&:nil?) }
    end

    # ── Slice 3: pathfinding ────────────────────────────────────────────────

    def rooms_with_resource(kind) = @rooms.values.select { |r| (r["resource"] || []).include?(kind) }
    def room_by_id(id) = @rooms.values.find { |r| r["id"] == id }
    def name_for_id(id) = room_by_id(id)&.dig("name")
    def fp_for_id(id)
      @rooms.each { |fp, r| return fp if r["id"] == id }
      nil
    end

    def current_id
      @current_fp && @rooms[@current_fp] ? @rooms[@current_fp]["id"] : nil
    end

    # Resolve a destination query to a room id. Accepts "#5"/"5" (an id) or a
    # case-insensitive name substring. When several rooms match a name, pick the
    # one with the shortest known route from the current room.
    def resolve_destination(query, from_fp: @current_fp)
      q = query.to_s.strip
      if q =~ /\A#?(\d+)\z/
        id = Regexp.last_match(1).to_i
        return room_by_id(id) ? id : nil
      end

      ql = q.downcase
      # An exact (whole-name) match wins outright; otherwise fall back to a
      # substring search. This keeps full names like "Market Square"
      # unambiguous while still accepting shorthand like "market".
      exact   = @rooms.values.select { |r| r["name"].to_s.downcase == ql }
      matches = exact.empty? ? @rooms.values.select { |r| r["name"].to_s.downcase.include?(ql) } : exact
      return nil if matches.empty?
      return matches.first["id"] if matches.size == 1

      # Ambiguous name: choose the closest reachable match from where we are.
      scored = matches.map { |r| [r["id"], route_to(r["id"], from_fp: from_fp)] }
                      .reject { |(_, path)| path.nil? }
      return matches.first["id"] if scored.empty?
      scored.min_by { |(_, path)| path.length }.first
    end

    # BFS shortest route (list of directions) from a room to a target id, over
    # the KNOWN graph (walked edges only). Returns [] if already there, nil if
    # the target isn't reachable within what we've mapped.
    def route_to(target_id, from_fp: @current_fp)
      return nil unless from_fp && (start = @rooms[from_fp])
      return [] if start["id"] == target_id

      visited = { from_fp => true }
      queue   = [[from_fp, []]]
      until queue.empty?
        fp, path = queue.shift
        (@rooms[fp]["exits"] || {}).each do |dir, tid|
          next if tid.nil?
          return path + [dir] if tid == target_id
          tfp = fp_for_id(tid)
          next if tfp.nil? || visited[tfp]
          visited[tfp] = true
          queue << [tfp, path + [dir]]
        end
      end
      nil
    end

    # Estimate a route's total movement-point cost by summing per-edge costs
    # along it. Unknown-cost edges fall back to `default` and are counted, so the
    # caller can see how confident the estimate is. Returns
    # { total:, unknown:, steps: }.
    def route_cost(dirs, from_fp: @current_fp, default: 1)
      return { total: 0, unknown: 0, steps: 0 } if dirs.nil? || dirs.empty?

      fp = from_fp
      total = 0
      unknown = 0
      steps = 0
      dirs.each do |d|
        room = fp && @rooms[fp]
        break unless room
        c = (room["edge_cost"] || {})[d]
        if c.nil? || c <= 0
          unknown += 1
          total   += default
        else
          total += c
        end
        steps += 1
        nid = (room["exits"] || {})[d]
        fp  = nid ? fp_for_id(nid) : nil
        break if fp.nil?
      end
      { total: total, unknown: unknown, steps: steps }
    end

    # BFS to the nearest room that still has an unexplored exit. Returns
    # [directions, frontier_room_id], or nil if nothing is left to explore.
    def nearest_frontier_route(from_fp: @current_fp)
      return nil unless from_fp && @rooms[from_fp]

      visited = { from_fp => true }
      queue   = [[from_fp, []]]
      until queue.empty?
        fp, path = queue.shift
        room = @rooms[fp]
        return [path, room["id"]] if (room["exits"] || {}).values.any?(&:nil?)
        room["exits"].each do |dir, tid|
          next if tid.nil?
          tfp = fp_for_id(tid)
          next if tfp.nil? || visited[tfp]
          visited[tfp] = true
          queue << [tfp, path + [dir]]
        end
      end
      nil
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
