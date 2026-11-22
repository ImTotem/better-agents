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
# The hook calls jq by absolute path (P20); GA_TEST_JQ (test mode only) simulates a missing or broken one.
nojq_path() { local d t; d=$(mktemp -d); for t in bash cat mktemp head rm dirname readlink tr; do ln -s "$(command -v "$t")" "$d/$t"; done; echo "$d"; }
test_r35_no_jq_with_state_denies() { local r m np out
  r=$(inputs_root); np=$(nojq_path)
  out=$(ev write_archdoc "$r" | (cd "$r" && PATH=$np GA_TEST_JQ=/nonexistent/jq "$PLUGIN/adapters/claude-code/hook.sh" pre-write))
  assert_eq deny "$(jq -r .hookSpecificOutput.permissionDecision <<<"$out")"; assert_contains "$(jq -r .hookSpecificOutput.permissionDecisionReason <<<"$out")" "jq"
  out=$(ev bash_redirect "$r" | (cd "$r/docs" && PATH=$np GA_TEST_JQ=/nonexistent/jq "$PLUGIN/adapters/claude-code/hook.sh" pre-bash))
  assert_eq deny "$(jq -r .hookSpecificOutput.permissionDecision <<<"$out")"
  m=$(mk_project); assert_eq "" "$(ev write_src "$m" | (cd "$m" && PATH=$np GA_TEST_JQ=/nonexistent/jq "$PLUGIN/adapters/claude-code/hook.sh" pre-write))"; }
test_r35_broken_jq_with_state_denies() { local r d out
  r=$(inputs_root); d=$(mktemp -d); printf '#!/bin/bash\nexit 127\n' >"$d/jq"; chmod +x "$d/jq"
  out=$(ev write_archdoc "$r" | (cd "$r" && GA_TEST_JQ=$d/jq "$PLUGIN/adapters/claude-code/hook.sh" pre-write))
  assert_contains "$out" '"permissionDecision":"deny"'; }
test_r35_non_allow_decision_denies() { local r s out
  r=$(inputs_root); s=$(mktemp); printf '#!/bin/bash\necho %s\n' "'{\"decision\":\"block\",\"reason\":\"x\"}'" >"$s"; chmod +x "$s"
  out=$(ev write_archdoc "$r" | GA_BIN=$s hk pre-write); assert_eq deny "$(jq -r .hookSpecificOutput.permissionDecision <<<"$out")"
  printf '#!/bin/bash\necho %s\n' "'{\"decision\":\"maybe\"}'" >"$s"
  out=$(ev bash_redirect "$r" | GA_BIN=$s hk pre-bash); assert_eq deny "$(jq -r .hookSpecificOutput.permissionDecision <<<"$out")"; }
test_r35_unparseable_input_with_state_denies() { local r out
  r=$(inputs_root); out=$(printf 'not json' | (cd "$r" && hk pre-bash)); assert_eq deny "$(jq -r .hookSpecificOutput.permissionDecision <<<"$out")"
  m=$(mk_project); assert_eq "" "$(printf 'not json' | (cd "$m" && hk pre-bash))"; }

# Gate redesign: the hook names its harness for the core (GA_HARNESS=claude-code), so the bash gate can
# read the isolation state; a Stop notice reaches the user as systemMessage.
test_pre_bash_follows_isolation_state() { local r out
  export GA_TEST_MANAGED_SETTINGS=/nonexistent/ga-managed-settings.json
  r=$(mk_project); GA_HARNESS=claude-code ga --root "$r" init >/dev/null
  assert_eq "" "$(ev bash_redirect "$r" | env -u GA_HARNESS "$PLUGIN/adapters/claude-code/hook.sh" pre-bash)"
  rm -f "$r/.claude/settings.local.json"
  out=$(ev bash_redirect "$r" | env -u GA_HARNESS "$PLUGIN/adapters/claude-code/hook.sh" pre-bash)
  assert_eq deny "$(jq -r .hookSpecificOutput.permissionDecision <<<"$out")"
  assert_contains "$(jq -r .hookSpecificOutput.permissionDecisionReason <<<"$out")" ga_enforce; }
test_stop_notice_becomes_system_message() { local r out
  r=$(inputs_root); rm -rf "$HOME/.local/state/grounded-arch"
  out=$(ev stop "$r" | hk stop)
  assert_eq "" "$(jq -r '.decision // empty' <<<"$out")"; assert_contains "$(jq -r .systemMessage <<<"$out")" "상태 지문"; }

