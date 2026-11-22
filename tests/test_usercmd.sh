#!/bin/bash
# Tests for ga user-command (core/lib/usercmd.sh).
uc() { local f; f=$(mktemp); printf '%s' "$2" >"$f"; ga --root "$1" user-command --text-file "$f"; }
dec() { jq -r .decision <<<"$1"; }
sj() { jq -r "$2" "$1/docs/architecture/.state/state.json"; }
lj() { jq -r "$2" "$1/docs/architecture/.state/ledger.json"; }
ready_inputs() { use_fake_claude; r=$(mk_project); ga --root "$r" init >/dev/null; seed_ledger "$r" "$FIX/ledger_inputs_ready.json"; ga --root "$r" verify >/dev/null; echo "$r"; }

test_line_must_start_with_GA() { r=$(ready_inputs); assert_eq allow "$(dec "$(uc "$r" '이건 GA 승인 입력 이라는 뜻이 아니다')")"; assert_eq inputs "$(sj "$r" .phase)"; }
test_no_command_allows_with_empty_context() { r=$(ready_inputs); out=$(uc "$r" '그냥 대화'); assert_eq allow "$(dec "$out")"; assert_eq "" "$(jq -r .context <<<"$out")"; }
test_no_state_with_command_allows() { r=$(mk_project); out=$(uc "$r" 'GA 승인 입력'); assert_eq allow "$(dec "$out")"; assert_eq "" "$(jq -r .context <<<"$out")"; }
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
nodec_ledger() { jq '.items|=map(select(.id!="ASM-1" and .id!="Q-1" and .id!="FACT-1" and .id!="MAP-1"))' "$FIX/ledger_valid.json"; }
test_internal_failure_restores_and_unlocks() { use_fake_claude; r=$(mk_project); ga --root "$r" init >/dev/null; seed_ledger "$r" "$FIX/ledger_inputs_open_asm.json"; set_state "$r" '.phase="implement"|.round="1"'
  sd=$r/docs/architecture/.state; cp "$sd/ledger.json" "$r/l0"; cp "$sd/state.json" "$r/s0"
  f=$(mktemp); printf 'GA 확인 ASM-1 맞음\nGA 새라운드' >"$f"; rc=0; ga --root "$r" user-command --text-file "$f" >/dev/null 2>&1 || rc=$?
  assert_eq 2 "$rc"; cmp -s "$sd/ledger.json" "$r/l0" || _fail "ledger not restored"; cmp -s "$sd/state.json" "$r/s0" || _fail "state not restored"
  assert_status 1 test -d "$sd/.lock"; }
test_corrupt_state_no_stuck_lock() { r=$(ready_inputs); sd=$r/docs/architecture/.state; echo '{broken' >"$sd/state.json"
  f=$(mktemp); printf 'GA 일시정지' >"$f"; ga --root "$r" user-command --text-file "$f" >/dev/null 2>&1 || true; assert_status 1 test -d "$sd/.lock"; }
test_zero_high_drivers_blocks_input() { use_fake_claude; r=$(mk_project); ga --root "$r" init >/dev/null; jq '.items|=map(select(.id=="DRV-1"))' "$FIX/ledger_inputs_ready.json" | seed_ledger "$r" -; ga --root "$r" verify >/dev/null
  out=$(uc "$r" 'GA 승인 입력'); assert_eq block "$(dec "$out")"; assert_contains "$out" "high"; assert_eq inputs "$(sj "$r" .phase)"; }
test_iteration_gap_blocks_input() { use_fake_claude; r=$(mk_project); ga --root "$r" init >/dev/null
  jq '.items += [(.items[]|select(.id=="DRV-3")) | .id="DRV-4" | .iteration=3 | .statement="다른 품질" | .source.quote="다른 요구"]' "$FIX/ledger_inputs_ready.json" | seed_ledger "$r" -; ga --root "$r" verify >/dev/null
  out=$(uc "$r" 'GA 승인 입력'); assert_eq block "$(dec "$out")"; assert_contains "$out" "2"; assert_eq inputs "$(sj "$r" .phase)"; }
