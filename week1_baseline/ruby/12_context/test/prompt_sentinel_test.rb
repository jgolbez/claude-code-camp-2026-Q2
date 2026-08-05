require_relative "test_helper"

# read_until_prompt decides where a command's output ENDS. It used to match a bare
# "> ", which the game's own output contains — the equipment listing renders slot
# labels like "<used as light>      a candle", and that ">" plus a space is an exact
# match. Every `equipment` read therefore stopped at the first slot and returned 32
# bytes, so nothing in the harness could tell whether a character was armed. A
# housekeeping check built on it confidently reported "BARE-HANDED" for a character
# wielding a small sword.
#
# The prompt is anchored on the VITALS pattern instead. These cases lock that in.
class PromptSentinelTest < Minitest::Test
  PROMPT_RE = /\d+H\s+\d+M\s+\d+V[^\n]*?>\s/.freeze

  # The real listing, verbatim from the running server.
  EQUIPMENT = "You are using:\r\n" \
              "<used as light>      a candle\r\n" \
              "<worn on finger>     a leather ring\r\n" \
              "<worn on body>       a breast plate\r\n" \
              "<wielded>            a small sword\r\n" \
              "<held>               a metal staff\r\n" \
              "\r\n21H 100M 7V (news) (motd) > "

  def test_slot_labels_are_not_mistaken_for_the_prompt
    ["<used as light>      a candle",
     "<wielded>            a small sword",
     "<held>               a metal staff",
     "<worn around neck>   a leather gorget"].each do |line|
      refute_match PROMPT_RE, line, "#{line.inspect} must not read as a prompt"
      assert_includes line, "> ", "…even though it does contain the old sentinel"
    end
  end

  def test_the_real_vitals_prompt_matches
    ["21H 100M 7V (news) (motd) > ", "53H 100M 93V > ", "9H 12M 4V (motd) > "].each do |pr|
      assert_match PROMPT_RE, pr
    end
  end

  # The bug, end to end: cutting at the first match must now yield the WHOLE listing.
  def test_equipment_listing_survives_to_the_prompt
    m = PROMPT_RE.match(EQUIPMENT)
    refute_nil m, "the prompt must be found"
    body = EQUIPMENT[0...m.begin(0)]
    assert_includes body, "<wielded>", "the wielded slot must survive the read"
    assert_includes body, "a small sword"
    assert_operator body.length, :>, 100, "must not truncate to the first slot label"
  end

  def test_old_sentinel_would_have_truncated
    # Documents the defect so the reason for the stricter pattern stays legible.
    cut = EQUIPMENT.index("> ")
    assert_operator cut, :<, 40, "the bare sentinel matched inside the first slot label"
    refute_includes EQUIPMENT[0...cut], "<wielded>"
  end

  def test_wielded_is_extractable_from_a_full_listing
    w = EQUIPMENT[/<wielded>\s*(.+)$/i, 1]
    assert_equal "a small sword", w.to_s.strip
  end
end
