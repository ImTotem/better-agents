#!/bin/bash
ev() { sed "s#__ROOT__#$2#g" "$FIX/claude_events/$1.json"; }
hk() { "$PLUGIN/adapters/claude-code/hook.sh" "$1"; }
inputs_root() { local r; r=$(mk_project); ga --root "$r" init >/dev/null; echo "$r"; }
stub_ga() { local s; s=$(mktemp); printf '#!/bin/bash\necho boom >&2\nexit %s\n' "${1:-9}" >"$s"; chmod +x "$s"; echo "$s"; }

test_pre_write_deny_shape() { r=$(inputs_root); out=$(ev write_src "$r" | hk pre-write); assert_eq deny "$(jq -r .hookSpecificOutput.permissionDecision <<<"$out")"; assert_eq PreToolUse "$(jq -r .hookSpecificOutput.hookEventName <<<"$out")"; }
test_pre_write_allow_no_output() { r=$(inputs_root); assert_eq "" "$(ev write_archdoc "$r" | hk pre-write)"; }
test_notebook_path_used() { r=$(inputs_root); out=$(ev notebook_src "$r" | hk pre-write); assert_eq deny "$(jq -r .hookSpecificOutput.permissionDecision <<<"$out")"; }
test_pre_bash_deny_shape() { r=$(inputs_root); out=$(ev bash_redirect "$r" | hk pre-bash); assert_eq deny "$(jq -r .hookSpecificOutput.permissionDecision <<<"$out")"; }
test_stop_block_shape() { r=$(inputs_root); seed_ledger "$r" "$FIX/ledger_bad_asm.json"; assert_eq block "$(ev stop "$r" | hk stop | jq -r .decision)"; }
test_user_prompt_context_has_rule() { r=$(mk_project); out=$(ev prompt_plain "$r" | hk user-prompt); assert_contains "$(jq -r .hookSpecificOutput.additionalContext <<<"$out")" "근거 없는 가정"; assert_eq UserPromptSubmit "$(jq -r .hookSpecificOutput.hookEventName <<<"$out")"; }
test_user_prompt_block_shape() { r=$(inputs_root); assert_eq block "$(ev prompt_ga_unknown "$r" | hk user-prompt | jq -r .decision)"; }
test_session_start_shape() { r=$(inputs_root); assert_contains "$(ev session_start "$r" | hk session-start | jq -r .hookSpecificOutput.additionalContext)" "설계 진행 중"; }
test_adapter_fail_closed_on_ga_error() { r=$(inputs_root); s=$(stub_ga 9)
  out=$(ev write_src "$r" | GA_BIN=$s hk pre-write)
  assert_eq deny "$(jq -r .hookSpecificOutput.permissionDecision <<<"$out")"
  assert_contains "$(jq -r .hookSpecificOutput.permissionDecisionReason <<<"$out")" "ga 오류: boom"; }
test_adapter_has_no_phase_logic() { assert_status 1 grep -E 'inputs|iterating|design-review|skeleton|implement' "$PLUGIN/adapters/claude-code/hook.sh"; }
test_adapter_declares_capabilities() { assert_eq 4 "$(jq '[.write_block,.user_prompt_capture,.stop_check,.context_inject]|map(type=="boolean")|map(select(.))|length' "$PLUGIN/adapters/claude-code/capabilities.json")"; }

# R30: without a design, GA lines are ordinary text (no block).
test_user_prompt_ga_without_state_allowed() { r=$(mk_project); out=$(ev prompt_ga_unknown "$r" | hk user-prompt); assert_eq "" "$(jq -r '.decision // empty' <<<"$out")"; assert_contains "$(jq -r .hookSpecificOutput.additionalContext <<<"$out")" "근거 없는 가정"; }
test_pre_write_no_path_no_output() { r=$(inputs_root); assert_eq "" "$(ev write_nopath "$r" | hk pre-write)"; }
test_user_prompt_ga_error_still_injects_rule() { r=$(inputs_root); s=$(stub_ga 2)
  out=$(ev prompt_plain "$r" | GA_BIN=$s hk user-prompt)
  assert_eq "" "$(jq -r '.decision // empty' <<<"$out")"
  ctx=$(jq -r .hookSpecificOutput.additionalContext <<<"$out")
  assert_contains "$ctx" "ga 오류"
  assert_contains "$ctx" "근거 없는 가정"; }
