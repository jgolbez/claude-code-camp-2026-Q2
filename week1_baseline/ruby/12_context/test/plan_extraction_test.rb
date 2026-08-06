require_relative "test_helper"
require "json"

# Pulling the milestone array out of a planner reply used to be `raw[/\[.*\]/m]` —
# a GREEDY match from the first "[" anywhere in the text to the last "]". Any bracket
# in prose, or a ```json fence, made the span start mid-object, and a perfectly good
# plan died as "malformed JSON (unexpected token at '{ "tools": [...])". That aborted
# a live run.
#
# Mirrors Plan.extract_json_array / Plan.balanced_span — kept in step with
# planning/orchestrator.rb, which can't be required here without a live MUD.
class PlanExtractionTest < Minitest::Test
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

  def extract(raw)
    text = raw.to_s.gsub(/```(?:json)?/i, "")
    text.each_char.with_index.select { |ch, _| ch == "[" }.each do |_, start|
      span = balanced_span(text, start)
      next unless span
      parsed = (JSON.parse(span) rescue nil)
      return span if parsed.is_a?(Array) && parsed.all? { |m| m.is_a?(Hash) } && !parsed.empty?
    end
    nil
  end

  def plan_of(raw)
    span = extract(raw)
    span && JSON.parse(span)
  end

  def test_plain_array
    assert_equal [{ "milestone" => "a" }], plan_of('[{"milestone":"a"}]')
  end

  def test_prose_before_the_array
    assert_equal [{ "milestone" => "a" }], plan_of(%(Here is the plan:\n[{"milestone":"a"}]))
  end

  def test_json_code_fence
    assert_equal [{ "milestone" => "a" }], plan_of(%(```json\n[{"milestone":"a"}]\n```))
  end

  # The exact shape that aborted the live run: a bracket in prose ahead of the plan.
  def test_bracket_in_prose_does_not_capture_the_wrong_array
    raw = %(Use tools [hunt] first. [{"milestone":"a"}])
    assert_equal [{ "milestone" => "a" }], plan_of(raw),
                 "must skip [hunt] and find the real milestone array"
  end

  def test_trailing_prose
    assert_equal [{ "milestone" => "a" }], plan_of('[{"milestone":"a"}]  Let me know.')
  end

  def test_nested_tool_arrays_are_kept_whole
    plan = plan_of('[{"milestone":"a","tools":["hunt","fight"]}]')
    assert_equal %w[hunt fight], plan.first["tools"]
  end

  # Depth counting must ignore brackets inside string literals.
  def test_bracket_inside_a_string_literal
    plan = plan_of('[{"milestone":"go to [the vault]","tools":["seek"]}]')
    assert_equal "go to [the vault]", plan.first["milestone"]
  end

  # Truncation must still yield nil, so the caller reports the token-limit hint
  # rather than a confusing parse error.
  def test_truncated_array_returns_nil
    assert_nil extract('[{"milestone":"a","tools":["hunt"')
  end

  def test_prose_only_returns_nil
    assert_nil extract("Sure! I'd suggest hunting first, then buying a teleporter.")
  end

  def test_array_of_non_objects_is_rejected
    assert_nil extract('["hunt","fight"]'), "a bare string array is not a milestone plan"
  end
end
