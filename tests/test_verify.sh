vroot() { r=$(mk_project brownfield); ga --root "$r" init >/dev/null; seed_ledger "$r" "$FIX/ledger_valid.json"; set_state "$r" '.phase="iterating"|.iteration=1|.iteration_count=1'
  echo '{"members":[{"runner":"claude","model":"opus"},{"runner":"claude","model":"sonnet"}],"timeout_sec":5}' >"$r/docs/architecture/.state/panel.json"; echo "$r"; }
rep() { jq -r "$2" "$1/docs/architecture/.state/report.json"; }
test_verify_billing_refusal_no_report() { use_fake_claude; r=$(vroot); FAKE_AUTH_METHOD=api_key assert_status 4 ga --root "$r" verify; assert_status 1 test -f "$r/docs/architecture/.state/report.json"; }
test_verify_merges_same_target() { use_fake_claude; r=$(vroot); export FAKE_P_DIR=$FIX/runner_outputs/merge; ga --root "$r" verify >/dev/null
  assert_eq 1 "$(rep "$r" '.findings|length')"; assert_eq '["opus","sonnet"]' "$(rep "$r" '.findings[0].models|sort|tojson')"
  assert_eq FND-1 "$(rep "$r" '.findings[0].id')"; assert_eq 2 "$(rep "$r" '.findings[0].claims|length')"; assert_eq 2 "$(rep "$r" '.findings[0].evidence|length')"; }
test_verify_drops_no_evidence() { use_fake_claude; r=$(vroot); export FAKE_P_DIR=$FIX/runner_outputs/noevidence; ga --root "$r" verify >/dev/null; assert_eq 0 "$(rep "$r" '.findings|length')"; assert_eq 1 "$(rep "$r" '.panel[0].dropped')"; }
test_verify_drops_bad_file_ref() { use_fake_claude; r=$(vroot); export FAKE_P_DIR=$FIX/runner_outputs/badref; ga --root "$r" verify >/dev/null; assert_eq 0 "$(rep "$r" '.findings|length')"; }
test_verify_drops_mixed_good_url_bad_file() { use_fake_claude; r=$(vroot); export FAKE_P_DIR=$FIX/runner_outputs/mixedref; ga --root "$r" verify >/dev/null
  assert_eq 0 "$(rep "$r" '.findings|length')"; assert_eq 1 "$(rep "$r" '.panel[0].dropped')"; assert_eq 0 "$(rep "$r" '.panel[0].kept')"; }
test_verify_invalid_output_status() { use_fake_claude; r=$(vroot); export FAKE_P_DIR=$FIX/runner_outputs/garbage; assert_status 5 ga --root "$r" verify; assert_eq invalid_output "$(rep "$r" '.panel[0].status')"; }
test_verify_member_failed_status() { use_fake_claude; r=$(vroot); d=$(mktemp -d); echo 3 >"$d/opus.rc"; export FAKE_P_DIR=$d
  assert_status 5 ga --root "$r" verify; assert_eq failed "$(rep "$r" '.panel[0].status')"; assert_eq ok "$(rep "$r" '.panel[1].status')"; }
test_verify_timeout_status() { use_fake_claude; r=$(vroot); d=$(mktemp -d); echo 30 >"$d/opus.sleep"; export FAKE_P_DIR=$d
  echo '{"members":[{"runner":"claude","model":"opus"}],"timeout_sec":1}' >"$r/docs/architecture/.state/panel.json"
  assert_status 5 ga --root "$r" verify; assert_eq timeout "$(rep "$r" '.panel[0].status')"; }
test_verify_ok_exit_zero_and_summary() { use_fake_claude; r=$(vroot); out=$(ga --root "$r" verify); assert_contains "$out" "opus"; assert_contains "$out" "ok"
  assert_eq true "$(ga --root "$r" status --json | jq .panel_ok)"; assert_eq 0 "$(ga --root "$r" status --json | jq .findings_unprocessed)"; assert_eq null "$(ga --root "$r" status --json | jq .build_ok)"; }
