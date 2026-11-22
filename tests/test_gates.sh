dec() { jq -r .decision <<<"$1"; }
phase() { r=$(mk_project ${2:-greenfield}); ga --root "$r" init >/dev/null; set_state "$r" ".phase=\"$1\""; echo "$r"; }
bash_dec() { # ROOT CMD
  (cd "$1" && dec "$(ga gate bash --command "$2")"); }
test_write_no_state_allows() { r=$(mk_project); assert_eq allow "$(dec "$(ga gate write --path "$r/src/a.c")")"; }
test_write_inputs_src_denied() { r=$(phase inputs); assert_eq deny "$(dec "$(ga gate write --path "$r/src/a.c")")"; }
test_write_inputs_arch_doc_allowed() { r=$(phase inputs); assert_eq allow "$(dec "$(ga gate write --path "$r/docs/architecture/architecture.md")")"; }
test_write_state_dir_denied_in_implement() { r=$(phase implement); assert_eq deny "$(dec "$(ga gate write --path "$r/docs/architecture/.state/state.json")")"; }
test_write_paused_allows() { r=$(phase inputs); set_state "$r" '.paused=true'; assert_eq allow "$(dec "$(ga gate write --path "$r/src/a.c")")"; }
test_write_outside_root_allows() { r=$(phase inputs); assert_eq allow "$(dec "$(ga gate write --path "$HOME/.scratch-ga-test")")"; }
test_write_skeleton_brownfield_unmapped_denied() { r=$(phase skeleton brownfield); assert_eq deny "$(dec "$(ga gate write --path "$r/src/other.c")")"; }
test_write_skeleton_brownfield_mapped_allowed() { r=$(phase skeleton brownfield); seed_map "$r" "src/new.c" new; assert_eq allow "$(dec "$(ga gate write --path "$r/src/new.c")")"; }
test_write_korean_space_path() { r=$(phase skeleton brownfield); seed_map "$r" "src/결제 모듈/a.ts" new; assert_eq allow "$(dec "$(ga gate write --path "$r/src/결제 모듈/a.ts")")"; }
test_write_private_tmp_alias() { r=$(phase inputs); alias_path="/private${r#/private}"; assert_eq deny "$(dec "$(ga gate write --path "$alias_path/src/a.c")")"; assert_eq allow "$(dec "$(ga gate write --path "$alias_path/docs/architecture/x.md")")"; }
test_write_corrupt_state_denies() { r=$(phase inputs); echo '{bad' >"$r/docs/architecture/.state/state.json"; out=$(ga gate write --path "$r/src/a.c"); assert_eq deny "$(dec "$out")"; assert_contains "$out" "state.json"; }
test_write_implement_allows() { r=$(phase implement); assert_eq allow "$(dec "$(ga gate write --path "$r/src/a.c")")"; }
test_stop_format_error_blocks_even_hook_active() { r=$(phase iterating); seed_ledger "$r" "$FIX/ledger_bad_asm.json"; assert_eq block "$(cd "$r" && dec "$(ga gate stop --hook-active true)")"; }
test_stop_asked_question_allows() { r=$(phase inputs); seed_ledger "$r" "$FIX/ledger_asked_q.json"; assert_eq allow "$(cd "$r" && dec "$(ga gate stop)")"; }

