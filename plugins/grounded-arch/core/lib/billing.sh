# Subscription-only billing preflight and runner execution. Sourced; bash 3.2 + jq.
# Fail closed: any doubt refuses (exit 4).

GA_BILLING_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

ga_billing_record() { # RUNNER -> path of record file (may not exist)
  echo "${GA_RUNNERS_DIR:-$GA_BILLING_DIR/verifier/runners}/$1.json"
}

# Settings files to inspect: home, CLAUDE_CONFIG_DIR, managed, and project
# settings in the exec dir (ROOT if non-empty, else $PWD) and every ancestor.
ga_billing_settings_files() { # ROOT
  local d
  echo "$HOME/.claude/settings.json"
  echo "$HOME/.claude/settings.local.json"
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    echo "$CLAUDE_CONFIG_DIR/settings.json"
    echo "$CLAUDE_CONFIG_DIR/settings.local.json"
  fi
  echo "/Library/Application Support/ClaudeCode/managed-settings.json"
  d=${1:-$PWD}
  while :; do
    if [ "$d" = / ]; then
      echo "/.claude/settings.json"
      echo "/.claude/settings.local.json"
      break
    fi
    echo "$d/.claude/settings.json"
    echo "$d/.claude/settings.local.json"
    d=$(dirname "$d")
  done
}

