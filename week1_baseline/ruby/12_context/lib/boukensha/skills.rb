# frozen_string_literal: true

module Boukensha
  # Class-agnostic skill knowledge. Kept deliberately separate so boukensha stays
  # character-neutral (identity lives in config):
  #
  #   * WHAT a character has trained comes from the GAME — `parse_practice` reads
  #     the `practice` listing. Authoritative, works for any class.
  #   * HOW each skill is used comes from the shared CATALOG — a static map of
  #     skill name → role + preconditions. The combat/utility layers consult it.
  #
  # Together they let the same code play a Thief's backstab or a Warrior's bash
  # without hardcoding either.
  module Skills
    module_function

    ANSI = /\e\[[0-9;?]*[ -\/]*[@-~]/.freeze

    # CircleMUD proficiency ladder, worst → best. Index doubles as a rank so the
    # combat layer can gate "only lead with an opener if it's at least `fair`".
    PROFICIENCY = %w[unlearned awful bad poor average fair good very-good superb].freeze

    def proficiency_rank(word)
      w = word.to_s.downcase.strip.delete("()").gsub(/\s+/, "-")
      w = "unlearned" if w.empty? || w == "not-learned"
      PROFICIENCY.index(w) || 0
    end

    # Parse a `practice` listing into { sessions: Int, skills: { name => prof } }.
    #   You have 0 practice sessions remaining.
    #   You know of the following skills:
    #   backstab              (fair)
    #   pick lock             (poor)
    #   sneak                 (awful)
    def parse_practice(text)
      clean    = text.to_s.gsub(ANSI, "")
      sessions = clean[/have\s+(\d+)\s+practice\s+session/i, 1]&.to_i || 0
      skills   = {}
      clean.each_line do |line|
        m = line.match(/\A\s*([a-z][a-z '\-]*?)\s{2,}\(?\s*([a-z][a-z \-]*?)\s*\)?\s*\z/i)
        next unless m
        name = m[1].strip.downcase
        prof = m[2].strip.downcase
        next if name.empty? || name =~ /\byou\b|\bknow\b|\bhave\b|following|session/
        skills[name] = prof
      end
      { sessions: sessions, skills: skills }
    end

    # How the harness USES a skill. Roles:
    #   :opener        — a pre-combat first strike (needs to initiate)
    #   :combat_move   — usable each round once fighting
    #   :utility_lock  — opens locked doors/gates/chests (navigation)
    #   :utility_stealth / :utility_theft — approach / thievery
    # `needs` lists preconditions the caller must check against live state.
    CATALOG = {
      "backstab"  => { role: :opener,      strike: "backstab",
                       needs: %i[initiating piercing_weapon], on_fail: :engage_anyway,
                       min_prof: "poor" },
      "bash"      => { role: :combat_move, strike: "bash" },
      "kick"      => { role: :combat_move, strike: "kick" },
      "rescue"    => { role: :combat_move, strike: "rescue" },
      "pick lock" => { role: :utility_lock },
      "sneak"     => { role: :utility_stealth },
      "hide"      => { role: :utility_stealth },
      "steal"     => { role: :utility_theft }
    }.freeze

    def catalog(skill) = CATALOG[skill.to_s.downcase]
    def role(skill)    = catalog(skill)&.dig(:role)

    # From a character's trained skills, the openers they can lead with, best
    # proficiency first. (Precondition checks like weapon type are the caller's
    # job — they depend on live equipment.)
    def openers(trained_skills)
      trained_skills
        .select { |name, _| role(name) == :opener }
        .sort_by { |name, prof| -proficiency_rank(prof) }
        .map { |name, prof| [name, prof] }
    end
  end
end
