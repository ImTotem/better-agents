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
test_bash_redirect_src_denied_inputs() { r=$(phase inputs); assert_eq deny "$(cd "$r" && dec "$(ga gate bash --command 'echo x > src/a.c')")"; }
test_bash_redirect_devnull_allowed() { r=$(phase inputs); assert_eq allow "$(cd "$r" && dec "$(ga gate bash --command 'ls > /dev/null 2>&1')")"; }
test_bash_internal_usercommand_denied_implement() { r=$(phase implement); assert_eq deny "$(cd "$r" && dec "$(ga gate bash --command 'ga user-command --text-file /tmp/p')")"; }
test_bash_state_write_denied_implement() { r=$(phase implement); assert_eq deny "$(cd "$r" && dec "$(ga gate bash --command "jq . x > docs/architecture/.state/ledger.json")")"; }
test_bash_ga_add_allowed_inputs() { r=$(phase inputs); assert_eq allow "$(cd "$r" && dec "$(ga gate bash --command "ga add question <<'EOF'
{}
EOF")")"; }
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
test_bash_corrupt_state_denies_writes() { r=$(phase inputs); echo '{bad' >"$r/docs/architecture/.state/state.json"; out=$(cd "$r" && ga gate bash --command 'touch src/x'); assert_eq deny "$(dec "$out")"; assert_contains "$out" "state.json"; }
test_bash_cp_denied_inputs() { r=$(phase inputs); assert_eq deny "$(bash_dec "$r" 'cp a b')"; }
test_bash_git_checkout_denied_inputs() { r=$(phase inputs); assert_eq deny "$(bash_dec "$r" 'git checkout -- src/a.c')"; assert_eq deny "$(bash_dec "$r" 'git -C . stash')"; }
test_bash_git_status_allowed_inputs() { r=$(phase inputs); assert_eq allow "$(bash_dec "$r" 'git status && git log --oneline')"; }
test_bash_stderr_dup_only_allowed() { r=$(phase inputs); assert_eq allow "$(bash_dec "$r" 'ls nope 2>&1')"; assert_eq allow "$(bash_dec "$r" 'ls >&2')"; }
test_bash_tmp_redirect_allowed() { r=$(phase inputs); assert_eq allow "$(bash_dec "$r" 'echo x > /tmp/ga-x')"; assert_eq allow "$(bash_dec "$r" 'echo x >> "$TMPDIR/ga-x"')"; }
test_bash_arch_doc_redirect_allowed() { r=$(phase inputs); assert_eq allow "$(bash_dec "$r" 'echo x >> docs/architecture/architecture.md')"; }
test_bash_state_redirect_denied_inputs() { r=$(phase inputs); assert_eq deny "$(bash_dec "$r" 'echo x > docs/architecture/.state/state.json')"; }
test_bash_cd_state_then_redirect_denied() { r=$(phase implement); assert_eq deny "$(bash_dec "$r" 'cd docs/architecture/.state && echo x > ledger.json')"; }
test_bash_state_read_allowed_implement() { r=$(phase implement); assert_eq allow "$(bash_dec "$r" 'cat docs/architecture/.state/ledger.json | jq .items')"; }
test_bash_state_rm_denied_implement() { r=$(phase implement); assert_eq deny "$(bash_dec "$r" 'rm docs/architecture/.state/state.json')"; }
test_bash_hook_sh_denied() { r=$(phase implement); assert_eq deny "$(bash_dec "$r" 'bash plugins/x/adapters/claude-code/hook.sh')"; }
test_bash_internal_hook_denied_via_path() { r=$(phase implement); assert_eq deny "$(bash_dec "$r" 'echo hi; /opt/x/bin/ga hook foo')"; }
test_bash_implement_allows_writes() { r=$(phase implement); assert_eq allow "$(bash_dec "$r" 'echo x > src/a.c && rm -f build/x')"; }
test_bash_skeleton_allows_writes() { r=$(phase skeleton); assert_eq allow "$(bash_dec "$r" 'echo x > src/a.c')"; }
test_bash_heredoc_body_not_scanned() { r=$(phase inputs); assert_eq allow "$(bash_dec "$r" "cat <<'EOF' >> docs/architecture/architecture.md
a -> b > c
rm -rf x
EOF")"; }
test_bash_heredoc_marker_line_redirect_scanned() { r=$(phase inputs); assert_eq deny "$(bash_dec "$r" "cat <<EOF > src/a.c
hello
EOF")"; }
test_bash_after_heredoc_still_scanned() { r=$(phase inputs); assert_eq deny "$(bash_dec "$r" "cat <<EOF
hello
EOF
rm src/a.c")"; }
test_bash_heredoc_dash_tab_terminator() { r=$(phase inputs); assert_eq allow "$(bash_dec "$r" "cat <<-EOF
	x > y
	EOF
ls")"; }
test_bash_segment_split_denies_second() { r=$(phase inputs); assert_eq deny "$(bash_dec "$r" 'ls && touch src/a.c')"; assert_eq deny "$(bash_dec "$r" 'ls | tee src/a.c')"; assert_eq deny "$(bash_dec "$r" 'ls; mv a b')"; }
test_bash_sed_i_denied_sed_n_allowed() { r=$(phase inputs); assert_eq deny "$(bash_dec "$r" "sed -i 's/a/b/' src/a.c")"; assert_eq allow "$(bash_dec "$r" "sed -n '1,3p' src/a.c")"; }
test_bash_perl_pi_denied() { r=$(phase inputs); assert_eq deny "$(bash_dec "$r" "perl -pi -e 's/a/b/' src/a.c")"; assert_eq allow "$(bash_dec "$r" "perl -Mstrict -e 'print 1'")"; }
test_bash_path_qualified_rm_denied() { r=$(phase inputs); assert_eq deny "$(bash_dec "$r" '/bin/rm src/a.c')"; assert_eq deny "$(bash_dec "$r" 'FOO=1 rm src/a.c')"; assert_eq deny "$(bash_dec "$r" 'sudo rm src/a.c')"; }
test_bash_ga_public_path_form_allowed() { r=$(phase inputs); assert_eq allow "$(bash_dec "$r" '/x/core/bin/ga --root . add driver --json "{\"a\":\"b c\"}" | cat')"; }
test_bash_ga_segment_redirect_src_denied_inputs() { r=$(phase inputs); assert_eq deny "$(bash_dec "$r" 'ga status > src/a.c')"; }
test_bash_ga_segment_devnull_allowed_inputs() { r=$(phase inputs); assert_eq allow "$(bash_dec "$r" 'ga status > /dev/null')"; }
test_bash_arith_shift_not_heredoc() { r=$(phase inputs); assert_eq deny "$(bash_dec "$r" 'echo $((1<<2))
echo x > src/a.c')"; assert_eq deny "$(bash_dec "$r" 'echo $((1<<n))
echo x > src/a.c')"; }
test_bash_deny_reason_korean() { r=$(phase inputs); out=$(cd "$r" && ga gate bash --command 'rm src/a.c'); assert_contains "$out" "inputs"; assert_contains "$out" "GA 일시정지"; assert_contains "$out" "rm"; }
test_gate_output_single_json_line_exit0() { r=$(phase inputs); out=$(cd "$r" && ga gate bash --command 'rm x'); assert_eq 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"; assert_status 0 ga gate write --path "$r/src/a.c"; }
test_stop_no_state_allows() { r=$(mk_project); assert_eq allow "$(cd "$r" && dec "$(ga gate stop)")"; }
test_stop_paused_allows() { r=$(phase iterating); seed_ledger "$r" "$FIX/ledger_bad_asm.json"; set_state "$r" '.paused=true'; assert_eq allow "$(cd "$r" && dec "$(ga gate stop)")"; }
test_stop_reason_lists_errors_and_hint() { r=$(phase iterating); seed_ledger "$r" "$FIX/ledger_bad_asm.json"; out=$(cd "$r" && ga gate stop --hook-active false); assert_contains "$out" "ASM-1: "; assert_contains "$out" "ga add question"; }
test_stop_unreadable_ledger_blocks() { r=$(phase inputs); echo 'garbage' >"$r/docs/architecture/.state/ledger.json"; assert_eq block "$(cd "$r" && dec "$(ga gate stop)")"; }
test_stop_corrupt_state_allows() { r=$(phase inputs); echo '{bad' >"$r/docs/architecture/.state/state.json"; out=$(cd "$r" && ga gate stop); assert_eq allow "$(dec "$out")"; }
# --- fix round 1 regressions (review probes) ---
bd() { # PHASE EXPECTED CMD   (fresh project in that phase)
  local r; r=$(phase "$1"); assert_eq "$2" "$(bash_dec "$r" "$3")"; }
test_bash_c1_nocmd_redirects_denied_inputs() {
  bd inputs deny '>src/a.c'; bd inputs deny '>>src/a.c'; bd inputs deny '2>src/a.c'
  bd inputs deny 'X=1 >src/a.c'; bd inputs deny 'ls && >src/a.c'; bd inputs deny '(echo a; echo b) >src/a.c'; }
test_bash_c1_nocmd_state_redirect_denied() {
  bd implement deny '>docs/architecture/.state/ledger.json'; bd skeleton deny '>docs/architecture/.state/state.json'; }
test_bash_c2_heredoc_tag_with_dash() {
  bd inputs deny "cat <<'END-OF' > docs/architecture/a.md
body
END-OF
rm src/main.c"
  bd inputs deny "cat <<EOF-1 >/dev/null
body
EOF-1
rm src/main.c"
  bd implement deny "cat <<EOF-1 >/dev/null
body
EOF-1
echo x > docs/architecture/.state/ledger.json"; }
test_bash_c2_heredoc_in_quotes() {
  bd inputs deny 'echo "a<<b" && cat <<EOF
x
EOF
rm src/main.c'; }
test_bash_i1_state_via_variable() {
  bd implement deny 'L=docs/architecture/.state/ledger.json
jq . "$L" > /tmp/l.json && mv /tmp/l.json "$L"'
  bd implement deny 'L=docs/architecture/.state/ledger.json; cp /tmp/l.json $L'
  bd skeleton deny 'L=docs/architecture/.state/state.json; cp /tmp/l.json $L'; }
test_write_i2_case_alias_state_denied() {
  r=$(phase implement); assert_eq deny "$(dec "$(ga gate write --path "$r/docs/architecture/.STATE/ledger.json")")"
  assert_eq deny "$(dec "$(ga gate write --path "$r/docs/Architecture/.state/ledger.json")")"
  r=$(phase inputs); assert_eq deny "$(dec "$(ga gate write --path "$r/docs/architecture/.STATE/ledger.json")")"; }
test_write_i2_case_alias_arch_doc_inputs_allowed() { r=$(phase inputs); assert_eq allow "$(dec "$(ga gate write --path "$r/docs/Architecture/x.md")")"; }
test_bash_i2_case_alias_state_denied() {
  bd implement deny 'echo x > docs/architecture/.STATE/ledger.json'; bd implement deny 'echo x > docs/Architecture/.state/ledger.json'; }
test_bash_i3_glob_var_targets_denied() {
  bd inputs deny 'echo x > docs/architecture/.s*/ledger.json'
  bd implement deny 'echo x > docs/architecture/.s*/ledger.json'
  bd implement deny 'S=.state; echo x > docs/architecture/$S/ledger.json'
  bd inputs deny 'echo x > docs/architecture/$S/a.md'; }
test_bash_i3_relative_after_cd_denied() {
  bd inputs deny 'cd src && echo x > ../src/a.c'
  bd implement deny 'cd docs/architecture && echo x > ../architecture/.state/ledger.json'; }
test_bash_i3_tmpdir_var_override_denied() { bd inputs deny 'TMPDIR=src; echo x > $TMPDIR/a.c'; }
test_bash_i3_tmpdir_still_allowed() { bd inputs allow 'echo x > "$TMPDIR/ga-x"'; }
test_bash_i4_internal_via_subshell_denied() {
  bd inputs deny '(ga user-command --text-file /tmp/p)'; bd inputs deny 'x=$(ga hook stop)'
  bd inputs deny 'echo `ga hook stop`'; bd inputs deny "ga 'user-command' --text-file /tmp/p"
  bd implement deny '(ga hook stop)'; }
test_bash_i5_single_ampersand_splits() { bd inputs deny 'ls & rm src/main.c'; bd inputs deny 'sleep 1 &touch src/x'; }
test_bash_i5_amp_redirects_not_split() { bd inputs allow 'ls nope 2>&1 && ls &>/dev/null'; }
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
test_i6_corrupt_state_bash_read_only_allowed() { local r c out; r=$(phase inputs); echo '{"phase":' >"$r/docs/architecture/.state/state.json"
  for c in 'ls -la' 'git status' 'cat docs/architecture/.state/state.json' 'git log --oneline | head'; do assert_eq allow "$(bash_dec "$r" "$c")"; done
  out=$(cd "$r" && ga gate bash --command 'rm src/main.c'); assert_eq deny "$(dec "$out")"; assert_contains "$out" "GA 일시정지"; assert_contains "$out" "state.json"
  assert_eq deny "$(bash_dec "$r" 'echo x > src/a.c')"; assert_eq deny "$(bash_dec "$r" 'echo {} > docs/architecture/.state/state.json')"; }
test_i6_corrupt_state_write_denied_with_recovery() { local r out; r=$(phase inputs); echo '{bad' >"$r/docs/architecture/.state/state.json"
  out=$(ga gate write --path "$r/src/a.c"); assert_eq deny "$(dec "$out")"; assert_contains "$out" "GA 일시정지"; assert_contains "$out" "복원"; }
# I7 (R32a,b): .state itself or any ancestor is protected in every phase; git clean is denied.
test_i7_state_ancestor_writes_denied_every_phase() { local p
  for p in implement skeleton; do
    bd $p deny 'rm -rf docs/architecture'; bd $p deny 'rm -rf docs'; bd $p deny 'mv docs/architecture docs/old'; bd $p deny 'rm -rf .'
    bd $p deny 'cp -r /tmp/x/ docs/architecture'; bd $p deny 'cp /tmp/f.json docs/architecture/.stat?/state.json'
    bd $p deny 'tee docs/architecture/.st*/state.json < /tmp/f.json'; bd $p deny 'rm -rf docs/*'; bd $p deny 'mkdir docs/architecture/.state/.lock'
    bd $p allow 'rm -rf build'; bd $p allow 'cp src/a.c src/b.c'; bd $p allow 'mv docs/notes.md docs/old-notes.md'
  done; }
test_i7_git_clean_denied_every_phase() { bd implement deny 'git clean -fdx'; bd skeleton deny 'git clean -fd'; bd inputs deny 'git -C . clean -x'; bd implement allow 'git status'
  bd implement deny 'git stash -u'; bd implement allow 'git stash'; }
test_i7_git_checkout_restore_state_ancestor_denied() {
  bd implement deny 'git checkout HEAD~3 -- docs'; bd implement deny 'git restore --source=other docs/architecture'; bd implement deny 'git checkout other -- .'
  bd implement allow 'git checkout -b feature'; bd implement allow 'git checkout main'; bd implement allow 'git restore src/a.c'; }
bfs() { # EXPECTED CMD : brownfield skeleton, MAP-1 src/new.c (new)
  local r; r=$(phase skeleton brownfield); seed_map "$r" src/new.c new; assert_eq "$1" "$(bash_dec "$r" "$2")"; }
test_i7_brownfield_skeleton_bash_uses_mapping() {
  bfs deny 'echo hacked > src/main.c'; bfs deny "sed -i '' 's/0/1/' src/main.c"; bfs deny 'cp /tmp/x src/main.c'
  bfs deny 'mv src/main.c src/old.c'; bfs deny 'tee src/main.c < /dev/null'; bfs deny 'truncate -s 0 src/main.c'; bfs deny 'echo x > $D/a.c'
  bfs allow 'echo x > src/new.c'; bfs allow 'cp /tmp/x src/new.c'; bfs allow 'echo x >> docs/architecture/notes.md'; bfs allow 'ls > /tmp/out'
  bfs allow "sed -i '' 's/a/b/' src/new.c"; bfs allow 'truncate -s 0 src/new.c'; bfs allow 'ls src'; bfs allow 'rm -f /tmp/ga-build-*'; bfs deny 'rm -f src/*.o'; }
# I8 (R33c): internal hook scripts of any adapter are not callable from Bash.
test_i8_any_adapter_hook_denied() { bd implement deny 'bash /opt/p/adapters/codex/hook.sh pre-bash'; bd inputs deny 'plugins/x/adapters/opencode/hook.sh stop'; }
# I9 (R34b): GA_* / PATH assignments around a ga invocation are denied.
test_i9_env_override_around_ga_denied() { local c
  for c in 'GA_RUNNERS_DIR=/tmp/r ga verify' 'GA_TEST_MODE=1 GA_RUNNERS_DIR=/tmp/r ga verify' 'export GA_TEST_MODE=1; ga verify' \
           'env GA_ROOT=/x ga status' 'PATH=/tmp/evil:$PATH ga verify' 'export PATH=/tmp/evil:$PATH && ga verify' 'GA_IN_RUNNER=1 /x/bin/ga gate stop'; do
    bd implement deny "$c"; bd inputs deny "$c"; done
  bd implement allow 'PATH=./node_modules/.bin:$PATH npm test'; bd inputs allow 'ga verify'; bd inputs allow 'ga --root . status --json'; }
# I9 (R34d): the plugin itself is write-protected while a design is active.
test_i9_plugin_root_write_denied() { local r; r=$(phase implement)
  assert_eq deny "$(cd "$r" && dec "$(ga gate write --path "$PLUGIN/core/lib/gates.sh")")"
  assert_eq deny "$(bash_dec "$r" "echo x > $PLUGIN/core/verifier/runners/claude.json")"
  assert_eq deny "$(bash_dec "$r" "cp /tmp/x $PLUGIN/core/verifier/runners/claude.json")"
  assert_eq deny "$(bash_dec "$r" "sed -i '' s/a/b/ $PLUGIN/core/lib/gates.sh")"
  set_state "$r" '.paused=true'; assert_eq allow "$(cd "$r" && dec "$(ga gate write --path "$PLUGIN/core/lib/gates.sh")")"; }
# R35-2: heredoc bodies fed to a shell or interpreter are scanned like command lines.
test_r35_heredoc_to_shell_scanned() {
  bd inputs deny "bash <<'EOF'
rm -rf src
EOF"
  bd inputs deny 'sh <<EOF
echo x > src/a.c
EOF'
  bd inputs deny 'cat <<EOF | bash
rm -rf src
EOF'
  bd inputs deny "python3 - <<'EOF'
import os
EOF
python3 x.py > src/a.c"
  bd inputs allow "cat <<'EOF' > docs/architecture/x.md
rm -rf src
EOF"; }
test_r35_shell_c_and_eval_scanned() { bd inputs deny 'bash -c "rm -rf src"'; bd inputs deny "sh -c 'echo x > src/a.c'"; bd inputs deny "eval 'rm -rf src'"; bd inputs allow 'bash -c "ls -la"'; }

# --- targeted fix wave: N1 false denies, N2 nested repo, O1 globbed redirects ---
bx() { # DIR EXPECTED CMD   (gate run with cwd DIR; names the command on failure)
  local got; got=$(bash_dec "$1" "$3"); [ "$got" = "$2" ] || _fail "[$3] in ${1##*/}: expected $2 got $got"; }
# N1: variable and glob targets that cannot reach .state are not .state targets (cwd = root).
test_n1_var_glob_targets_allowed() { local p r c
  for p in implement skeleton; do
    r=$(phase $p); mkdir -p "$r/src" "$r/build"
    for c in 'rm -f *.o' 'rm -rf "$tmp"' 'tmp=$(mktemp -d) && rm -rf "$tmp"' "sed -i '' 's/a/b/' *.c" 'mkdir -p "$OUT"' \
             'mkdir -p "$(dirname "$f")"' 'cp "$src" "$dst"' 'mv *.txt build/' 'for f in src/*.c; do sed -i "" "s/a/b/" "$f"; done' \
             'cd build && rm -f *.o' 'cp ../x .' 'rm -rf build/*' 'rm -rf src/{a,b}.o' 'cp src/*.c build/'; do
      bx "$r" allow "$c"; done
  done; }
test_n1_state_reaching_targets_still_denied() { local p r c
  for p in implement skeleton; do
    r=$(phase $p); mkdir -p "$r/build"
    for c in 'rm -rf *' 'rm -rf ./*' 'rm -rf d*' 'rm -rf docs/a*' 'rm -rf docs' 'rm -rf docs/architecture' 'mv docs/architecture x' \
             'cp ../docs .' 'rm -rf docs/*/.state' 'rm -rf $X/architecture' 'rm -f "$D"/.state/x' 'rm -rf D?CS' 'rm -rf {build,docs}' \
             'rm -rf docs/{a,b}*/.s*' 'rm -rf docs/**' 'rm -rf "$D"/*' 'cd build && rm -rf *' 'cd build && rm -rf ../d*' \
             'cp -t . ../docs' 'cp -R /tmp/x/ docs' 'mv /tmp/x/.STATE docs/architecture/' 'install -d -m 000 x docs' \
             'rm -rf build/*/../../docs' 'rm -rf ../*' 'echo x > build/*/../../docs/a*/.s*/state.json'; do
      bx "$r" deny "$c"; done
  done; }
# N1 (d): cp/mv/ln/install into an existing directory write <dir>/<basename of each source>.
test_n1_copy_into_existing_dir_classifies_written_path() { local r
  r=$(phase implement)
  bx "$r" allow 'cp -r /tmp/x docs/architecture'; bx "$r" allow 'cp -r /tmp/x docs'; bx "$r" allow 'ln -s ../x .'
  bx "$r" deny 'cp -r /tmp/x/ docs/architecture'; bx "$r" deny 'cp -R /tmp/.state docs/architecture'; bx "$r" deny 'cp -rT /tmp/x docs'
  bx "$r" deny 'cp -r /tmp/x/. docs/architecture'; bx "$r" deny 'cp "$S" docs/architecture/'; }
# N2: from a nested repository (cwd inside it) the design is found from the write targets.
nested() { # GITKIND(file|dir) PHASE [MODE] -> design root with vendor/lib as a nested repo
  local r; r=$(phase "$2" ${3:-greenfield}); mkdir -p "$r/.git" "$r/src" "$r/vendor/lib"
  if [ "$1" = file ]; then echo 'gitdir: ../../.git/modules/lib' >"$r/vendor/lib/.git"; else mkdir -p "$r/vendor/lib/.git"; fi
  echo "$r"; }
test_n2_nested_repo_targets_use_outer_design() { local k r v
  for k in file dir; do
    r=$(nested $k iterating); v=$r/vendor/lib
    bx "$v" deny 'rm -rf ../../docs/architecture/.state'; bx "$v" deny 'echo x > ../../src/main.c'
    bx "$v" deny "cp x $r/src/a.c"; bx "$v" deny 'cd ../.. && echo x > src/main.c'
    bx "$v" allow 'make'; bx "$v" allow 'rm -f foo.o && echo x > build.log'; bx "$v" allow 'echo x > /tmp/ga-x'
    bx "$v" allow 'echo x >> ../../docs/architecture/notes.md'
    r=$(nested $k implement); v=$r/vendor/lib
    bx "$v" deny 'rm -rf ../../docs/architecture/.state'; bx "$v" deny 'rm -rf ../../docs'; bx "$v" deny 'rm -rf ../../d*'
    bx "$v" deny 'echo {} > ../../docs/a*/.s*/state.json'; bx "$v" deny 'cd ../.. && rm -rf docs'; bx "$v" deny 'rm -rf ../..'
    bx "$v" deny 'rm -rf ../../..'
    bx "$v" allow 'echo x > ../../src/main.c'; bx "$v" allow 'rm -f ../../build/*.o'; bx "$v" allow 'make'
  done; }
test_n2_nested_repo_brownfield_and_pause() { local r v
  r=$(nested file skeleton brownfield); seed_map "$r" src/new.c new; v=$r/vendor/lib
  bx "$v" deny 'echo x > ../../src/main.c'; bx "$v" allow 'echo x > ../../src/new.c'; bx "$v" deny 'rm -f ../../src/*.o'
  bx "$v" allow 'echo x > local.c'
  r=$(nested dir iterating); v=$r/vendor/lib; set_state "$r" '.paused=true'
  bx "$v" allow 'echo x > ../../src/main.c'; bx "$v" allow 'rm -rf ../../src'; }
# O1: a globbed redirect is classified like a command target (text, then the glob walk toward .state).
test_o1_globbed_redirect_into_state_denied() { local p r
  for p in implement skeleton; do
    r=$(phase $p)
    bx "$r" deny 'echo {} > d*/a*/.s*/approvals.jsonl'; bx "$r" deny 'echo {} > docs/a*/.s*/state.json'
    bx "$r" deny 'echo {} >> D?CS/*/.st?te/ledger.json'
    bx "$r" allow 'echo hi > "$LOG"'; bx "$r" allow 'echo hi > out.txt'; bx "$r" allow 'npm test 2>&1 | tee test.log'
    bx "$r" allow 'echo hi > build/*.log'
  done; }
