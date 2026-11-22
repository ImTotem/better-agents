#!/bin/bash
# Tests for the state fingerprint (core/lib/fingerprint.sh) and GA 상태승인.
load_ga() { GA_CORE=$CORE; . "$CORE"/lib/common.sh; . "$CORE"/lib/state.sh; . "$CORE"/lib/check.sh; . "$CORE"/lib/ledger.sh; . "$CORE"/lib/effect.sh; . "$CORE"/lib/fingerprint.sh; }
uc() { local f; f=$(mktemp); printf '%s' "$2" >"$f"; ga --root "$1" user-command --text-file "$f"; }
dec() { jq -r .decision <<<"$1"; }
proj() { local r; r=$(mk_project); ga --root "$r" init >/dev/null; echo "$r"; }
fpfile() { ( load_ga; ga_fp_path "$1" ); }
fpcheck() { local rc=0; ( load_ga; ga_fp_check "$1" ) >/dev/null 2>&1 || rc=$?; echo $rc; }

test_fp_recorded_after_ga_write() { r=$(proj); p=$(fpfile "$r"); [ -f "$p" ] || _fail "no fingerprint file $p after init"
  ga --root "$r" add assumption <"$FIX/asm.json" >/dev/null; assert_eq 0 "$(fpcheck "$r")"
  assert_eq "$(cd -P "$r" && pwd -P)" "$(jq -r .root "$p")"; }
# P17: only ga init and GA 상태승인 create or replace the record; no other write re-creates it.
test_p17_missing_or_unreadable_record_not_recreated_by_writes() { r=$(proj); p=$(fpfile "$r"); rm -f "$p"; assert_eq 2 "$(fpcheck "$r")"
  ga --root "$r" add assumption <"$FIX/asm.json" >/dev/null; assert_eq 2 "$(fpcheck "$r")"
  uc "$r" 'GA 일시정지' >/dev/null; assert_eq 2 "$(fpcheck "$r")"
  echo '{}' >"$p"; uc "$r" 'GA 재개' >/dev/null; assert_eq 2 "$(fpcheck "$r")"
  ( f=$(mktemp); printf '계속' >"$f"; ga --root "$r" user-command --text-file "$f" --transcript /tmp/t.jsonl >/dev/null ); assert_eq 2 "$(fpcheck "$r")"
  uc "$r" 'GA 상태승인' >/dev/null; assert_eq 0 "$(fpcheck "$r")"; }
test_fp_none_before_any_write_rc2() { r=$(mk_project); mkdir -p "$r/docs/architecture/.state"; echo '{}' >"$r/docs/architecture/.state/state.json"; assert_eq 2 "$(fpcheck "$r")"; }
test_fp_mismatch_after_direct_edit() { r=$(proj); assert_eq 0 "$(fpcheck "$r")"
  tamper_state "$r" '.phase="skeleton"'; assert_eq 1 "$(fpcheck "$r")"; }
test_fp_ledger_direct_edit_detected() { r=$(proj); sd=$r/docs/architecture/.state
  echo '{"items":[],"x":1}' >"$sd/ledger.json"; assert_eq 1 "$(fpcheck "$r")"
  uc "$r" 'GA 상태승인' >/dev/null; assert_eq 0 "$(fpcheck "$r")"
  echo '{"ts":"t"}' >>"$sd/approvals.jsonl"; assert_eq 1 "$(fpcheck "$r")"; }
test_fp_user_accept_rebaselines() { r=$(proj); tamper_state "$r" '.phase="skeleton"'; assert_eq 1 "$(fpcheck "$r")"
  out=$(uc "$r" 'GA 상태승인'); assert_eq allow "$(dec "$out")"; assert_eq 0 "$(fpcheck "$r")"
  assert_eq 상태승인 "$(tail -n1 "$r/docs/architecture/.state/approvals.jsonl" | jq -r .point)"; }
test_fp_accept_trailing_text_blocked() { r=$(proj); tamper_state "$r" '.phase="skeleton"'
  out=$(uc "$r" 'GA 상태승인 지금'); assert_eq block "$(dec "$out")"; assert_eq 1 "$(fpcheck "$r")"; }
test_fp_accept_with_unreadable_state_blocked() { r=$(proj); echo 'not json' >"$r/docs/architecture/.state/state.json"
  assert_eq block "$(dec "$(uc "$r" 'GA 상태승인')")"; }
