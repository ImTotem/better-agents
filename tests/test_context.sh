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
