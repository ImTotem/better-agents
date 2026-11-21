#!/bin/bash
# Tests for ga user-command (core/lib/usercmd.sh).
uc() { local f; f=$(mktemp); printf '%s' "$2" >"$f"; ga --root "$1" user-command --text-file "$f"; }
dec() { jq -r .decision <<<"$1"; }
sj() { jq -r "$2" "$1/docs/architecture/.state/state.json"; }
lj() { jq -r "$2" "$1/docs/architecture/.state/ledger.json"; }
ready_inputs() { use_fake_claude; r=$(mk_project); ga --root "$r" init >/dev/null; seed_ledger "$r" "$FIX/ledger_inputs_ready.json"; ga --root "$r" verify >/dev/null; echo "$r"; }

test_line_must_start_with_GA() { r=$(ready_inputs); assert_eq allow "$(dec "$(uc "$r" '이건 GA 승인 입력 이라는 뜻이 아니다')")"; assert_eq inputs "$(sj "$r" .phase)"; }
test_no_command_allows_with_empty_context() { r=$(ready_inputs); out=$(uc "$r" '그냥 대화'); assert_eq allow "$(dec "$out")"; assert_eq "" "$(jq -r .context <<<"$out")"; }
test_no_state_with_command_blocks() { r=$(mk_project); out=$(uc "$r" 'GA 승인 입력'); assert_eq block "$(dec "$out")"; assert_contains "$out" "설계가 시작되지 않았습니다"; }
test_no_state_no_command_allows() { r=$(mk_project); assert_eq allow "$(dec "$(uc "$r" '안녕')")"; }
test_unknown_verb_blocks() { r=$(ready_inputs); out=$(uc "$r" 'GA 아무거나'); assert_eq block "$(dec "$out")"; assert_contains "$out" "승인"; assert_contains "$out" "새라운드"; }
test_approve_inputs_success() { r=$(ready_inputs); out=$(uc "$r" 'GA 승인 입력'); assert_eq allow "$(dec "$out")"; assert_eq iterating "$(sj "$r" .phase)"
  assert_eq 1 "$(sj "$r" .iteration)"; assert_eq 1 "$(sj "$r" .iteration_count)"; assert_contains "$out" "inputs→iterating"
  assert_eq 1 "$(wc -l <"$r/docs/architecture/.state/approvals.jsonl" | tr -d ' ')"
  assert_eq 입력 "$(jq -r .point "$r/docs/architecture/.state/approvals.jsonl")"; assert_eq "GA 승인 입력" "$(jq -r .quote "$r/docs/architecture/.state/approvals.jsonl")"; }
test_approve_blocked_by_open_assumption() { use_fake_claude; r=$(mk_project); ga --root "$r" init >/dev/null; seed_ledger "$r" "$FIX/ledger_inputs_open_asm.json"; ga --root "$r" verify >/dev/null
  out=$(uc "$r" 'GA 승인 입력'); assert_eq block "$(dec "$out")"; assert_contains "$out" "ASM-1"; }
test_confirm_then_approve() { use_fake_claude; r=$(mk_project); ga --root "$r" init >/dev/null; seed_ledger "$r" "$FIX/ledger_inputs_open_asm.json"; ga --root "$r" verify >/dev/null
  assert_eq allow "$(dec "$(uc "$r" 'GA 확인 ASM-1 맞음')")"; assert_eq user "$(lj "$r" '.items[]|select(.id=="ASM-1").resolution.by')"
  assert_eq "GA 확인 ASM-1 맞음" "$(lj "$r" '.items[]|select(.id=="ASM-1").resolution.quote')"
  assert_eq allow "$(dec "$(uc "$r" 'GA 승인 입력')")"; }
