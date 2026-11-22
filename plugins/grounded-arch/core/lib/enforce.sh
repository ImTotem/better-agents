# grounded-arch: harness-neutral glue for the adapter's OS isolation settings. Sourced.

# Prints the settings path on success. rc 2 with a Korean message when the adapter is unavailable.
_ga_run_enforce() { # ROOT
  local h=${GA_HARNESS:-} s
  [ -n "$h" ] || { echo "ga: GA_HARNESS 가 설정되지 않았습니다" >&2; return 2; }
  case "$h" in *[!a-zA-Z0-9_-]*) echo "ga: GA_HARNESS 값이 올바르지 않습니다: ${h}" >&2; return 2 ;; esac
  s=$GA_CORE/../adapters/$h/enforce.sh
  [ -x "$s" ] || { echo "ga: 하네스 '${h}' 의 격리 설정 어댑터가 없습니다 (${s})" >&2; return 2; }
  "$s" install "$1"
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
