# grounded-arch: harness-neutral glue for the adapter's OS isolation settings. Sourced.
# The harness is named by GA_HARNESS (the hook adapter and the MCP server set it); its adapter's
# enforce.sh knows where the harness keeps its settings. The core never names those paths.
# Adapter contract (adapters/<harness>/enforce.sh):
#   install ROOT [--record]  prints the settings path; with --record also a second line: the JSON
#                            record of what it added (kept in .state/enforce.json for uninstall)
#   uninstall ROOT           removes exactly what install added (reads .state/enforce.json)
#   status ROOT              prints {"active":bool,"reason":"...","settings":"...","warnings":[...]}
#                            (the first bytes are exactly {"active":true, or {"active":false,)
#   protects ROOT PATH       exit 0: a settings file with the isolation settings; 3: a file the
#                            harness runs outside the sandbox (protected while a design exists); 1:
#                            neither
#   protects ROOT --list     the same for paths on stdin: prints "0 PATH" / "3 PATH" lines
#   exec ROOT [--protect P]... -- CMD...
#                            runs CMD in an OS sandbox that denies writes by default (P27): CMD may
#                            write ROOT, a fresh temp folder (its TMPDIR, TMP, TEMP; removed after) and
#                            the harness's user-granted write folders, but never the git folder, the
#                            harness's own folders, the state folder, P or the plugin folder; CMD gets
#                            the user's PATH (GA_USER_PATH). No sandbox tool: exit 125 and
#                            "격리 실행 도구 없음" on stderr

GA_ENFORCE_RECORD=enforce.json

# Prints the adapter's enforce.sh path. rc 2 with a Korean message when it cannot be used.
_ga_enforce_script() {
  local h=${GA_HARNESS:-} s
  [ -n "$h" ] || { echo "ga: GA_HARNESS 가 설정되지 않았습니다" >&2; return 2; }
  case "$h" in *[!a-zA-Z0-9_-]*) echo "ga: GA_HARNESS 값이 올바르지 않습니다: ${h}" >&2; return 2 ;; esac
  s=$GA_CORE/../adapters/$h/enforce.sh
  [ -x "$s" ] || { echo "ga: 하네스 '${h}' 의 격리 설정 어댑터가 없습니다 (${s})" >&2; return 2; }
  echo "$s"
}

# Installs the isolation settings and keeps the adapter's record of what it added in
# .state/enforce.json (P23). Prints the settings path; rc 2 with the adapter's message on stderr.
_ga_run_enforce() { # ROOT
  local s out path rec rc
  s=$(_ga_enforce_script) || return 2
  out=$("$s" install "$1" --record) || return 2
  path=${out%%$'\n'*}
  rec=${out#*$'\n'}
  [ "$rec" != "$out" ] && [ -n "$rec" ] || { echo "ga: 어댑터가 설치 기록을 주지 않았습니다" >&2; return 2; }
  ga_lock "$1"
  printf '%s\n' "$rec" | ga_write_json "$(ga_state_dir "$1")/$GA_ENFORCE_RECORD"
  rc=$?
  ga_unlock "$1"
  [ "$rc" = 0 ] || return 2
  echo "$path"
}

# Prints {"active":bool,"reason":"...","settings":"...",...} for design ROOT. rc 0 active, 1 inactive,
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

# What the adapter says canonical PATH is for design ROOT: rc 0 a settings file with the isolation
# settings, 3 a file the harness runs outside the sandbox, 1 neither (also with no harness named),
# 2 the adapter failed (callers treat it as protected).
ga_enforce_protects() { # ROOT PATH
  local s rc=0
  s=$(_ga_enforce_script 2>/dev/null) || return 1
  "$s" protects "$1" "$2" >/dev/null 2>&1 || rc=$?
  case "$rc" in 0 | 1 | 3) return "$rc" ;; *) return 2 ;; esac
}

# stdin: paths relative to ROOT. Prints the ones that are the harness's settings files (P19: those
# are never effect violations). Nothing without a harness.
ga_enforce_settings_rel() { # ROOT
  local s c p k
  if ! s=$(_ga_enforce_script 2>/dev/null) || ! c=$(ga_canon "$1"); then cat >/dev/null; return 0; fi
  while IFS= read -r p; do [ -n "$p" ] && printf '%s/%s\n' "$c" "$p"; done |
    "$s" protects "$1" --list 2>/dev/null |
    while IFS= read -r p; do
      k=${p%% *}; p=${p#* }
      [ "$k" = 0 ] || continue
      case "$p" in "$c"/*) printf '%s\n' "${p#"$c"/}" ;; esac
    done
}

# P16/P27: runs CMD... inside the adapter's OS sandbox (writes denied by default; see the contract
# above). rc 125 with "격리 실행 도구 없음" when there is no harness or no tool.
ga_enforce_exec() { # ROOT CMD...
  local s root=$1
  shift
  s=$(_ga_enforce_script 2>/dev/null) || { echo "격리 실행 도구 없음 (하네스 어댑터 없음)" >&2; return 125; }
  "$s" exec "$root" --protect "$(ga_fp_dir)" -- "$@"
}

cmd_enforce() {
  local root path rc
  [ $# -eq 0 ] || ga_die "사용법: ga enforce" 2
  ga_need_state
  root=$GA_ROOT
  path=$(_ga_run_enforce "$root") || { rc=$?; ga_die "ga: 격리 설정을 설치하지 못했습니다 (OS 격리 없음)" "$rc"; }
  echo "격리 설정: ${path} (이 저장소의 모든 세션에 적용됩니다. 지우려면 사용자가 'GA 격리해제'를 입력합니다)"
}
