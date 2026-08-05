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
  EXECUTOR    = "claude-haiku-4-5"
  MAX_RUNS_PER_MILESTONE = 4
  # Replanning is the recovery path, but it must terminate: a goal that is genuinely
  # impossible would otherwise loop forever, replanning around a wall that never moves.
  MAX_REPLANS = 3

  module_function

  def c(t) = t.to_s.gsub(/\e\[[0-9;?]*[ -\/]*[@-~]/, "")

  # ---- deterministic game-state read (its own short-lived connection) --------
  def read_state
    ctx = Boukensha::Context.new(system: "t")
    reg = Boukensha::Registry.new(ctx)
    Boukensha::Tools::Mud.register(reg, **MUD)
    score = c(reg.dispatch("check", { "kind" => "score" }))
    prac  = Boukensha::Skills.parse_practice(reg.dispatch("practice", {}))
    loc   = c(reg.dispatch("look", {})).lines.first.to_s.strip
    # Quit CLEANLY, not just disconnect: a bare disconnect would leave Perry
    # link-dead in whatever room this read touched. mud_quit saves + extracts him
    # (login restores his position), so these frequent state reads never leave an
    # attackable idle body behind.
    reg.dispatch("mud_quit", {})
    {
      level:     score[/\(level\s+(\d+)\)/i, 1]&.to_i,
      xp:        score[/have\s+(\d+)\s+exp/i, 1]&.to_i,
      hp:        score[/(\d+)\(\d+\)\s+hit/i, 1]&.to_i,
      location:  loc,
      sessions:  prac[:sessions],
      skills:    prac[:skills]
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
      { "type":"at_place",       "name": "<room name substring>" }
      { "type":"skill_trained",  "skill": "<skill>" }
      { "type":"has_item",       "name": "<item substring>" }

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

  def state_block(state)
    places = known_places
    <<~S.strip
      #{CHAR_NAME} now: level #{state[:level]}, #{state[:xp]} exp, at #{state[:location]},
      #{state[:sessions]} practice session(s), skills #{state[:skills].empty? ? '(none trained)' : state[:skills].map { |k, v| "#{k} (#{v})" }.join(', ')}.
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
    raw  = Boukensha.run(task: task, system: PLANNER_SYSTEM, model: PLANNER, mud: false, working_dir: false)
    json = raw[/\[.*\]/m] or raise "planner returned no JSON:\n#{raw}"
    JSON.parse(json)
  end

  # ---- REPLAN: a blocker is information, not a reason to retry ----------------
  # When a milestone runs and nothing about the world changes, repeating it is
  # pure waste — the executor already said why it couldn't proceed. Hand the
  # planner that report and let it route AROUND the obstacle: usually by making
  # the missing prerequisite (a place not yet found, an item not owned) its own
  # milestone first.
  def replan!(goal, state, stuck_milestone, blocker, done_so_far)
    task = <<~T
      GOAL: #{goal}
      #{state_block(state)}

      THE PLAN IS STUCK and must be revised.
      Already accomplished: #{done_so_far.empty? ? '(nothing yet)' : done_so_far.join('; ')}
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
      Output ONLY the JSON array, no prose.
    T
    raw  = Boukensha.run(task: task, system: PLANNER_SYSTEM, model: PLANNER, mud: false, working_dir: false)
    json = raw[/\[.*\]/m] or raise "replanner returned no JSON:\n#{raw}"
    JSON.parse(json)
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
    when "skill_trained"
      after[:skills] != before[:skills] || after[:sessions].to_i != before[:sessions].to_i
    when "at_place"
      # Getting somewhere is navigation: moving OR mapping new ground is progress.
      after[:location].to_s != before[:location].to_s || !!mapped_more
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

  # ---- deterministic milestone completion check -----------------------------
  def done?(check, state, baseline)
    case check["type"]
    when "xp_at_least"    then state[:xp] && state[:xp]    >= check["value"].to_i
    when "level_at_least" then state[:level] && state[:level] >= check["value"].to_i
    when "at_place"       then state[:location].to_s.downcase.include?(check["name"].to_s.downcase)
    when "has_item"       then false # (executor-reported; not read here)
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
      milestones = plan!(goal, st).map { |m| m.merge("status" => "pending") }
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
        puts "   ✗ #{runs} runs without completing — escalating (stopping this demo)."
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
      elsif plan["replans"].to_i >= MAX_REPLANS
        puts "   ✗ stuck, and already replanned #{plan['replans']}× — escalating (stopping)."
        m["status"] = "blocked"; save(plan); break
      else
        # NOTHING changed. Retrying would reproduce the same refusal, so revise the
        # plan using what the executor just told us about the obstacle.
        puts "   ✗ no change in game state — treating as a BLOCKER, replanning around it."
        puts "     executor said: #{reply.to_s.lines.first(2).join(' ').strip[0, 160]}"
        done_so_far = plan["milestones"].first(i).map { |mm| mm["milestone"] }
        begin
          revised = replan!(goal, st2, m, reply, done_so_far).map { |mm| mm.merge("status" => "pending") }
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
        plan["progress"] << "REPLANNED around blocker on #{m['milestone'].inspect}."
        save(plan)
        puts "   ↻ new plan (replan #{plan['replans']}/#{MAX_REPLANS}):"
        revised.each_with_index { |mm, j| puts "     #{i + j + 1}. #{mm['milestone']}  [#{mm['done_check'].to_json}]" }
      end
    end

    puts "\n== FINAL PLAN STATE =="
    plan["milestones"].each_with_index { |mm, i| puts "  #{i + 1}. [#{mm['status']}] #{mm['milestone']}" }
  end
end