test_iteration_without_decision_blocks() { use_fake_claude; r=$(mk_project); ga --root "$r" init >/dev/null
  nodec_ledger | seed_ledger "$r" -; set_state "$r" '.phase="iterating"|.iteration=2|.iteration_count=2'; ga --root "$r" verify >/dev/null
  out=$(uc "$r" 'GA 승인 반복'); assert_eq block "$(dec "$out")"; assert_contains "$out" "결정"; assert_eq iterating "$(sj "$r" .phase)"; }
test_earlier_round_open_asm_blocks_new_round() { use_fake_claude; r=$(mk_project); ga --root "$r" init >/dev/null; seed_ledger "$r" "$FIX/ledger_inputs_open_asm.json"; set_state "$r" '.phase="implement"'
  out=$(uc "$r" 'GA 새라운드'); assert_eq block "$(dec "$out")"; assert_contains "$out" "ASM-1"; assert_eq 1 "$(sj "$r" .round)"; }
test_earlier_round_open_asm_blocks_approval() { use_fake_claude; r=$(mk_project); ga --root "$r" init >/dev/null; seed_ledger "$r" "$FIX/ledger_inputs_open_asm.json"; set_state "$r" '.round=2'; ga --root "$r" verify >/dev/null
  out=$(uc "$r" 'GA 승인 입력'); assert_eq block "$(dec "$out")"; assert_contains "$out" "ASM-1"; }
test_trailing_text_blocks() { r=$(ready_inputs)
  out=$(uc "$r" 'GA 승인 입력 아직 아님 보류'); assert_eq block "$(dec "$out")"; assert_eq inputs "$(sj "$r" .phase)"
  assert_eq block "$(dec "$(uc "$r" 'GA 일시정지 지금')")"; assert_eq false "$(sj "$r" .paused)"
  set_state "$r" '.phase="implement"'; assert_eq block "$(dec "$(uc "$r" 'GA 새라운드 x')")"; assert_eq 1 "$(sj "$r" .round)"
  assert_eq block "$(dec "$(uc "$r" 'GA 재개 x')")"; set_state "$r" '.phase="skeleton"'; assert_eq block "$(dec "$(uc "$r" 'GA 되돌리기 x')")"; assert_eq skeleton "$(sj "$r" .phase)"; }
test_approvals_record_pre_transition_iteration() { r=$(ready_inputs); uc "$r" 'GA 승인 입력' >/dev/null
  assert_eq 0 "$(jq -r .iteration "$r/docs/architecture/.state/approvals.jsonl")"
  r=$(mk_project); ga --root "$r" init >/dev/null; nodec_ledger | seed_ledger "$r" -; set_state "$r" '.phase="iterating"|.iteration=1|.iteration_count=2'; ga --root "$r" verify >/dev/null
  uc "$r" 'GA 승인 반복' >/dev/null; assert_eq 1 "$(jq -r .iteration "$r/docs/architecture/.state/approvals.jsonl")"; }
test_messages_correct_under_utf8() { r=$(ready_inputs); out=$(LC_ALL=ko_KR.UTF-8 uc "$r" 'GA 승인 설계'); assert_contains "$out" "현재 단계는 inputs입니다"
  out=$(LC_ALL=ko_KR.UTF-8 uc "$r" 'GA 승인 입력'); assert_contains "$out" "inputs→iterating"; }
test_non_integer_iteration_fails_closed() { use_fake_claude; r=$(mk_project); ga --root "$r" init >/dev/null; nodec_ledger | seed_ledger "$r" -; set_state "$r" '.phase="iterating"|.iteration=1|.iteration_count=1'; ga --root "$r" verify >/dev/null
  set_state "$r" '.iteration_count="x"'; out=$(uc "$r" 'GA 승인 반복'); assert_eq block "$(dec "$out")"; assert_eq iterating "$(sj "$r" .phase)"; }
test_lock_is_reentrant() { r=$(mk_project); ga --root "$r" init >/dev/null
  ( . "$CORE/lib/common.sh"; ga_lock "$r"; ga_lock "$r"; ga_unlock "$r"; [ -d "$r/docs/architecture/.state/.lock" ] || exit 1; ga_unlock "$r"; [ ! -d "$r/docs/architecture/.state/.lock" ] ) || _fail "lock not reentrant"; }
