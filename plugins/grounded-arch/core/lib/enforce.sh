# grounded-arch: harness-neutral glue for the adapter's OS isolation settings. Sourced.
# The harness is named by GA_HARNESS (the hook adapter and the MCP server set it); its adapter's
# enforce.sh knows where the harness keeps its settings. The core never names those paths.

# Prints the adapter's enforce.sh path. rc 2 with a Korean message when it cannot be used.
_ga_enforce_script() {
  local h=${GA_HARNESS:-} s
  [ -n "$h" ] || { echo "ga: GA_HARNESS 가 설정되지 않았습니다" >&2; return 2; }
  case "$h" in *[!a-zA-Z0-9_-]*) echo "ga: GA_HARNESS 값이 올바르지 않습니다: ${h}" >&2; return 2 ;; esac
  s=$GA_CORE/../adapters/$h/enforce.sh
  [ -x "$s" ] || { echo "ga: 하네스 '${h}' 의 격리 설정 어댑터가 없습니다 (${s})" >&2; return 2; }
  echo "$s"
}

# Prints the settings path on success. rc 2 with a Korean message when the adapter is unavailable.
_ga_run_enforce() { # ROOT
  local s
  s=$(_ga_enforce_script) || return 2
  "$s" install "$1"
}

# Prints {"active":bool,"reason":"...","settings":"..."} for design ROOT. rc 0 active, 1 inactive,
# 2 when the harness or its adapter cannot tell (reason says why).
ga_enforce_status() { # ROOT
  local s out err
  if ! s=$(_ga_enforce_script 2>/dev/null); then
    err=$(_ga_enforce_script 2>&1 >/dev/null)
    jq -nc --arg r "${err#ga: }" '{active:false, reason:$r, settings:""}'
    return 2
  fi
  out=$("$s" status "$1" 2>/dev/null) || out=""
  case "$out" in
    '{"active":true,'*) printf '%s\n' "$out"; return 0 ;;
    '{"active":false,'*) printf '%s\n' "$out"; return 1 ;;
  esac
  jq -nc --arg r "격리 상태를 확인하지 못했습니다 (${s} status)" '{active:false, reason:$r, settings:""}'
  return 2
}

# True when the adapter says canonical PATH is one of the harness's settings files for design ROOT
# (they hold the isolation settings). An adapter failure counts as protected; no harness, as not.
ga_enforce_protects() { # ROOT PATH
  local s rc=0
  s=$(_ga_enforce_script 2>/dev/null) || return 1
  "$s" protects "$1" "$2" >/dev/null 2>&1 || rc=$?
  [ "$rc" != 1 ]
}

cmd_enforce() {
  local root path rc canon rel
  [ $# -eq 0 ] || ga_die "사용법: ga enforce" 2
  ga_need_state
  root=$GA_ROOT
  path=$(_ga_run_enforce "$root") || { rc=$?; ga_die "ga: 격리 설정을 설치하지 못했습니다 (OS 격리 없음)" "$rc"; }
  echo "격리 설정: ${path}"
  canon=$(ga_canon "$root") || canon=$root
  case "$path" in
    "$canon"/*)
      rel=${path#"$canon"/}
      ga_effect_rebaseline "$root" "$rel" || ga_die "ga: 파일 변경 기준을 갱신하지 못했습니다" 2 ;;
  esac
}
