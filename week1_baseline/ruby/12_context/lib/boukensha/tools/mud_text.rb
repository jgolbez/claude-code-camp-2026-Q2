# frozen_string_literal: true

module Boukensha
  module Tools
    # MudText distils raw CircleMUD output into compact, decision-relevant text
    # so the agent spends tokens on choices, not on combat spam and repeated
    # prompts.
    #
    # The design bias is SAFETY over compression: we only drop lines we can
    # positively identify as round-by-round combat flavor. Anything ambiguous is
    # kept. An outcome line (death, xp, loot, level, "mortally wounded", flee) is
    # never treated as a round, so the agent always sees what a fight produced.
    module MudText
      module_function

      ANSI   = /\e\[[0-9;?]*[ -\/]*[@-~]/.freeze
      # CircleMUD prompt, e.g. "21H 103M 21V (news) (motd) > "
      PROMPT = /(\d+)H\s+(\d+)M\s+(\d+)V\b/.freeze

      # Round-by-round attack/defence flavor verbs (CircleMUD damage() messages).
      ATTACK = /\b(hits?|miss(?:es)?|pierces?|tickles?|scratch(?:es)?|injur\w+|
                  wound\w*|mauls?|maims?|slash(?:es)?|crush(?:es)?|pounds?|claws?|
                  bites?|punch(?:es)?|smites?|lunges?|swings?|avoids?|ducks?|
                  dodges?|blow|clobber\w*|thrash\w*|batter\w*|pommel\w*)\b/xi.freeze

      # Lines that carry a real result — never dropped, even if they also contain
      # an attack verb (e.g. the killing blow "... resulting in its immediate death!").
      OUTCOME = /\b(is dead|R\.I\.P|experience|rises? a level|raises? a level|
                   stunned|mortally wounded|incapacitated|bleeding|corpse|
                   flees?|PANIC|death|dies?)\b/xi.freeze

      COMBATANT = /\byou\b|\bthe\b/i.freeze

      def strip_ansi(text)
        text.to_s.gsub(ANSI, "")
      end

      def prompt_line?(line)
        line.strip =~ /\A#{PROMPT}.*>\s*\z/
      end

      # The last vitals seen, as a compact tag: "HP 18/… M 103 V 39".
      def vitals_tag(text)
        m = strip_ansi(text).scan(PROMPT).last
        m && "HP #{m[0]} | M #{m[1]} | V #{m[2]}"
      end

      def round_line?(line)
        l = line.strip
        return false if l.empty?
        l =~ ATTACK && l =~ COMBATANT && l !~ OUTCOME
      end

      # Collapse combat responses: drop identified round lines, keep outcomes,
      # note how many rounds were omitted, and append the final vitals. Apply
      # this ONLY to combat tool responses (attack/skill_strike/flee) — other
      # command output (e.g. `score`) legitimately contains words like "hit" and
      # must not be run through the round filter.
      def combat(raw)
        text  = strip_ansi(raw)
        kept  = []
        rounds = 0
        text.each_line do |line|
          l = line.rstrip
          next if l.strip.empty?
          next if prompt_line?(l)
          if round_line?(l)
            rounds += 1
          else
            kept << l.strip
          end
        end
        out = kept
        out << "[+#{rounds} combat round#{rounds == 1 ? '' : 's'} omitted]" if rounds.positive?
        tag = vitals_tag(text)
        out << "(#{tag})" if tag
        result = out.join("\n")
        result.empty? ? strip_ansi(raw).strip : result
      end

      # Light, always-safe compaction for non-combat responses: strip the
      # trailing prompt line and append a compact vitals tag. No round filtering,
      # so no risk of dropping informational lines.
      def compact(raw)
        text = strip_ansi(raw)
        body = text.each_line.reject { |l| prompt_line?(l) || l.strip.empty? }
                   .map(&:rstrip).join("\n").strip
        tag  = vitals_tag(text)
        tag ? "#{body}\n(#{tag})" : body
      end
    end
  end
end