# R21(b): GA 새라운드 is blocked while a deviation decision awaits the user's GA 확인.
test_open_deviation_blocks_new_round() { local r out
  r=$(mk_project); ga --root "$r" init >/dev/null; set_state "$r" '.phase="iterating"|.iteration=1|.iteration_count=1'
  jq '.deviation=true' "$FIX/dec.json" | ga --root "$r" add decision >/dev/null; set_state "$r" '.phase="implement"'
  out=$(uc "$r" 'GA 새라운드'); assert_eq block "$(dec "$out")"; assert_contains "$out" "DEC-1"; assert_eq 1 "$(sj "$r" .round)"
  assert_eq allow "$(dec "$(uc "$r" 'GA 확인 DEC-1')")"
  assert_eq allow "$(dec "$(uc "$r" 'GA 새라운드')")"; assert_eq 2 "$(sj "$r" .round)"; }

# --- final review fixes ---
# C1 (R24): inside a verifier runner (GA_IN_RUNNER=1) user-command records nothing.
test_c1_in_runner_user_command_records_nothing() { local r f out sd
  r=$(ready_inputs); sd=$r/docs/architecture/.state; f=$(mktemp); printf 'GA 승인 입력\nGA 일시정지' >"$f"
  out=$(GA_IN_RUNNER=1 ga --root "$r" user-command --text-file "$f" --transcript /nested/t.jsonl)
  assert_eq allow "$(dec "$out")"; assert_eq "" "$(jq -r .context <<<"$out")"
  assert_eq "inputs false null" "$(sj "$r" '"\(.phase) \(.paused) \(.transcript_path)"')"
  assert_eq 0 "$(wc -l <"$sd/approvals.jsonl" | tr -d ' ')"; assert_status 1 test -e "$sd/PAUSED"; }
# I5 (R30): with no design state, GA lines are ignored entirely.
test_i5_no_state_ga_line_allowed() { local r out
  r=$(mk_project); out=$(uc "$r" 'GA release is planned for May'); assert_eq allow "$(dec "$out")"; assert_eq "" "$(jq -r .context <<<"$out")"; }
# I6 (R31a): GA 일시정지 / GA 재개 manage a PAUSED marker file, also with an unreadable state.json.
test_i6_pause_resume_marker() { local r sd
  r=$(ready_inputs); sd=$r/docs/architecture/.state
  uc "$r" 'GA 일시정지' >/dev/null; assert_status 0 test -f "$sd/PAUSED"; assert_eq true "$(sj "$r" .paused)"
  uc "$r" 'GA 재개' >/dev/null; assert_status 1 test -e "$sd/PAUSED"; assert_eq false "$(sj "$r" .paused)"; }
test_i6_pause_with_corrupt_state() { local r sd out
  r=$(ready_inputs); sd=$r/docs/architecture/.state; echo '{broken' >"$sd/state.json"
  out=$(uc "$r" 'GA 일시정지'); assert_eq allow "$(dec "$out")"; assert_status 0 test -f "$sd/PAUSED"
  assert_eq '{broken' "$(cat "$sd/state.json")"
  assert_eq allow "$(dec "$(ga gate write --path "$r/src/a.c")")"
  assert_eq allow "$(cd "$r" && dec "$(ga gate bash --command 'rm -rf src')")"
  out=$(uc "$r" 'GA 재개'); assert_eq allow "$(dec "$out")"; assert_status 1 test -e "$sd/PAUSED"; assert_status 1 test -d "$sd/.lock"; }
test_i6_corrupt_state_other_commands_explain_recovery() { local r out
  r=$(ready_inputs); echo '{broken' >"$r/docs/architecture/.state/state.json"
  out=$(uc "$r" 'GA 승인 입력'); assert_eq block "$(dec "$out")"; assert_contains "$out" "GA 일시정지"; assert_contains "$out" "state.json"; }
# I9 (R34c): the approval context names the runner binaries that produced the report.
test_i9_approval_context_shows_runner_paths() { local r out
  r=$(ready_inputs); out=$(uc "$r" 'GA 승인 입력'); assert_eq allow "$(dec "$out")"
  assert_contains "$(jq -r .context <<<"$out")" "$REPO/tests/fakes/claude"; }
