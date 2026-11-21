# Rule and session-context output. Sourced by core/bin/ga; bash 3.2 + jq.

cmd_rule() {
  cat "$GA_CORE/rules/inject.txt"
}

cmd_context() {
  local sub=${1:-}
  case "$sub" in
    session-start) _ga_context_session_start ;;
    *) ga_die "사용법: ga context session-start" 2 ;;
  esac
}

_ga_context_session_start() {
  local st line open asked n rep ids names
  if [ -n "${GA_ROOT:-}" ]; then
    if st=$(_ga_status_json "$GA_ROOT" 2>/dev/null) && [ -n "$st" ]; then
      rep=없음
      if [ -f "$(ga_state_dir "$GA_ROOT")/report.json" ]; then
        if [ "$(printf '%s' "$st" | jq -r '.report_fresh')" = true ]; then rep=최신; else rep=오래됨; fi
      fi
      line=$(printf '%s' "$st" | jq -r --arg rep "$rep" '
        "설계 진행 중: 단계 \(.phase), 반복 \(.iteration)/\(.iteration_count), 미해결 \(.open + .asked)개, 검증 보고 \($rep)"
        + (if .paused == true then " (일시정지됨)" else "" end)')
      echo "$line"
      ids=$(jq -r --argjson r "$(printf '%s' "$st" | jq -c '.round')" '
        [.items[]? | select(.round == $r and (.status == "open" or .status == "asked")) | .id] | .[:10] | join(", ")' \
        "$(ga_ledger_path "$GA_ROOT")" 2>/dev/null)
      [ -n "$ids" ] && echo "미해결 항목: $ids"
    else
      echo "경고: 설계 상태를 읽을 수 없습니다 (docs/architecture/.state 확인 필요)."
    fi
  fi
  if names=$(ga_billing_scan_settings "${GA_ROOT:-}" claude 2>/dev/null); then
    if [ -n "$names" ]; then
      names=$(printf '%s\n' "$names" | sort -u | paste -sd, - | sed 's/,/, /g')
      echo "경고: 이 세션은 API 과금 경로(${names})로 동작할 수 있습니다. 구독 로그인만 사용하세요."
    fi
  else
    echo "경고: API 과금 경로 점검에 실패했습니다. 구독 로그인만 사용하세요."
  fi
  return 0
}