test_confirm_and_approve_same_prompt() { use_fake_claude; r=$(mk_project); ga --root "$r" init >/dev/null; seed_ledger "$r" "$FIX/ledger_inputs_open_asm.json"; ga --root "$r" verify >/dev/null
  assert_eq allow "$(dec "$(uc "$r" "GA 확인 ASM-1 맞음
GA 승인 입력")")"; assert_eq iterating "$(sj "$r" .phase)"; }
test_approve_blocked_stale_report() { r=$(ready_inputs); echo '{"statement":"변경"}' | ga --root "$r" update DRV-1; assert_eq block "$(dec "$(uc "$r" 'GA 승인 입력')")"; }
test_approve_blocked_unprocessed_finding() { use_fake_claude; r=$(mk_project brownfield); ga --root "$r" init >/dev/null; seed_ledger "$r" "$FIX/ledger_inputs_ready.json"; FAKE_P_DIR=$FIX/runner_outputs/merge ga --root "$r" verify >/dev/null
  out=$(uc "$r" 'GA 승인 입력'); assert_eq block "$(dec "$out")"; assert_contains "$out" "FND-1"; uc "$r" 'GA 기각 FND-1 해당 없음' >/dev/null; assert_eq allow "$(dec "$(uc "$r" 'GA 승인 입력')")"; }
test_approve_wrong_phase_blocks() { r=$(ready_inputs); assert_eq block "$(dec "$(uc "$r" 'GA 승인 설계')")"; }
test_atomic_multi_line() { use_fake_claude; r=$(mk_project); ga --root "$r" init >/dev/null; seed_ledger "$r" "$FIX/ledger_inputs_open_asm.json"
  assert_eq block "$(dec "$(uc "$r" "GA 확인 ASM-1 맞음
GA 아무거나")")"; assert_eq open "$(lj "$r" '.items[]|select(.id=="ASM-1").status')"; }
test_atomic_restores_after_applied_line() { r=$(ready_inputs); sd=$r/docs/architecture/.state
  cp "$sd/ledger.json" "$r/l0"; cp "$sd/state.json" "$r/s0"; cp "$sd/approvals.jsonl" "$r/a0"
  out=$(uc "$r" "GA 일시정지
GA 승인 입력
GA 승인 설계"); assert_eq block "$(dec "$out")"
  cmp -s "$sd/ledger.json" "$r/l0" || _fail "ledger changed"; cmp -s "$sd/state.json" "$r/s0" || _fail "state changed"; cmp -s "$sd/approvals.jsonl" "$r/a0" || _fail "approvals changed"
  assert_eq false "$(sj "$r" .paused)"; assert_eq inputs "$(sj "$r" .phase)"; }
test_atomic_restore_removes_new_files() { r=$(ready_inputs); sd=$r/docs/architecture/.state
  out=$(uc "$r" "GA 테스트명령 make test
GA 아무거나"); assert_eq block "$(dec "$out")"; assert_status 1 test -f "$sd/test_command"; }
test_pause_resume() { r=$(ready_inputs); uc "$r" 'GA 일시정지' >/dev/null; assert_eq true "$(sj "$r" .paused)"; uc "$r" 'GA 재개' >/dev/null; assert_eq false "$(sj "$r" .paused)"; }
test_back_from_skeleton() { r=$(ready_inputs); set_state "$r" '.phase="skeleton"|.iteration=2|.iteration_count=2'; uc "$r" 'GA 되돌리기' >/dev/null; assert_eq '"iterating" 3' "$(jq -c '.phase' "$r/docs/architecture/.state/state.json") $(sj "$r" .iteration)"; assert_eq 3 "$(sj "$r" .iteration_count)"; }
test_back_wrong_phase_blocks() { r=$(ready_inputs); assert_eq block "$(dec "$(uc "$r" 'GA 되돌리기')")"; }
test_new_round() { r=$(ready_inputs); set_state "$r" '.phase="implement"|.iteration=2|.iteration_count=2'; uc "$r" 'GA 새라운드' >/dev/null; assert_eq 2 "$(sj "$r" .round)"; assert_eq inputs "$(sj "$r" .phase)"; assert_eq 0 "$(sj "$r" .iteration)"; assert_eq 0 "$(sj "$r" .iteration_count)"; }
test_iteration_coverage_blocks() { use_fake_claude; r=$(mk_project); ga --root "$r" init >/dev/null; seed_ledger "$r" "$FIX/ledger_iter_uncovered.json"; set_state "$r" '.phase="iterating"|.iteration=1|.iteration_count=1'; ga --root "$r" verify >/dev/null
  out=$(uc "$r" 'GA 승인 반복'); assert_eq block "$(dec "$out")"; assert_contains "$out" "DRV-4"; assert_not_contains "$out" "DRV-3,"; }
test_iteration_last_goes_to_design_review() { use_fake_claude; r=$(mk_project); ga --root "$r" init >/dev/null; seed_ledger "$r" "$FIX/ledger_valid.json"; set_state "$r" '.phase="iterating"|.iteration=1|.iteration_count=1'
  jq '.items|=map(select(.id!="ASM-1" and .id!="Q-1" and .id!="FACT-1" and .id!="MAP-1"))' "$FIX/ledger_valid.json" | seed_ledger "$r" -; ga --root "$r" verify >/dev/null
  assert_eq allow "$(dec "$(uc "$r" 'GA 승인 반복')")"; assert_eq design-review "$(sj "$r" .phase)"; }
test_iteration_next_when_more_remain() { use_fake_claude; r=$(mk_project); ga --root "$r" init >/dev/null
  jq '.items|=map(select(.id!="ASM-1" and .id!="Q-1" and .id!="FACT-1" and .id!="MAP-1"))' "$FIX/ledger_valid.json" | seed_ledger "$r" -; set_state "$r" '.phase="iterating"|.iteration=1|.iteration_count=2'; ga --root "$r" verify >/dev/null
  assert_eq allow "$(dec "$(uc "$r" 'GA 승인 반복')")"; assert_eq iterating "$(sj "$r" .phase)"; assert_eq 2 "$(sj "$r" .iteration)"; }
test_brownfield_skeleton_needs_build_ok() { use_fake_claude; r=$(mk_project brownfield); ga --root "$r" init >/dev/null; seed_ledger "$r" "$FIX/ledger_valid.json"; set_state "$r" '.phase="skeleton"'; ga --root "$r" verify >/dev/null
  out=$(uc "$r" 'GA 승인 뼈대'); assert_eq block "$(dec "$out")"; assert_contains "$out" "GA 테스트명령"; }
test_records_transcript_path() { r=$(ready_inputs); f=$(mktemp); echo hi >"$f"; ga --root "$r" user-command --text-file "$f" --transcript /x/t.jsonl >/dev/null; assert_eq /x/t.jsonl "$(sj "$r" .transcript_path)"; }
test_approve_blocked_report_from_other_phase() { r=$(ready_inputs)
  set_state "$r" '.phase="iterating"|.iteration=1|.iteration_count=1'; out=$(uc "$r" 'GA 승인 반복'); assert_eq block "$(dec "$out")"; assert_contains "$out" "다른 단계"; assert_eq iterating "$(sj "$r" .phase)"; assert_eq 1 "$(sj "$r" .iteration)"; }
test_answer_stores_answer() { use_fake_claude; r=$(mk_project); ga --root "$r" init >/dev/null; seed_ledger "$r" "$FIX/ledger_valid.json"
  assert_eq allow "$(dec "$(uc "$r" 'GA 답 Q-1 클라우드(AWS)에 배포한다')")"; assert_eq "클라우드(AWS)에 배포한다" "$(lj "$r" '.items[]|select(.id=="Q-1").answer')"; assert_eq user "$(lj "$r" '.items[]|select(.id=="Q-1").resolution.by')"; }
test_answer_empty_blocks() { use_fake_claude; r=$(mk_project); ga --root "$r" init >/dev/null; seed_ledger "$r" "$FIX/ledger_valid.json"
  assert_eq block "$(dec "$(uc "$r" 'GA 답 Q-1')")"; assert_eq open "$(lj "$r" '.items[]|select(.id=="Q-1").status')"; }
test_verdict_on_non_disputed_blocks() { use_fake_claude; r=$(mk_project brownfield); ga --root "$r" init >/dev/null; seed_ledger "$r" "$FIX/ledger_inputs_ready.json"; FAKE_P_DIR=$FIX/runner_outputs/merge ga --root "$r" verify >/dev/null
  assert_eq block "$(dec "$(uc "$r" 'GA 판정 FND-1 반박인정')")"; }
test_verdict_on_disputed_accepts() { use_fake_claude; r=$(mk_project brownfield); ga --root "$r" init >/dev/null; seed_ledger "$r" "$FIX/ledger_inputs_ready.json"; FAKE_P_DIR=$FIX/runner_outputs/merge ga --root "$r" verify >/dev/null
  ga --root "$r" dispute FND-1 --evidence "src/main.c:1에 이미 있음" >/dev/null; assert_eq allow "$(dec "$(uc "$r" 'GA 판정 FND-1 반박인정')")"
  assert_eq accept "$(jq -r '.findings[0].disposition.verdict' "$r/docs/architecture/.state/report.json")"; assert_eq 0 "$(ga --root "$r" status --json | jq .findings_unprocessed)"; }
test_confirm_non_deviation_decision_blocks() { use_fake_claude; r=$(mk_project); ga --root "$r" init >/dev/null; seed_ledger "$r" "$FIX/ledger_valid.json"
  assert_eq block "$(dec "$(uc "$r" 'GA 확인 DEC-1')")"; }
test_confirm_question_blocks() { use_fake_claude; r=$(mk_project); ga --root "$r" init >/dev/null; seed_ledger "$r" "$FIX/ledger_valid.json"
  assert_eq block "$(dec "$(uc "$r" 'GA 확인 Q-1')")"; assert_eq open "$(lj "$r" '.items[]|select(.id=="Q-1").status')"; }
test_test_command_written() { r=$(ready_inputs); assert_eq allow "$(dec "$(uc "$r" 'GA 테스트명령 make test')")"; assert_eq "make test" "$(cat "$r/docs/architecture/.state/test_command")"; }
test_test_command_empty_blocks() { r=$(ready_inputs); assert_eq block "$(dec "$(uc "$r" 'GA 테스트명령')")"; assert_status 1 test -f "$r/docs/architecture/.state/test_command"; }
test_sourcing_has_no_side_effects() { ( . "$CORE/lib/common.sh"; . "$CORE/lib/usercmd.sh"; [ -n "$GA_VERBS" ] ) || _fail "GA_VERBS missing"; }
test_lock_is_reentrant() { r=$(mk_project); ga --root "$r" init >/dev/null
  ( . "$CORE/lib/common.sh"; ga_lock "$r"; ga_lock "$r"; ga_unlock "$r"; [ -d "$r/docs/architecture/.state/.lock" ] || exit 1; ga_unlock "$r"; [ ! -d "$r/docs/architecture/.state/.lock" ] ) || _fail "lock not reentrant"; }
