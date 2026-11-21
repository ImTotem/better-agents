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
test_bash_corrupt_state_denies() { r=$(phase inputs); echo '{bad' >"$r/docs/architecture/.state/state.json"; out=$(cd "$r" && ga gate bash --command 'ls'); assert_eq deny "$(dec "$out")"; assert_contains "$out" "state.json"; }
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
test_stop_corrupt_state_blocks() { r=$(phase inputs); echo '{bad' >"$r/docs/architecture/.state/state.json"; out=$(cd "$r" && ga gate stop); assert_eq block "$(dec "$out")"; assert_contains "$out" "state.json"; }
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