# --- final fix wave (rulings P15, P17, P20): the session root comes from the harness, not from the
# hook cwd; a missing fingerprint record is never re-created by a prompt; tools by absolute path.
export GA_TEST_MANAGED_SETTINGS=/nonexistent/ga-managed-settings.json
fp15() { # -> physical path of a git project (src/a.c committed) with a brownfield design and isolation
  local p; p=$(mk_project); mkdir -p "$p/src"; echo 'int x;' >"$p/src/a.c"
  git -C "$p" init -q; git -C "$p" add -A; git -C "$p" -c user.email=t@example.com -c user.name=t commit -qm init
  GA_HARNESS=claude-code ga --root "$p" init --mode brownfield >/dev/null; (cd -P "$p" && pwd -P); }
hw() { local o # CWD PATH -> allow (no output) or the hook's permission decision
  o=$(jq -nc --arg c "$1" --arg p "$2" '{session_id:"s",cwd:$c,tool_name:"Write",tool_input:{file_path:$p,content:"x"}}' | hk pre-write)
  if [ -z "$o" ]; then echo allow; else jq -r '.hookSpecificOutput.permissionDecision' <<<"$o"; fi; }
hev() { jq -nc --arg c "$1" --argjson x "$2" '{session_id:"s",transcript_path:"/tmp/t.jsonl",cwd:$c} + $x'; } # CWD EXTRA_JSON
fpf() { ( GA_CORE=$CORE; . "$CORE/lib/common.sh"; . "$CORE/lib/state.sh"; . "$CORE/lib/fingerprint.sh"; ga_fp_path "$1" ); }
fpc() { local rc=0; ( GA_CORE=$CORE; . "$CORE/lib/common.sh"; . "$CORE/lib/state.sh"; . "$CORE/lib/fingerprint.sh"; ga_fp_check "$1" ) >/dev/null 2>&1 || rc=$?; echo $rc; }

# The reviewer's probe1, step by step: a planted .git entry plus a cd must not open the state folder,
# the fingerprint store or the settings files, and must not turn off Stop, the bash gate or GA lines.
test_p15_planted_git_marker_does_not_open_state() { local p d
  p=$(fp15); export CLAUDE_PROJECT_DIR=$p; d=$p/docs/architecture
  assert_eq allow "$(hw "$p" "$d/.git")"                  # step 1: a file under docs/architecture
  echo 'gitdir: nowhere' >"$d/.git"
  assert_eq deny "$(hw "$p" "$d/.state/state.json")"       # step 2
  assert_eq deny "$(hw "$d" "$d/.state/state.json")"       # step 2 after the cwd drifted (step 3)
  assert_eq deny "$(hw "$d" "$d/.STATE/ledger.json")"
  assert_eq deny "$(hw "$d" "$d/.state")"
  unset CLAUDE_PROJECT_DIR                                  # no harness value: the hook cwd is the fallback
  assert_eq deny "$(hw "$d" "$d/.state/state.json")"; }
test_p15_drifted_cwd_keeps_session_protections() { local p d
  p=$(fp15); export CLAUDE_PROJECT_DIR=$p; d=$p/docs/architecture; echo 'gitdir: nowhere' >"$d/.git"
  assert_eq deny "$(hw "$d" "$(fpf "$p")")"                 # step 4: the fingerprint store
  assert_eq deny "$(hw "$d" "$HOME/.claude/settings.json")" # step 4: the user settings
  assert_eq deny "$(hw "$d" "$p/.claude/settings.local.json")"
  echo 'int y;' >>"$p/src/a.c"                              # step 5: Stop still sees the change
  assert_eq block "$(hev "$d" '{"stop_hook_active":false}' | hk stop | jq -r '.decision // empty')"
  mv "$p/.claude/settings.local.json" "$p/sl.bak"           # step 6: the bash gate still checks the isolation
  assert_eq deny "$(hev "$d" '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | hk pre-bash | jq -r .hookSpecificOutput.permissionDecision)"
  mv "$p/sl.bak" "$p/.claude/settings.local.json"
  # GA lines stay user commands (not ordinary text), and SessionStart shows the design
  assert_eq block "$(hev "$d" '{"prompt":"GA 아무거나"}' | hk user-prompt | jq -r '.decision // empty')"
  assert_contains "$(hev "$d" '{"source":"startup"}' | hk session-start)" "설계 진행 중"; }
