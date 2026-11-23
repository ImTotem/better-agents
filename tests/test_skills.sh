#!/bin/bash
# Skills: frontmatter, grounding body == core/rules/grounding.md, and every MCP tool, `ga <sub>` and
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

# Explicit invocation only (spec 2, non-goal "명시적으로 호출할 때만 동작").
test_design_skill_disables_model_invocation() {
  local fm
  fm=$(awk 'NR==1{next} /^---$/{exit} {print}' "$PLUGIN/skills/design-architecture/SKILL.md")
  assert_contains "$fm" "disable-model-invocation: true"
}

# Compaction keeps only the first 5,000 tokens of a skill: the re-read instruction must sit at the top.
test_design_skill_reread_instruction_near_top() {
  assert_contains "$(head -15 "$PLUGIN/skills/design-architecture/SKILL.md")" '${CLAUDE_SKILL_DIR}/SKILL.md'
}

test_grounding_skill_matches_rule_source() {
  local body
  body=$(awk 'f>=2{print} /^---$/{f++}' "$PLUGIN/skills/grounding/SKILL.md")
  assert_eq "$(cat "$CORE/rules/grounding.md")" "$body"
}

# State-changing ga commands reach the agent only as MCP tools (spec 5.5): every tool name the skill
# mentions (mcp__plugin_<plugin>_<server>__<tool>) is in the server's tools/list.
test_skill_mcp_tools_exist() {
  local t tools names init list
  init='{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}'
  list='{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
  names=" $(printf '%s\n%s\n' "$init" "$list" | "$CORE/mcp/server.sh" 2>/dev/null | jq -r 'select(.id == 1) | .result.tools[].name' | tr '\n' ' ') "
  assert_contains "$names" " ga_add "
  tools=$(grep -oE 'mcp__plugin_[A-Za-z0-9_-]+__[a-z_]+' "$PLUGIN/skills/design-architecture/SKILL.md" | sort -u)
  # Guard against a vacuous pass (extraction finding nothing).
  assert_contains " $(echo $tools) " " mcp__plugin_better-agents_ga__ga_add "
  for t in $tools; do
    case "$t" in mcp__plugin_better-agents_ga__*) ;; *) _fail "wrong plugin or server prefix: $t" ;; esac
    assert_contains "$names" " ${t#mcp__plugin_better-agents_ga__} "
  done
}

# The shell examples left in the skill are read commands (they run inside the OS sandbox) and exist.
test_skill_shell_ga_commands_read_only() {
  local c cmds
  cmds=$(grep -oE '\bga [a-z-]+' "$PLUGIN/skills/design-architecture/SKILL.md" | awk '{print $2}' | sort -u)
  assert_contains " $(echo $cmds) " " status "
  for c in $cmds; do
    case " status check rule effect billing version " in *" $c "*) ;; *) _fail "state-changing or internal shell command in the skill: ga $c" ;; esac
    assert_status 0 grep -q "cmd_${c//-/_}()" "$CORE"/lib/*.sh "$CORE/bin/ga"
  done
}

test_design_skill_at_most_300_lines() {
  local n; n=$(wc -l <"$PLUGIN/skills/design-architecture/SKILL.md" | tr -d ' ')
  [ "$n" -le 300 ] || _fail "SKILL.md has $n lines"
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
