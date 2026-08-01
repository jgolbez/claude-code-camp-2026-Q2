require "mud_manager"
require_relative "mud_text"
require_relative "../world_model"
require_relative "../skills"

module Boukensha
  module Tools
    # Mud registers MUD-gameplay tools against a registry.
    #
    # A single MudManager::Session is created when the tools are registered and
    # shared by every tool via closure — the agent logs in once and reuses the
    # connection for all subsequent tool calls.
    #
    # Tools registered (grouped by concern):
    #
    #   Connection
    #     mud_connect       — open socket and log in
    #     mud_disconnect    — close socket gracefully
    #     mud_status        — report whether the session is open
    #
    #   Perception
    #     look              — look at the room or a specific target
    #     examine           — examine something in detail
    #     check             — query self-info (score, inventory, equipment, exits, gold…)
    #
    #   Movement
    #     move              — go a compass direction or up/down
    #     flee              — flee from combat
    #     set_position      — change body position (stand/sit/rest/sleep/wake)
    #     track             — track a mob or player by name to find their direction
    #
    #   Combat
    #     attack            — attack a target (kill / hit / murder)
    #     skill_strike      — use a combat skill (bash, kick, backstab, rescue, assist)
    #     consider          — assess a mob's relative strength before fighting
    #
    #   Communication
    #     say               — say/emote/reply in the room
    #     tell              — tell/whisper/ask a specific player
    #     channel_say       — broadcast over a channel (shout, gossip, auction…)
    #
    #   Inventory & equipment
    #     get_item          — pick up an item (optionally from a container)
    #     drop_item         — drop, donate, or junk an item
    #     put_item          — put an item into a container
    #     equip_item        — wear, wield, hold, grab, or remove an item
    #     consume_item      — eat, drink, taste, or sip something
    #
    #   Magic
    #     cast_spell        — cast a named spell with an optional target
    #     use_magic_item    — quaff a potion, recite a scroll, or use a wand/staff
    #
    #   Utility
    #     shop              — buy, sell, list, or value items at a shop
    #     practice          — list or practice a skill with a guildmaster
    #     save_character    — save the character to disk
    #     send_raw          — send an arbitrary command string (escape hatch)
    #
    # Usage:
    #
    #   Boukensha::Tools::Mud.register(
    #     registry,
    #     host:     "localhost",
    #     port:     4000,
    #     name:     "Gandalf",
    #     password: "secret"
    #   )
    #
    module Mud
      def self.register(registry, host: "localhost", port: 4000, name:, password:)
        session = MudManager::Session.new(host: host, port: port)
        p       = MudManager::Primitives

        # Slice 1 world-model: recognises rooms and counts visits. Shared by the
        # movement/perception tools via closure, same as the session.
        world = WorldModel.new

        # Send a primitive command and return the MUD's response text.
        # Raises if the session is not open.
        #
        # We drain any stale buffered bytes (leftover login output, async ticks,
        # etc.) before sending so that read_until_prompt sees only fresh data
        # produced by this command. Then we wait for CircleMUD's "> " prompt
        # sentinel, which the server always appends at the end of a response.
        # Bytes drained just before the last command. Kept so the upkeep reflex
        # can see async server pushes (hunger/thirst ticks) that arrived while idle
        # — which drain would otherwise silently discard before we read them.
        last_drained = ""

        send_cmd = lambda do |command|
          last_drained = session.drain.to_s
          session.send_command(command)
          session.read_until_prompt
        end

        # Leave the game GRACEFULLY. The in-game `quit` command saves the character
        # and extracts it from the world, so — unlike a bare socket close, which
        # leaves the body LINK-DEAD in the room where aggressive mobs can kill it —
        # no attackable body is left behind. We must NOT wait for a "> " prompt here:
        # `quit` drops the connection, so read_until_prompt would block. Instead we
        # send, briefly let the goodbye arrive, drain it, and close. Best-effort:
        # if the character can't quit (e.g. mid-combat) the server rejects it and the
        # socket close still happens, so this is never worse than mud_disconnect.
        quit_cleanly = lambda do
          out = ""
          begin
            session.drain
            session.send_command("quit")
            sleep 0.4
            out = session.drain.to_s
          rescue => e
            out = "quit note: #{e.message}"
          ensure
            session.close rescue nil
          end
          out
        end

        # Send a command that produces combat output and return a DISTILLED
        # result: round-by-round attack flavor is collapsed to a count, while
        # outcomes (death, xp, loot, level, "mortally wounded", flee) and the
        # final vitals are kept. This is the token-efficiency lever for combat —
        # the agent decides from "enemy stunned, HP 19", not 20 lines of spam.
        combat_cmd = lambda do |command|
          MudText.combat(send_cmd.call(command))
        end

        # Return an error string if the session is not open so the agent
        # can decide whether to call mud_connect first.
        guard = lambda do
          unless session.open?
            "error: not connected — call mud_connect first"
          end
        end

        # Feed room text to the world-model and, if it recognises a room, append
        # a one-line [memory] note to the tool result. Never lets a memory error
        # break gameplay — the raw text is always returned.
        # Track the last-seen movement points (V in the vitals prompt) so we can
        # measure each move's cost and check trip feasibility (slice 5).
        move_pts = nil
        parse_v  = lambda do |text|
          m = MudText.strip_ansi(text.to_s).scan(/(\d+)H\s+(\d+)M\s+(\d+)V/).last
          m && m[2].to_i
        end

        # Slice 6: survival upkeep reflex. The MUD pushes "You are hungry" /
        # "You are thirsty" each tick while in that state; when we see it in any
        # output we read, eat/drink a held item automatically (deterministic, no
        # LLM). When nothing is on hand, append a [upkeep] note pointing at a known
        # source so the agent can decide how to acquire more.
        # Auto-eat ONLY reliably-safe staples. Corpse meat and foraged fish/mushrooms
        # can be POISONED — Perry once ate looted meat and poison-drained his HP (it
        # even read as "dangerous area"). Never auto-eat those; the agent can still
        # eat them deliberately with consume_item if it truly means to.
        food_kw     = /\b(bread|loaf|waybread|ration|biscuit|hardtack|cheese|apple|banana|fruit)\b/i
        risky_food  = /\b(meat|steak|flesh|fish|mushroom|corpse|carcass)\b/i
        drink_kw    = /\b(waterskin|flask|canteen|bottle|jug)\b/i
        upkeep_busy = false

        # Build a "no supplies" hint from ACTUAL tagged sources in the world-model
        # (never a guessed room name). Routes to the nearest reachable source, or
        # honestly says none is known yet.
        source_hint = lambda do |kind, action|
          candidates = world.rooms_with_resource(kind)
          return "no #{kind} source discovered yet — explore to find one, then #{action}." if candidates.empty?

          reachable = candidates.map { |r| [r, world.route_to(r["id"])] }.reject { |(_, rt)| rt.nil? }
          if reachable.empty?
            nearest = candidates.first
            "nearest known #{kind} source is #{nearest['name']} (##{nearest['id']}) but no mapped route from here yet — #{action} once you reach it."
          else
            room, rt = reachable.min_by { |(_, r)| r.length }
            if rt.empty?
              "you are at #{room['name']} — #{action} here."
            else
              est = world.route_cost(rt)
              "nearest #{kind} source is #{room['name']} (##{room['id']}) — travel_to it (route #{rt.join(',')}, ≈#{est[:total]} movement), then #{action}."
            end
          end
        end

        upkeep = lambda do |text|
          return nil if upkeep_busy
          hungry  = text =~ /you are hungry/i
          thirsty = text =~ /you are thirsty/i
          return nil unless hungry || thirsty

          upkeep_busy = true
          notes = []
          begin
            inv = MudText.strip_ansi(send_cmd.call(p.info_self("inventory")).to_s)
            if hungry
              if (m = inv.match(food_kw))
                send_cmd.call(p.consume("eat", m[0].downcase))
                notes << "[upkeep] hungry → ate #{m[0].downcase}."
              else
                risky = inv =~ risky_food ? "You're carrying meat/fish — do NOT eat it, it may be poisoned. " : ""
                notes << "[upkeep] hungry — no safe food on hand. #{risky}" + source_hint.call("food", "buy bread")
              end
            end
            if thirsty
              if (m = inv.match(drink_kw))
                send_cmd.call(p.consume("drink", m[0].downcase))
                notes << "[upkeep] thirsty → drank from #{m[0].downcase}."
              else
                notes << "[upkeep] thirsty: " + source_hint.call("water", "drink")
              end
            end
          rescue StandardError => e
            warn "[boukensha] upkeep error: #{e.message}"
          ensure
            upkeep_busy = false
          end
          notes.empty? ? nil : notes.join("\n")
        end

        # Force-consume carried food/water regardless of a hunger tick — used to
        # unblock rest regen, which stalls when hungry/thirsty. Harmless if not
        # needed (the MUD just says "too full" / "not thirsty"). Returns notes.
        provision = lambda do
          inv   = MudText.strip_ansi(send_cmd.call(p.info_self("inventory")).to_s)
          notes = []
          if (m = inv.match(food_kw))
            send_cmd.call(p.consume("eat", m[0].downcase)); notes << "ate #{m[0].downcase}"
          end
          if (m = inv.match(drink_kw))
            send_cmd.call(p.consume("drink", m[0].downcase)); notes << "drank #{m[0].downcase}"
          end
          notes
        end

        remember = lambda do |text, arrived_via: nil, full: false|
          async = last_drained.to_s   # async pushes (e.g. hunger ticks) drained before this command
          note = begin
            v_after = parse_v.call(text)
            # Movement cost of this move = points before minus points after.
            cost = (arrived_via && move_pts && v_after) ? [move_pts - v_after, 0].max : nil
            world.observe(text, arrived_via: arrived_via, move_cost: cost)
            # Slice 4: read the game's own exit destinations (one cheap command,
            # no LLM tokens) and record named edges — including the way back — so
            # the agent isn't stranded at a one-way destination.
            if world.current_id
              exits_text = send_cmd.call(p.info_self("exits"))
              world.record_named_edges(world.parse_exits(exits_text))
            end
            move_pts = v_after if v_after
            world.current_memory_line
          rescue StandardError => e
            warn "[boukensha] world_model error: #{e.message}"
            nil
          end
          up = upkeep.call("#{text}\n#{async}")
          # Slice 7c: return a distilled room block (ANSI-stripped, description
          # dropped on revisits unless `full`) to keep token cost down; `note`
          # is non-nil exactly when this was a room block. Non-room text (errors,
          # blocked moves) is only ANSI-stripped so nothing meaningful is lost.
          body = note ? world.distill(text, full: full) : MudText.strip_ansi(text)
          [body, note, up].compact.join("\n")
        end

        # Establish "you are here" by looking once and feeding it to the
        # world-model, so travel_to/explore work on the FIRST action of a session
        # (route_to needs a current room; without this it's nil until the agent
        # happens to look). Silent — the result is not returned to the agent.
        orient = lambda do
          begin
            world.observe(send_cmd.call(p.look))
          rescue StandardError => e
            warn "[boukensha] orient failed: #{e.message}"
          end
        end

        # Slice 3: deterministic travel. Resolve a destination, BFS a route over
        # the mapped graph, and walk it step by step — spending no model tokens on
        # the mundane moves. Control returns to the agent only on a compelling
        # event: combat, a blocked exit, or arriving off-map.
        full_dir   = { "n" => "north", "s" => "south", "e" => "east",
                       "w" => "west", "u" => "up", "d" => "down" }
        opp_dir    = { "n" => "south", "s" => "north", "e" => "west",
                       "w" => "east", "u" => "down", "d" => "up" }
        combat_re  = /\b(?:hits?|bashes?|bites?|claws?|attacks?|strikes?|slashes?|pierces?|crushes?|pounds?|mauls?|smites?)\s+you\b|\byou\s+are\s+attacked\b|\byou\s+have\s+been\s+(?:killed|attacked)\b/i
        blocked_re = /\b(?:cannot\s+go\s+that\s+way|the\s+door\s+is\s+closed|it\s+seems\s+to\s+be\s+closed|isn'?t\s+open)\b/i
        # The MUD hides an over-level zone: every room there shows this instead of
        # its real name. A hard "do not grind here" signal we can back out of.
        overlevel_re = /above your recommended level/i
        # DEATH-TRAP rooms (e.g. "Mid-Air" on the sewer ledge) zero your HP on entry
        # and often have no exits — you can't back out, only teleport. Recognise them
        # so the exit that leads there gets marked off-limits forever.
        trap_re      = /\bmid-?air\b|you (?:plummet|plunge|fall to your)|free fall|bottomless (?:pit|chasm)/i

        # Walk a known route one room at a time, feeding each new room to the
        # world-model and keeping move_pts current. Returns [walked_dirs, interrupt]
        # — interrupt is nil on a clean finish, else a message saying why we
        # stopped (blocked exit / combat). Shared by travel_to and explore.
        walk_route = lambda do |route|
          walked = []
          route.each do |short|
            dir    = full_dir[short] || short
            result = send_cmd.call(p.move(dir))
            world.observe(result, arrived_via: dir)
            body   = MudText.strip_ansi(result).strip

            if world.parse_room(result).nil? || body =~ blocked_re
              return [walked, "Stopped: move #{dir} was blocked after #{walked.empty? ? 'no moves' : walked.join(' → ')}.\n#{body}"]
            end
            if body =~ combat_re
              return [walked, "Stopped en route — COMBAT at room ##{world.current_id} after #{walked.join(' → ')}. Your call:\n#{body}"]
            end
            v = parse_v.call(result)
            move_pts = v if v
            walked << dir
          end
          [walked, nil]
        end

        travel = lambda do |destination|
          dest = destination.to_s.strip
          return "error: no destination given" if dest.empty?

          target = world.resolve_destination(dest)
          if target
            route = world.route_to(target)
            return "#{dest.inspect} is room ##{target}, but no mapped path connects it to where you are. Explore to link them." if route.nil?
            label = "#{world.name_for_id(target)} (##{target})"
          else
            fr = world.nearest_frontier_route
            return "Can't route to #{dest.inspect}: not on the map, and no unexplored exits to head toward. Try 'look', or move manually." if fr.nil?
            route, fid = fr
            target = nil
            label  = "the nearest unexplored area (room ##{fid})"
          end

          return "Already at #{label}." if route.empty?

          # Slice 5 pre-flight: if we lack the movement to finish, stop BEFORE
          # walking and escalate the decision (rest / reroute / abandon) rather
          # than walking into exhaustion. Affordable trips just proceed silently.
          if move_pts
            est = world.route_cost(route)
            if est[:total] > move_pts
              gap  = est[:total] - move_pts
              conf = est[:unknown].positive? ? " (estimate — #{est[:unknown]} of #{est[:steps]} legs not yet costed)" : ""
              return "Can't complete the trip to #{label} right now: it needs ≈#{est[:total]} movement#{conf}, " \
                     "you have #{move_pts} (short ≈#{gap}). No moves made. Options: rest to recover " \
                     "(rest_until movement: #{est[:total]}) if this room is safe, or choose a nearer destination."
            end
          end

          walked, interrupt = walk_route.call(route)
          return interrupt if interrupt

          arrived = world.current_id
          if target && arrived != target
            return "Walked #{walked.join(' → ')} but ended at room ##{arrived}, not #{label} — the map may be stale. Re-look and replan."
          end
          "Arrived at #{label} via #{walked.join(' → ')} (#{walked.size} room#{walked.size == 1 ? '' : 's'}). No decisions needed en route."
        end

        # First-class exploration: walk to the nearest room with an unwalked exit,
        # then STEP THROUGH it into territory we've never seen. travel_to only
        # covers KNOWN ground; this is what actually grows the map. The final step
        # gets the full arrival treatment (remember: records the edge + named
        # neighbours + runs upkeep) so the new room lands as richly mapped as
        # possible. Stops on a decision point or when nothing is left to explore.
        explore = lambda do
          fr = world.nearest_frontier_route
          return "Nothing left to explore — every exit you've seen has been walked. Use 'look' or a single 'move' to reach a genuinely new area." if fr.nil?
          route, fid = fr

          # Pre-flight: need enough movement to reach the frontier AND take the
          # step through it. Escalate a shortfall rather than walking into it.
          if move_pts
            est  = world.route_cost(route)
            need = est[:total] + 1
            if need > move_pts
              return "Can't explore right now: reaching the nearest unexplored area (room ##{fid}) and stepping in needs ≈#{need} movement, you have #{move_pts}. No moves made. rest_until movement: #{need} if this room is safe, or handle food/water first."
            end
          end

          walked, interrupt = walk_route.call(route)
          return interrupt if interrupt

          dirs = world.unexplored_dirs
          return "Reached room ##{world.current_id} but it has no unexplored exits after all — the map already covers its neighbours. Call explore again for the next frontier." if dirs.empty?

          short  = dirs.first
          # A room's exit list can carry a parenthesised token for a closed door,
          # e.g. "(d)" — that's NOT a valid move direction and p.move would raise.
          # Normalise to the bare direction before moving; keep `short` as the map
          # key for mark_blocked.
          norm   = short.to_s.gsub(/[^a-zA-Z]/, "").downcase
          dir    = full_dir[norm] || norm
          before = world.current_id

          unless %w[north south east west up down].include?(dir)
            world.mark_blocked(short, reason: "not a walkable exit")
            return "Explored from room ##{before}: #{short.inspect} isn't a real direction (marked, won't retry). Call explore again for the next frontier."
          end

          result   = send_cmd.call(p.move(dir))
          enriched = remember.call(result, arrived_via: dir)
          body     = MudText.strip_ansi(result).strip

          if world.parse_room(result).nil? || body =~ blocked_re
            # Bounced (closed door/rock, or not a real direction). Mark this exit
            # blocked so we don't fixate on it — next explore picks another frontier.
            world.mark_blocked(short, reason: body[/[^\n.]*\b(?:closed|cannot go|can'?t go)[^\n.]*/i])
            return "Explored #{dir} from room ##{before} — blocked (won't retry it): #{body.lines.first&.strip}"
          end

          if body =~ trap_re
            # Stepped into a DEATH TRAP (Mid-Air etc.) that zeroed HP — usually no
            # way back. Mark the exit off-limits and teleport out immediately.
            world.mark_blocked(short, from_fp: world.fp_for_id(before), reason: "DEATH TRAP")
            send_cmd.call("teleport MIDGAARD")
            return "Explored #{dir} from room ##{before} into a DEATH TRAP (#{body.lines.first&.strip}) — it zeroes your HP. Teleported you out, marked that exit off-limits forever. Rest to recover."
          end

          if body =~ overlevel_re
            # Stepped into an over-level zone the MUD hides from us — dangerous. Back
            # out the way we came and mark the exit off-limits so we never grind there.
            back = opp_dir[norm]
            world.observe(send_cmd.call(p.move(back))) if back
            world.mark_blocked(short, from_fp: world.fp_for_id(before), reason: "above your level")
            return "Explored #{dir} from room ##{before} — that zone is ABOVE your level (backed out, won't retry). Try another direction, or hunt elsewhere."
          end

          prefix = walked.empty? ? "" : "Walked #{walked.join(' → ')} to the frontier, then "
          tail   = body =~ combat_re ? " — COMBAT, your call" : ""
          "#{prefix}stepped #{dir} into new territory#{tail} (now room ##{world.current_id}).\n#{enriched}"
        end

        # Classify a `consider` rating: :safe (go), :even (perfect match — only at
        # full HP), :unsafe (needs luck / mad / death — skip), :miss (no such mob).
        consider_tier = lambda do |rating|
          t = rating.to_s.downcase
          return :miss   if t =~ /consider killing who|no ?one (?:by that|is here|here)|aren'?t (?:fighting|here)|isn'?t here|can'?t find|not here/
          return :safe   if t =~ /kill it easily|do it with|little effort|no (?:problem|contest|sweat)|piece of cake|with a needle|fairly easy|\beasy\b/
          return :even   if t =~ /perfect match/
          return :risky  if t =~ /some luck/   # "you would need some luck(and great equipment)!"
          :unsafe                              # a lot of luck / feel lucky / mad / death
        end

        # Perry is in top condition to take a calculated risk: full-ish HP, movement
        # in hand (can flee/travel), and carrying food AND water (hunger/thirst won't
        # bite mid-fight). Gate the riskier tiers (:even, :risky) on this.
        good_condition = lambda do
          s     = MudText.strip_ansi(send_cmd.call(p.info_self("score")))
          hp    = s[/(\d+)\(\d+\)\s+hit/i, 1]&.to_i
          maxhp = s[/\d+\((\d+)\)\s+hit/i, 1]&.to_i
          mv    = s[/(\d+)\(\d+\)\s+movement/i, 1]&.to_i
          inv   = MudText.strip_ansi(send_cmd.call(p.info_self("inventory")))
          supplied = (inv =~ food_kw) && (inv =~ drink_kw)
          !!(hp && maxhp && hp >= (maxhp * 0.9).floor && mv && mv.positive? && supplied)
        end

        # Consider one mob by trying its candidate keywords until the MUD matches
        # one. Returns [keyword, rating, tier] or nil if nothing matched.
        consider_mob = lambda do |kwset|
          kwset[:keywords].each do |kw|
            rating = MudText.strip_ansi(send_cmd.call(p.consider(kw))).strip.lines.first.to_s.strip
            tier   = consider_tier.call(rating)
            next if tier == :miss
            return [kw, rating, tier]
          end
          nil
        end

        # Prey PREFERENCE from a consider rating — drives "prefer the hardest safe
        # mob" (more xp) and a FLOOR below which a mob isn't worth our time. Higher =
        # better. nil = not engageable (too dangerous / no such mob). Because consider
        # is RELATIVE to your level, the floor scales automatically: what's "easy" at
        # level 4 becomes "where did that critter go" (0.0, skipped) once you outlevel
        # it.
        prey_pref = lambda do |rating|
          t = rating.to_s.downcase
          return nil if t =~ /a lot of luck|feel lucky|are you mad|\bmad\b|death awaits|consider killing who|no ?one|isn'?t here|not here|aren'?t/
          return 3.0 if t =~ /perfect match/                                 # even fight — best xp for the risk
          return 2.0 if t =~ /fairly easy|little effort/                     # a real mob — great xp, still safe
          return 0.5 if t =~ /some luck/                                     # RISKY — engageable topped-up, low priority
          return 0.0 if t =~ /where did that critter|with a needle|do it with a needle|no (?:problem|contest|sweat)|piece of cake|not even/  # TRIVIAL — below the floor
          return 1.0 if t =~ /kill it easily|\beasy\b/                       # easy prey (creepy) — modest xp
          1.0                                                                # unknown-but-safe → treat as easy
        end

        # HUNT — the search-phase offload. Deterministically look for a mob Perry
        # can safely fight: in each room, consider every mob; if none is safe, step
        # to the next room via explore and try again, up to max_rooms. Walks and
        # considers for ZERO model tokens and returns control only when it finds
        # safe prey (→ fight), gets attacked, runs out of movement, or exhausts the
        # search. One agent decision instead of dozens of move+consider calls.
        hunt = lambda do |max_rooms:|
          cond     = nil  # Perry's condition, computed lazily once per hunt
          hp_of    = ->(t) { (m = MudText.strip_ansi(t.to_s)[/(\d+)H\s+\d+M\s+\d+V/, 1]) && m.to_i }
          start_hp = nil

          # Eat/drink first so hunger/thirst don't throttle movement regen — a
          # common reason a grind session opens with a near-empty movement bar.
          provision.call
          mv_now = move_pts || parse_v.call(send_cmd.call(p.info_self("score")))
          if mv_now && mv_now < 12 && !world.prey_here?
            move_pts = mv_now
            return "Low on movement (#{mv_now}) to hunt — I've eaten/drunk so regen isn't blocked. rest_until movement: 60 here (it's safe), then hunt again."
          end

          # Best engageable mob in ONE room (or a combat interrupt, or nil). Considers
          # every mob and returns the HIGHEST-preference one — preferring a harder
          # mob for the xp, skipping trivially-easy ones (below the floor), and gating
          # perfect-match/risky on being topped up. Returns { kw:, rating:, pref:, hid: }
          # or { combat: msg } or nil. Town/guarded rooms are skipped.
          # Records, for observability, the mobs hunt looked at and did NOT pick, with
          # the reason — so the decision ("passed up a weak creepy for the monster") is
          # visible in the result, not just inside the tool.
          passed = []
          best_prey_here = lambda do |raw, hid|
            return nil if raw =~ /peacekeeper|cityguard|city\s*guard/i
            engageable = []
            world.mob_keyword_sets(raw).each do |kwset|
              hit = consider_mob.call(kwset)
              next unless hit
              kw, rating, _tier = hit
              if rating =~ combat_re || rating =~ /swings?\s+at\s+you|takes?\s+a\s+swing|lunges?\s+at\s+you|attacks?\s+you/i
                return { combat: "Attacked while hunting — an aggressive mob in #{world.name_for_id(hid)} (##{hid}) is on you: #{rating}\n→ call fight to kill it, or flee." }
              end
              pref = prey_pref.call(rating)
              if pref.nil?                                        # too dangerous
                passed << "#{kw} (\"#{rating}\", too tough)"; next
              end
              if pref <= 0.0                                      # below the floor — not worth the time
                passed << "#{kw} (\"#{rating}\", too trivial)"; next
              end
              if pref >= 3.0 || pref == 0.5                       # perfect-match / risky need full HP
                cond = good_condition.call if cond.nil?
                (passed << "#{kw} (\"#{rating}\", only at full HP)"; next) unless cond
              end
              engageable << { kw: kw, rating: rating, pref: pref, hid: hid }
            end
            return nil if engageable.empty?
            best = engageable.max_by { |e| e[:pref] }
            (engageable - [best]).each { |e| passed << "#{e[:kw]} (\"#{e[:rating]}\", weaker — took the tougher one)" }
            best
          end

          # Build the "found prey" reply — including what hunt PASSED UP to pick this
          # one — and tag the grind spot.
          found_msg = lambda do |b|
            world.mark_prey(tier: (b[:pref] >= 3 ? :even : b[:pref] <= 0.5 ? :risky : :safe), note: b[:kw])
            note = if    b[:pref] >= 3.0 then " A PERFECT MATCH — best xp, winnable at full HP."
                   elsif b[:pref] >= 2.0 then " A proper mob — more xp than the little ones."
                   elsif b[:pref] == 0.5 then " RISKIER (\"some luck\") but you're topped up; wimpy guards it."
                   else ""
                   end
            skipped = passed.uniq.reject { |s| s.start_with?("#{b[:kw]} ") }.first(5)
            pline   = skipped.empty? ? "" : "\n[chose it over: #{skipped.join('; ')}]"
            "Found prey: '#{b[:kw]}' in #{world.name_for_id(b[:hid])} (##{b[:hid]}). consider: \"#{b[:rating]}\".#{note}#{pline}\n→ call fight with target \"#{b[:kw]}\"."
          end

          # ── Mode 1: KNOWN GRIND SPOTS → cycle them, never blind-wander ──────
          # Once we know where safe prey lives, we ONLY visit those rooms (routing
          # over the mapped graph). If they're all clear right now, we rest for
          # respawns rather than exploring into unknown/dangerous territory — the
          # thing that kept marching Perry into town / the sewer / the chessboard.
          spots = world.prey_room_ids
          if spots.any?
            checked = []; best = nil
            ([world.current_id] + spots).compact.uniq.each do |sid|
              if sid != world.current_id
                rt = world.route_to(sid)
                next if rt.nil? || rt.empty?
                next if move_pts && world.route_cost(rt)[:total] > move_pts   # can't afford; skip, don't strand
                _walked, interrupt = walk_route.call(rt)
                return interrupt if interrupt && interrupt =~ /COMBAT/i
              end
              raw = send_cmd.call(p.look); world.observe(raw)
              hp = hp_of.call(raw); start_hp ||= hp
              return "Stopped hunting — you're taking damage (HP #{hp}). Get to a safe room and rest before hunting again." if hp && start_hp && hp <= [start_hp / 2, 10].max
              res = best_prey_here.call(raw, world.current_id)
              return res[:combat] if res.is_a?(Hash) && res[:combat]
              if res.is_a?(Hash)
                best = res if best.nil? || res[:pref] > best[:pref]
                # A proper mob (perfect-match / fairly-easy) is worth taking at once —
                # no point searching further. Trivial/easy/risky prey we remember and
                # keep checking the other spots for something better.
                return found_msg.call(res) if res[:pref] >= 2.0
                passed << "#{res[:kw]} (\"#{res[:rating]}\", kept looking elsewhere for better)"
              end
              checked << world.current_id
            end
            # Cycle done. Take the best low-value fallback we saw, walking back to it.
            if best
              if best[:hid] != world.current_id
                rt = world.route_to(best[:hid]); walk_route.call(rt) if rt && !rt.empty?
              end
              return found_msg.call(best)
            end
            names = checked.uniq.map { |i| "#{world.name_for_id(i)} (##{i})" }
            return "Your known grind spots (#{names.join(', ')}) are all clear (or only mobs too trivial to be worth your time) right now — they respawn on a timer. rest_until here (it's safe), then hunt again shortly. NOT wandering off — unknown areas are where the danger is."
          end

          # ── Mode 2: BOOTSTRAP → no grind spot known yet, explore to find one ──
          route = []
          max_rooms.times do
            raw = send_cmd.call(p.look); world.observe(raw)
            hid = world.current_id
            route << hid
            hp = hp_of.call(raw); start_hp ||= hp
            return "Stopped hunting — you're taking damage while searching (HP #{hp} from #{start_hp}). Rest somewhere safe, then hunt in the newbie zone (the level 1–5 grind)." if hp && start_hp && hp <= [start_hp / 2, 10].max

            res = best_prey_here.call(raw, hid)
            return res[:combat] if res.is_a?(Hash) && res[:combat]
            return found_msg.call(res) if res.is_a?(Hash)

            step = begin
              explore.call
            rescue StandardError => e
              "Nothing left to explore — search halted (#{e.class}: #{e.message})"
            end
            case step
            when /Nothing left to explore|no unexplored exits|search halted/i then break
            when /COMBAT/i
              return "Attacked while hunting — now in #{world.name_for_id(world.current_id)} (##{world.current_id}). Handle it:\n#{step}"
            when /Can'?t explore right now/i
              return "Hunt paused — not enough movement to search further. #{step}"
            end
          end
          detail = passed.empty? ? "no mobs at all" : "only mobs not worth fighting: #{passed.uniq.first(6).join('; ')}"
          "No worthwhile prey found after searching #{route.uniq.size} room#{route.uniq.size == 1 ? '' : 's'} (#{route.uniq.map { |x| "##{x}" }.join(', ')}). Found #{detail}.\n→ Relocate to the newbie zone (level 1–5 grind) and hunt there — don't wander into unknown areas."
        end

        # SEEK — find a PLACE by name you haven't mapped yet. `explore` in a
        # deterministic loop: expand the map (inheriting explore's over-level /
        # death-trap guards) and after each step check whether the named room is now
        # on the map; stop the moment it is. One LLM decision, zero model tokens for
        # the walking — `hunt`, but for places instead of prey. On failure it hands
        # back a SHAPE SUMMARY of the areas it passed so the agent can redirect once
        # (call-level course-correction), never per-room LLM reasoning.
        seek = lambda do |name:, max_rooms:|
          target = name.to_s.strip
          return "error: no place name to seek" if target.empty?
          if (known = world.resolve_destination(target))
            return "You already know #{world.name_for_id(known)} (##{known}) — use travel_to \"#{target}\", no need to seek."
          end
          provision.call
          areas = []
          max_rooms.times do
            step = begin
              explore.call
            rescue StandardError => e
              "Nothing left to explore — #{e.class}: #{e.message}"
            end
            areas << world.name_for_id(world.current_id) if world.current_id
            if (found = world.resolve_destination(target))
              return "Found \"#{target}\" — it's #{world.name_for_id(found)} (##{found}). → travel_to \"#{target}\" to go there (or you may be standing in it)."
            end
            case step
            when /Nothing left to explore|no unexplored exits|search halted/i then break
            when /COMBAT/i
              return "Interrupted while seeking — combat at #{world.name_for_id(world.current_id)} (##{world.current_id}). Handle it, then seek \"#{target}\" again."
            when /Can'?t explore right now/i
              return "Seek paused — not enough movement. #{step}\nrest_until, then seek \"#{target}\" again."
            end
          end
          shape = areas.compact.uniq.last(6)
          "Didn't find \"#{target}\" after searching #{areas.compact.uniq.size} rooms. Path drifted through: #{shape.join(' → ')}. " \
          "If that's the wrong part of the map, travel_to a better hub first (or a landmark nearer the target), then seek \"#{target}\" again; otherwise seek again to keep expanding."
        end

        # ── Combat: skill-aware fight-to-completion ─────────────────────────

        # The character's trained skills, read from the game (`practice`) and
        # cached for the session. Refreshed after training / level-up.
        char_skills = { sessions: 0, skills: {}, loaded: false }
        load_skills = lambda do |force: false|
          if !char_skills[:loaded] || force
            parsed = Boukensha::Skills.parse_practice(send_cmd.call(p.practice))
            char_skills[:sessions] = parsed[:sessions]
            char_skills[:skills]   = parsed[:skills]
            char_skills[:loaded]   = true
          end
          char_skills
        end

        # Pull xp / level / hp from a fresh score read, for before/after deltas.
        score_stats = lambda do
          s = MudText.strip_ansi(send_cmd.call(p.info_self("score")))
          {
            hp:    s[/(\d+)\((\d+)\)\s+hit/i, 1]&.to_i,
            maxhp: (s =~ /(\d+)\((\d+)\)\s+hit/i) ? Regexp.last_match(2).to_i : nil,
            xp:    s[/have\s+(\d+)\s+exp/i, 1]&.to_i,
            need:  s[/need\s+(\d+)\s+exp/i, 1]&.to_i,
            level: s[/\(level\s+(\d+)\)/i, 1]&.to_i
          }
        end

        # A carried piercing weapon to swap in for a backstab. Keyword match on
        # inventory; if backstab later complains, we detect that and fall back.
        piercing_kw = /\b(dagger|dirk|knife|stiletto|kris|main-gauche|rapier|needle)\b/i
        find_dagger = lambda do
          inv  = MudText.strip_ansi(send_cmd.call(p.info_self("inventory")))
          line = inv.lines.find { |l| l =~ piercing_kw }
          line && line[piercing_kw, 1]&.downcase
        end

        # FIGHT — kill one mob to completion, skill-aware and hands-off. Re-considers
        # the target (bails if unsafe unless force:), sets a wimpy safety floor, leads
        # with the best trained opener whose preconditions hold (backstab: wield a
        # dagger → strike → re-wield the main weapon for sustained damage), lets the
        # MUD's auto-rounds run to the kill, auto-loots the corpse, and returns ONE
        # distilled line (outcome + vitals + xp/level delta). Round spam never reaches
        # the model. This is the fight-phase offload.
        fight = lambda do |target:, force: false|
          tgt = target.to_s.strip
          return "error: no target given" if tgt.empty?

          rating = MudText.strip_ansi(send_cmd.call(p.consider(tgt))).strip.lines.first.to_s.strip
          tier   = consider_tier.call(rating)
          return "No '#{tgt}' here to fight (#{rating.empty? ? 'nothing matched' : rating})." if tier == :miss
          if tier == :unsafe && !force
            return "Refusing to fight '#{tgt}' — consider says \"#{rating}\". Too dangerous. Use hunt to find safe prey, or pass force:true only if you truly mean it."
          end
          # A perfect-match or "some luck" fight is only worth it when Perry is topped
          # up (full HP, movement, supplies) — wimpy covers the downside from there.
          if (tier == :even || tier == :risky) && !force && !good_condition.call
            return "'#{tgt}' would be a #{tier == :risky ? "'some luck'" : 'perfect-match'} fight — only worth it at full HP with movement and food/water on hand, and you're not there right now. rest_until / restock first, or pass force:true."
          end

          before = score_stats.call
          # Deterministic wimpy floor ≈ 1/3 max HP (fires before a lethal hit lands).
          wimpy_floor = before[:maxhp] ? [(before[:maxhp] / 3.0).ceil, 1].max : nil
          send_cmd.call("toggle wimpy #{wimpy_floor}") if wimpy_floor

          # Skill-aware opener.
          opener_note = "plain attack"
          struck  = false
          swapped = false
          main_kw = nil
          opener, prof = Boukensha::Skills.openers(load_skills.call[:skills]).first
          if opener == "backstab"
            pierce_fail = /piercing weapon|only.*(?:pierc|stab)/i
            attempt = -> { MudText.strip_ansi(send_cmd.call(p.skill_strike("backstab", tgt))) }

            # Try with the CURRENT weapon first — some "swords" are piercing. Only
            # swap in a carried dagger if the game rejects the weapon type. (A
            # weapon-type rejection aborts before combat, so retrying is safe.)
            bs = attempt.call
            if bs =~ pierce_fail
              eq      = MudText.strip_ansi(send_cmd.call(p.info_self("equipment")))
              main_kw = eq[/<wielded>\s+(.+)/i, 1]&.strip&.sub(/\s*\.\..*/, "")&.split&.last
              if (dagger = find_dagger.call)
                send_cmd.call(p.equip("wield", dagger))
                swapped = true
                bs = attempt.call
              end
            end

            if bs =~ pierce_fail
              opener_note = "backstab (#{prof}) — no piercing weapon available, plain attack"
            elsif bs =~ /they aren'?t here|no ?one (?:by that|here)|isn'?t here/i
              send_cmd.call(p.equip("wield", main_kw)) if swapped && main_kw
              return "'#{tgt}' is gone — nothing to fight now."
            elsif bs =~ /can'?t backstab.*fight|already fighting|while .*fighting/i
              opener_note = "target already engaged — plain attack"
            else
              struck      = true
              opener_note = bs =~ /miss|fail|feint|fumble/i ? "backstab MISSED (#{prof}) — lost surprise, fighting on" : "backstab landed (#{prof})"
            end
            # If we swapped to a dagger for the strike, return to the main weapon
            # (best sustained damage) for the rest of the fight.
            send_cmd.call(p.equip("wield", main_kw)) if swapped && main_kw
          end

          # Outcome patterns. Perry fleeing (wimpy / failed escape) is first-person;
          # a MOB fleeing is third-person ("… panics, and attempts to flee. … flees
          # east!") — detect them apart so a mob's retreat isn't read as Perry bailing.
          kill_re  = /is dead|R\.I\.P|you receive your|you gain|slain|experience/i
          death_re = /has been KILLED|you are dead|you die\b/i
          you_fled = /\byou flee\b|you flee head over heels|you couldn'?t escape|PANIC! you/i
          mob_fled = /\bpanics?,?\s+and\s+(?:attempts?\s+to\s+)?flee|\bflees\b|flee[sd]?\s+(?:in\s+terror|to\s+the\b)/i

          # Poll the MUD's auto-rounds until an outcome or things go quiet.
          run_rounds = lambda do
            acc = +""
            dl  = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
            loop do
              chunk = session.read_until_quiet(1.4, timeout: 5)
              acc << chunk
              break if acc =~ kill_re || acc =~ death_re || acc =~ you_fled || acc =~ mob_fled
              break if chunk.strip.empty?
              break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > dl
            end
            acc
          end

          send_cmd.call(p.attack("kill", tgt)) unless struck
          rounds = run_rounds.call

          # CHASE a fleeing quarry. A mob only flees when it's losing, so it's low on
          # HP — following it and finishing the kill is fast and free xp. Bounded so a
          # mob can't lead Perry on a long march into danger; wimpy still guards HP.
          chased = 0
          flee_dir = /\bflee[sd]?\s+(?:to\s+the\s+)?(north|south|east|west|up|down)\b/i
          while chased < 3 && rounds !~ kill_re && rounds !~ death_re &&
                rounds !~ you_fled && rounds =~ mob_fled
            dir = rounds[flee_dir, 1]&.downcase
            if dir.nil?
              # The "… flees east" line often lands a beat AFTER "panics, and
              # attempts to flee" (which already broke the poll). Read a moment more
              # to catch the direction before giving up the chase.
              rounds << session.read_until_quiet(1.0, timeout: 3)
              dir = rounds[flee_dir, 1]&.downcase
            end
            break unless dir   # it fled but we truly can't tell which way — let it go
            follow = MudText.strip_ansi(send_cmd.call(p.move(dir)))
            world.observe(follow)
            break if follow =~ /you (?:cannot|can'?t) go|Alas|too dark|pitch black/i
            strike = MudText.strip_ansi(send_cmd.call(p.attack("kill", tgt)))
            break if strike =~ /they aren'?t here|no ?one (?:by that|here)|isn'?t here|not here/i  # lost it
            rounds = strike + run_rounds.call
            chased += 1
          end

          killed      = rounds =~ kill_re
          died        = rounds =~ death_re
          perry_fled  = !killed && rounds =~ you_fled
          quarry_fled = !killed && !perry_fled && rounds =~ mob_fled
          after       = score_stats.call
          chase_note  = chased.positive? ? " (chased it down #{chased} room#{chased == 1 ? '' : 's'})" : ""

          # Auto-loot on a kill (items + any coins). Perry is in the room where it died.
          if killed
            send_cmd.call(p.get("all", container: "corpse"))
            send_cmd.call(p.get("coins", container: "corpse"))
          end

          dxp     = (after[:xp] && before[:xp]) ? after[:xp] - before[:xp] : nil
          leveled = after[:level] && before[:level] && after[:level] > before[:level]
          vit     = after[:hp] && after[:maxhp] ? "HP #{after[:hp]}/#{after[:maxhp]}" : nil
          xpline  = dxp ? "+#{dxp} xp" : "xp unchanged"
          nextl   = after[:need] ? " (#{after[:need]} to next level)" : ""
          # Did wimpy actually pull Perry out? Only if his HP is down near the floor.
          low_hp  = after[:hp] && wimpy_floor && after[:hp] <= wimpy_floor + 3

          if died
            "You DIED fighting '#{tgt}'. Respawned — your gear is on your corpse. #{vit}."
          elsif leveled
            "Killed '#{tgt}'#{chase_note} — #{opener_note}. #{xpline} → LEVEL #{after[:level]}! Looted corpse. #{vit}. You have new practice sessions — train at your guild."
          elsif killed
            "Killed '#{tgt}'#{chase_note} — #{opener_note}. #{xpline}#{nextl}. Looted corpse. #{vit}."
          elsif perry_fled
            if low_hp
              "Wimpy pulled you out of the fight with '#{tgt}' — HP got dangerously low. #{vit}. Rest to recover, then hunt weaker prey."
            else
              "Broke off the fight with '#{tgt}' (#{opener_note}). #{vit} — you're fine, wimpy didn't trigger. Re-engage with fight if you want it, or hunt for another."
            end
          elsif quarry_fled
            tail = chased.positive? ? "outran you after #{chased} room#{chased == 1 ? '' : 's'} of chase" : "panicked and fled before you could pin it"
            "'#{tgt}' #{tail} — no kill, no xp, but you're unhurt. #{vit}. hunt for another target."
          else
            "Fight with '#{tgt}' didn't fully resolve (#{opener_note}). #{vit}. If it's still here, fight again; if you're hurt, rest."
          end
        end

        # ── Connection ─────────────────────────────────────────────────────

        registry.tool "mud_connect",
          description: "Open the connection to the MUD server and log in with the configured " \
                       "character name and password. Safe to call when already connected " \
                       "(returns current status instead of reconnecting).",
          parameters: {} do
          if session.open?
            "already connected to #{session.host}:#{session.port}"
          else
            begin
              session.open
              welcome = session.login(name, password)
              orient.call
              "connected to #{session.host}:#{session.port}\n#{welcome}"
            rescue MudManager::Session::Error => e
              "error: #{e.message}"
            end
          end
        end

        registry.tool "mud_disconnect",
          description: "Leave the MUD. Quits cleanly (saves the character and removes it " \
                       "from the world so it can't be attacked while away), then closes the " \
                       "connection — never leaves the character link-dead. Alias of mud_quit.",
          parameters: {} do
          if session.open?
            note = quit_cleanly.call
            note.to_s.empty? ? "disconnected" : "disconnected\n#{note}"
          else
            "already disconnected"
          end
        end

        registry.tool "mud_quit",
          description: "Leave the game CLEANLY: send the in-game 'quit' command so the " \
                       "character is saved and removed from the world (it cannot be " \
                       "attacked while you are away), then close the socket. Prefer this " \
                       "over mud_disconnect whenever you are done playing — a bare " \
                       "disconnect leaves the body link-dead in the room, where aggressive " \
                       "mobs can beat it to death.",
          parameters: {} do
          if session.open?
            note = quit_cleanly.call
            note.to_s.empty? ? "quit and disconnected" : "quit and disconnected\n#{note}"
          else
            "already disconnected"
          end
        end

        registry.tool "mud_status",
          description: "Return whether the MUD session is currently connected.",
          parameters: {} do
          session.open? ? "connected to #{session.host}:#{session.port}" : "disconnected"
        end

        # ── Perception ──────────────────────────────────────────────────────

        registry.tool "look",
          description: "Look at the current room or at a specific target. " \
                       "Call with NO arguments to describe the current room (do NOT pass target: 'room'). " \
                       "Pass a target to inspect a specific item, mob, or player (e.g. target: 'sword'). " \
                       "Use preposition 'in' to look inside a container, 'at' to inspect something, " \
                       "or a direction (north/east/south/west/up/down) to peek into an adjacent room.",
          parameters: {
            target:      { type: "string", description: "Item, mob, or player name to inspect. Omit entirely to describe the current room." },
            preposition: { type: "string", description: "Preposition: in, at, north, east, south, west, up, down (optional)" }
          } do |target: nil, preposition: nil|
          next guard.call if guard.call
          begin
            result = send_cmd.call(p.look(target: target, preposition: preposition))
            # Only a bare look describes the room you're actually in; looking at a
            # target or peeking a direction must not count as a visit.
            if target.nil? && preposition.nil?
              remember.call(result, full: true)
            else
              result
            end
          rescue ArgumentError => e
            "error: #{e.message}"
          end
        end

        registry.tool "examine",
          description: "Examine a target in detail (more verbose than look).",
          parameters: {
            target: { type: "string", description: "The item, mob, or player to examine" }
          } do |target:|
          next guard.call if guard.call
          begin
            send_cmd.call(p.examine(target))
          rescue ArgumentError => e
            "error: #{e.message}"
          end
        end

        registry.tool "check",
          description: "Query information about your character or surroundings. " \
                       "Kinds: score, inventory, equipment, gold, exits, time, weather, " \
                       "levels, wimpy, toggle, where.",
          parameters: {
            kind: { type: "string", description: "What to check: score | inventory | equipment | gold | exits | time | weather | levels | wimpy | toggle | where" }
          } do |kind:|
          next guard.call if guard.call
          begin
            send_cmd.call(p.info_self(kind))
          rescue ArgumentError => e
            "error: #{e.message}"
          end
        end

        # ── Movement ────────────────────────────────────────────────────────

        registry.tool "move",
          description: "Move in a compass direction or up/down. If a step lands in a zone " \
                       "above your level, it backs you out automatically — that terrain is lethal " \
                       "for a fragile Thief.",
          parameters: {
            direction: { type: "string", description: "Direction: north | east | south | west | up | down" }
          } do |direction:|
          next guard.call if guard.call
          begin
            from_fp  = world.current_fp
            result   = send_cmd.call(p.move(direction))
            enriched = remember.call(result, arrived_via: direction)
            body     = MudText.strip_ansi(result)

            # DEATH TRAP (e.g. Mid-Air): it zeroed your HP and usually has no way
            # out. Mark the exit that led here off-limits so we never route through
            # it again, then teleport to safety.
            if body =~ trap_re
              world.mark_blocked(direction.to_s.strip.downcase[0], from_fp: from_fp, reason: "DEATH TRAP")
              send_cmd.call("teleport MIDGAARD")
              next "DEATH TRAP — '#{direction}' drops into #{body.lines.first&.strip} which zeroes your HP. Teleported you out and marked that exit off-limits forever. Rest to recover; never go that way."
            end

            # Same guard hunt/explore use, now for deliberate steps: don't let the
            # agent hand-walk into an over-level zone (the Obs B4 chessboard march).
            if body =~ overlevel_re
              back = opp_dir[direction.to_s.strip.downcase[0]]
              if back
                world.observe(send_cmd.call(p.move(back)))
                next "That way is ABOVE your recommended level — lethal terrain for you. Backed you out. Use travel_to a safe area or teleport MIDGAARD; do not push deeper."
              end
              next "You're in an over-level zone and there's no safe way back the way you came — teleport MIDGAARD to escape now."
            end
            enriched
          rescue ArgumentError => e
            "error: #{e.message}"
          end
        end

        registry.tool "travel_to",
          description: "Automatically walk to a destination you have already mapped, instead of " \
                       "moving one room at a time. Give a room name (e.g. 'Market Square') or an " \
                       "#id (e.g. '#5'). It plans the shortest route over rooms you've visited and " \
                       "walks the whole way itself. It stops and hands control back only when " \
                       "something needs a decision: combat en route, a blocked/closed exit, or " \
                       "arriving somewhere off-map. If the destination isn't mapped yet, it heads " \
                       "toward the nearest unexplored exit instead. Prefer this over repeated move " \
                       "calls whenever you know where you want to go.",
          parameters: {
            destination: { type: "string", description: "Room name or #id to travel to" }
          } do |destination:|
          next guard.call if guard.call
          travel.call(destination)
        end

        registry.tool "explore",
          description: "Discover NEW rooms. Walks to the nearest place with an unmapped exit and steps " \
                       "THROUGH it into territory you have not seen yet — the one thing travel_to cannot do " \
                       "(travel_to only moves over rooms you've already visited). Use this whenever your goal " \
                       "is somewhere you have NOT found yet (a guild, a shop you've never reached): it expands " \
                       "the map one frontier step per call, so call it repeatedly to search. It stops and hands " \
                       "control back on a decision point (combat, a blocked exit) or when there's nothing left " \
                       "to explore. Always prefer this over chaining manual move calls to search.",
          parameters: {} do
          next guard.call if guard.call
          explore.call
        end

        registry.tool "hunt",
          description: "Find a mob you can safely fight. Walks room by room, considers every mob it " \
                       "finds, and STOPS the moment one rates safe to kill — telling you which mob and " \
                       "where, so you can then call `fight` on it. If it finds only mobs too strong (or " \
                       "none at all), it says so and suggests relocating. This is how you search for " \
                       "prey: it spends NONE of your turn budget on the walking or the considering, so " \
                       "always prefer it over doing move + consider by hand to look for something to " \
                       "kill. Call it, read whether it found prey, then fight or move on.",
          parameters: {
            max_rooms: { type: "integer", description: "How many rooms to search before giving up (default 12)" }
          } do |max_rooms: 12|
          next guard.call if guard.call
          begin
            hunt.call(max_rooms: (max_rooms || 12).to_i.clamp(1, 40))
          rescue MudManager::Session::Error, ArgumentError => e
            "Hunt stopped on an error (#{e.message}). You're safe where you are — try `look`, then move or hunt again."
          end
        end

        registry.tool "seek",
          description: "FIND a place by name that you have NOT mapped yet — the way to reach a landmark " \
                       "(a guild, a shop) you've only heard of. It explores the map for you, room by room, " \
                       "and STOPS the moment it finds a room whose name matches, telling you where it is so " \
                       "you can travel_to it. Use this instead of calling `explore` over and over by hand to " \
                       "hunt for somewhere — seek spends NONE of your turn budget on the walking. If it can't " \
                       "find it in range, it reports which areas it passed through so you can redirect. Once " \
                       "found, the place is on your map for good (travel_to works after).",
          parameters: {
            name:      { type: "string",  description: "Name (or part of it) of the place to find, e.g. \"Thieves\" or \"Thieves guild\"" },
            max_rooms: { type: "integer", description: "How many rooms to explore before giving up (default 25)" }
          } do |name:, max_rooms: 25|
          next guard.call if guard.call
          begin
            seek.call(name: name, max_rooms: (max_rooms || 25).to_i.clamp(1, 60))
          rescue MudManager::Session::Error, ArgumentError => e
            "Seek stopped on an error (#{e.message}). You're safe — try `look`, then seek again."
          end
        end

        registry.tool "plan_route",
          description: "Plan (but do NOT walk) the shortest known route to a destination room, so " \
                       "you can see the path first. Returns the list of directions, or a note if " \
                       "the destination is unmapped or not yet connected to your location.",
          parameters: {
            destination: { type: "string", description: "Room name or #id" }
          } do |destination:|
          next guard.call if guard.call
          target = world.resolve_destination(destination.to_s)
          if target.nil?
            fr = world.nearest_frontier_route
            next(fr ? "#{destination.inspect} isn't mapped. Nearest unexplored area: #{fr[0].empty? ? 'right here' : fr[0].join(', ')}." \
                    : "#{destination.inspect} isn't mapped and there's nothing left to explore.")
          end
          route = world.route_to(target)
          next "Room ##{target} is known but not yet connected to your location." if route.nil?
          next "You're already at #{world.name_for_id(target)} (##{target})." if route.empty?
          "Route to #{world.name_for_id(target)} (##{target}): #{route.join(', ')} — #{route.size} step#{route.size == 1 ? '' : 's'}."
        end

        registry.tool "rest_until",
          description: "Recover by resting/sleeping until a target — HP and/or MOVEMENT. Give `hp` to " \
                       "HEAL between fights (it SLEEPS, which regens HP fastest, and caps near ~85% of " \
                       "your max since the last stretch crawls); give `movement` to recover for a trip. " \
                       "It checks the room is SAFE first and eats/drinks so hunger/thirst don't block " \
                       "regen; it refuses if you're in danger and wakes if a fight starts. After a rough " \
                       "fight, rest_until hp: BEFORE fighting again — don't fight wounded.",
          parameters: {
            hp:       { type: "integer", description: "Target HP to heal to (sleeps; auto-capped near 85% of your max). Use when hurt." },
            movement: { type: "integer", description: "Target movement points (rests). Use before a trip." }
          } do |hp: nil, movement: nil|
          next guard.call if guard.call

          read = lambda do
            s = MudText.strip_ansi(send_cmd.call(p.info_self("score")))
            { hp: s[/(\d+)\(\d+\)\s+hit/i, 1]&.to_i, maxhp: s[/\d+\((\d+)\)\s+hit/i, 1]&.to_i,
              mv: s[/(\d+)\(\d+\)\s+movement/i, 1]&.to_i, raw: s }
          end

          # Safety gate: never rest/sleep into danger. Sleeping to heal leaves you
          # UNAWARE, so beyond an over-level zone or an active attack, refuse if ANY
          # mob is in the room — it can maul a sleeping Perry before he wakes. Move
          # to an empty room (or teleport to the Temple) to heal. Stand up FIRST so
          # the look shows the actual room (a sleeping char just sees "In your
          # dreams…", which would blind this check). From sleep you must wake before
          # you can stand.
          send_cmd.call(p.set_position("wake"))
          send_cmd.call(p.set_position("stand"))
          here = MudText.strip_ansi(send_cmd.call(p.look))
          next "Won't rest here — this zone is above your level (unsafe). teleport MIDGAARD or move to a safe room first." if here =~ overlevel_re
          next "Won't rest — you're under attack. Deal with the threat (fight or flee) before resting." if here =~ combat_re
          mobs_here = world.mob_keyword_sets(here).map { |m| m[:keywords].first }.compact.uniq
          unless mobs_here.empty?
            next "Not safe to rest here — there's something in the room (#{mobs_here.first(3).join(', ')}) that could attack you while you sleep. Move to an EMPTY room first, or teleport MIDGAARD (the Temple is safe), then rest_until."
          end

          start = read.call
          hp_target = (hp && start[:maxhp]) ? [hp.to_i, (start[:maxhp] * 0.85).ceil].min : nil
          mv_target = movement&.to_i
          next "Give a target: hp (to heal) and/or movement (to recover for a trip)." if hp_target.nil? && mv_target.nil?
          reached = lambda { |s| (hp_target.nil? || (s[:hp] && s[:hp] >= hp_target)) && (mv_target.nil? || (s[:mv] && s[:mv] >= mv_target)) }
          if reached.call(start)
            next "Already rested — HP #{start[:hp]}/#{start[:maxhp]}#{mv_target ? ", #{start[:mv]} move" : ''}. Nothing to recover; you're ready."
          end

          fed = provision.call
          healing = !hp_target.nil?
          send_cmd.call(p.set_position(healing ? "sleep" : "rest"))   # sleep heals fastest

          last = start
          stalls = 0
          interrupted = false
          # Poll ~15s apart (a CircleMUD tick is ~75s); healing to 85% can span
          # several ticks, so allow a generous window before giving up.
          20.times do
            break if reached.call(last)
            sleep 15
            score = MudText.strip_ansi(send_cmd.call(p.info_self("score")))
            if score =~ /you are fighting/i || score =~ /you (?:awaken|wake)/i || score =~ combat_re
              interrupted = true; break
            end
            s = { hp: score[/(\d+)\(\d+\)\s+hit/i, 1]&.to_i, maxhp: score[/\d+\((\d+)\)\s+hit/i, 1]&.to_i, mv: score[/(\d+)\(\d+\)\s+movement/i, 1]&.to_i }
            gained = (s[:hp].to_i > last[:hp].to_i) || (s[:mv].to_i > last[:mv].to_i)
            gained ? (stalls = 0) : (fed |= provision.call; stalls += 1)
            last = s
            break if stalls >= 6
          end
          send_cmd.call(p.set_position("wake"))   # must wake before standing, when we slept
          send_cmd.call(p.set_position("stand"))
          move_pts = last[:mv] if last[:mv]
          vit = "HP #{last[:hp]}/#{last[:maxhp]}#{last[:mv] ? ", #{last[:mv]} move" : ''}"
          next "Rest interrupted — a fight started (#{vit}). Standing — handle it." if interrupted
          ate = fed.empty? ? "" : " (#{fed.uniq.join(', ')})"
          if reached.call(last)
            "Rested up#{ate} — #{vit}. Standing, ready."
          elsif (last[:hp].to_i > start[:hp].to_i) || (last[:mv].to_i > start[:mv].to_i)
            "Recovered to #{vit}#{ate} (target not fully reached — regen is slow; call rest_until again to keep going). Standing."
          else
            "No recovery (#{vit})#{ate}. Regen may be blocked — out of food/water, or the room keeps interrupting. Standing."
          end
        end

        registry.tool "flee",
          description: "Attempt to flee from combat in a random available direction.",
          parameters: {} do
          next guard.call if guard.call
          combat_cmd.call(p.flee)
        end

        registry.tool "set_position",
          description: "Change body position. Use 'rest' or 'sleep' between fights to recover " \
                       "HP and mana. Must be standing to move or fight.",
          parameters: {
            position: { type: "string", description: "Position: stand | sit | rest | sleep | wake" }
          } do |position:|
          next guard.call if guard.call
          begin
            send_cmd.call(p.set_position(position))
          rescue ArgumentError => e
            "error: #{e.message}"
          end
        end

        registry.tool "track",
          description: "Attempt to track a mob or player by name, revealing which direction " \
                       "they are in. Requires the Track skill.",
          parameters: {
            target: { type: "string", description: "Name of the mob or player to track" }
          } do |target:|
          next guard.call if guard.call
          begin
            send_cmd.call(p.track(target))
          rescue ArgumentError => e
            "error: #{e.message}"
          end
        end

        # ── Combat ──────────────────────────────────────────────────────────

        registry.tool "fight",
          description: "Kill one mob, start to finish, in a single call — the way to actually fight. " \
                       "It re-considers the target (refuses if too dangerous unless force:true), sets a " \
                       "wimpy safety floor, leads with your best trained OPENER when it applies (e.g. a " \
                       "Thief's backstab: it wields a dagger, strikes, then swaps back to your main " \
                       "weapon), lets the fight's auto-rounds run to the kill, loots the corpse, and " \
                       "returns ONE line: outcome + your HP + xp/level gained. You do NOT see or drive " \
                       "individual rounds. Pair with `hunt`: hunt finds safe prey, fight kills it. Use " \
                       "this instead of attack/skill_strike by hand.",
          parameters: {
            target: { type: "string", description: "Name/keyword of the mob to kill (e.g. 'crawler')" },
            force:  { type: "boolean", description: "Fight even if consider rates it unsafe (default false). Rarely needed." }
          } do |target:, force: false|
          next guard.call if guard.call
          begin
            fight.call(target: target, force: force ? true : false)
          rescue MudManager::Session::Error, ArgumentError => e
            "error: #{e.message}"
          end
        end

        registry.tool "attack",
          description: "Low-level single attack (one command, one round of response). Prefer `fight`, " \
                       "which runs a whole fight to completion. Use this only for a deliberate one-off " \
                       "strike. Style 'kill' is standard; 'murder' bypasses the mercy check; 'hit' is a " \
                       "one-off strike.",
          parameters: {
            target: { type: "string", description: "Name of the mob or player to attack" },
            style:  { type: "string", description: "Attack style: kill | hit | murder (default: kill)" }
          } do |target:, style: "kill"|
          next guard.call if guard.call
          begin
            combat_cmd.call(p.attack(style, target))
          rescue ArgumentError => e
            "error: #{e.message}"
          end
        end

        registry.tool "skill_strike",
          description: "Use a combat skill against a target.",
          parameters: {
            skill:  { type: "string", description: "Skill: bash | kick | backstab | rescue | assist" },
            target: { type: "string", description: "Name of the mob or player" }
          } do |skill:, target:|
          next guard.call if guard.call
          begin
            combat_cmd.call(p.skill_strike(skill, target))
          rescue ArgumentError => e
            "error: #{e.message}"
          end
        end

        registry.tool "consider",
          description: "Assess a mob's relative strength before engaging in combat. " \
                       "Returns a phrase such as 'You could kill it easily' or " \
                       "'Death awaits you'. Always consider before attacking an unknown mob.",
          parameters: {
            target: { type: "string", description: "Name of the mob to consider" }
          } do |target:|
          next guard.call if guard.call
          begin
            send_cmd.call(p.consider(target))
          rescue ArgumentError => e
            "error: #{e.message}"
          end
        end

        # ── Communication ───────────────────────────────────────────────────

        registry.tool "say",
          description: "Speak or emote in the current room.",
          parameters: {
            text: { type: "string", description: "What to say or emote" },
            mode: { type: "string", description: "Mode: say | emote | reply (default: say)" }
          } do |text:, mode: "say"|
          next guard.call if guard.call
          begin
            send_cmd.call(p.say_local(mode, text))
          rescue ArgumentError => e
            "error: #{e.message}"
          end
        end

        registry.tool "tell",
          description: "Send a private message to a specific player.",
          parameters: {
            target: { type: "string", description: "Player name to message" },
            text:   { type: "string", description: "The message" },
            mode:   { type: "string", description: "Mode: tell | whisper | ask (default: tell)" }
          } do |target:, text:, mode: "tell"|
          next guard.call if guard.call
          begin
            send_cmd.call(p.say_targeted(mode, target, text))
          rescue ArgumentError => e
            "error: #{e.message}"
          end
        end

        registry.tool "channel_say",
          description: "Broadcast a message over a global channel.",
          parameters: {
            channel: { type: "string", description: "Channel: shout | gossip | auction | grats | holler" },
            text:    { type: "string", description: "The message to broadcast" }
          } do |channel:, text:|
          next guard.call if guard.call
          begin
            send_cmd.call(p.say_channel(channel, text))
          rescue ArgumentError => e
            "error: #{e.message}"
          end
        end

        # ── Inventory & equipment ────────────────────────────────────────────

        registry.tool "get_item",
          description: "Pick up an item from the room or from a container.",
          parameters: {
            item:      { type: "string",  description: "Name of the item to get" },
            container: { type: "string",  description: "Container to get it from (optional)" },
            count:     { type: "integer", description: "Number of items to get (optional)" }
          } do |item:, container: nil, count: nil|
          next guard.call if guard.call
          begin
            send_cmd.call(p.get(item, container: container, count: count))
          rescue ArgumentError => e
            "error: #{e.message}"
          end
        end

        registry.tool "drop_item",
          description: "Drop, donate, or junk an item.",
          parameters: {
            item:  { type: "string",  description: "Name of the item" },
            mode:  { type: "string",  description: "Mode: drop | donate | junk (default: drop)" },
            count: { type: "integer", description: "Number of items (optional)" }
          } do |item:, mode: "drop", count: nil|
          next guard.call if guard.call
          begin
            send_cmd.call(p.drop(mode, item, count: count))
          rescue ArgumentError => e
            "error: #{e.message}"
          end
        end

        registry.tool "put_item",
          description: "Put an item into a container.",
          parameters: {
            item:      { type: "string",  description: "Name of the item to put" },
            container: { type: "string",  description: "Name of the container" },
            count:     { type: "integer", description: "Number of items (optional)" }
          } do |item:, container:, count: nil|
          next guard.call if guard.call
          begin
            send_cmd.call(p.put(item, container, count: count))
          rescue ArgumentError => e
            "error: #{e.message}"
          end
        end

        registry.tool "equip_item",
          description: "Wear, wield, hold, grab, or remove an item.",
          parameters: {
            item:     { type: "string", description: "Name of the item" },
            action:   { type: "string", description: "Action: wear | wield | hold | grab | remove" },
            body_loc: { type: "string", description: "Body location to wear on (optional, e.g. 'head', 'finger')" }
          } do |item:, action:, body_loc: nil|
          next guard.call if guard.call
          begin
            send_cmd.call(p.equip(action, item, body_loc: body_loc))
          rescue ArgumentError => e
            "error: #{e.message}"
          end
        end

        registry.tool "consume_item",
          description: "Eat, drink, taste, or sip a consumable item.",
          parameters: {
            item: { type: "string", description: "Name of the item to consume" },
            mode: { type: "string", description: "Mode: eat | drink | taste | sip (default: eat)" }
          } do |item:, mode: "eat"|
          next guard.call if guard.call
          begin
            send_cmd.call(p.consume(mode, item))
          rescue ArgumentError => e
            "error: #{e.message}"
          end
        end

        # ── Magic ────────────────────────────────────────────────────────────

        registry.tool "cast_spell",
          description: "Cast a spell, optionally at a target.",
          parameters: {
            spell:  { type: "string", description: "Full spell name (e.g. 'cure light wounds', 'magic missile')" },
            target: { type: "string", description: "Target mob, player, or object (optional)" }
          } do |spell:, target: nil|
          next guard.call if guard.call
          begin
            send_cmd.call(p.cast(spell, target: target))
          rescue ArgumentError => e
            "error: #{e.message}"
          end
        end

        registry.tool "use_magic_item",
          description: "Activate a magic item: quaff a potion, recite a scroll, or use a wand/staff.",
          parameters: {
            item:        { type: "string", description: "Name of the item to activate" },
            mode:        { type: "string", description: "Mode: quaff | recite | use" },
            target_args: { type: "string", description: "Optional target arguments (e.g. mob name for a wand)" }
          } do |item:, mode:, target_args: nil|
          next guard.call if guard.call
          begin
            send_cmd.call(p.use_magic_item(mode, item, target_args: target_args))
          rescue ArgumentError => e
            "error: #{e.message}"
          end
        end

        # ── Utility ──────────────────────────────────────────────────────────

        registry.tool "shop",
          description: "Interact with a shop NPC: list stock, buy, sell, or get the value of an item.",
          parameters: {
            action: { type: "string", description: "Action: list | buy | sell | value | offer" },
            args:   { type: "string", description: "Item name or number (optional)" }
          } do |action:, args: nil|
          next guard.call if guard.call
          begin
            send_cmd.call(p.shop(action, args: args))
          rescue ArgumentError => e
            "error: #{e.message}"
          end
        end

        registry.tool "practice",
          description: "List your known skills at a guildmaster, or practice a specific skill.",
          parameters: {
            skill: { type: "string", description: "Skill name to practice (omit to list all)" }
          } do |skill: nil|
          next guard.call if guard.call
          send_cmd.call(p.practice(skill))
        end

        registry.tool "save_character",
          description: "Save your character to disk so progress is not lost on disconnect.",
          parameters: {} do
          next guard.call if guard.call
          send_cmd.call(p.save_char)
        end

        registry.tool "send_raw",
          description: "Send an arbitrary command string to the MUD and return the response. " \
                       "Use this as an escape hatch when no structured tool fits.",
          parameters: {
            command: { type: "string", description: "The raw command to send (e.g. 'who', 'help backstab')" }
          } do |command:|
          next guard.call if guard.call
          session.send_command(command)
          session.read_until_quiet
        end

        # ── Thief & survival ─────────────────────────────────────────────────

        registry.tool "stealth",
          description: "Move or act unseen — core to a fragile Thief. 'hide' before a backstab so " \
                       "the first blow lands from concealment; 'sneak' to cross rooms without waking " \
                       "mobs; 'visible' to drop concealment. Hiding can fail silently — do not assume " \
                       "it worked; verify before relying on it.",
          parameters: {
            mode: { type: "string", description: "Mode: hide | sneak | visible" }
          } do |mode:|
          next guard.call if guard.call
          begin
            send_cmd.call(p.stealth(mode))
          rescue ArgumentError => e
            "error: #{e.message}"
          end
        end

        registry.tool "steal",
          description: "Steal an item or gold from a target with no fight — the Thief's signature skill. " \
                       "RISKY: on failure the victim notices and may attack, which at low HP is often " \
                       "fatal. Prefer sleeping or weak marks, and consider them first. Use item 'coins' " \
                       "(or 'gold') to take money.",
          parameters: {
            item:   { type: "string", description: "Item to steal, or 'coins'/'gold' for money" },
            victim: { type: "string", description: "Name of the mob or player to steal from" }
          } do |item:, victim:|
          next guard.call if guard.call
          begin
            combat_cmd.call(p.steal(item, victim))
          rescue ArgumentError => e
            "error: #{e.message}"
          end
        end

        registry.tool "door",
          description: "Operate a door or container: open/close to pass, lock/unlock with a held key, " \
                       "or 'pick' a lock (a Thief skill). Give direction when several exits have doors " \
                       "(e.g. the north door).",
          parameters: {
            action:    { type: "string", description: "Action: open | close | lock | unlock | pick" },
            target:    { type: "string", description: "The door or container (e.g. 'door', 'gate', 'chest')" },
            direction: { type: "string", description: "Direction of the door (optional): north|east|south|west|up|down" }
          } do |action:, target:, direction: nil|
          next guard.call if guard.call
          begin
            send_cmd.call(p.door(action, target, direction: direction))
          rescue ArgumentError => e
            "error: #{e.message}"
          end
        end

        registry.tool "set_wimpy",
          description: "Set an auto-flee threshold: when your hit points fall below this in combat you " \
                       "flee automatically. Your single best survival lever at low HP — set it to roughly " \
                       "a third of your max HP before any fight. Use 0 to turn it off.",
          parameters: {
            hp: { type: "integer", description: "HP threshold to auto-flee below (0 disables)" }
          } do |hp:|
          next guard.call if guard.call
          # NOTE: this tbaMUD build wants "toggle wimpy <hp>". The bare "wimpy <hp>"
          # that MudManager::Primitives.set_wimpy emits returns "Huh!?!" here, so we
          # send the working form directly.
          if hp.is_a?(Integer) && hp >= 0
            send_cmd.call("toggle wimpy #{hp}")
          else
            "error: hp must be a non-negative integer"
          end
        end

        registry.tool "diagnose",
          description: "Read a target's remaining health mid-fight (or before one) to decide whether " \
                       "you are winning or should flee. Omit target to diagnose your current opponent.",
          parameters: {
            target: { type: "string", description: "Name of the mob to diagnose (optional)" }
          } do |target: nil|
          next guard.call if guard.call
          begin
            send_cmd.call(p.diagnose(target))
          rescue ArgumentError => e
            "error: #{e.message}"
          end
        end

        registry.tool "rent",
          description: "Rent a room at an inn to persist your character, gear, and location so death " \
                       "does not cost them. Costs gold per day scaled to what you carry.",
          parameters: {} do
          next guard.call if guard.call
          send_cmd.call(p.rent)
        end

        registry.tool "bank",
          description: "Use a bank at a banker NPC: check balance, deposit gold (so death does not drop " \
                       "it), or withdraw.",
          parameters: {
            action: { type: "string",  description: "Action: balance | deposit | withdraw" },
            amount: { type: "integer", description: "Amount of gold (for deposit/withdraw)" }
          } do |action:, amount: nil|
          next guard.call if guard.call
          begin
            send_cmd.call(p.bank(action, amount: amount))
          rescue ArgumentError => e
            "error: #{e.message}"
          end
        end

        # Auto-connect at startup so the session is ready immediately and the
        # agent doesn't need to waste a turn calling mud_connect first.
        begin
          session.open
          session.login(name, password)
          orient.call
        rescue MudManager::Session::Error => e
          warn "[boukensha] MUD auto-connect failed: #{e.message} — call mud_connect manually"
        end

      end # def self.register
    end # Mud
  end # Tools
end # Boukensha