test_p15_fp_store_always_protected() { local q dd
  q=$(mk_project); export CLAUDE_PROJECT_DIR=$q # no design anywhere
  assert_eq deny "$(hw "$q" "$HOME/.local/state/grounded-arch/x.json")"
  dd=$(mktemp -d); assert_eq deny "$(GA_DATA_DIR=$dd hw "$q" "$dd/abc.json")"
  assert_eq allow "$(hw "$q" "$q/src/a.c")"; }

# P17 through the adapter's real path: every prompt carries transcript_path.
test_p17_prompt_does_not_recreate_missing_fp_record() { local r f out
  use_fake_claude; r=$(mk_project); ga --root "$r" init >/dev/null; seed_ledger "$r" "$FIX/ledger_inputs_ready.json"; ga --root "$r" verify >/dev/null
  f=$(fpf "$r"); echo '{}' >"$f"; assert_eq 2 "$(fpc "$r")"
  hev "$r" '{"prompt":"계속 진행해 주세요"}' | hk user-prompt >/dev/null; assert_eq 2 "$(fpc "$r")"
  out=$(hev "$r" '{"prompt":"GA 승인 입력"}' | hk user-prompt); assert_eq block "$(jq -r '.decision // empty' <<<"$out")"
  assert_contains "$out" "상태 지문"; assert_eq inputs "$(jq -r .phase "$r/docs/architecture/.state/state.json")"
  ga --root "$r" add assumption <"$FIX/asm.json" >/dev/null; assert_eq 2 "$(fpc "$r")" # an agent write (the MCP tool path)
  rm -f "$f"; hev "$r" '{"prompt":"계속"}' | hk user-prompt >/dev/null; assert_eq 2 "$(fpc "$r")"
  hev "$r" '{"prompt":"GA 상태승인"}' | hk user-prompt >/dev/null; assert_eq 0 "$(fpc "$r")"; }

# P20: hooks call jq and git by absolute path, and never search a relative PATH entry.
test_p20_hooks_ignore_path_jq_git_and_relative_entries() { local p d m t
  [ -x /usr/bin/jq ] && [ -x /usr/bin/git ] || return 0
  p=$(fp15); d=$(mktemp -d); m=$d/ran; mkdir -p "$p/rel"
  for t in jq git; do printf '#!/bin/bash\n: >"%s"\nexec /usr/bin/%s "$@"\n' "$m" "$t" >"$d/$t"; chmod +x "$d/$t"; done
  printf '#!/bin/bash\n: >"%s"\nexec /usr/bin/mktemp "$@"\n' "$m" >"$p/rel/mktemp"; chmod +x "$p/rel/mktemp"
  echo 'int y;' >>"$p/src/a.c"
  hev "$p" '{"stop_hook_active":false}' | (cd "$p" && PATH="rel:$d:$PATH" hk stop) >/dev/null
  hev "$p" '{"prompt":"안녕"}' | (cd "$p" && PATH="rel:$d:$PATH" hk user-prompt) >/dev/null
  jq -nc --arg c "$p" '{cwd:$c,tool_name:"Write",tool_input:{file_path:($c + "/src/b.c"),content:"x"}}' | (cd "$p" && PATH="rel:$d:$PATH" hk pre-write) >/dev/null
  [ ! -e "$m" ] || _fail "a jq, git or mktemp found on PATH (or a relative entry) ran"; }

# --- second fix wave (P28): code outside the sandbox runs only system tools ---
# Every hook, the adapter and ga take their own tools (tail, sed, mktemp, jq, git, sha256sum ...) from
# the system folders only, never from the user's PATH -- even from absolute entries outside the project.
test_p28_hooks_run_only_system_tools() { local p d m e
  p=$(fp15); export CLAUDE_PROJECT_DIR=$p; d=$(mktemp -d); m=$HOME/tools-ran; e=$(mktemp -d); fake_tools "$d" "$m"
  echo 'int y;' >>"$p/src/a.c"
  hev "$p" '{"source":"startup"}' >"$e/ss"; hev "$p" '{"prompt":"안녕"}' >"$e/up"; hev "$p" '{"prompt":"GA 일시정지"}' >"$e/pz"
  jq -nc --arg c "$p" '{cwd:$c,tool_name:"Write",tool_input:{file_path:($c + "/docs/architecture/x.md"),content:"x"}}' >"$e/pw"
  hev "$p" '{"tool_name":"Bash","tool_input":{"command":"ls"}}' >"$e/pb"; hev "$p" '{"stop_hook_active":false}' >"$e/st"
  ( export PATH="$d:$PATH"
    hk session-start <"$e/ss"; hk user-prompt <"$e/up"; hk pre-write <"$e/pw"; hk pre-bash <"$e/pb"; hk stop <"$e/st"
    hk user-prompt <"$e/pz"; "$PLUGIN/adapters/claude-code/enforce.sh" status "$p"; "$CORE/bin/ga" --root "$p" effect check
  ) >/dev/null 2>&1 || true
  [ ! -e "$m" ] || _fail "tools from the user's PATH ran outside the sandbox: $(sort -u "$m" | tr '\n' ' ')"; }