test_hash_ignores_resolution() { use_fake_claude; r=$(vroot); ga --root "$r" verify >/dev/null
  ( . "$CORE/lib/common.sh"; for f in "$CORE"/lib/*.sh; do . "$f"; done; ga_ledger_resolve_by_user "$r" ASM-1 "GA 확인 ASM-1" )
  assert_eq true "$(ga --root "$r" status --json | jq .report_fresh)"; }
test_hash_changes_on_content() { use_fake_claude; r=$(vroot); ga --root "$r" verify >/dev/null; echo '{"statement":"바뀜"}' | ga --root "$r" update ASM-1
  assert_eq false "$(ga --root "$r" status --json | jq .report_fresh)"; }
test_hash_ignores_ga_blocks() { use_fake_claude; r=$(vroot); f=$r/docs/architecture/architecture.md
  printf '\n<!-- ga:begin zzz -->\n원래 내용\n<!-- ga:end zzz -->\n' >>"$f"; ga --root "$r" verify >/dev/null
  sed -i.bak 's/원래 내용/바뀐 내용/' "$f"
  assert_eq true "$(ga --root "$r" status --json | jq .report_fresh)"; echo "새 본문" >>"$f"; assert_eq false "$(ga --root "$r" status --json | jq .report_fresh)"; }
test_dispute_sets_disposition() { use_fake_claude; r=$(vroot); export FAKE_P_DIR=$FIX/runner_outputs/merge; ga --root "$r" verify >/dev/null
  ga --root "$r" dispute FND-1 --evidence "src/main.c:1에 이미 있음"; assert_eq disputed "$(rep "$r" '.findings[0].disposition.type')"
  assert_eq null "$(rep "$r" '.findings[0].disposition.verdict')"; assert_eq 1 "$(ga --root "$r" status --json | jq .findings_unprocessed)"; }
test_dispute_unknown_finding_exit3() { use_fake_claude; r=$(vroot); export FAKE_P_DIR=$FIX/runner_outputs/merge; ga --root "$r" verify >/dev/null
  assert_status 3 ga --root "$r" dispute FND-9 --evidence "x"; assert_status 3 ga --root "$r" dispute FND-1 --evidence ""; }
test_finding_helpers_processed_rules() { use_fake_claude; r=$(vroot); export FAKE_P_DIR=$FIX/runner_outputs/merge; ga --root "$r" verify >/dev/null
  h() { ( . "$CORE/lib/common.sh"; for f in "$CORE"/lib/*.sh; do . "$f"; done; "$@" ); }
  assert_status 3 h ga_finding_verdict "$r" FND-1 accept "GA 인정"
  ga --root "$r" dispute FND-1 --evidence "있음"
  h ga_finding_verdict "$r" FND-1 reject "GA 기각 아님"; assert_eq 1 "$(ga --root "$r" status --json | jq .findings_unprocessed)"
  h ga_finding_verdict "$r" FND-1 accept "GA 인정"; assert_eq 0 "$(ga --root "$r" status --json | jq .findings_unprocessed)"
  assert_eq accept "$(rep "$r" '.findings[0].disposition.verdict')"
  h ga_finding_user_reject "$r" FND-1 "GA 무시"; assert_eq user_rejected "$(rep "$r" '.findings[0].disposition.type')"
  assert_status 3 h ga_finding_user_reject "$r" FND-9 "q"; }
test_verify_brownfield_skeleton_build_check() { use_fake_claude; r=$(vroot); set_state "$r" '.phase="skeleton"'; echo 'exit 3' >"$r/docs/architecture/.state/test_command"
  ga --root "$r" verify >/dev/null; assert_eq 3 "$(rep "$r" '.build_check.exit')"; assert_eq false "$(ga --root "$r" status --json | jq .build_ok)"; }
test_verify_no_build_check_without_command() { use_fake_claude; r=$(vroot); set_state "$r" '.phase="skeleton"'; ga --root "$r" verify >/dev/null; assert_eq null "$(rep "$r" '.build_check')"; }
test_verify_no_build_check_outside_skeleton() { use_fake_claude; r=$(vroot); echo 'exit 3' >"$r/docs/architecture/.state/test_command"; ga --root "$r" verify >/dev/null; assert_eq null "$(rep "$r" '.build_check')"; }
test_verify_default_panel_has_three() { assert_eq '["opus","sonnet","fable"]' "$(jq -c '[.members[].model]' "$CORE/verifier/panel.json")"; }