test_state_accept_verb_listed_and_recorded() { r=$(ready_inputs); . "$CORE/lib/usercmd.sh"; assert_contains " $GA_VERBS " " 상태승인 "
  out=$(uc "$r" "GA 상태승인"); assert_eq allow "$(dec "$out")"; assert_contains "$out" "상태 지문"; assert_eq 상태승인 "$(tail -n1 "$r/docs/architecture/.state/approvals.jsonl" | jq -r .point)"; }
test_state_accept_trailing_text_blocks() { r=$(ready_inputs); out=$(uc "$r" "GA 상태승인 확인"); assert_eq block "$(dec "$out")"; assert_contains "$out" "다른 글자"; }

# --- G-approval additions (spec 5.5): no file change outside the phase allow-list, state fingerprint matches ---
test_approval_blocked_by_effect_violation() { local r out
  r=$(ready_inputs); mkdir -p "$r/src"; echo 'int x;' >"$r/src/hack.c"
  out=$(uc "$r" 'GA 승인 입력'); assert_eq block "$(dec "$out")"; assert_contains "$out" src/hack.c; assert_eq inputs "$(sj "$r" .phase)"
  assert_contains "$out" "되돌린 뒤"; assert_contains "$out" "GA 상태승인"
  rm -f "$r/src/hack.c"; out=$(uc "$r" 'GA 승인 입력'); assert_eq allow "$(dec "$out")"; assert_eq iterating "$(sj "$r" .phase)"; }
# P12: the user accepts a file change with GA 상태승인 (also in the same message as the approval),
# or by pausing around it (GA 재개 takes a new file baseline).
test_approval_after_user_accepts_file_change() { local r out
  r=$(ready_inputs); mkdir -p "$r/src"; echo 'int x;' >"$r/src/user.c"
  out=$(uc "$r" "GA 상태승인
GA 승인 입력"); assert_eq allow "$(dec "$out")"; assert_eq iterating "$(sj "$r" .phase)"
  r=$(ready_inputs); uc "$r" 'GA 일시정지' >/dev/null; mkdir -p "$r/src"; echo 'int y;' >"$r/src/paused.c"; uc "$r" 'GA 재개' >/dev/null
  assert_eq allow "$(dec "$(uc "$r" 'GA 승인 입력')")"; assert_eq iterating "$(sj "$r" .phase)"
  # a refused message rolls the new baseline back too
  r=$(ready_inputs); mkdir -p "$r/src"; echo 'int z;' >"$r/src/z.c"
  assert_eq block "$(dec "$(uc "$r" "GA 상태승인
GA 아무거나")")"; assert_eq block "$(dec "$(uc "$r" 'GA 승인 입력')")"; }
test_approval_blocked_by_fp_mismatch() { local r out
  r=$(ready_inputs); tamper_state "$r" '.x = 1'
  out=$(uc "$r" 'GA 승인 입력'); assert_eq block "$(dec "$out")"; assert_contains "$out" "GA 상태승인"; assert_eq inputs "$(sj "$r" .phase)"
  # the user accepts the current state first (the same message works)
  out=$(uc "$r" "GA 상태승인
GA 승인 입력"); assert_eq allow "$(dec "$out")"; assert_eq iterating "$(sj "$r" .phase)"; }
test_approval_blocked_without_fp_record() { local r out
  r=$(ready_inputs); rm -rf "$HOME/.local/state/grounded-arch"
  out=$(uc "$r" 'GA 승인 입력'); assert_eq block "$(dec "$out")"; assert_contains "$out" "상태 지문"; assert_eq inputs "$(sj "$r" .phase)"
  assert_eq allow "$(dec "$(uc "$r" 'GA 상태승인')")"; assert_eq allow "$(dec "$(uc "$r" 'GA 승인 입력')")"; }
test_approval_takes_missing_snapshot() { local r out sd
  r=$(ready_inputs); sd=$r/docs/architecture/.state; rm -f "$sd/snapshot.json"; _fp_sync "$r"
  mkdir -p "$r/src"; echo x >"$r/src/old.c" # made before any baseline existed: not judged
  out=$(uc "$r" 'GA 승인 설계'); assert_eq block "$(dec "$out")"; assert_contains "$out" "파일 변경 기준"
  [ -f "$sd/snapshot.json" ] || _fail "snapshot not kept after a blocked approval"
  out=$(uc "$r" 'GA 승인 입력'); assert_eq allow "$(dec "$out")"; assert_not_contains "$out" "파일 변경 기준"; }