# Outside test mode, nothing in the environment can point the hook at another program.
test_p28_test_overrides_ignored_outside_test_mode() { local r s m out
  r=$(inputs_root); m=$HOME/stub-ran; s=$(mktemp)
  printf '#!/bin/bash\n: >"%s"\necho "{\\"decision\\":\\"allow\\",\\"reason\\":\\"\\"}"\n' "$m" >"$s"; chmod +x "$s"
  out=$(ev write_src "$r" | env -u GA_TEST_MODE GA_BIN="$s" "$PLUGIN/adapters/claude-code/hook.sh" pre-write)
  [ ! -e "$m" ] || _fail "GA_BIN outside test mode ran another program"
  assert_eq deny "$(jq -r .hookSpecificOutput.permissionDecision <<<"$out")"; }
# macOS: git is the developer tools' own binary, never the /usr/bin/git shim (it runs DEVELOPER_DIR's xcrun).
test_p28_git_is_never_the_xcrun_shim() { local p d m rc
  [ -x /usr/bin/xcode-select ] || return 0
  p=$(fp15); d=$(mktemp -d); m=$HOME/shim-ran; mkdir -p "$d/usr/bin"
  printf '#!/bin/bash\n: >"%s"\nexit 1\n' "$m" >"$d/usr/bin/xcrun"; chmod +x "$d/usr/bin/xcrun"
  echo 'int y;' >>"$p/src/a.c"
  rc=0; DEVELOPER_DIR=$d "$CORE/bin/ga" --root "$p" effect check >"$HOME/out" 2>/dev/null || rc=$?
  [ ! -e "$m" ] || _fail "the /usr/bin/git shim ran a program from DEVELOPER_DIR"
  assert_eq 1 "$rc"; assert_eq '["src/a.c"]' "$(jq -c .violations "$HOME/out")"; }

# --- P32: user-visible confirmations reach the user, and the jq-unusable path keeps P21 ---
# M3: the GA 재개 list, the GA 격리해제 confirmation and the excludedCommands warning go out as systemMessage.
test_p32_confirmations_reach_the_user() { local p out s
  p=$(fp15); export CLAUDE_PROJECT_DIR=$p
  hev "$p" '{"prompt":"GA 일시정지"}' | hk user-prompt >/dev/null; echo n >"$p/src/n.c"
  out=$(hev "$p" '{"prompt":"GA 재개"}' | hk user-prompt); assert_contains "$(jq -r '.systemMessage // ""' <<<"$out")" src/n.c
  s=$p/.claude/settings.local.json; jq '.sandbox.excludedCommands = ["docker *"]' "$s" >"$s.x"; mv "$s.x" "$s"
  out=$(hev "$p" '{"source":"startup"}' | hk session-start); assert_contains "$(jq -r '.systemMessage // ""' <<<"$out")" "docker *"
  out=$(hev "$p" '{"prompt":"GA 격리해제"}' | hk user-prompt); assert_contains "$(jq -r '.systemMessage // ""' <<<"$out")" "격리해제"; }
# P21 in the jq-unusable path: a PAUSED marker never opens writes to the state folder or the fingerprint store.
test_p32_jq_unusable_pause_keeps_state_and_store_locked() { local r p out
  r=$(inputs_root); : >"$r/docs/architecture/.state/PAUSED"
  for p in "$r/docs/architecture/.state/state.json" "$HOME/.local/state/grounded-arch/x.json"; do
    out=$(jq -nc --arg c "$r" --arg p "$p" '{cwd:$c,tool_name:"Write",tool_input:{file_path:$p,content:"x"}}' | (cd "$r" && GA_TEST_JQ=/nonexistent/jq hk pre-write))
    assert_contains "$out" '"permissionDecision":"deny"'
  done
  assert_eq "" "$(ev bash_redirect "$r" | (cd "$r" && GA_TEST_JQ=/nonexistent/jq hk pre-bash))"; }