test_stop_ga_error_does_not_block() { r=$(inputs_root); s=$(stub_ga 2); assert_eq "" "$(ev stop "$r" | GA_BIN=$s hk stop)"; }
test_session_start_clean_dir_no_output() {
  r=$(mk_project); h=$(mktemp -d)
  out=$(ev session_start "$r" | env -u ANTHROPIC_API_KEY HOME=$h "$PLUGIN/adapters/claude-code/hook.sh" session-start)
  assert_eq "" "$out"; }
test_bin_ga_wrapper_follows_symlink() { d=$(mktemp -d); ln -s "$PLUGIN/bin/ga" "$d/ga"; "$d/ga" rule | grep -q "근거"; }
test_hooks_json_registers_command_hooks() {
  f=$PLUGIN/hooks/hooks.json
  assert_eq 0 "$(jq '[.hooks[][].hooks[].type] | map(select(. != "command")) | length' "$f")"
  assert_eq 5 "$(jq '[.hooks[][]] | length' "$f")"
  assert_eq "Bash|PowerShell|Monitor,Write|Edit|MultiEdit|NotebookEdit" "$(jq -r '[.hooks.PreToolUse[].matcher] | sort | join(",")' "$f")"
  assert_contains "$(jq -r '.hooks.Stop[0].hooks[0].command' "$f")" '${CLAUDE_PLUGIN_ROOT}/adapters/claude-code/hook.sh'; }

# --- final review fixes ---
# R35-1: without a working jq, a project with a design is fail-closed for writes and shell commands.
nojq_path() { local d t; d=$(mktemp -d); for t in bash cat mktemp head rm dirname readlink tr; do ln -s "$(command -v "$t")" "$d/$t"; done; echo "$d"; }
test_r35_no_jq_with_state_denies() { local r m np out
  r=$(inputs_root); np=$(nojq_path)
  out=$(ev write_archdoc "$r" | (cd "$r" && PATH=$np "$PLUGIN/adapters/claude-code/hook.sh" pre-write))
  assert_eq deny "$(jq -r .hookSpecificOutput.permissionDecision <<<"$out")"; assert_contains "$(jq -r .hookSpecificOutput.permissionDecisionReason <<<"$out")" "jq"
  out=$(ev bash_redirect "$r" | (cd "$r/docs" && PATH=$np "$PLUGIN/adapters/claude-code/hook.sh" pre-bash))
  assert_eq deny "$(jq -r .hookSpecificOutput.permissionDecision <<<"$out")"
  m=$(mk_project); assert_eq "" "$(ev write_src "$m" | (cd "$m" && PATH=$np "$PLUGIN/adapters/claude-code/hook.sh" pre-write))"; }
test_r35_broken_jq_with_state_denies() { local r d out
  r=$(inputs_root); d=$(mktemp -d); printf '#!/bin/bash\nexit 127\n' >"$d/jq"; chmod +x "$d/jq"
  out=$(ev write_archdoc "$r" | (cd "$r" && PATH=$d:$PATH "$PLUGIN/adapters/claude-code/hook.sh" pre-write))
  assert_contains "$out" '"permissionDecision":"deny"'; }
test_r35_non_allow_decision_denies() { local r s out
  r=$(inputs_root); s=$(mktemp); printf '#!/bin/bash\necho %s\n' "'{\"decision\":\"block\",\"reason\":\"x\"}'" >"$s"; chmod +x "$s"
  out=$(ev write_archdoc "$r" | GA_BIN=$s hk pre-write); assert_eq deny "$(jq -r .hookSpecificOutput.permissionDecision <<<"$out")"
  printf '#!/bin/bash\necho %s\n' "'{\"decision\":\"maybe\"}'" >"$s"
  out=$(ev bash_redirect "$r" | GA_BIN=$s hk pre-bash); assert_eq deny "$(jq -r .hookSpecificOutput.permissionDecision <<<"$out")"; }
test_r35_unparseable_input_with_state_denies() { local r out
  r=$(inputs_root); out=$(printf 'not json' | (cd "$r" && hk pre-bash)); assert_eq deny "$(jq -r .hookSpecificOutput.permissionDecision <<<"$out")"
  m=$(mk_project); assert_eq "" "$(printf 'not json' | (cd "$m" && hk pre-bash))"; }
