# Subscription-only billing preflight and runner execution. Sourced; bash 3.2 + jq.
# Fail closed: any doubt refuses (exit 4).
# Harness-neutral (spec 5.0, R33): the core validates the runner record, strips the billing
# environment, refuses forbidden flags and runs the record's preflight script. Everything that
# is specific to one CLI (its settings files, its auth status output) lives in that script
# (core/verifier/runners/<name>.preflight.sh; contract in core/verifier/runners/README.md).

GA_BILLING_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# Runner records live in core/verifier/runners. GA_RUNNERS_DIR is honored only by the test
# suite (GA_TEST_MODE=1): the agent's environment cannot redirect the records (R34a).
ga_runners_dir() {
  if [ "${GA_TEST_MODE:-}" = 1 ] && [ -n "${GA_RUNNERS_DIR:-}" ]; then
    echo "$GA_RUNNERS_DIR"
  else
    echo "$GA_BILLING_DIR/verifier/runners"
  fi
}

ga_billing_record() { # RUNNER -> path of record file (may not exist)
  echo "$(ga_runners_dir)/$1.json"
}

ga_billing_refuse() { echo "ga: 과금 점검 거부: $1" >&2; return 4; }

_ga_runner_name_ok() { case "$1" in "" | */* | .*) return 1 ;; esac; return 0; }

# Path of the record's preflight script: a plain file name, looked up next to the records and
# then in the built-in runners directory. Returns 1 when missing or not a plain name.
_ga_preflight_path() { # RECFILE
  local name d
  name=$(jq -r '.preflight_script | strings' "$1" 2>/dev/null)
  [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
  for d in "$(ga_runners_dir)" "$GA_BILLING_DIR/verifier/runners"; do
    if [ -f "$d/$name" ]; then echo "$d/$name"; return 0; fi
  done
  return 1
}

# P16/P28: ga verify runs outside the OS sandbox with only system tools on PATH; a runner command is
# looked up in the user's PATH (GA_USER_PATH), absolute entries outside the project (GA_ROOT) and the
# session root only: a relative or empty entry, or one inside the project, is agent-writable. Prints
# the absolute path of the binary COMMAND resolves to (what ga_runner_exec runs; the report keeps it).
ga_runner_command_path() { # COMMAND
  local e d oldifs=$IFS noglob=1 up
  local -a ins=()
  [ -n "$1" ] || return 1
  for d in "${GA_ROOT:-}" "${GA_SESSION_ROOT:-}"; do
    [ -n "$d" ] && [ "$d" != / ] || continue
    ins+=("${d%/}"); d=$(ga_phys_dir "$d" 2>/dev/null) && ins+=("${d%/}")
  done
  case "$1" in
    /*) # an absolute command: used as it is, unless it lies inside the project
      [ -f "$1" ] && [ -x "$1" ] || return 1
      d=$(ga_phys_dir "${1%/*}/" 2>/dev/null) || return 1
      for e in ${ins[@]+"${ins[@]}"}; do case "$d/" in "$e"/*) return 1 ;; esac; done
      echo "$1"; return 0 ;;
    */*) return 1 ;; # relative to an agent-writable directory
  esac
  up=$(_ga_runner_path)
  case $- in *f*) ;; *) noglob=0; set -f ;; esac
  IFS=:
  for e in $up; do
    [ -f "$e/$1" ] && [ -x "$e/$1" ] || continue
    d=$(ga_phys_dir "$e" 2>/dev/null) || continue
    if [ ${#ins[@]} -gt 0 ] && _ga_in_any "$d" "${ins[@]}"; then continue; fi
    IFS=$oldifs; [ "$noglob" = 0 ] && set +f
    echo "${e%/}/$1"
    return 0
  done
  IFS=$oldifs; [ "$noglob" = 0 ] && set +f
  return 1
}

_ga_in_any() { # DIR PREFIX... -> true when DIR is one of the PREFIXes or below one
  local d=$1 p
  shift
  for p in "$@"; do case "${d%/}/" in "$p"/*) return 0 ;; esac; done
  return 1
}

# PATH for a runner or its preflight: the user's PATH, absolute entries outside the project and the
# session root only.
_ga_runner_path() { ga_user_path "${GA_ROOT:-}" "${GA_SESSION_ROOT:-}"; }

# TMPDIR for a runner or its preflight: the user's (P33: ga's private temp folder is ga's own).
_ga_runner_tmpdir() { printf '%s' "${GA_USER_TMPDIR:-${TMPDIR:-/tmp}}"; }

# Sets GA_STRIP_ARGS=(-u NAME ...) from the record's strip_env. Returns 4 when unusable.
_ga_strip_args() { # RECFILE
  local out v
  GA_STRIP_ARGS=()
  out=$(jq -r '.strip_env[]' "$1" 2>/dev/null) || { ga_billing_refuse "기록을 읽을 수 없습니다"; return 4; }
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    [[ "$v" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { ga_billing_refuse "올바르지 않은 환경변수 이름: $v"; return 4; }
    GA_STRIP_ARGS+=(-u "$v")
  done <<EOF
$out
EOF
  [ "${#GA_STRIP_ARGS[@]}" -gt 0 ] || { ga_billing_refuse "기록에서 strip_env를 읽을 수 없습니다"; return 4; }
  return 0
}

# Prints the billing-path names the runner's preflight script finds in the current environment
# and settings (for the SessionStart warning). Returns 1 when the scan cannot be done.
ga_billing_scan_settings() { # ROOT RUNNER
  local rec script
  _ga_runner_name_ok "$2" || return 1
  rec=$(ga_billing_record "$2")
  [ -f "$rec" ] || return 1
  script=$(_ga_preflight_path "$rec") || return 1
  GA_RUNNER_RECORD=$rec /bin/bash "$script" --scan "$PWD" "$1" </dev/null 2>/dev/null
}

# Validate a snapshot record and run its preflight. Prints "ok: authMethod=<m>".
ga_billing_check_rec() { # RUNNER RECFILE
  local rec=$2 cmd k script out errf rc method
  jq -e 'type=="object"' "$rec" >/dev/null 2>&1 || { ga_billing_refuse "실행기 기록이 올바른 JSON이 아닙니다"; return 4; }
  for k in name command subscription_auth strip_env preflight_script allowed_auth_methods refused_auth_methods forbidden_flags invoke result_path sources; do
    jq -e --arg k "$k" 'has($k) and .[$k] != null and .[$k] != "" and .[$k] != [] and .[$k] != {}' "$rec" >/dev/null 2>&1 \
      || { ga_billing_refuse "실행기 기록에 필수 키가 없거나 비어 있습니다: $k"; return 4; }
  done
  jq -e '(.command|type=="string") and (.preflight_script|type=="string") and (.strip_env|type=="array") and (.allowed_auth_methods|type=="array")
    and (.refused_auth_methods|type=="array") and (.forbidden_flags|type=="array") and (.invoke|type=="array")
    and (.strip_env|all(type=="string")) and (.forbidden_flags|all(type=="string")) and (.invoke|all(type=="string"))
    and (.allowed_auth_methods|all(type=="string")) and (.refused_auth_methods|all(type=="string"))' "$rec" >/dev/null 2>&1 \
    || { ga_billing_refuse "실행기 기록의 값 형식이 올바르지 않습니다"; return 4; }
  jq -e '.strip_env|all(test("^[A-Za-z_][A-Za-z0-9_]*$"))' "$rec" >/dev/null 2>&1 \
    || { ga_billing_refuse "strip_env에 올바르지 않은 환경변수 이름이 있습니다"; return 4; }
  jq -e '(.sources|type=="array") and (.sources|all(type=="object" and ((.url // "")|type=="string" and .!="") and ((.checked // "")|type=="string" and .!="")))' "$rec" >/dev/null 2>&1 \
    || { ga_billing_refuse "sources의 각 항목에는 url과 checked가 있어야 합니다"; return 4; }
  jq -e '[.forbidden_flags[] as $f | .invoke[] | select(. == $f or startswith($f + "="))] | length == 0' "$rec" >/dev/null 2>&1 \
    || { ga_billing_refuse "실행기 기록의 invoke에 금지된 플래그가 있습니다"; return 4; }

  cmd=$(jq -r '.command' "$rec") || { ga_billing_refuse "기록을 읽을 수 없습니다"; return 4; }
  ga_runner_command_path "$cmd" >/dev/null || { ga_billing_refuse "실행기 명령을 찾을 수 없습니다: $cmd"; return 4; }
  script=$(_ga_preflight_path "$rec") \
    || { ga_billing_refuse "실행기 기록의 preflight_script가 없거나 이름이 올바르지 않습니다 (runners 디렉터리의 파일 이름이어야 합니다)"; return 4; }
  _ga_strip_args "$rec" || return 4

  # The runner-specific preflight runs with the billing environment already stripped.
  errf=$(mktemp "${TMPDIR:-/tmp}/ga-pre.XXXXXX") || { ga_billing_refuse "임시 파일을 만들 수 없습니다"; return 4; }
  rc=0
  out=$(env "${GA_STRIP_ARGS[@]}" PATH="$(_ga_runner_path)" TMPDIR="$(_ga_runner_tmpdir)" GA_RUNNER_RECORD="$rec" /bin/bash "$script" "$PWD" "${GA_ROOT:-}" </dev/null 2>"$errf") || rc=$?
  if [ "$rc" -ne 0 ]; then
    [ -n "$out" ] || out=$(head -n 1 "$errf")
    rm -f "$errf"
    ga_billing_refuse "${out:-실행 전 점검 스크립트가 실패했습니다 (종료 코드 $rc)}"
    return 4
  fi
  rm -f "$errf"
  local re='^ok: authMethod=([A-Za-z0-9_.:-]+)$'
  if ! [[ $out =~ $re ]]; then
    ga_billing_refuse "실행 전 점검 결과를 읽을 수 없습니다: $out"
    return 4
  fi
  method=${BASH_REMATCH[1]}
  # Generic hard floor from the record (must be non-empty), then the allow list.
  if jq -e --arg m "$method" '.refused_auth_methods | index($m) != null' "$rec" >/dev/null 2>&1; then
    ga_billing_refuse "API 과금 또는 미로그인 상태입니다 (authMethod=$method)"; return 4
  fi
  jq -e --arg m "$method" '.allowed_auth_methods | index($m) != null' "$rec" >/dev/null 2>&1 \
    || { ga_billing_refuse "구독 로그인이 아닙니다 (authMethod=$method). 허용: $(jq -r '.allowed_auth_methods|join(", ")' "$rec")"; return 4; }
  echo "ok: authMethod=$method"
  return 0
}

# Copies the record to a snapshot file (path in GA_BILLING_SNAP). Return 4 on failure.
ga_billing_snapshot() { # RUNNER
  local runner=$1 rec
  GA_BILLING_SNAP=""
  _ga_runner_name_ok "$runner" || { ga_billing_refuse "실행기 이름이 올바르지 않습니다: $runner"; return 4; }
  command -v jq >/dev/null 2>&1 || { ga_billing_refuse "jq가 없어 점검할 수 없습니다"; return 4; }
  rec=$(ga_billing_record "$runner")
  [ -f "$rec" ] || { ga_billing_refuse "실행기 기록이 없습니다: $rec"; return 4; }
  GA_BILLING_SNAP=$(mktemp "${TMPDIR:-/tmp}/ga-runner.XXXXXX") || { ga_billing_refuse "임시 파일을 만들 수 없습니다"; return 4; }
  cp "$rec" "$GA_BILLING_SNAP" 2>/dev/null || { rm -f "$GA_BILLING_SNAP"; ga_billing_refuse "기록을 읽을 수 없습니다"; return 4; }
  return 0
}

ga_billing_check() { # RUNNER
  local rc
  ga_billing_snapshot "$1" || return 4
  ga_billing_check_rec "$1" "$GA_BILLING_SNAP"
  rc=$?
  rm -f "$GA_BILLING_SNAP"
  return $rc
}

# Runs the runner's command (resolved to an absolute path) with the billing environment
# stripped and GA_IN_RUNNER=1, so the core ignores the runner's own hook events (R24).
ga_runner_exec() { # RUNNER ARGS...
  local runner=$1 snap cmd cpath a f out
  shift
  local -a flags=()
  ga_billing_snapshot "$runner" || return 4
  snap=$GA_BILLING_SNAP
  ga_billing_check_rec "$runner" "$snap" >/dev/null || { rm -f "$snap"; return 4; }

  out=$(jq -r '.forbidden_flags[]' "$snap") || { rm -f "$snap"; ga_billing_refuse "기록을 읽을 수 없습니다"; return 4; }
  while IFS= read -r f; do [ -n "$f" ] && flags+=("$f"); done <<EOF
$out
EOF
  _ga_strip_args "$snap" || { rm -f "$snap"; return 4; }
  cmd=$(jq -r '.command' "$snap") || { rm -f "$snap"; ga_billing_refuse "기록을 읽을 수 없습니다"; return 4; }
  rm -f "$snap"
  if [ "${#GA_STRIP_ARGS[@]}" -eq 0 ] || [ "${#flags[@]}" -eq 0 ] || [ -z "$cmd" ]; then
    ga_billing_refuse "기록에서 strip_env/forbidden_flags/command를 읽을 수 없습니다"
    return 4
  fi
  cpath=$(ga_runner_command_path "$cmd") || { ga_billing_refuse "실행기 명령을 찾을 수 없습니다: $cmd"; return 4; }
  for a in "$@"; do
    for f in "${flags[@]}"; do
      case "$a" in
        "$f" | "$f="*) ga_billing_refuse "금지된 플래그입니다: $a"; return 4 ;;
      esac
    done
  done
  env "${GA_STRIP_ARGS[@]}" PATH="$(_ga_runner_path)" TMPDIR="$(_ga_runner_tmpdir)" GA_IN_RUNNER=1 "$cpath" "$@"
}

cmd_billing() {
  case "${1:-}" in
    check)
      [ $# -eq 2 ] || ga_die "사용법: ga billing check RUNNER" 2
      ga_billing_check "$2"
      exit $?
      ;;
    *) ga_die "사용법: ga billing check RUNNER" 2 ;;
  esac
}
