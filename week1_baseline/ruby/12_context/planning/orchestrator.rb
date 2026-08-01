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
  MUD         = { host: "localhost", port: 4000, name: "perry", password: "platypus" }
  PLANNER     = "claude-sonnet-5"
  EXECUTOR    = "claude-haiku-4-5"
  MAX_RUNS_PER_MILESTONE = 4

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
    You are the PLANNER for an agent playing tbaMUD as Perry, a Thief. A cheaper model
    executes your plan with deterministic tools (hunt=find best safe mob; fight=kill it;
    rest_until hp:N=heal; seek "<place>"=find an unmapped place; travel_to "<place>";
    practice "<skill>"=train at the guild, costs 1 practice session earned per level).
    Leveling comes only from killing mobs for xp. Perry is fragile — grind the newbie zone.

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

  def plan!(goal, state)
    task = <<~T
      GOAL: #{goal}
      Perry now: level #{state[:level]}, #{state[:xp]} exp, #{state[:sessions]} practice
      session(s), skills #{state[:skills].map { |k, v| "#{k} (#{v})" }.join(', ')}.
      Produce the milestone plan (JSON only).
    T
    raw  = Boukensha.run(task: task, system: PLANNER_SYSTEM, model: PLANNER, mud: false, working_dir: false)
    json = raw[/\[.*\]/m] or raise "planner returned no JSON:\n#{raw}"
    JSON.parse(json)
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
    (out.split("===REPLY===", 2)[1] || out).to_s.strip
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
               "progress" => [], "baseline" => nil }
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
      reply = run_milestone(goal, m, plan["progress"])
      st2   = read_state
      plan["progress"] << "#{m['milestone']} (run #{m['runs']}): L#{st2[:level]} #{st2[:xp]}xp — #{reply.to_s.lines.first(1).join.strip[0, 120]}"
      save(plan)

      if done?(m["done_check"], st2, base)
        puts "   ✓ done_check satisfied → advancing"
        m["status"] = "done"; plan["current"] += 1; plan["baseline"] = nil
        save(plan)
      else
        puts "   … not done yet (L#{st2[:level]} #{st2[:xp]}xp); will re-run."
      end
    end

    puts "\n== FINAL PLAN STATE =="
    plan["milestones"].each_with_index { |mm, i| puts "  #{i + 1}. [#{mm['status']}] #{mm['milestone']}" }
  end
end