# --- additional coverage ---
test_write_sibling_prefix_denied() { r=$(phase inputs); mkdir -p "$r/docsX"; assert_eq deny "$(dec "$(ga gate write --path "$r/docsX/a.md")")"; assert_eq deny "$(dec "$(ga gate write --path "$r/docs/architecture-old/a.md")")"; }
test_write_state_sibling_not_state() { r=$(phase inputs); assert_eq allow "$(dec "$(ga gate write --path "$r/docs/architecture/.statement.md")")"; }
test_write_state_dir_denied_with_dotdot() { r=$(phase inputs); assert_eq deny "$(dec "$(ga gate write --path "$r/docs/architecture/x/../.state/ledger.json")")"; }
test_write_relative_path_uses_pwd() { r=$(phase inputs); mkdir -p "$r/src"; assert_eq deny "$(cd "$r/src" && dec "$(ga gate write --path a.c)")"; }
test_write_root_found_from_path_not_pwd() { r=$(phase inputs); assert_eq deny "$(cd "$HOME" && dec "$(ga gate write --path "$r/src/a.c")")"; }
test_write_design_review_denies_src() { r=$(phase design-review); assert_eq deny "$(dec "$(ga gate write --path "$r/src/a.c")")"; }
test_write_deny_reason_korean_names_phase() { r=$(phase iterating); out=$(ga gate write --path "$r/src/a.c"); assert_contains "$out" "iterating"; assert_contains "$out" "GA 일시정지"; }
test_write_skeleton_greenfield_allows() { r=$(phase skeleton greenfield); assert_eq allow "$(dec "$(ga gate write --path "$r/src/a.c")")"; }
test_write_skeleton_brownfield_kept_denied() { r=$(phase skeleton brownfield); seed_map "$r" "src/kept.c" kept; assert_eq deny "$(dec "$(ga gate write --path "$r/src/kept.c")")"; }
test_write_skeleton_brownfield_arch_doc_allowed() { r=$(phase skeleton brownfield); assert_eq allow "$(dec "$(ga gate write --path "$r/docs/architecture/architecture.md")")"; }
test_write_skeleton_brownfield_changed_allowed() { r=$(phase skeleton brownfield); seed_map "$r" "./src/./c.c" changed; assert_eq allow "$(dec "$(ga gate write --path "$r/src/c.c")")"; }
test_write_skeleton_mapping_prefix_not_match() { r=$(phase skeleton brownfield); seed_map "$r" "src/new" new; assert_eq deny "$(dec "$(ga gate write --path "$r/src/new.c")")"; }
test_write_unknown_phase_denies() { r=$(phase inputs); set_state "$r" '.phase="bogus"'; assert_eq deny "$(dec "$(ga gate write --path "$r/src/a.c")")"; }
test_write_missing_path_denies() { r=$(phase inputs); assert_eq deny "$(cd "$r" && dec "$(ga gate write)")"; }
test_bash_no_state_allows() { r=$(mk_project); assert_eq allow "$(bash_dec "$r" 'rm -rf src')"; }
test_bash_paused_allows() { r=$(phase inputs); set_state "$r" '.paused=true'; assert_eq allow "$(bash_dec "$r" 'rm -rf src')"; }
test_gate_output_single_json_line_exit0() { r=$(phase inputs); out=$(cd "$r" && ga gate bash --command 'rm x'); assert_eq 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"; assert_status 0 ga gate write --path "$r/src/a.c"; }
test_stop_no_state_allows() { r=$(mk_project); assert_eq allow "$(cd "$r" && dec "$(ga gate stop)")"; }
test_stop_paused_allows() { r=$(phase iterating); seed_ledger "$r" "$FIX/ledger_bad_asm.json"; set_state "$r" '.paused=true'; assert_eq allow "$(cd "$r" && dec "$(ga gate stop)")"; }
test_stop_reason_lists_errors_and_hint() { r=$(phase iterating); seed_ledger "$r" "$FIX/ledger_bad_asm.json"; out=$(cd "$r" && ga gate stop --hook-active false); assert_contains "$out" "ASM-1: "; assert_contains "$out" "ga_add, kind question"; }
test_stop_unreadable_ledger_blocks() { r=$(phase inputs); echo 'garbage' >"$r/docs/architecture/.state/ledger.json"; assert_eq block "$(cd "$r" && dec "$(ga gate stop)")"; }
test_stop_corrupt_state_allows() { r=$(phase inputs); echo '{bad' >"$r/docs/architecture/.state/state.json"; out=$(cd "$r" && ga gate stop); assert_eq allow "$(dec "$out")"; }
test_write_i2_case_alias_state_denied() {
  r=$(phase implement); assert_eq deny "$(dec "$(ga gate write --path "$r/docs/architecture/.STATE/ledger.json")")"
  assert_eq deny "$(dec "$(ga gate write --path "$r/docs/Architecture/.state/ledger.json")")"
  r=$(phase inputs); assert_eq deny "$(dec "$(ga gate write --path "$r/docs/architecture/.STATE/ledger.json")")"; }
test_write_i2_case_alias_arch_doc_inputs_allowed() { r=$(phase inputs); assert_eq allow "$(dec "$(ga gate write --path "$r/docs/Architecture/x.md")")"; }
test_stop_limits_to_10_errors() {
  r=$(phase inputs)
  jq -n '{items:[range(1;16)|{id:"ASM-\(.)",kind:"assumption",round:1,phase_added:"inputs",iteration:null,status:"open",resolution:null,statement:"s",indirect_evidence:[],search_log:{code:"a",docs:"a",conversation:"a",web:"a"},alternatives:[{assumption:"x",reason:"y"}]}]}' | seed_ledger "$r" -
  out=$(cd "$r" && ga gate stop)
  n=$(jq -r .reason <<<"$out" | grep -c '^ASM-')
  assert_eq 10 "$n"
}

# --- final review fixes ---
# C1 (R24): inside a verifier runner the stop gate never forces the runner to continue.
test_c1_in_runner_stop_allows() { local r; r=$(phase iterating); seed_ledger "$r" "$FIX/ledger_bad_asm.json"
  assert_eq allow "$(dec "$(cd "$r" && GA_IN_RUNNER=1 ga gate stop)")"; }
# I6 (R31): the PAUSED marker opens every gate; a corrupt state.json keeps read-only work possible.
test_i6_paused_marker_opens_gates() { local r; r=$(phase inputs); seed_ledger "$r" "$FIX/ledger_bad_asm.json"; : >"$r/docs/architecture/.state/PAUSED"
  assert_eq allow "$(dec "$(ga gate write --path "$r/src/a.c")")"; assert_eq allow "$(bash_dec "$r" 'rm -rf src')"
  assert_eq allow "$(dec "$(cd "$r" && ga gate stop)")"; }
test_i6_corrupt_state_write_denied_with_recovery() { local r out; r=$(phase inputs); echo '{bad' >"$r/docs/architecture/.state/state.json"
  out=$(ga gate write --path "$r/src/a.c"); assert_eq deny "$(dec "$out")"; assert_contains "$out" "GA 일시정지"; assert_contains "$out" "복원"; }
# I9 (R34d): the plugin itself is write-protected while a design is active.
test_i9_plugin_root_write_denied() { local r; r=$(phase implement)
  assert_eq deny "$(cd "$r" && dec "$(ga gate write --path "$PLUGIN/core/lib/gates.sh")")"
  set_state "$r" '.paused=true'; assert_eq allow "$(cd "$r" && dec "$(ga gate write --path "$PLUGIN/core/lib/gates.sh")")"; }

# --- gate redesign (spec 5.5): shell commands run inside the OS sandbox, effects are checked afterwards ---
# The helpers call the gates as the Claude Code hook does (GA_HARNESS=claude-code). A managed-settings
# file on the test machine stays out of the isolation check.
export GA_TEST_MANAGED_SETTINGS=/nonexistent/ga-managed-settings.json
enforced() { # PHASE [MODE] -> design root initialized with the Claude Code isolation settings
  local r; r=$(mk_project "${2:-greenfield}"); GA_HARNESS=claude-code ga --root "$r" init >/dev/null; set_state "$r" ".phase=\"$1\""; echo "$r"; }
gb() { (cd "$1" && GA_HARNESS=claude-code ga gate bash --command "$2"); }                 # ROOT CMD
gw() { GA_HARNESS=claude-code ga gate write --path "$1"; }                                # PATH (cwd = session dir)
gs() { (cd "$1" && GA_HARNESS=claude-code ga gate stop --hook-active "${2:-false}"); }    # ROOT [HOOK_ACTIVE]
notice() { jq -r '.notice // ""' <<<"$1"; }
uc() { local f; f=$(mktemp); printf '%s' "$2" >"$f"; ga --root "$1" user-command --text-file "$f"; }

# The bash gate never reads the command: blocking writes is the operating system's job.
test_gate_bash_ignores_command_text() { local r p c
  for p in inputs implement; do
    r=$(enforced $p)
    for c in 'rm -rf docs/architecture/.state' 'bash hook.sh user-prompt' 'git clean -fdx ..' "bash $PLUGIN/adapters/claude-code/hook.sh user-prompt" \
             'echo x > src/a.c' 'ga user-command --text-file /tmp/f' 'GA_RUNNERS_DIR=/tmp/x ga verify' ''; do
      [ "$(dec "$(gb "$r" "$c")")" = allow ] || _fail "[$c] in $p not allowed"
    done
  done
  assert_eq allow "$(dec "$(cd "$r" && GA_HARNESS=claude-code ga gate bash)")"; }
test_gate_bash_denies_when_enforcement_inactive() { local r out s
  r=$(phase inputs) # initialized without a harness: no isolation settings
  out=$(gb "$r" ls); assert_eq deny "$(dec "$out")"
  assert_contains "$out" ga_enforce; assert_contains "$out" "GA 일시정지"; assert_contains "$out" settings.local.json
  r=$(enforced implement); s=$r/.claude/settings.local.json
  jq '.sandbox.allowUnsandboxedCommands = true' "$s" >"$s.new"; mv "$s.new" "$s"
  out=$(gb "$r" ls); assert_eq deny "$(dec "$out")"; assert_contains "$out" allowUnsandboxedCommands
  rm -f "$s"; assert_eq deny "$(dec "$(gb "$r" ls)")"
  # no harness named: the isolation cannot be checked
  r=$(enforced implement); out=$(cd "$r" && env -u GA_HARNESS "$CORE/bin/ga" gate bash); assert_eq deny "$(dec "$out")"; assert_contains "$out" GA_HARNESS
  # an unreadable state.json still counts as an active design
  r=$(phase inputs); echo '{bad' >"$r/docs/architecture/.state/state.json"; assert_eq deny "$(dec "$(gb "$r" ls)")"; }
test_gate_bash_allows_without_design_or_paused() { local r
  r=$(mk_project); assert_eq allow "$(dec "$(gb "$r" 'rm -rf src')")"
  assert_eq allow "$(dec "$(cd "$r" && env -u GA_HARNESS "$CORE/bin/ga" gate bash)")"
  r=$(phase inputs); set_state "$r" '.paused=true'; assert_eq allow "$(dec "$(gb "$r" 'rm -rf src')")"
  r=$(phase iterating); : >"$r/docs/architecture/.state/PAUSED"; assert_eq allow "$(dec "$(cd "$r" && env -u GA_HARNESS "$CORE/bin/ga" gate bash)")"
  echo '{bad' >"$r/docs/architecture/.state/state.json"; assert_eq allow "$(dec "$(gb "$r" ls)")"; }
# Wall-clock bounds are generous (about 5x and 8x the values measured on an idle Mac) so a loaded
# machine does not flake them; the report records the measured values.
test_gate_bash_speed() { local r t avg i
  r=$(enforced implement)
  TIMEFORMAT=%R
  t=$( { time (cd "$r" && for i in $(seq 1 100); do GA_HARNESS=claude-code "$CORE/bin/ga" gate bash --command "echo $i > src/f$i.c" >/dev/null; done); } 2>&1 )
  avg=$(awk -v t="$t" 'BEGIN { printf "%d", t * 1000 / 100 }')
  echo "ga gate bash: ${avg} ms per command (100 commands in ${t} s)" >&2
  [ "$avg" -lt 300 ] || _fail "bash gate too slow: ${avg} ms per command"
  assert_eq allow "$(dec "$(gb "$r" 'echo x > src/a.c')")"; }
test_gate_stop_speed_10k_files() { local r d f t ms out
  r=$(mk_project); git -C "$r" init -q
  for d in $(seq 1 100); do mkdir -p "$r/src/d$d"; for f in $(seq 1 100); do echo "$d $f" >"$r/src/d$d/f$f.c"; done; done
  git -C "$r" add -A; git -C "$r" -c user.email=t@example.com -c user.name=t commit -qm base
  GA_HARNESS=claude-code ga --root "$r" init >/dev/null; echo x >>"$r/src/d1/f1.c"
  TIMEFORMAT=%R
  t=$( { time gs "$r" >"$HOME/stop.out"; } 2>&1 ); out=$(cat "$HOME/stop.out")
  ms=$(awk -v t="$t" 'BEGIN { printf "%d", t * 1000 }')
  echo "ga gate stop, 10k tracked files: ${ms} ms" >&2
  assert_eq block "$(dec "$out")"; assert_contains "$out" src/d1/f1.c
  [ "$ms" -lt 2000 ] || _fail "stop gate too slow: ${ms} ms"; }

# G-write additions: protected paths in every phase while a design is active.
test_gate_write_denies_settings_and_fp_store() { local r m w p dd
  r=$(enforced implement); cd "$r"
  for p in "$r/.claude/settings.local.json" "$r/.claude/settings.json" "$r/.claude/SETTINGS.local.json" "$r/.claude/settings.backup.json" \
           "$HOME/.claude/settings.json" "$HOME/.claude/settings.local.json" "$HOME/.local/state/grounded-arch/x.json" \
           "$r/docs/architecture/.state/state.json" "$PLUGIN/core/lib/gates.sh"; do
    [ "$(dec "$(gw "$p")")" = deny ] || _fail "not denied: $p"
  done
  for p in "$r/.claude/commands/x.md" "$r/.claude/agents/a.md" "$r/src/a.c" "$r/settings.json" "$HOME/notes.txt"; do
    [ "$(dec "$(gw "$p")")" = allow ] || _fail "denied: $p"
  done
  assert_contains "$(gw "$r/.claude/settings.local.json")" "GA 일시정지"
  dd=$(mktemp -d); assert_eq deny "$(dec "$(GA_DATA_DIR=$dd gw "$dd/abc.json")")"
  # a worktree design protects the main checkout's settings too
  m=$(mk_project); w=$(mk_project); mkdir -p "$m/.git/worktrees/wt"; echo ../.. >"$m/.git/worktrees/wt/commondir"
  echo "gitdir: $m/.git/worktrees/wt" >"$w/.git"; GA_HARNESS=claude-code ga --root "$w" init >/dev/null
  assert_eq deny "$(cd "$w" && dec "$(gw "$m/.claude/settings.local.json")")"
  assert_eq allow "$(cd "$w" && dec "$(gw "$m/.claude/commands/x.md")")"
  # paused, or no design at the session: not protected
  set_state "$r" '.paused=true'; assert_eq allow "$(dec "$(gw "$r/.claude/settings.local.json")")"
  p=$(mk_project); assert_eq allow "$(cd "$p" && dec "$(gw "$HOME/.claude/settings.json")")"; }
test_gate_write_follows_final_symlink() { local r
  r=$(enforced implement)
  ln -s "$r/docs/architecture/.state/ledger.json" "$r/docs/architecture/link.json"
  ln -s "$HOME/.claude/settings.json" "$r/my-settings.json"
  assert_eq deny "$(dec "$(cd "$r" && gw "$r/docs/architecture/link.json")")"
  assert_eq deny "$(dec "$(cd "$r" && gw "$r/my-settings.json")")"
  ln -s "$r/src/a.c" "$r/a-link.c"; assert_eq allow "$(dec "$(cd "$r" && gw "$r/a-link.c")")"; }
test_gate_write_denied_while_fingerprint_mismatches() { local r out
  r=$(enforced implement); assert_eq allow "$(dec "$(gw "$r/src/a.c")")"
  tamper_state "$r" '.x = 1'
  out=$(gw "$r/src/a.c"); assert_eq deny "$(dec "$out")"; assert_contains "$out" "GA 상태승인"
  assert_eq deny "$(dec "$(gw "$r/docs/architecture/architecture.md")")"
  uc "$r" 'GA 상태승인' >/dev/null; assert_eq allow "$(dec "$(gw "$r/src/a.c")")"; }

# G-stop additions: file changes outside the phase allow-list and the state fingerprint.
test_gate_stop_blocks_on_effect_violation() { local r out
  r=$(enforced inputs); assert_eq allow "$(dec "$(gs "$r")")"
  mkdir -p "$r/src"; echo 'int x;' >"$r/src/new.c"
  out=$(gs "$r"); assert_eq block "$(dec "$out")"; assert_contains "$out" src/new.c
  # the reason says the agent can revert it (so it keeps blocking) and the user can accept it
  assert_contains "$out" "되돌릴 때까지 종료를 계속 막습니다"; assert_contains "$out" "GA 상태승인"
  assert_eq block "$(dec "$(gs "$r" true)")"
  rm -f "$r/src/new.c"; assert_eq allow "$(dec "$(gs "$r")")"
  echo x >>"$r/docs/architecture/architecture.md"; assert_eq allow "$(dec "$(gs "$r")")"; }
test_gate_stop_blocks_on_fp_mismatch() { local r out
  r=$(enforced implement); assert_eq allow "$(dec "$(gs "$r")")"
  tamper_state "$r" '.x = 1'
  out=$(gs "$r"); assert_eq block "$(dec "$out")"; assert_contains "$out" "GA 상태승인"
  assert_contains "$out" "사용자만 풀 수 있으므로 종료는 이번 한 번만 막습니다"
  # only the user can fix it: once the agent was told, the next stop passes and the user sees a notice
  out=$(gs "$r" true); assert_eq allow "$(dec "$out")"; assert_contains "$(notice "$out")" "GA 상태승인"
  uc "$r" 'GA 상태승인' >/dev/null; out=$(gs "$r"); assert_eq allow "$(dec "$out")"; assert_eq "" "$(notice "$out")"; }
# Both at once with stop_hook_active: the file change (the agent can revert it) still blocks; the
# mismatch (only the user can clear it) is not repeated to the agent, it goes to the user.
test_gate_stop_hook_active_blocks_files_not_fingerprint() { local r out
  r=$(enforced inputs); mkdir -p "$r/src"; echo y >"$r/src/new.c"; tamper_state "$r" '.x = 1'
  out=$(gs "$r" true); assert_eq block "$(dec "$out")"; assert_contains "$(jq -r .reason <<<"$out")" src/new.c
  assert_not_contains "$(jq -r .reason <<<"$out")" "상태 지문 불일치"; assert_contains "$(notice "$out")" "상태 지문 불일치"; }

# P12: the effect check cannot tell the user's edits from the agent's -- the user accepts them.
test_resume_accepts_files_changed_while_paused() { local r out
  r=$(enforced inputs)
  uc "$r" 'GA 일시정지' >/dev/null; mkdir -p "$r/src"; echo 'int x;' >"$r/src/fix.c"
  assert_eq allow "$(dec "$(gs "$r")")"
  out=$(uc "$r" 'GA 재개'); assert_eq allow "$(dec "$out")"; assert_contains "$out" "새 기준"
  assert_eq allow "$(dec "$(gs "$r")")"; assert_eq '[]' "$(ga --root "$r" effect check | jq -c .violations)"
  echo 'int y;' >"$r/src/after.c"; out=$(gs "$r"); assert_eq block "$(dec "$out")"; assert_contains "$out" src/after.c
  assert_not_contains "$out" src/fix.c; }
test_state_accept_clears_effect_violation() { local r out
  r=$(enforced inputs); mkdir -p "$r/src"; echo 'int x;' >"$r/src/user.c"
  assert_eq block "$(dec "$(gs "$r")")"
  out=$(uc "$r" 'GA 상태승인'); assert_eq allow "$(dec "$out")"; assert_contains "$out" "새 기준"
  out=$(gs "$r"); assert_eq allow "$(dec "$out")"; assert_eq "" "$(notice "$out")"
  assert_eq 0 "$( ( GA_CORE=$CORE; . "$CORE/lib/common.sh"; . "$CORE/lib/state.sh"; . "$CORE/lib/fingerprint.sh"; ga_fp_check "$r" ) >/dev/null 2>&1; echo $?)"; }
# The agent's own paths (ga commands, which the MCP tools run) never move the file baseline.
test_agent_paths_cannot_clear_effect_violation() { local r rc out
  use_fake_claude
  r=$(enforced inputs); seed_ledger "$r" "$FIX/ledger_inputs_ready.json"; mkdir -p "$r/src"; echo 'int x;' >"$r/src/agent.c"
  ga --root "$r" add assumption <"$FIX/asm.json" >/dev/null; ga --root "$r" render >/dev/null
  GA_HARNESS=claude-code ga --root "$r" enforce >/dev/null; ga --root "$r" verify >/dev/null || true
  rc=0; ga --root "$r" effect snapshot >/dev/null 2>&1 || rc=$?; assert_eq 2 "$rc"
  rc=0; out=$(ga --root "$r" effect check 2>/dev/null) || rc=$?; assert_eq 1 "$rc"; assert_eq '["src/agent.c"]' "$(jq -c .violations <<<"$out")"
  assert_eq block "$(dec "$(gs "$r")")"; }
test_gate_stop_takes_missing_snapshot_once() { local r out
  r=$(enforced inputs); rm -f "$r/docs/architecture/.state/snapshot.json"; _fp_sync "$r"
  mkdir -p "$r/src"; echo x >"$r/src/old.c" # made before any baseline existed: not judged
  out=$(gs "$r"); assert_eq allow "$(dec "$out")"; assert_contains "$(notice "$out")" "파일 변경 기준"
  [ -f "$r/docs/architecture/.state/snapshot.json" ] || _fail "no snapshot taken"
  out=$(gs "$r"); assert_eq allow "$(dec "$out")"; assert_eq "" "$(notice "$out")"
  echo y >"$r/src/new.c"; assert_eq block "$(dec "$(gs "$r")")"; }
test_gate_stop_reports_missing_fingerprint() { local r out
  r=$(enforced implement); rm -rf "$HOME/.local/state/grounded-arch"
  out=$(gs "$r"); assert_eq allow "$(dec "$out")"; assert_contains "$(notice "$out")" "상태 지문"; assert_contains "$(notice "$out")" "GA 상태승인"; }

# Read commands run inside the sandbox: they must not create anything under .state (not even a lock).
test_read_commands_write_nothing() { local r sd c bad=""
  r=$(enforced implement); sd=$r/docs/architecture/.state
  chmod -R a-w "$sd"
  for c in status 'status --json' check 'check --json' rule 'effect check'; do
    (cd "$r" && ga $c >/dev/null 2>&1) || bad="$bad [$c]"
  done
  chmod -R u+w "$sd"
  assert_eq "" "$bad"; [ ! -e "$sd/.lock" ] || _fail "lock dir created"; }
test_cli_write_permission_error_names_mcp_tool() { local r sd out out2 out3 rc=0 rc2=0 rc3=0 s
  use_fake_claude
  r=$(enforced inputs); sd=$r/docs/architecture/.state; seed_ledger "$r" "$FIX/ledger_inputs_ready.json"
  chmod -R a-w "$sd"; s=$SECONDS
  out=$(ga --root "$r" add assumption <"$FIX/asm.json" 2>&1) || rc=$?
  out2=$(ga --root "$r" render 2>&1) || rc2=$?
  out3=$(ga --root "$r" verify 2>&1) || rc3=$? # refused before the panel runs
  chmod -R u+w "$sd"
  [ "$rc" != 0 ] || _fail "ga add succeeded"; [ "$rc2" != 0 ] || _fail "ga render succeeded"; [ "$rc3" != 0 ] || _fail "ga verify succeeded"
  assert_contains "$out" ga_add; assert_contains "$out2" ga_render; assert_contains "$out3" ga_verify
  [ $((SECONDS - s)) -lt 3 ] || _fail "took $((SECONDS - s)) s (lock retry loop or panel run?)"
  assert_eq 0 "$(jq '[.items[] | select(.kind == "assumption")] | length' "$sd/ledger.json")"; [ ! -e "$sd/report.json" ] || _fail "report written"
  [ ! -e "$sd/.lock" ] || _fail "lock left behind"
  # the lock itself also reports the MCP tool (a folder that turns read-only after the probe)
  out=$( ( GA_CORE=$CORE; . "$CORE/lib/common.sh"; GA_SUB=ask; chmod a-w "$sd"; ga_lock "$r" ) 2>&1 ) || true
  chmod u+w "$sd"; assert_contains "$out" ga_ask; [ ! -e "$sd/.lock" ] || _fail "lock created"; }
