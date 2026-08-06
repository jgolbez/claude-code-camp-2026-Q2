require_relative "test_helper"

# Two guards added after three characters were stranded and one nearly killed:
#
#   * the DANGER LEASH. `seek` already refused to blind-search a dangerous zone;
#     `explore` did not, and the sewer sits directly beside the newbie zone — it is
#     the obvious frontier once that zone thins, it is one-way in four places, and
#     walking back out costs several runs. Hectic fell in twice, Solace once, and
#     Solace ended her run trapped there with 57 gold and one purchase left.
#   * ALIGNMENT reporting. `score_stats` never parsed alignment, so nothing could see
#     the meter that turns city guards hostile. Hectic went 114 -> 4 in two janitor
#     kills and no tool result mentioned it.
#
# Mirrors the predicates in lib/boukensha/tools/mud.rb, which can't be required here
# without a live MUD session.
class DangerLeashTest < Minitest::Test
  # safe_to_quit_here — the zone predicate both leashes use.
  def safe?(zone)
    !!(zone =~ /newbie zone/i || (zone =~ /midgaard/i && zone !~ /sewer|passage|cesspit/i))
  end

  def test_the_newbie_zone_is_safe_to_auto_explore
    assert safe?("Newbie Zone")
    assert safe?("The Newbie Zone")
  end

  def test_midgaard_town_is_safe
    assert safe?("Northern Midgaard")
    assert safe?("Midgaard City")
  end

  # The exact zone string the MUD reports for the sewer.
  def test_the_sewer_is_not_safe
    refute safe?("Sewer, First Level"), "the tar pit that stranded three characters"
    refute safe?("Sewer, Second Level")
  end

  # A sewer that mentions Midgaard must NOT pass on the "midgaard" clause.
  def test_a_midgaard_sewer_is_still_dangerous
    refute safe?("The Sewers of Midgaard")
    refute safe?("Midgaard Cesspit")
    refute safe?("Midgaard Passage")
  end

  # Unknown zones fail closed — conservative by design.
  def test_unknown_zones_are_treated_as_dangerous
    refute safe?("The Shadow Grove")
    refute safe?("")
    refute safe?(nil.to_s)
  end

  # ---- alignment reporting -------------------------------------------------

  def align_note(before, after)
    return "" unless before && after && before != after
    d = after - before
    note = " Alignment #{d.positive? ? '+' : ''}#{d} → #{after}."
    if after < 0
      note += " ⚠ You are now EVIL-aligned: city guards turn on characters who kill townsfolk."
    elsif d.negative? && after < 100
      note += " (Falling — these are townsfolk; keep killing them and the guards will answer.)"
    end
    note
  end

  def test_no_note_when_alignment_does_not_move
    assert_equal "", align_note(50, 50)
  end

  def test_no_note_when_alignment_is_unreadable
    assert_equal "", align_note(nil, 50)
    assert_equal "", align_note(50, nil)
  end

  # Hectic's real numbers: two janitor kills took him 114 -> 4, silently.
  def test_a_fall_toward_zero_warns
    note = align_note(114, 4)
    assert_includes note, "-110"
    assert_includes note, "Falling"
    assert_includes note, "guards will answer"
  end

  def test_going_negative_warns_loudly
    note = align_note(20, -30)
    assert_includes note, "EVIL-aligned"
    assert_includes note, "guards turn on"
  end

  # Killing vermin RAISES alignment — that must read as ordinary, not alarming.
  def test_a_rise_is_reported_without_a_warning
    note = align_note(15, 79)
    assert_includes note, "+64"
    refute_includes note, "Falling"
    refute_includes note, "EVIL"
  end

  # A fall while still comfortably good is worth stating but not scolding.
  def test_a_small_fall_from_a_high_alignment_is_quiet
    note = align_note(500, 450)
    assert_includes note, "-50"
    refute_includes note, "Falling", "still well clear of trouble"
  end
end
