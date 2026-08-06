# Planning orchestrator: Sonnet-5 PLANS (structured, checkable milestones), Haiku
# EXECUTES one milestone per run, a persistent Ruby ORCHESTRATOR threads the goal +
# progress across runs via plan.json and judges completion deterministically.
ENV["BOUKENSHA_DIR"] ||= "/home/tim/claude-codecamp/.boukensha"
$LOAD_PATH.unshift File.expand_path("/home/tim/claude-codecamp/week1_baseline/ruby/12_context/lib")
require "boukensha"
require "boukensha/registry"
require "boukensha/context"
require "boukensha/tools/mud"
require "boukensha/skills"
require "json"

module Plan
  PLAN_PATH   = File.join(ENV["BOUKENSHA_DIR"], "plan.json")
  # WHO is playing comes from the config dir (BOUKENSHA_DIR), never from here —
  # same rule as the rest of boukensha: identity in config. Point BOUKENSHA_DIR at
  # a different character's dir and the whole orchestration runs as that character.
  CFG         = Boukensha.config
  MUD         = { host: CFG.mud_host, port: CFG.mud_port,
                  name: CFG.mud_username, password: CFG.mud_password,
                  char_class: CFG.mud_class }
  CHAR_NAME   = (CFG.mud_username || "the character").capitalize
  CHAR_CLASS  = (CFG.mud_class || "adventurer").capitalize
  PLANNER     = "claude-sonnet-5"
  # The planner emits a whole JSON plan in ONE response, so it needs far more output
  # room than the executor's short per-turn replies. Inheriting the executor's
  # `agent.max_output_tokens` (1024) truncated a five-milestone plan mid-string —
  # the JSON never closed its bracket and planning died with "returned no JSON".
  # Compound goals ("get equipped, find X, earn money, provision, buy Y") are exactly
  # the case that overflows it.
  PLANNER_MAX_TOKENS = 4096
  EXECUTOR    = "claude-haiku-4-5"
  MAX_RUNS_PER_MILESTONE = 4
  # Replanning is the recovery path, but it must terminate: a goal that is genuinely
  # impossible would otherwise loop forever, replanning around a wall that never moves.
  #
  # Scaled to the GOAL, not fixed: a five-part compound goal ("get equipped, find the
  # zone, earn money, provision, buy a teleporter") legitimately needs more course
  # corrections than "go kill things". A flat 3 stranded a character with 44 gold in
  # hand and two milestones left, having spent every replan on things the planner
  # could not have known (prices, a light it already owned).
  MIN_REPLANS = 3
  MAX_REPLANS_CAP = 8

  module_function

  # One replan per milestone in the ORIGINAL plan, within bounds. (Defined AFTER
  # `module_function` on purpose — above it, this is only an instance method and
  # `Plan.orchestrate` would NoMethodError the moment a blocker appeared.)
  def replan_budget(plan)
    n = (plan["milestones"] || []).size
    [[n, MIN_REPLANS].max, MAX_REPLANS_CAP].min
  end

  def c(t) = t.to_s.gsub(/\e\[[0-9;?]*[ -\/]*[@-~]/, "")

  # ---- deterministic game-state read (its own short-lived connection) --------
  def read_state
    ctx = Boukensha::Context.new(system: "t")
    reg = Boukensha::Registry.new(ctx)
    Boukensha::Tools::Mud.register(reg, **MUD)
    score = c(reg.dispatch("check", { "kind" => "score" }))
    prac  = Boukensha::Skills.parse_practice(reg.dispatch("practice", {}))
    loc   = c(reg.dispatch("look", {})).lines.first.to_s.strip
    # What the character is CARRYING and WEARING. Without this, `has_item` done_checks
    # could never be verified — they were hardcoded to false, so an entire provisioning
    # plan (buy armour / weapon / food / water / teleporter) was unsatisfiable by
    # construction: the character could own every item and still never tick a milestone.
    items = c(reg.dispatch("check", { "kind" => "inventory" })).to_s +
            "\n" + c(reg.dispatch("check", { "kind" => "equipment" })).to_s
    # Quit CLEANLY, not just disconnect: a bare disconnect would leave Perry
    # link-dead in whatever room this read touched. mud_quit saves + extracts him
    # (login restores his position), so these frequent state reads never leave an
    # attackable idle body behind.
    reg.dispatch("mud_quit", {})
    {
      level:     score[/\(level\s+(\d+)\)/i, 1]&.to_i,
      xp:        score[/have\s+(\d+)\s+exp/i, 1]&.to_i,
      hp:        score[/(\d+)\(\d+\)\s+hit/i, 1]&.to_i,
      gold:      score[/(\d+)\s+gold\s+coins/i, 1]&.to_i,
      location:  loc,
      sessions:  prac[:sessions],
      skills:    prac[:skills],
      items:     items.downcase
    }
  end

  # ---- planner: goal + state -> structured milestones -----------------------
  PLANNER_SYSTEM = <<~SYS
    You are the PLANNER for an agent playing tbaMUD as #{CHAR_NAME}, a #{CHAR_CLASS}. A cheaper
    model executes your plan with deterministic tools (hunt=find best safe mob; fight=kill it;
    rest_until hp:N=heal; explore=step into unmapped territory; seek "<place>"=find an unmapped
    place; travel_to "<place>"; practice "<skill>"=train at the guild, costs 1 practice session
    earned per level). Leveling comes only from killing mobs for xp.

    Plan for the character as they ACTUALLY are — the state block below is the truth about
    their level, gear, and skills. Do NOT assume they know where anything is: if a milestone
    needs a place they have not been, the milestone is to FIND it (explore/seek), and only
    then to use it.

    Turn the goal into an ordered JSON array of milestones the executor can run. Each:
      { "milestone": "<short imperative>", "tools": ["hunt","fight",...],
        "done_check": <one of the machine-checkable forms below> }
    done_check MUST be one of:
      { "type":"xp_at_least",    "value": <int> }
      { "type":"level_at_least", "value": <int> }
      { "type":"gold_at_least",  "value": <int> }
      { "type":"at_place",       "name": "<room name substring>" }
      { "type":"skill_trained",  "skill": "<skill>" }
      { "type":"has_item",       "name": "<item substring>" }

    Match the check to the goal. Money goals use gold_at_least with the ACTUAL price —
    a 12-coin item needs 12 coins, not "reach level 5". Acquisition goals use has_item
    with a short distinctive substring ("sword", "canteen", "teleporter"), never a
    level as a proxy.

    YOU DO NOT KNOW PRICES until something reports one. Never plan a purchase the
    character cannot currently afford — if the gold on hand looks thin, put an
    EARNING milestone (gold_at_least) in front of the purchase rather than hoping.
    When a report below tells you what something actually cost, use that number.

    ORDER OF OPERATIONS — plan for survival first. A new character is naked, broke and
    fragile, and the cheap fixes come before the expensive ones:
      1. GEAR UP first. A wielded weapon and worn armour change what is survivable more
         than anything else, and a newcomer can be outfitted for free before spending a
         coin. Never send an unarmed character out to explore or fight.
      2. LIGHT, FOOD and WATER next — BUT ONLY IF THE CHARACTER CAN PAY FOR THEM.
         Anything bought needs coin, so read the GOLD in the state block first: if it is
         low, an EARNING milestone (gold_at_least) MUST come before every purchase.
         A broke character's real order is gear → HUNT → provisions, not gear →
         provisions → hunt. Scheduling a purchase for someone with no money is the
         single most common way these plans stall.
      3. THEN hunt, to earn xp and gold (or FIRST, per the rule above, when broke).
      4. TRAIN LAST. Practice sessions are earned by LEVELLING, so training before the
         character can level is out of order, and the guildmaster must be FOUND first.
    Never schedule a milestone whose prerequisite comes later in the plan.

    FINDING SOMEWHERE IS NOT A MILESTONE. "Find the shop that sells X", "locate the
    guild", "find a hunting ground" are HOW the executor accomplishes the next step —
    it has seek/explore and does the searching itself. Write the milestone that OWNS
    the outcome ("buy X" with has_item, "train Y" with skill_trained) and let the search
    happen inside it. Only use at_place when ARRIVING somewhere is genuinely the goal,
    and only for a room in the MAP list above — a name that is not there cannot be
    checked, so the milestone can never complete.

    CRITICAL: milestones are CHECKPOINTS — real, verifiable progress markers — not
    individual tool calls. The executor already sequences the fine-grained tools on its
    own (finding a mob, healing, retrying, chasing) WITHIN a milestone. So:
      - Do NOT make "find a mob", "heal", or "rest" their own milestones — those are
        execution details inside a grind milestone (the "tools" list can still name them).
      - Every milestone's done_check must be a REAL, non-trivial checkpoint — never a
        check that's already true at the start.
      - Aim for the FEWEST milestones that capture the actual progress (e.g. reaching an
        xp/level, arriving somewhere, training a skill).
    Order so dependencies come first. Output ONLY the JSON array, no prose.
  SYS

  # Places the character has ACTUALLY been. Without this the planner cannot tell a
  # found place from an imagined one, and cheerfully schedules "train at the guild"
  # for a character who has never located a guild — the executor then reports the
  # blocker every run and the plan stalls. Read straight from the map store.
  def known_places(limit = 40)
    path = File.join(ENV["BOUKENSHA_DIR"], "world.json")
    return [] unless File.exist?(path)
    JSON.parse(File.read(path)).fetch("rooms", {}).values.map { |r| r["name"] }.compact.uniq.first(limit)
  rescue JSON::ParserError
    []
  end

  # The item lines a planner needs, condensed: what is worn/wielded and what is carried.
  # Without this the planner re-schedules gear the character is ALREADY wearing ("buy
  # armor" for someone in a breast plate) and plans purchases for someone with no money.
  # It also lets it pick has_item substrings that MATCH the real item names — "armor"
  # never matches "a breast plate", so a guessed noun makes an untickable milestone.
  def owned_summary(state)
    lines = state[:items].to_s.lines.map(&:strip).reject(&:empty?)
    worn    = lines.grep(/\A<[^>]+>/).map { |l| l.sub(/\A<([^>]+)>\s*/) { "#{$1}: " } }
    carried = lines.reject { |l| l =~ /\A<[^>]+>/ || l =~ /you are (using|carrying)/i || l =~ /\Anothing\.?\z/i }
    { worn: worn, carried: carried }
  end

  def state_block(state)
    places = known_places
    own    = owned_summary(state)
    <<~S.strip
      #{CHAR_NAME} now: level #{state[:level]}, #{state[:xp]} exp, #{state[:gold].to_i} GOLD COINS,
      at #{state[:location]}, #{state[:sessions]} practice session(s),
      skills #{state[:skills].empty? ? '(none trained)' : state[:skills].map { |k, v| "#{k} (#{v})" }.join(', ')}.
      WEARING/WIELDING: #{own[:worn].empty? ? '(nothing — unarmed and unarmoured)' : own[:worn].join('; ')}
      CARRYING: #{own[:carried].empty? ? '(nothing)' : own[:carried].join('; ')}
      Do NOT plan to acquire something already listed above, and do NOT plan a purchase
      costing more than #{state[:gold].to_i} gold — earn the coin first. When you use
      has_item, take the substring from the item names above so the check can match.
      MAP — the #{places.size} place(s) #{CHAR_NAME} has actually found so far:
      #{places.empty? ? '(nothing mapped yet — everywhere is unknown)' : places.join('; ')}
      Anywhere NOT in that list has not been found yet and cannot simply be travelled to.
    S
  end

  def plan!(goal, state)
    task = <<~T
      GOAL: #{goal}
      #{state_block(state)}
      Produce the milestone plan (JSON only).
    T
    raw  = Boukensha.run(task: task, system: PLANNER_SYSTEM, model: PLANNER, mud: false, working_dir: false,
                         max_output_tokens: PLANNER_MAX_TOKENS)
    parse_plan(raw, "planner")
  end

  # Pull the milestone array out of a planner reply, and say something USEFUL when it
  # isn't there. The failure that motivated this was a silently TRUNCATED response —
  # valid JSON as far as it went, no closing bracket — reported only as "returned no
  # JSON" with a wall of text. Distinguish "ran out of room" from "wrote prose".
  # Pull the FIRST balanced JSON array out of a reply. A greedy /\[.*\]/m match was
  # wrong: it spans from the first "[" ANYWHERE in the text to the last "]", so a
  # bracket in prose (or a ```json fence) makes the match start mid-object and the
  # parse fails on valid output. Scan with a depth counter instead, and respect
  # string literals so a "[" inside a milestone description can't throw the count off.
  def extract_json_array(raw)
    text = raw.to_s.gsub(/```(?:json)?/i, "")
    # Try EVERY "[" as a candidate start, not just the first: prose like
    # "use tools [hunt] first" opens a bracket that closes into "[hunt]", which is
    # not the plan. Take the first candidate that parses into an array of milestones.
    text.each_char.with_index.select { |ch, _| ch == "[" }.each do |_, start|
      span = balanced_span(text, start)
      next unless span
      parsed = begin
        JSON.parse(span)
      rescue JSON::ParserError
        nil
      end
      return span if parsed.is_a?(Array) && parsed.all? { |m| m.is_a?(Hash) } && !parsed.empty?
    end
    nil
  end

  # The substring from `start` (a "[") through its matching "]", or nil if unclosed.
  # String-aware, so a bracket inside a milestone description can't skew the depth.
  def balanced_span(text, start)
    depth = 0
    in_str = false
    escaped = false
    text[start..].each_char.with_index do |ch, i|
      if in_str
        if escaped       then escaped = false
        elsif ch == "\\" then escaped = true
        elsif ch == '"'  then in_str = false
        end
        next
      end
      case ch
      when '"' then in_str = true
      when "[" then depth += 1
      when "]"
        depth -= 1
        return text[start, i + 1] if depth.zero?
      end
    end
    nil
  end

  def parse_plan(raw, who)
    json = extract_json_array(raw)
    unless json
      hint = if raw.to_s.include?("[")
               "the reply STARTS a JSON array but never closes it — almost certainly " \
               "truncated by the output-token limit (currently #{PLANNER_MAX_TOKENS}). " \
               "Raise PLANNER_MAX_TOKENS or ask for fewer milestones."
             else
               "the reply contains no JSON array at all — the #{who} wrote prose instead."
             end
      raise "#{who} returned no usable plan: #{hint}\n--- reply ---\n#{raw.to_s[0, 800]}"
    end
    JSON.parse(json)
  rescue JSON::ParserError => e
    raise "#{who} returned malformed JSON (#{e.message}):\n#{json.to_s[0, 800]}"
  end

  # ---- REPLAN: a blocker is information, not a reason to retry ----------------
  # When a milestone runs and nothing about the world changes, repeating it is
  # pure waste — the executor already said why it couldn't proceed. Hand the
  # planner that report and let it route AROUND the obstacle: usually by making
  # the missing prerequisite (a place not yet found, an item not owned) its own
  # milestone first.
  # A short history of orderings ALREADY TRIED and how they failed. Without it the
  # replanner has amnesia: on a live run it inverted "buy before earn" at replan 1,
  # corrected it at 2, and then re-proposed the SAME inversion at replan 4 — three of
  # five replans spent cycling through an approach it had already abandoned.
  def attempt_history(plan)
    tried = (plan["progress"] || []).grep(/REPLANNED/).last(6)
    return "(this is the first revision)" if tried.empty?
    tried.map { |t| "- #{t}" }.join("\n")
  end

  def replan!(goal, state, stuck_milestone, blocker, done_so_far, history = nil)
    task = <<~T
      GOAL: #{goal}
      #{state_block(state)}

      THE PLAN IS STUCK and must be revised.
      Already accomplished: #{done_so_far.empty? ? '(nothing yet)' : done_so_far.join('; ')}

      ALREADY TRIED, and the state the character was in AT THE TIME:
      #{history || '(this is the first revision)'}

      Use that as evidence, NOT as a blocklist. Most of these failed because a
      PRECONDITION was missing, not because the idea was wrong — a purchase that failed
      at 0 gold is perfectly sound once the gold exists. Compare each against the CURRENT
      state above: repeat an approach only if what defeated it has since changed, and
      never repeat one whose blocker still stands. Do not drop a step the goal genuinely
      needs just because an earlier ordering of it failed.

      The milestone that stalled: #{stuck_milestone['milestone'].inspect}
      The executor attempted it and reported back:
      ---
      #{blocker.to_s.strip[0, 1200]}
      ---
      Nothing measurable changed in the game state, so re-running it unchanged would
      fail the same way.

      Produce a NEW ordered milestone array for everything that REMAINS of the goal,
      routing AROUND this blocker:
        - If it's a missing prerequisite (somewhere not yet found, an item not owned,
          a skill not trained), make FINDING or ACQUIRING that the next milestone —
          `explore`/`seek` find unmapped places.
        - If the stalled step turns out not to be needed for the goal, drop it.
        - Do not re-issue the stalled milestone unchanged.
        - Do not re-propose an ordering whose blocker STILL applies; an ordering that
          failed for a reason since resolved is fair game again.
      Output ONLY the JSON array, no prose.
    T
    raw  = Boukensha.run(task: task, system: PLANNER_SYSTEM, model: PLANNER, mud: false, working_dir: false,
                         max_output_tokens: PLANNER_MAX_TOKENS)
    parse_plan(raw, "replanner")
  end

  # Did the run move the milestone FORWARD? Deterministic, no text heuristics — but
  # judged against what the milestone is actually for, because a single global
  # "did anything change" signal is wrong in both directions:
  #
  #   * too lenient — during an xp grind, wandering one room read as "progress",
  #     so a run that killed nothing re-ran instead of replanning.
  #   * too strict  — an exploration milestone that mapped a dozen rooms and ended
  #     where it started read as "nothing happened", burning a replan on a success.
  #
  # So each done_check type gets the signal that actually reflects it, and map
  # growth counts as progress for the exploring kinds.
  def progressed?(before, after, check = nil, rooms_before = nil, rooms_after = nil)
    mapped_more = rooms_before && rooms_after && rooms_after > rooms_before

    case check && check["type"]
    when "xp_at_least", "level_at_least"
      after[:xp].to_i > before[:xp].to_i || after[:level].to_i > before[:level].to_i
    when "gold_at_least"
      # Money milestones are measured in MONEY. This used to fall through to the
      # permissive branch, where mapping a few rooms counted as "progress" — so a
      # character could wander for four runs earning nothing and never trigger the
      # replan that would have sent it somewhere with coin.
      after[:gold].to_i > before[:gold].to_i
    when "skill_trained"
      after[:skills] != before[:skills] || after[:sessions].to_i != before[:sessions].to_i
    when "at_place"
      # Getting somewhere is navigation: moving OR mapping new ground is progress.
      after[:location].to_s != before[:location].to_s || !!mapped_more
    when "has_item"
      # Acquiring something means the INVENTORY changed, or we found new ground while
      # looking for the shop. Pacing between rooms already on the map is not progress —
      # that let a character shuttle Temple ↔ Temple Square for four runs, "progressing"
      # every time, until the run budget ran out.
      after[:items].to_s != before[:items].to_s || !!mapped_more
    else
      # Unknown/has_item: fall back to "did anything at all move", map included.
      after[:xp].to_i > before[:xp].to_i ||
        after[:level].to_i > before[:level].to_i ||
        after[:sessions].to_i != before[:sessions].to_i ||
        after[:location].to_s != before[:location].to_s ||
        after[:skills] != before[:skills] ||
        !!mapped_more
    end
  end

  # How many rooms the map holds right now — the progress signal for exploration.
  def room_count
    path = File.join(ENV["BOUKENSHA_DIR"], "world.json")
    return 0 unless File.exist?(path)
    JSON.parse(File.read(path)).fetch("rooms", {}).size
  rescue JSON::ParserError
    0
  end

  # A planner naming an item it has never seen must GUESS the in-game noun, and the
  # guess is usually the category ("water", "food") while the game hands you "a cup"
  # and "a danish pastry". A literal substring match then fails on a milestone the
  # character actually completed — Solace bought both, spent 37 gold, and the plan
  # aborted anyway. So: exact match first, then fall back to the category the word
  # names. Deliberately generous — a false "yes" costs one skipped milestone, a false
  # "no" burns the whole run budget on something already done.
  ITEM_CATEGORIES = {
    # Any container noun means "get me something to drink from" — the shop may sell a
    # cup where the planner guessed canteen.
    /\A(?:water|drink|liquid|waterskin|canteen|bottle|flask|jug|cup)\z/ => /waterskin|flask|canteen|bottle|jug|cup|skin\b/,
    /\A(?:food|rations?|provisions?|bread)\z/ => /bread|loaf|waybread|ration|biscuit|hardtack|cheese|apple|banana|fruit|pastry|danish|pie|cake/,
    /\A(?:light|lamp|torch|candle)\z/         => /candle|torch|lantern|lamp|glowing/,
    /\A(?:weapon|blade)\z/                    => /sword|dagger|mace|club|axe|spear|staff|blade|hammer|flail|knife|whip/,
    /\A(?:armou?r|armour)\z/                  => /armou?r|plate|mail|shield|helm|cap\b|leggings|boots|gloves|sleeves|gorget|vest|wristguard/
  }.freeze

  def has_item?(state, name)
    items = state[:items].to_s
    want  = name.to_s.downcase.strip
    return false if want.empty?
    return true if items.include?(want)

    _, pattern = ITEM_CATEGORIES.find { |word_re, _| want =~ word_re }
    pattern ? !!(items =~ pattern) : false
  end

  # ---- plan validation: check the CHECKS before spending runs on them --------
  #
  # A plan is a set of assertions about what is verifiable. Nothing tested those
  # assertions, so an unverifiable one cost four executor runs to discover — the
  # planner asked three separate times to reach a room called "Teleporter", which
  # does not exist (the vendor is in the Reading Room), and once for gold_at_least 57
  # from a character holding exactly 57.
  #
  # Same failure the tool layer had, one storey up: asserting something without
  # checking it. So every done_check must be EVALUABLE NOW and NOT ALREADY TRUE
  # before the plan is accepted. Repair in place where we can; only the empty-plan
  # case goes back to the planner.
  #
  # Below this, a character cannot buy anything worth buying, so any acquisition
  # milestone scheduled ahead of an earning one is doomed.
  BROKE_BELOW = 15

  # Straighten an ordering the planner keeps getting wrong, WITHOUT asking it again.
  #
  # A broke character must earn before it can buy, but the ORDER OF OPERATIONS rule
  # states gear -> provisions -> hunt as a fixed sequence, so the planner proposes
  # purchases first about half the time. On a live run it inverted at replan 1,
  # corrected at 2, and regressed to the same inversion at 4 — reaching the right
  # order by attrition across five replans.
  #
  # We know the gold and we know which milestones acquire versus earn, so the fix is
  # mechanical: if every earning milestone sits behind an acquisition and the purse is
  # empty, hoist the first earning milestone to the front. Costs nothing, and the
  # planner may then propose whatever order it likes.
  # NOT everything acquired must be bought. A newcomer is outfitted FREE at the
  # donation room — weapon, armour and a light — so those acquisitions are not gated
  # on money and must never be pushed behind an earning milestone. Treating them as
  # purchases sent an unarmed 26-HP character off to hunt, which is exactly what the
  # gear-up-first rule exists to prevent.
  FREE_KIT = /\A(?:weapon|blade|sword|dagger|mace|club|axe|armou?r|plate|mail|shield|helm|light|lamp|torch|candle)\z/i

  def purchase?(milestone)
    check = milestone["done_check"] || {}
    return false unless check["type"] == "has_item"
    check["name"].to_s.strip !~ FREE_KIT
  end

  def repair_order(milestones, state)
    gold = state[:gold].to_i
    return [milestones, nil] if gold >= BROKE_BELOW

    # Only real PURCHASES need money in hand first.
    acquire_at = milestones.index { |m| purchase?(m) }
    earn_at    = milestones.index { |m| m.dig("done_check", "type") == "gold_at_least" }
    return [milestones, nil] unless acquire_at && earn_at && earn_at > acquire_at

    earner = milestones[earn_at]
    reordered = ([earner] + (milestones - [earner]))
    [reordered,
     "reordered: #{earner['milestone'].inspect} moved ahead of " \
     "#{milestones[acquire_at]['milestone'].inspect} — #{gold} gold can't buy anything yet"]
  end

  # Returns [kept_milestones, notes].
  def validate_plan(milestones, state, baseline)
    kept  = []
    notes = []

    milestones.each do |m|
      check = m["done_check"] || {}
      label = m["milestone"].to_s

      # 1. Already satisfied → no run needed. Advance past it silently.
      if done?(check, state, baseline)
        notes << "dropped (already true): #{label.inspect}"
        next
      end

      case check["type"]
      when "at_place"
        # FINDING SOMEWHERE IS NOT A CHECKPOINT — it is how the executor accomplishes
        # the milestone that follows, and `seek`/`explore` already do it. An at_place
        # naming a room we have never mapped is the planner expressing an instrumental
        # step as a terminal one; drop it and let the next milestone's real check
        # (has_item / xp / skill) carry the goal, with the search folded inside.
        name = check["name"].to_s.downcase.strip
        if name.empty? || known_places(1000).none? { |p| p.downcase.include?(name) }
          notes << "dropped (no mapped room matches #{check['name'].inspect}; the executor will find it while doing the next step): #{label.inspect}"
          next
        end
      when "skill_trained"
        # Can't verify training a skill the character does not know of.
        sk = check["skill"].to_s.downcase
        unless state[:skills].key?(sk)
          notes << "dropped (#{check['skill'].inspect} is not a skill this character knows): #{label.inspect}"
          next
        end
      when "xp_at_least", "level_at_least", "gold_at_least", "has_item"
        # Evaluable by construction; the already-true test above covers the rest.
      else
        notes << "dropped (unknown done_check type #{check['type'].inspect}): #{label.inspect}"
        next
      end

      kept << m
    end

    # Last: straighten earn-before-buy, once the unverifiable milestones are gone.
    kept, note = repair_order(kept, state)
    notes << note if note

    [kept, notes]
  end

  # ---- deterministic milestone completion check -----------------------------
  def done?(check, state, baseline)
    case check["type"]
    when "xp_at_least"    then state[:xp] && state[:xp]    >= check["value"].to_i
    when "level_at_least" then state[:level] && state[:level] >= check["value"].to_i
    when "at_place"       then state[:location].to_s.downcase.include?(check["name"].to_s.downcase)
    when "gold_at_least"  then state[:gold].to_i >= check["value"].to_i
    # Matches carried OR worn/wielded — "buy a sword" is satisfied by a sword in hand
    # just as much as one in the pack.
    when "has_item"       then has_item?(state, check["name"])
    when "skill_trained"
      sk = check["skill"].to_s.downcase
      Boukensha::Skills.proficiency_rank(state[:skills][sk]) >
        Boukensha::Skills.proficiency_rank(baseline[:skills][sk]) ||
        (state[:sessions] && baseline[:sessions] && state[:sessions] < baseline[:sessions])
    else false
    end
  end

  LIB_DIR  = "/home/tim/claude-codecamp/week1_baseline/ruby/12_context"
  EXEC_RB  = File.join(File.dirname(__FILE__), "exec_milestone.rb")

  # ---- executor: run ONE milestone via Haiku IN A SUBPROCESS (own MUD session),
  #      fed the goal + progress -------------------------------------------------
  def run_milestone(goal, m, progress)
    require "tempfile"
    task = <<~T
      You are executing ONE step of a larger plan — do only this step, then stop.
      OVERALL GOAL: #{goal}
      PROGRESS SO FAR: #{progress.empty? ? '(just started)' : progress.last}
      YOUR STEP NOW: #{m['milestone']}
      Do this step with your tools (#{Array(m['tools']).join(', ')}). Stop and report the
      moment the step is done, or report exactly what blocks you. Do not pursue later steps.
    T
    f = Tempfile.new("milestone"); f.write(task); f.close
    out = `cd #{LIB_DIR} && mise exec -- ruby #{EXEC_RB} #{f.path} #{EXECUTOR} 2>&1`
    f.unlink
    # exec_milestone prints the ===REPLY=== marker only after a completed turn. No
    # marker => the subprocess DIED (API error, crash) and never reported. That is an
    # infrastructure failure, not something the character can plan around — return nil
    # so the caller retries instead of replanning around a phantom obstacle.
    return nil unless out.include?("===REPLY===")
    out.split("===REPLY===", 2)[1].to_s.strip
  end

  # ---- persistence ----------------------------------------------------------
  def save(plan)  = File.write(PLAN_PATH, JSON.pretty_generate(plan))
  def load        = File.exist?(PLAN_PATH) ? JSON.parse(File.read(PLAN_PATH)) : nil

  # ---- the orchestration loop ----------------------------------------------
  def orchestrate(goal, fresh: true)
    File.delete(PLAN_PATH) if fresh && File.exist?(PLAN_PATH)
    plan = load
    unless plan
      st = read_state
      puts "== PLANNING (#{PLANNER}) =="
      raw_ms = plan!(goal, st).map { |m| m.merge("status" => "pending") }
      milestones, vnotes = validate_plan(raw_ms, st, { skills: st[:skills] || {}, sessions: st[:sessions] })
      vnotes.each { |n| puts "   · #{n}" }
      if milestones.empty?
        puts "   · every milestone was already satisfied or unverifiable — nothing to do."
      end
      plan = { "goal" => goal, "milestones" => milestones, "current" => 0,
               "progress" => [], "baseline" => nil, "replans" => 0 }
      save(plan)
      milestones.each_with_index { |m, i| puts "  #{i + 1}. #{m['milestone']}  [#{m['done_check'].to_json}]" }
    end

    loop do
      i = plan["current"]
      break puts("\n== ALL MILESTONES DONE — goal complete ==") if i >= plan["milestones"].size
      m = plan["milestones"][i]
      # snapshot baseline the first time this milestone becomes active
      plan["baseline"] ||= read_state.transform_keys(&:to_s)
      base = { skills: plan["baseline"]["skills"] || {}, sessions: plan["baseline"]["sessions"] }
      st   = read_state
      puts "\n== MILESTONE #{i + 1}/#{plan['milestones'].size}: #{m['milestone']} =="
      puts "   state: L#{st[:level]} #{st[:xp]}xp #{st[:sessions]}sess @ #{st[:location]}"

      if done?(m["done_check"], st, base)
        puts "   ✓ done_check already satisfied → advancing"
        m["status"] = "done"; plan["current"] += 1; plan["baseline"] = nil
        plan["progress"] << "#{m['milestone']}: done."
        save(plan); next
      end

      runs = (m["runs"] || 0)
      if runs >= MAX_RUNS_PER_MILESTONE
        # "Failed four times" is a BLOCKER report like any other — the right answer is
        # to plan around it, not to throw away the remaining milestones. Aborting here
        # stranded a character with a full pack and six untouched steps, while most of
        # the replan budget sat unused. Only stop once replanning is also exhausted.
        if plan["replans"].to_i < replan_budget(plan)
          puts "   ✗ #{runs} runs without completing — replanning around it instead of stopping."
          reply = "This milestone ran #{runs} times without satisfying its done_check and made no " \
                  "further progress. Treat it as unreachable AS WRITTEN: drop it, or replace it " \
                  "with a different route to the same end."
          revised = begin
            r = replan!(goal, st, m, reply, plan["milestones"].first(i).map { |mm| mm["milestone"] },
                        attempt_history(plan))
                  .map { |mm| mm.merge("status" => "pending") }
            r, vn = validate_plan(r, st, base)
            vn.each { |n| puts "   · #{n}" }
            r.empty? ? nil : r
          rescue StandardError => e
            puts "   ✗ replan failed (#{e.message.lines.first.to_s.strip}) — escalating."
            nil
          end
          if revised
            m["status"]        = "superseded"
            plan["milestones"] = plan["milestones"].first(i) + revised
            plan["current"]    = i
            plan["baseline"]   = nil
            plan["replans"]    = plan["replans"].to_i + 1
            plan["progress"] << "REPLANNED after #{runs} failed runs on #{m['milestone'].inspect} " \
                                "[at the time: L#{st[:level]} #{st[:xp]}xp #{st[:gold].to_i} gold]. " \
                                "That plan ordered them: #{plan['milestones'].drop(i).first(4).map { |mm| mm['milestone'] }.join(' → ')}"
            save(plan)
            puts "   ↻ new plan (replan #{plan['replans']}/#{replan_budget(plan)}):"
            revised.each_with_index { |mm, j| puts "     #{i + j + 1}. #{mm['milestone']}  [#{mm['done_check'].to_json}]" }
            next
          end
        end
        puts "   ✗ #{runs} runs without completing and no replan budget left — stopping."
        m["status"] = "blocked"; save(plan); break
      end
      m["runs"] = runs + 1; save(plan)

      puts "   → executor run #{m['runs']} (#{EXECUTOR})…"
      rooms_before = room_count
      reply = run_milestone(goal, m, plan["progress"])
      if reply.nil?
        # The executor never reported — it crashed (API overload, etc). Retrying the
        # same milestone is exactly right here; replanning would invent a game-world
        # explanation for a network problem.
        puts "   ⚠ executor did not report back (crashed — API error or similar). " \
             "Infrastructure failure, NOT a blocker; retrying this milestone."
        plan["progress"] << "#{m['milestone']} (run #{m['runs']}): executor crashed, no reply — retried."
        save(plan)
        sleep 5   # let a transient overload pass before hammering it again
        next
      end
      rooms_after = room_count
      st2   = read_state
      plan["progress"] << "#{m['milestone']} (run #{m['runs']}): L#{st2[:level]} #{st2[:xp]}xp — #{reply.to_s.lines.first(1).join.strip[0, 120]}"
      save(plan)

      if done?(m["done_check"], st2, base)
        puts "   ✓ done_check satisfied → advancing"
        m["status"] = "done"; plan["current"] += 1; plan["baseline"] = nil
        save(plan)
      elsif progressed?(st, st2, m["done_check"], rooms_before, rooms_after)
        # Moved toward THIS milestone — it's simply unfinished. Re-run it.
        mapped = rooms_after > rooms_before ? ", +#{rooms_after - rooms_before} rooms mapped" : ""
        puts "   … not done yet (L#{st2[:level]} #{st2[:xp]}xp#{mapped}); progress made, will re-run."
      elsif plan["replans"].to_i >= replan_budget(plan)
        puts "   ✗ stuck, and already replanned #{plan['replans']}× — escalating (stopping)."
        m["status"] = "blocked"; save(plan); break
      else
        # NOTHING changed. Retrying would reproduce the same refusal, so revise the
        # plan using what the executor just told us about the obstacle.
        puts "   ✗ no change in game state — treating as a BLOCKER, replanning around it."
        puts "     executor said: #{reply.to_s.lines.first(2).join(' ').strip[0, 160]}"
        done_so_far = plan["milestones"].first(i).map { |mm| mm["milestone"] }
        begin
          revised = replan!(goal, st2, m, reply, done_so_far, attempt_history(plan))
                      .map { |mm| mm.merge("status" => "pending") }
          revised, vnotes = validate_plan(revised, st2, base)
          vnotes.each { |n| puts "   · #{n}" }
          if revised.empty?
            puts "   ✗ replan produced nothing verifiable — escalating."
            m["status"] = "blocked"; save(plan); break
          end
        rescue StandardError => e
          puts "   ✗ replan failed (#{e.message}) — escalating."
          m["status"] = "blocked"; save(plan); break
        end
        m["status"] = "superseded"
        # Keep the completed prefix; everything from here on is the new plan.
        plan["milestones"] = plan["milestones"].first(i) + revised
        plan["current"]    = i
        plan["baseline"]   = nil
        plan["replans"]    = plan["replans"].to_i + 1
        plan["progress"] << "REPLANNED around blocker on #{m['milestone'].inspect} " \
                            "[at the time: L#{st2[:level]} #{st2[:xp]}xp #{st2[:gold].to_i} gold]. " \
                            "That plan ordered them: #{plan['milestones'].drop(i).first(4).map { |mm| mm['milestone'] }.join(' → ')}"
        save(plan)
        puts "   ↻ new plan (replan #{plan['replans']}/#{replan_budget(plan)}):"
        revised.each_with_index { |mm, j| puts "     #{i + j + 1}. #{mm['milestone']}  [#{mm['done_check'].to_json}]" }
      end
    end

    puts "\n== FINAL PLAN STATE =="
    plan["milestones"].each_with_index { |mm, i| puts "  #{i + 1}. [#{mm['status']}] #{mm['milestone']}" }
  end
end
