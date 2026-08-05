require_relative "test_helper"

# `consider` is the safety oracle: every fight decision hangs off its rating. The
# tool used to take the FIRST line of the reply, which mid-fight is combat spam —
# so "You pierce the sewer rat." got rated by the conservative fallthrough as
# :unsafe and `fight` refused a mob that was already attacking. The agent's only
# out was `flee`, which in tbaMUD costs experience (do_flee → gain_exp(ch, -loss)),
# so the misread actively drained xp.
#
# These are the COMPLETE set of do_consider replies, taken from the running
# server's own src/act.informative.c — not guessed at.
class ConsiderReplyTest < Minitest::Test
  # Deliberately one line: with /x, Ruby strips the literal spaces inside these
  # phrases and nothing matches. The same trap is documented on NON_PREY.
  CONSIDER_REPLY = /consider killing who|very easy indeed|cross and a shovel|where did that chicken go|do it with a needle|\beasy\b|fairly easy|perfect match|need some luck|a lot of luck|feel lucky, punk|are you mad|you are mad/i

  ALL_REPLIES = [
    "Consider killing who?",
    "Easy!  Very easy indeed!",
    "Would you like to borrow a cross and a shovel?",
    "Now where did that chicken go?",
    "You could do it with a needle!",
    "Easy.",
    "Fairly easy.",
    "The perfect match!",
    "You would need some luck!",
    "You would need a lot of luck!",
    "You would need a lot of luck and great equipment!",
    "Do you feel lucky, punk?",
    "Are you mad!?",
    "You ARE mad!"
  ].freeze

  # Real round messages that landed where a rating was expected.
  COMBAT_SPAM = [
    "You pierce the sewer rat.",
    "The huge hungry-looking sewer rat bites you.",
    "You massacre the sewer rat to small fragments!",
    "The sewer rat panics, and attempts to flee!",
    "You flee head over heels.",
    "You are in pretty bad shape, unable to flee!"
  ].freeze

  def test_every_real_consider_reply_is_recognised
    ALL_REPLIES.each do |line|
      assert_match CONSIDER_REPLY, line, "must recognise the real consider reply #{line.inspect}"
    end
  end

  def test_combat_spam_is_never_mistaken_for_a_rating
    COMBAT_SPAM.each do |line|
      refute_match CONSIDER_REPLY, line, "#{line.inspect} is NOT a consider rating"
    end
  end

  # The exact live failure: the rating is present, but buried under round spam.
  # Picking the first MATCHING line (not the first line) is what recovers it.
  def test_rating_is_found_beneath_interleaved_combat_spam
    raw = <<~OUT
      You pierce the sewer rat.
      The huge hungry-looking sewer rat bites you.
      Do you feel lucky, punk?
    OUT
    found = raw.lines.map(&:strip).find { |l| l =~ CONSIDER_REPLY }
    assert_equal "Do you feel lucky, punk?", found
  end

  def test_a_reply_with_no_rating_at_all_yields_nothing
    raw = "You pierce the sewer rat.\nThe sewer rat bites you.\n"
    assert_nil raw.lines.map(&:strip).find { |l| l =~ CONSIDER_REPLY },
               "no rating present -> must report 'unrated', never guess a tier"
  end
end
