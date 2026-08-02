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
    # Sentinel neighbour value: an exit that exists but can't be walked (a closed
    # door / rock we tried and bounced off). Not nil, so it stops counting as an
    # unexplored frontier; not an id, so routing skips it. Keeps auto-explore from
    # hammering the same blocked exit forever.
    BLOCKED = "blocked".freeze

    # Normalise a movement direction (full word or short form) to its short form,
    # matching the letters CircleMUD prints in the "[ Exits: ... ]" line.
    SHORT = {
      "north" => "n", "south" => "s", "east" => "e", "west" => "w",
      "up" => "u", "down" => "d",
      "n" => "n", "s" => "s", "e" => "e", "w" => "w", "u" => "u", "d" => "d"
    }.freeze
    # Opposite short directions — used to infer the reverse of a walked edge.
    OPP = { "n" => "s", "s" => "n", "e" => "w", "w" => "e", "u" => "d", "d" => "u" }.freeze

    attr_reader :rooms, :current_fp, :path

    # Resolve the store path from the boukensha working dir (set by the launcher)
    # so world.json sits next to the session logs.
    #
    # BOUKENSHA_DIR is authoritative when set. Otherwise, rather than blindly
    # anchoring to Dir.pwd (which silently forks a SEPARATE map when you launch
    # from a subdirectory — the "stray map" footgun), walk up from the current
    # directory to the nearest ancestor that already holds a .boukensha/world.json
    # and use that, the way git finds its .git. Only when no map exists anywhere
    # upward do we fall back to creating one at Dir.pwd.
    def self.default_path
      return File.join(ENV["BOUKENSHA_DIR"], "world.json") if ENV["BOUKENSHA_DIR"]

      dir = Dir.pwd
      loop do
        candidate = File.join(dir, ".boukensha", "world.json")
        return candidate if File.exist?(candidate)

        parent = File.dirname(dir)
        break if parent == dir # reached filesystem root
        dir = parent
      end
      File.join(Dir.pwd, ".boukensha", "world.json")
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
          "id"          => (@next_id += 1),
          "name"        => room[:name],
          "description" => room[:description],  # stored so identity is recomputable
          "exits"       => {},  # direction => neighbour id (nil = unexplored frontier)
          "exit_names"  => {},  # direction => destination name (from the `exits` cmd)
          "edge_via"    => {},  # direction => how the edge was learned: walked | named
          "edge_cost"   => {},  # direction => observed movement-point cost (slice 5)
          "visits"      => 1,
          "first_seen"  => now
        }
        @rooms[fp] = entry
      end
      # Mutable room STATUS, refreshed every visit (identity stays fixed): which
      # exits are currently closed doors. This is the "update a room whose exits
      # change" mechanism — a door opening/closing updates status, not identity.
      entry["doors"] = room[:doors]
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

          # Infer the REVERSE edge so the map stays routable. If the room we just
          # arrived in advertises an exit back the opposite way and it's still an
          # open frontier, link it to where we came from. Only when the exit
          # actually exists (never invents a path through a one-way exit); a real
          # walked/named edge later overrides this lower-confidence guess. Without
          # this, route_to strands rooms we've clearly walked between.
          rev = OPP[d]
          if rev && entry["exits"].key?(rev) && entry["exits"][rev].nil?
            entry["exits"][rev]             = prev["id"]
            (entry["edge_via"] ||= {})[rev] = "inferred"
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

      # Global broadcasts (login announcements, channel chatter) can arrive
      # interleaved with a room read and land as the FIRST non-empty line — they must
      # NOT be taken as the room NAME (that pollutes the map with bogus rooms like
      # "A booming voice announces, 'Welcome Perry to the realm!'"). Skip them.
      broadcast_re = /\bannounces,|\bbooming voice\b|\bgossips?\b|\bauctions?\b|\bshouts?\b|\[\s*(?:gossip|auction|shout|newbie)\s*\]/i
      name_idx = lines.index { |l| !l.strip.empty? && l !~ broadcast_re }
      return nil unless name_idx && name_idx < exits_idx

      name = lines[name_idx].strip
      desc = lines[(name_idx + 1)...exits_idx]
             .map(&:strip).reject(&:empty?).join(" ")

      raw_exits = lines[exits_idx][/\[\s*Exits:\s*([^\]]*)\]/i, 1].to_s.strip
      tokens = raw_exits =~ /none/i ? [] : raw_exits.split(/\s+/)
      # A parenthesised token like "(w)" is a CLOSED door west. Normalise the
      # direction so a room keeps ONE identity whether its doors are open or
      # closed, and separately note which exits are currently closed doors — that
      # is mutable room STATUS, updated each visit, not part of identity.
      dirs  = tokens.map { |t| t.gsub(/[()]/, "").downcase }.reject(&:empty?).uniq.sort
      doors = tokens.select { |t| t.include?("(") }
                    .map { |t| t.gsub(/[()]/, "").downcase }.reject(&:empty?).uniq.sort

      { name: name, description: desc, exits: dirs, doors: doors }
    end

    # Slice 7c: render a room block compactly for the model. Strips ANSI, keeps
    # the name, exits, and the live "who/what is here" lines (mobs, items,
    # shopkeepers — decision-relevant and NOT in [memory]), and drops the raw
    # vitals prompt. The multi-line description is kept on a FIRST visit (nav
    # clues) but dropped on a revisit, where [memory] already gives name+id+exits
    # — unless `full:` is set (an explicit `look` = "show me this room"). Returns
    # nil when `raw` is not a room block, so non-room text is never distilled.
    def distill(raw, full: false)
      room = parse_room(raw)
      return nil unless room

      entry   = @current_fp && @rooms[@current_fp]
      revisit = entry && entry["visits"].to_i > 1

      clean     = raw.to_s.gsub(ANSI, "").gsub("\r\n", "\n").gsub("\r", "\n")
      lines     = clean.split("\n")
      exits_idx = lines.index { |l| l =~ /\[\s*Exits:/i }

      # Occupant/object lines follow the exits line. Drop blanks and the vitals
      # prompt ("23H 100M 63V (news) > ").
      here = (exits_idx ? lines[(exits_idx + 1)..] : []).to_a.reject do |l|
        s = l.strip
        s.empty? || s =~ /\d+H\s+\d+M\s+\d+V/ || s =~ /\A>+\s*\z/
      end.map(&:rstrip)

      out = [room[:name]]
      out << room[:description] if !room[:description].empty? && (full || !revisit)
      out << "[ Exits: #{room[:exits].join(' ')} ]"
      out.concat(here)
      out.join("\n")
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
        if tgt == BLOCKED then "#{d}→✕ (#{names[d] || 'blocked'})"
        elsif tgt         then "#{d}→##{tgt}"
        elsif names[d]    then "#{d}→? (#{names[d]})"
        else                   "#{d}→? (unexplored)"
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

    # ── Grind spots: where safe prey has been found ───────────────────────
    # Prey respawns, so a tag marks a good area to RETURN to (not a guaranteed
    # mob). Lets hunt route to known-good hunting instead of exploring blind.
    def mark_prey(tier:, note: nil, from_fp: @current_fp)
      room = from_fp && @rooms[from_fp]
      return unless room
      room["prey"] = { "tier" => tier.to_s, "note" => note.to_s, "last" => now }
      save
    end

    # Grind-spot room ids, most-recently-confirmed first.
    def prey_room_ids
      @rooms.values.select { |r| r["prey"] }
            .sort_by { |r| r.dig("prey", "last").to_s }.reverse.map { |r| r["id"] }
    end

    # BFS route to the nearest known grind spot reachable over walked edges.
    # Returns [directions, room_id] ([] dirs = we're already there), or nil.
    def nearest_prey_route(from_fp: @current_fp, exclude: [])
      best = nil
      (prey_room_ids - exclude).each do |id|
        rt = route_to(id, from_fp: from_fp)
        next if rt.nil?
        best = [rt, id] if best.nil? || rt.length < best[0].length
      end
      best
    end

    def prey_here?(from_fp: @current_fp)
      room = from_fp && @rooms[from_fp]
      !!(room && room["prey"])
    end

    # One-time repair: infer missing reverse edges across the whole map, so
    # route_to can traverse connections we only ever walked one way (the cause of
    # the "can't reach a room I've been to" fragmentation). Same rule as observe —
    # only where the opposite exit exists and is still unset. Returns the count.
    def backfill_reverse_edges
      added = 0
      @rooms.each_value do |a|
        (a["exits"] || {}).each do |d, tid|
          next unless tid.is_a?(Integer)
          rev = OPP[d]
          next unless rev
          b = room_by_id(tid)
          next unless b && (b["exits"] || {}).key?(rev) && b["exits"][rev].nil?
          b["exits"][rev]             = a["id"]
          (b["edge_via"] ||= {})[rev] = "inferred"
          added += 1
        end
      end
      save if added.positive?
      added
    end

    # Directions out of a room whose exit is advertised but not yet WALKED — the
    # frontier legs `explore` can step through to map new territory. Sorted for a
    # deterministic choice, and exits whose destination NAME is already known
    # (from the `exits` command) come first so exploration heads toward real,
    # named rooms before blind ones.
    def unexplored_dirs(from_fp: @current_fp)
      room = from_fp && @rooms[from_fp]
      return [] unless room
      names = room["exit_names"] || {}
      (room["exits"] || {}).select { |_d, tid| tid.nil? }.keys
                           .sort_by { |d| [names[d] ? 0 : 1, d] }
    end

    # Mark an exit non-traversable after a step through it bounced (closed door /
    # rock). Uses the exact exit key as stored (matches parse_room's tokens, e.g.
    # "d" or "(d)"). Afterwards it no longer counts as an unexplored frontier, so
    # explore/nearest_frontier skip it instead of retrying forever.
    def mark_blocked(exit_key, from_fp: @current_fp, reason: nil)
      room = from_fp && @rooms[from_fp]
      return nil unless room && (room["exits"] || {}).key?(exit_key)
      room["exits"][exit_key] = BLOCKED
      (room["exit_names"] ||= {})[exit_key] = reason.to_s.strip if reason && !reason.to_s.strip.empty?
      save
      exit_key
    end

    # ── Combat: finding prey ──────────────────────────────────────────────
    # The live "who/what is here" lines that follow the [ Exits ] line, minus
    # blanks, the vitals prompt, and any [memory] seam. Mobs are excluded from the
    # fingerprint on purpose, so we read them straight from raw text here.
    def occupant_lines(raw)
      clean = raw.to_s.gsub(ANSI, "").gsub("\r\n", "\n").gsub("\r", "\n")
      lines = clean.split("\n")
      ei = lines.index { |l| l =~ /\[\s*Exits:/i }
      return [] unless ei
      lines[(ei + 1)..].to_a.map(&:strip).reject do |s|
        s.empty? || s.start_with?("[memory]") ||
          s =~ /\d+H\s+\d+M\s+\d+V/ || s =~ /\A>+\s*\z/
      end
    end

    # Corpses and objects are not prey; their lines are skipped. (No /x flag —
    # extended mode would strip the literal spaces in "has been installed".)
    NON_PREY = /\bcorpse\b|\bremains\b|has\s+been\s+(?:installed|left|placed)|\bsigns?\b|\bcoins?\b|\bkeys?\b|is\s+lying\s+here|lies\s+here/i.freeze

    # Words that are never a mob's alias — dropped from keyword candidates so we
    # don't waste `consider` calls on them.
    CONSIDER_STOP = %w[
      the and are was were here its you your yours what just about around all over
      this that these those with but for from into onto out off down back
      they them their there where who whom how why when then than some any each
      perhaps maybe seems appears looks feels wonders wondering sneaking standing
      sitting resting sleeping flying floating hovering leaning lying moving crawling
      walking wandering slithering watching guarding taste like little funny thing
      things nice place really about here have has been
    ].freeze

    # Candidate keywords for `consider`, ordered by how likely the MUD is to match
    # them to a mob's alias list: parenthetical species hints first ("(a quasit
    # perhaps?)" → quasit), then capitalized proper nouns ("Minotaur"), then the
    # remaining longer content words. `consider <kw>` validates the real one.
    # Returns [{ line:, keywords: [...] }] for each live-creature line.
    def mob_keyword_sets(raw)
      occupant_lines(raw).reject { |l| l =~ NON_PREY }.map do |line|
        paren = line.scan(/\(([^)]*)\)/).flatten.join(" ").downcase.scan(/[a-z]{3,}/)
        cap   = line.split.each_with_index
                    .select { |w, i| i.positive? && w =~ /\A[A-Z][a-z]{2,}/ }
                    .map { |(w, _)| w.downcase }.sort_by { |w| -w.length }
        rest  = line.downcase.scan(/[a-z]{3,}/).sort_by { |w| -w.length }
        kws   = (paren + cap + rest).reject { |w| CONSIDER_STOP.include?(w) }.uniq
        { line: line, keywords: kws.first(6) }
      end.reject { |t| t[:keywords].empty? }
    end
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
