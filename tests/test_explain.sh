#!/bin/bash
# explain-clearly plugin: hooks inject the guide at SessionStart and the reminder on every
# prompt; both stay under the hook output cap; the guide's examples follow its own template.
EXP=$REPO/plugins/explain-clearly

_exp_hook_cmd() { # EVENT -> command string
  jq -er --arg e "$1" '.hooks[$e][0].hooks[0].command' "$EXP/hooks/hooks.json"
}

test_explain_manifests() {
  assert_eq "explain-clearly" "$(jq -r .name "$EXP/.claude-plugin/plugin.json")"
  assert_eq "./plugins/explain-clearly" \
    "$(jq -r '.plugins[] | select(.name == "explain-clearly") | .source' "$REPO/.claude-plugin/marketplace.json")"
  assert_status 0 jq -e '.hooks | has("SessionStart") and has("UserPromptSubmit")' "$EXP/hooks/hooks.json"
}

test_explain_hooks_print_rule_files() {
  local out
  out=$(CLAUDE_PLUGIN_ROOT=$EXP bash -c "$(_exp_hook_cmd SessionStart)")
  assert_eq "$(cat "$EXP/rules/guide.md")" "$out"
  out=$(CLAUDE_PLUGIN_ROOT=$EXP bash -c "$(_exp_hook_cmd UserPromptSubmit)")
  assert_eq "$(cat "$EXP/rules/reminder.md")" "$out"
}

# Hook output over 10,000 characters is replaced by a file path and a 2,000-character preview
# (https://code.claude.com/docs/en/hooks). The reminder is injected on every prompt, so keep it small.
test_explain_sizes_under_hook_cap() {
  local g r
  g=$(wc -m < "$EXP/rules/guide.md" | tr -d ' ')
  r=$(wc -m < "$EXP/rules/reminder.md" | tr -d ' ')
  [ "$g" -lt 8000 ] || _fail "guide.md has $g characters (limit 8000)"
  [ "$r" -lt 800 ] || _fail "reminder.md has $r characters (limit 800)"
}

test_explain_guide_has_template_and_three_examples() {
  local g
  g=$(cat "$EXP/rules/guide.md")
  assert_contains "$g" "## 지금 상황"
  assert_contains "$g" "## 정해 주실 것"
  assert_contains "$g" "- 무엇:"
  assert_eq 3 "$(grep -c '^<example>$' "$EXP/rules/guide.md")"
  assert_eq 3 "$(grep -c '^</example>$' "$EXP/rules/guide.md")"
}

# Every bold item title inside the examples is followed by exactly the 무엇 / 예 / 영향 lines,
# so the examples never teach a different shape than the template.
test_explain_examples_follow_item_shape() {
  local bad
  bad=$(awk '
    /^<examples>$/ { inx = 1; next }
    /^<\/examples>$/ { inx = 0 }
    !inx { next }
    want == 1 { if ($0 !~ /^- 무엇: /) print "line " NR ": expected 무엇"; want = 2; next }
    want == 2 { if ($0 !~ /^- 예: /) print "line " NR ": expected 예"; want = 3; next }
    want == 3 { if ($0 !~ /^- 영향: /) print "line " NR ": expected 영향"; want = 0; next }
    /^\*\*[^*]+ [0-9]+: .+\*\*$/ { want = 1; items++ }
    END { if (items < 2) print "only " items " item titles found" }
  ' "$EXP/rules/guide.md")
  [ -z "$bad" ] || _fail "$bad"
}

# The reminder names the same sections and labels as the guide.
test_explain_reminder_matches_guide_labels() {
  local r l
  r=$(cat "$EXP/rules/reminder.md")
  for l in "## 지금 상황" "## 정해 주실 것" "- 무엇:" "- 예:" "- 영향:"; do
    assert_contains "$r" "$l"
    assert_contains "$(cat "$EXP/rules/guide.md")" "$l"
  done
}

# The template is only for asking approval or a direction (user, 2026-11-22: "설명 규칙은 나에게 승인이나
# 방향을 선택 받기 위해 질문할때에만 적용해라"). Both files say so, and the guide shows a plain progress
# note that uses none of the template headings.
test_explain_template_only_for_decisions() {
  local l
  for l in "승인이나 방향" "양식 없이"; do
    assert_contains "$(cat "$EXP/rules/guide.md")" "$l"
    assert_contains "$(cat "$EXP/rules/reminder.md")" "$l"
  done
  local plain
  plain=$(awk '/^상황: 정할 일이 없는 진행 보고/{f=1; next} /^<\/example>$/{f=0} f' "$EXP/rules/guide.md")
  [ -n "$plain" ] || _fail "guide has no plain progress-note example"
  case "$plain" in *"## 지금 상황"*|*"- 무엇:"*) _fail "plain example uses the template" ;; esac
}