test_fp_store_outside_project() { r=$(proj); p=$(fpfile "$r"); case "$p" in "$r"/*) _fail "inside project: $p" ;; esac
  case "$p" in "$HOME"/.local/state/grounded-arch/*.json) ;; *) _fail "unexpected path $p" ;; esac
  p2=$( export GA_DATA_DIR=$r/../dd; fpfile "$r" ); assert_contains "$p2" "/dd/"; }
test_fp_read_commands_do_not_touch_data_dir() { r=$(proj); rm -rf "$HOME/.local/state/grounded-arch"
  ga --root "$r" status >/dev/null; ga --root "$r" check >/dev/null 2>&1 || true
  [ ! -e "$HOME/.local/state/grounded-arch" ] || _fail "read command created data dir"; }
test_fp_excludes_lock_and_temp_files() { r=$(proj); sd=$r/docs/architecture/.state
  mkdir -p "$sd/.lock"; echo x >"$sd/state.json.tmp.123"; assert_eq 0 "$(fpcheck "$r")"; }
test_fp_new_file_in_state_detected() { r=$(proj); echo x >"$r/docs/architecture/.state/extra"; assert_eq 1 "$(fpcheck "$r")"; }
test_fp_usercmd_failure_keeps_fingerprint_consistent() { r=$(proj); assert_eq 0 "$(fpcheck "$r")"
  out=$(uc "$r" "GA 일시정지
GA 아무거나"); assert_eq block "$(dec "$out")"; assert_eq 0 "$(fpcheck "$r")"
  # a rolled-back 상태승인 must not re-baseline a tampered state
  tamper_state "$r" '.round=9'; assert_eq 1 "$(fpcheck "$r")"
  out=$(uc "$r" "GA 상태승인
GA 아무거나"); assert_eq block "$(dec "$out")"; assert_eq 1 "$(fpcheck "$r")"; }
test_fp_usercmd_success_records() { r=$(proj); uc "$r" 'GA 일시정지' >/dev/null; assert_eq 0 "$(fpcheck "$r")"; }
test_fp_usercmd_does_not_rebaseline_tampering() { r=$(proj); tamper_state "$r" '.round=9'; uc "$r" 'GA 일시정지' >/dev/null
  assert_eq 1 "$(fpcheck "$r")"; }
test_fp_missing_sha_tools_fail_closed() { r=$(proj); rc=0; err=$( ( load_ga; PATH=/nonexistent; ga_fp_check "$r" ) 2>&1 ) || rc=$?
  rc2=0; err2=$( ( load_ga; PATH=/nonexistent; ga_fp_record "$r" ) 2>&1 ) || rc2=$?
  [ "$rc" = 3 ] || _fail "check rc=$rc"; [ "$rc2" = 3 ] || _fail "record rc=$rc2"; assert_contains "$err" "sha256sum"; assert_contains "$err2" "shasum"; }
test_fp_reinit_records_fresh_fingerprint() { r=$(proj); ga --root "$r" add assumption <"$FIX/asm.json" >/dev/null; assert_eq 0 "$(fpcheck "$r")"
  rm -rf "$r/docs/architecture/.state"; ga --root "$r" init >/dev/null; assert_eq 0 "$(fpcheck "$r")"; }
test_fp_unwritable_data_dir_warns() { r=$(proj); f=$(mktemp); rc=0; err=$( ( export GA_DATA_DIR=$f/sub; load_ga; ga_fp_record "$r" ) 2>&1 ) || rc=$?
  [ "$rc" = 1 ] || _fail "rc=$rc"; assert_contains "$err" "경고"; assert_contains "$err" "GA_DATA_DIR"; }
# P3: while the fingerprint mismatches, every state-writing command refuses; reads and GA lines still work.
test_fp_mismatch_refuses_state_writes() { local r sd c out rc l0
  r=$(proj); sd=$r/docs/architecture/.state; ga --root "$r" add assumption <"$FIX/asm.json" >/dev/null
  tamper_state "$r" '.x = 1'; l0=$(cat "$sd/ledger.json")
  for c in 'add assumption' 'update ASM-1' 'ask Q-1' 'resolve ASM-1 --source-type code --ref a.c:1' render verify enforce 'dispute FND-1 --evidence x'; do
    rc=0; out=$(echo '{"statement":"x"}' | GA_HARNESS=claude-code ga --root "$r" $c 2>&1) || rc=$?
    [ "$rc" = 3 ] || _fail "ga $c: rc=$rc"; assert_contains "$out" "GA 상태승인"
  done
  assert_eq "$l0" "$(cat "$sd/ledger.json")"; [ ! -e "$r/.claude/settings.local.json" ] || _fail "enforce ran"
  ga --root "$r" status >/dev/null; ga --root "$r" check >/dev/null
  assert_eq allow "$(dec "$(uc "$r" 'GA 일시정지')")"; assert_eq 1 "$(fpcheck "$r")"
  uc "$r" 'GA 상태승인' >/dev/null; ga --root "$r" add assumption <"$FIX/asm.json" >/dev/null; assert_eq 0 "$(fpcheck "$r")"; }
