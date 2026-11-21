#!/bin/bash
# Skills: frontmatter, grounding body == core/rules/grounding.md, and every `ga <sub>` /
# `GA <verb>` the design-architecture skill mentions exists in the implementation.
# Extraction uses grep -oE '\b...' (BSD grep 2.6 and GNU grep both support \b).

test_skill_frontmatter() {
  local s f
  for s in grounding design-architecture; do
    f="$PLUGIN/skills/$s/SKILL.md"
    assert_eq "---" "$(head -1 "$f")"
    assert_contains "$(sed -n '2,6p' "$f")" "name: $s"
    assert_contains "$(sed -n '2,8p' "$f")" "description:"
  done
}

test_grounding_skill_matches_rule_source() {
  local body
  body=$(awk 'f>=2{print} /^---$/{f++}' "$PLUGIN/skills/grounding/SKILL.md")
  assert_eq "$(cat "$CORE/rules/grounding.md")" "$body"
}

test_skill_ga_commands_exist() {
  local c cmds
  cmds=$(grep -oE '\bga [a-z-]+' "$PLUGIN/skills/design-architecture/SKILL.md" | awk '{print $2}' | sort -u)
  # Guard against a vacuous pass (extraction finding nothing).
  assert_contains " $(echo $cmds) " " add "
  for c in $cmds; do
    assert_status 0 grep -q "cmd_${c//-/_}()" "$CORE"/lib/*.sh "$CORE/bin/ga"
  done
}

test_skill_user_verbs_exist() {
  local v verbs
  . "$CORE/lib/usercmd.sh"
  verbs=$(grep -oE '\bGA [^ `.]+' "$PLUGIN/skills/design-architecture/SKILL.md" | awk '{print $2}' | sort -u)
  # Guard against a vacuous pass (extraction finding nothing).
  assert_contains " $(echo $verbs) " " 승인 "
  for v in $verbs; do
    assert_contains " $GA_VERBS " " $v "
  done
}
