require "mud_manager"
require_relative "mud_text"
require_relative "../world_model"

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
        send_cmd = lambda do |command|
          session.drain
          session.send_command(command)
          session.read_until_prompt
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
        remember = lambda do |text, arrived_via: nil|
          note = begin
            world.observe(text, arrived_via: arrived_via)
          rescue StandardError => e
            warn "[boukensha] world_model error: #{e.message}"
            nil
          end
          note ? "#{text}\n#{note}" : text
        end

        # Slice 3: deterministic travel. Resolve a destination, BFS a route over
        # the mapped graph, and walk it step by step — spending no model tokens on
        # the mundane moves. Control returns to the agent only on a compelling
        # event: combat, a blocked exit, or arriving off-map.
        full_dir   = { "n" => "north", "s" => "south", "e" => "east",
                       "w" => "west", "u" => "up", "d" => "down" }
        combat_re  = /\b(?:hits?|bashes?|bites?|claws?|attacks?|strikes?|slashes?|pierces?|crushes?|pounds?|mauls?|smites?)\s+you\b|\byou\s+are\s+attacked\b|\byou\s+have\s+been\s+(?:killed|attacked)\b/i
        blocked_re = /\b(?:cannot\s+go\s+that\s+way|the\s+door\s+is\s+closed|it\s+seems\s+to\s+be\s+closed|isn'?t\s+open)\b/i

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

          walked = []
          route.each do |short|
            dir    = full_dir[short] || short
            result = send_cmd.call(p.move(dir))
            world.observe(result, arrived_via: dir)
            body   = MudText.strip_ansi(result).strip

            if world.parse_room(result).nil? || body =~ blocked_re
              return "Stopped: move #{dir} was blocked after #{walked.empty? ? 'no moves' : walked.join(' → ')}.\n#{body}"
            end
            if body =~ combat_re
              return "Stopped en route — COMBAT at room ##{world.current_id} after #{walked.join(' → ')}. Your call:\n#{body}"
            end
            walked << dir
          end

          arrived = world.current_id
          if target && arrived != target
            return "Walked #{walked.join(' → ')} but ended at room ##{arrived}, not #{label} — the map may be stale. Re-look and replan."
          end
          "Arrived at #{label} via #{walked.join(' → ')} (#{walked.size} room#{walked.size == 1 ? '' : 's'}). No decisions needed en route."
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
              "connected to #{session.host}:#{session.port}\n#{welcome}"
            rescue MudManager::Session::Error => e
              "error: #{e.message}"
            end
          end
        end

        registry.tool "mud_disconnect",
          description: "Close the connection to the MUD server gracefully.",
          parameters: {} do
          if session.open?
            session.close
            "disconnected"
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
              remember.call(result)
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
          description: "Move in a compass direction or up/down.",
          parameters: {
            direction: { type: "string", description: "Direction: north | east | south | west | up | down" }
          } do |direction:|
          next guard.call if guard.call
          begin
            result = send_cmd.call(p.move(direction))
            remember.call(result, arrived_via: direction)
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

        registry.tool "attack",
          description: "Attack a target. Style 'kill' is the standard approach; " \
                       "'murder' bypasses the mercy check; 'hit' is a one-off strike.",
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
        rescue MudManager::Session::Error => e
          warn "[boukensha] MUD auto-connect failed: #{e.message} — call mud_connect manually"
        end

      end # def self.register
    end # Mud
  end # Tools
end # Boukensha
