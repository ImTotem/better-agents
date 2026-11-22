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

# Billing warning for every distinct runner of the effective panel (R33b): the project's
# .state/panel.json when present, else the default panel. Each runner's own preflight script
# scans its harness (core/verifier/runners/README.md).
_ga_context_billing() {
  local pf runners r names
  pf=$GA_CORE/verifier/panel.json
  if [ -n "${GA_ROOT:-}" ] && [ -f "$(ga_state_dir "$GA_ROOT")/panel.json" ]; then pf=$(ga_state_dir "$GA_ROOT")/panel.json; fi
  runners=$(jq -r '[.members[]?.runner | strings] | unique[]' "$pf" 2>/dev/null) || runners=""
  if [ -z "$runners" ]; then
    echo "경고: 검증 패널 설정($pf)을 읽을 수 없어 API 과금 경로를 점검하지 못했습니다. 구독 로그인만 사용하세요."
    return 0
  fi
  for r in $runners; do
    if names=$(ga_billing_scan_settings "${GA_ROOT:-}" "$r" 2>/dev/null); then
      if [ -n "$names" ]; then
        names=$(printf '%s\n' "$names" | sort -u | paste -sd, - | sed 's/,/, /g')
        echo "경고: 이 세션은 API 과금 경로(${names})로 동작할 수 있습니다 (실행기 ${r}). 구독 로그인만 사용하세요."
      fi
    else
      echo "경고: 실행기 ${r}의 API 과금 경로 점검에 실패했습니다. 구독 로그인만 사용하세요."
    fi
  done
}

_ga_context_session_start() {
  local st line rep ids pz=""
  # R24: a verifier runner's own session gets no design context (and no hook side effects).
  [ "${GA_IN_RUNNER:-}" = 1 ] && return 0
  if [ -n "${GA_ROOT:-}" ]; then
    ga_paused_marker "$GA_ROOT" && pz=" (일시정지됨)"
    if st=$(_ga_status_json "$GA_ROOT" 2>/dev/null) && [ -n "$st" ]; then
      rep=없음
      if [ -f "$(ga_state_dir "$GA_ROOT")/report.json" ]; then
        if [ "$(printf '%s' "$st" | jq -r '.report_fresh')" = true ]; then rep=최신; else rep=오래됨; fi
      fi
      line=$(printf '%s' "$st" | jq -r --arg rep "$rep" '
        "설계 진행 중: 단계 \(.phase), 반복 \(.iteration)/\(.iteration_count), 미해결 \(.open + .asked)개, 검증 보고 \($rep)"
        + (if .paused == true then " (일시정지됨)" else "" end)')
      echo "$line"
      # Same selection as ga status / the approval rule (R35-3): assumptions and questions of every
      # round, other kinds of the current round.
      ids=$(jq -r --argjson r "$(printf '%s' "$st" | jq -c '.round')" '
        [.items[]? | select((.kind == "assumption" or .kind == "question" or .round == $r) and (.status == "open" or .status == "asked")) | .id] | .[:10] | join(", ")' \
        "$(ga_ledger_path "$GA_ROOT")" 2>/dev/null)
      [ -n "$ids" ] && echo "미해결 항목: $ids"
    else
      echo "경고: 설계 상태를 읽을 수 없습니다 (docs/architecture/.state 확인 필요).${pz} 사용자가 'GA 일시정지'를 입력하거나 docs/architecture/.state/state.json을 고치거나 복원해야 합니다."
    fi
    _ga_context_guard "$GA_ROOT"
  fi
  _ga_context_billing
  return 0
}

# One line: the OS isolation (spec 5.5 G-sandbox) and the state fingerprint (G-effect).
_ga_context_guard() { # ROOT
  local st iso fp rc=0 why warn
  if st=$(ga_enforce_status "$1"); then
    iso="격리: 켜짐"
  else
    why=$(printf '%s' "$st" | jq -r '.reason // ""' 2>/dev/null)
    iso="격리: 꺼짐 (${why:-이유를 알 수 없음}. 일시정지가 아니면 셸 명령이 막힙니다. MCP 도구 ga_enforce로 다시 설치하거나 사용자에게 'GA 일시정지'를 요청하세요)"
  fi
  # P22: the adapter's warnings (e.g. commands that run outside the sandbox).
  warn=$(printf '%s' "$st" | jq -r '.warnings // [] | .[] | strings' 2>/dev/null)
  [ -z "$warn" ] || printf '%s\n' "$warn" | while IFS= read -r why; do echo "경고: ${why}"; done
  ga_fp_check "$1" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) fp="상태 지문: 일치" ;;
    1) fp="상태 지문: 불일치 (상태가 ga 밖에서 바뀌었습니다. 쓰기와 승인이 막힙니다. 사용자가 확인한 뒤 'GA 상태승인')" ;;
    2) fp="상태 지문: 기록 없음 (사용자가 docs/architecture/.state/를 확인한 뒤 'GA 상태승인')" ;;
    *) fp="상태 지문: 확인할 수 없음 (shasum이나 sha256sum 필요)" ;;
  esac
  echo "${iso} / ${fp}"
}