# Prints forbidden top-level keys and billing env names found in settings files.
# Existing file that is not a JSON object (or any jq failure): prints
# "INVALID:<file>" and returns 1.
ga_billing_settings_scan() { # ROOT RECORD
  local root=$1 rec=$2 f forb strip out rc=0
  forb=$(jq -c '.forbidden_settings' "$rec" 2>/dev/null) || { echo "INVALID:$rec"; return 1; }
  strip=$(jq -c '.strip_env' "$rec" 2>/dev/null) || { echo "INVALID:$rec"; return 1; }
  while IFS= read -r f; do
    [ -e "$f" ] || continue
    if ! out=$(jq -r --argjson forb "$forb" --argjson strip "$strip" '
        if type=="object" then
          (keys[] | select(. as $k | $forb | index($k))),
          ((.env // {}) | if type=="object" then keys[] | select(. as $k | $strip | index($k)) else error("env not object") end)
        else error("not object") end' "$f" 2>/dev/null); then
      echo "INVALID:$f"
      rc=1
      continue
    fi
    [ -n "$out" ] && echo "$out"
  done <<EOF
$(ga_billing_settings_files "$root")
EOF
  return $rc
}

ga_billing_scan_settings() { # ROOT RUNNER
  local rec v
  rec=$(ga_billing_record "$2")
  [ -f "$rec" ] || return 0
  for v in $(jq -r '.strip_env[]?' "$rec" 2>/dev/null); do
    [[ "$v" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    [ -n "${!v:-}" ] && echo "$v"
  done
  ga_billing_settings_scan "$1" "$rec" | grep -v '^INVALID:'
  return 0
}

ga_billing_refuse() { echo "ga: 과금 점검 거부: $1" >&2; return 4; }

# Validate a snapshot record and run the preflight. Prints "ok: authMethod=<m>".
ga_billing_check_rec() { # RUNNER RECFILE
  local rec=$2 cmd v found method pre k
  local -a envargs=() preargs=()
  jq -e 'type=="object"' "$rec" >/dev/null 2>&1 || { ga_billing_refuse "실행기 기록이 올바른 JSON이 아닙니다"; return 4; }
  for k in name command subscription_auth strip_env forbidden_settings preflight allowed_auth_methods forbidden_flags invoke result_path sources; do
    jq -e --arg k "$k" 'has($k) and .[$k] != null and .[$k] != "" and .[$k] != [] and .[$k] != {}' "$rec" >/dev/null 2>&1 \
      || { ga_billing_refuse "실행기 기록에 필수 키가 없거나 비어 있습니다: $k"; return 4; }
  done
  jq -e '(.command|type=="string") and (.strip_env|type=="array") and (.forbidden_settings|type=="array") and (.preflight|type=="array") and (.allowed_auth_methods|type=="array") and (.forbidden_flags|type=="array") and (.invoke|type=="array")
    and (.strip_env|all(type=="string")) and (.forbidden_flags|all(type=="string")) and (.invoke|all(type=="string")) and (.preflight|all(type=="string")) and (.allowed_auth_methods|all(type=="string"))' "$rec" >/dev/null 2>&1 \
    || { ga_billing_refuse "실행기 기록의 값 형식이 올바르지 않습니다"; return 4; }
  jq -e '.strip_env|all(test("^[A-Za-z_][A-Za-z0-9_]*$"))' "$rec" >/dev/null 2>&1 \
    || { ga_billing_refuse "strip_env에 올바르지 않은 환경변수 이름이 있습니다"; return 4; }
  jq -e '(.sources|type=="array") and (.sources|all(type=="object" and ((.url // "")|type=="string" and .!="") and ((.checked // "")|type=="string" and .!="")))' "$rec" >/dev/null 2>&1 \
    || { ga_billing_refuse "sources의 각 항목에는 url과 checked가 있어야 합니다"; return 4; }
  jq -e '[.forbidden_flags[] as $f | .invoke[] | select(. == $f or startswith($f + "="))] | length == 0' "$rec" >/dev/null 2>&1 \
    || { ga_billing_refuse "실행기 기록의 invoke에 금지된 플래그가 있습니다"; return 4; }

  found=$(ga_billing_settings_scan "${GA_ROOT:-}" "$rec") && :
  if [ -n "$found" ]; then
    case "$found" in
      *INVALID:*) ga_billing_refuse "설정 파일을 JSON 객체로 읽을 수 없습니다: $(echo "$found" | grep '^INVALID:' | head -1 | sed 's/^INVALID://')"; return 4 ;;
    esac
    ga_billing_refuse "설정에 API 과금 항목이 있습니다: $(echo "$found" | tr '\n' ' ')"
    return 4
  fi

  cmd=$(jq -r '.command' "$rec") || { ga_billing_refuse "기록을 읽을 수 없습니다"; return 4; }
  command -v "$cmd" >/dev/null 2>&1 || { ga_billing_refuse "실행기 명령을 찾을 수 없습니다: $cmd"; return 4; }
  pre=$(jq -r '.strip_env[]' "$rec") || { ga_billing_refuse "기록을 읽을 수 없습니다"; return 4; }
  while IFS= read -r v; do [ -n "$v" ] && envargs+=(-u "$v"); done <<EOF
$pre
EOF
  pre=$(jq -r '.preflight[]' "$rec") || { ga_billing_refuse "기록을 읽을 수 없습니다"; return 4; }
  while IFS= read -r v; do preargs+=("$v"); done <<EOF
$pre
EOF
  pre=$(env ${envargs[@]+"${envargs[@]}"} "$cmd" ${preargs[@]+"${preargs[@]}"} </dev/null 2>/dev/null) \
    || { ga_billing_refuse "로그인 상태 점검 명령이 실패했습니다"; return 4; }
  method=$(printf '%s' "$pre" | jq -r '.authMethod // empty' 2>/dev/null)
  [ -n "$method" ] || { ga_billing_refuse "authMethod를 읽을 수 없습니다"; return 4; }
  case "$method" in
    api_key | api_key_helper | third_party | none)
      ga_billing_refuse "API 과금 또는 미로그인 상태입니다 (authMethod=$method)"; return 4 ;;
  esac
  jq -e --arg m "$method" '.allowed_auth_methods | index($m) != null' "$rec" >/dev/null 2>&1 \
    || { ga_billing_refuse "구독 로그인이 아닙니다 (authMethod=$method). 허용: $(jq -r '.allowed_auth_methods|join(", ")' "$rec")"; return 4; }
  echo "ok: authMethod=$method"
  return 0
}

# Copies the record to a snapshot file (path in GA_BILLING_SNAP). Return 4 on failure.
ga_billing_snapshot() { # RUNNER
  local runner=$1 rec
  GA_BILLING_SNAP=""
  case "$runner" in
    "" | */* | .*) ga_billing_refuse "실행기 이름이 올바르지 않습니다: $runner"; return 4 ;;
  esac
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

ga_runner_exec() { # RUNNER ARGS...
  local runner=$1 snap cmd a f v out
  shift
  local -a envargs=() flags=()
  ga_billing_snapshot "$runner" || return 4
  snap=$GA_BILLING_SNAP
  ga_billing_check_rec "$runner" "$snap" >/dev/null || { rm -f "$snap"; return 4; }

  out=$(jq -r '.forbidden_flags[]' "$snap") || { rm -f "$snap"; ga_billing_refuse "기록을 읽을 수 없습니다"; return 4; }
  while IFS= read -r f; do [ -n "$f" ] && flags+=("$f"); done <<EOF
$out
EOF
  out=$(jq -r '.strip_env[]' "$snap") || { rm -f "$snap"; ga_billing_refuse "기록을 읽을 수 없습니다"; return 4; }
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    [[ "$v" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { rm -f "$snap"; ga_billing_refuse "올바르지 않은 환경변수 이름: $v"; return 4; }
    envargs+=(-u "$v")
  done <<EOF
$out
EOF
  cmd=$(jq -r '.command' "$snap") || { rm -f "$snap"; ga_billing_refuse "기록을 읽을 수 없습니다"; return 4; }
  rm -f "$snap"
  if [ "${#envargs[@]}" -eq 0 ] || [ "${#flags[@]}" -eq 0 ] || [ -z "$cmd" ]; then
    ga_billing_refuse "기록에서 strip_env/forbidden_flags/command를 읽을 수 없습니다"
    return 4
  fi
  for a in "$@"; do
    for f in "${flags[@]}"; do
      case "$a" in
        "$f" | "$f="*) ga_billing_refuse "금지된 플래그입니다: $a"; return 4 ;;
      esac
    done
  done
  env "${envargs[@]}" "$cmd" "$@"
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
