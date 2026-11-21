#!/bin/bash
test_inject_length_under_800() {
  local l n
  for l in ko_KR.UTF-8 en_US.UTF-8; do
    if locale -a 2>/dev/null | grep -qix "$l"; then export LC_ALL=$l; break; fi
  done
  n=$(ga rule | wc -m | tr -d " ")
  [ "$n" -le 800 ] || { echo "len=$n"; return 1; }
}
test_inject_mentions_grades() { t=$(ga rule); for w in "확정" "근거 있는 가정" "근거 없는 가정" "질문"; do assert_contains "$t" "$w"; done; }
test_inject_mentions_evidence_kinds() {
  t=$(ga rule)
  for w in "사용자가 말한" "확인한 사실" "문헌" "측정" "응답에서 판단마다 근거"; do assert_contains "$t" "$w"; done
}
test_rule_works_without_root() { d=$(mktemp -d); assert_contains "$(cd "$d" && ga rule)" "확정"; }
test_session_context_with_state() { r=$(mk_project); ga --root "$r" init >/dev/null; assert_contains "$(cd "$r" && ga context session-start)" "설계 진행 중: 단계 inputs"; }
test_session_context_billing_warning() { r=$(mk_project); assert_contains "$(cd "$r" && ANTHROPIC_API_KEY=x ga context session-start)" "ANTHROPIC_API_KEY"; }
test_session_context_empty_when_clean() {
  local r h out rc=0
  r=$(mk_project); h=$(mktemp -d)
  out=$(cd "$r" && unset ANTHROPIC_API_KEY && HOME=$h ga context session-start) || rc=$?
  assert_eq 0 "$rc"; assert_eq "" "$out"
  r=$(mk_project); ga --root "$r" init >/dev/null
  out=$(cd "$r" && unset ANTHROPIC_API_KEY && HOME=$h ga context session-start | grep -c "경고") || true
  assert_eq 0 "$out"
}
test_session_context_status_fields() {
  r=$(mk_project); ga --root "$r" init >/dev/null
  assert_contains "$(cd "$r" && ga context session-start)" "반복 0/0, 미해결 0개, 검증 보고 없음"
}
test_session_context_paused() {
  r=$(mk_project); ga --root "$r" init >/dev/null; set_state "$r" '.paused=true'
  assert_contains "$(cd "$r" && ga context session-start)" "(일시정지됨)"
}
test_session_context_lists_open_ids() {
  r=$(mk_project); ga --root "$r" init >/dev/null
  seed_ledger "$r" - <<'J'
{"items":[{"id":"Q-1","kind":"question","round":1,"phase_added":"inputs","iteration":null,"status":"open","resolution":null},
{"id":"ASM-2","kind":"assumption","round":1,"phase_added":"inputs","iteration":null,"status":"open","resolution":null}]}
J
  t=$(cd "$r" && ga context session-start)
  assert_contains "$t" "미해결 2개"
  assert_contains "$t" "미해결 항목: Q-1, ASM-2"
}
test_session_context_billing_warning_settings_env() {
  r=$(mk_project); mkdir -p "$HOME/.claude"
  echo '{"env":{"ANTHROPIC_API_KEY":"x"}}' >"$HOME/.claude/settings.json"
  t=$(cd "$r" && unset ANTHROPIC_API_KEY && ga context session-start)
  assert_contains "$t" "경고: 이 세션은 API 과금 경로(ANTHROPIC_API_KEY)"
  assert_contains "$t" "구독 로그인만 사용하세요."
}

# --- final review fixes ---
# C1 (R24): a verifier runner's own SessionStart gets nothing.
test_c1_in_runner_session_start_silent() { local r; r=$(mk_project); ga --root "$r" init >/dev/null
  assert_eq "" "$(cd "$r" && GA_IN_RUNNER=1 ANTHROPIC_API_KEY=x ga context session-start)"; }
# I6 (R31a): the PAUSED marker shows as paused, also when state.json is unreadable.
test_i6_context_shows_paused_marker() { local r; r=$(mk_project); ga --root "$r" init >/dev/null; : >"$r/docs/architecture/.state/PAUSED"
  assert_contains "$(cd "$r" && ga context session-start)" "(일시정지됨)"
  echo '{bad' >"$r/docs/architecture/.state/state.json"; assert_contains "$(cd "$r" && ga context session-start)" "일시정지"; }
# I8 (R33b): every distinct runner of the effective panel is scanned through its own preflight script.
test_i8_context_warns_per_panel_runner() { local r d t; r=$(mk_project); ga --root "$r" init >/dev/null; d=$(mktemp -d)
  cp "$CORE/verifier/runners/claude.json" "$d/claude.json"
  jq '.name="other" | .command="other-cli" | .preflight_script="other.preflight.sh"' "$CORE/verifier/runners/claude.json" >"$d/other.json"
  printf '#!/bin/bash\nif [ "$1" = --scan ]; then echo OTHER_BILLING_KEY; fi\nexit 0\n' >"$d/other.preflight.sh"
  echo '{"members":[{"runner":"claude","model":"opus"},{"runner":"other","model":"m"}],"timeout_sec":5}' >"$r/docs/architecture/.state/panel.json"
  t=$(cd "$r" && unset ANTHROPIC_API_KEY && GA_RUNNERS_DIR=$d ga context session-start)
  assert_contains "$t" "OTHER_BILLING_KEY"; assert_contains "$t" "other"; }
# R35-3: open/asked items of earlier rounds (assumptions, questions) are listed.
test_r35_context_lists_earlier_round_open_assumption() { local r; r=$(mk_project); ga --root "$r" init >/dev/null
  seed_ledger "$r" "$FIX/ledger_inputs_open_asm.json"; set_state "$r" '.round=2'
  assert_contains "$(cd "$r" && ga context session-start)" "미해결 항목: ASM-1"; }
