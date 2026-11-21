# Subscription-only billing preflight and runner execution. Sourced; bash 3.2 + jq.
# Fail closed: any doubt refuses (exit 4).

GA_BILLING_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

ga_billing_record() { # RUNNER -> path of record file (may not exist)
  echo "${GA_RUNNERS_DIR:-$GA_BILLING_DIR/verifier/runners}/$1.json"
}

# Settings files to inspect; root ones only when ROOT is non-empty.
ga_billing_settings_files() { # ROOT
  echo "$HOME/.claude/settings.json"
  echo "$HOME/.claude/settings.local.json"
  if [ -n "$1" ]; then
    echo "$1/.claude/settings.json"
    echo "$1/.claude/settings.local.json"
  fi
  echo "/Library/Application Support/ClaudeCode/managed-settings.json"
}

# Prints forbidden top-level keys found in settings files. Returns 1 (and prints
# "INVALID:<file>") for an existing file that is not a JSON object.
ga_billing_settings_scan() { # ROOT RECORD
  local root=$1 rec=$2 f forb out rc=0
  forb=$(jq -c '.forbidden_settings' "$rec" 2>/dev/null) || return 1
  while IFS= read -r f; do
    [ -e "$f" ] || continue
    if ! out=$(jq -r --argjson forb "$forb" 'if type=="object" then keys[] | select(. as $k | $forb | index($k)) else error("not object") end' "$f" 2>/dev/null); then
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
  local rec; rec=$(ga_billing_record "$2")
  [ -f "$rec" ] || return 0
  local v
  for v in $(jq -r '.strip_env[]?' "$rec" 2>/dev/null); do
    [ -n "${!v:-}" ] && echo "$v"
  done
  ga_billing_settings_scan "$1" "$rec" | grep -v '^INVALID:'
  return 0
}

ga_billing_refuse() { echo "ga: 과금 점검 거부: $1" >&2; return 4; }

# Prints "ok: authMethod=<m>" on success (return 0); refusal reason to stderr (return 4).
ga_billing_check() { # RUNNER
  local runner=$1 rec cmd v found method pre
  case "$runner" in
    "" | */* | .*) ga_billing_refuse "실행기 이름이 올바르지 않습니다: $runner"; return 4 ;;
  esac
  command -v jq >/dev/null 2>&1 || { ga_billing_refuse "jq가 없어 점검할 수 없습니다"; return 4; }
  rec=$(ga_billing_record "$runner")
  [ -f "$rec" ] || { ga_billing_refuse "실행기 기록이 없습니다: $rec"; return 4; }
  jq -e 'type=="object"' "$rec" >/dev/null 2>&1 || { ga_billing_refuse "실행기 기록이 올바른 JSON이 아닙니다: $rec"; return 4; }
  local k
  for k in name command subscription_auth strip_env forbidden_settings preflight allowed_auth_methods forbidden_flags invoke result_path sources; do
    jq -e --arg k "$k" 'has($k) and .[$k] != null and .[$k] != "" and .[$k] != [] and .[$k] != {}' "$rec" >/dev/null 2>&1 \
      || { ga_billing_refuse "실행기 기록에 필수 키가 없거나 비어 있습니다: $k"; return 4; }
  done
  jq -e '(.command|type=="string") and (.strip_env|type=="array") and (.forbidden_settings|type=="array") and (.preflight|type=="array") and (.allowed_auth_methods|type=="array") and (.forbidden_flags|type=="array") and (.invoke|type=="array")' "$rec" >/dev/null 2>&1 \
    || { ga_billing_refuse "실행기 기록의 값 형식이 올바르지 않습니다"; return 4; }
  jq -e '(.sources|type=="array") and (.sources|all(type=="object" and ((.url // "")|type=="string" and .!="") and ((.checked // "")|type=="string" and .!="")))' "$rec" >/dev/null 2>&1 \
    || { ga_billing_refuse "sources의 각 항목에는 url과 checked가 있어야 합니다"; return 4; }

  found=$(ga_billing_settings_scan "${GA_ROOT:-}" "$rec")
  if [ -n "$found" ]; then
    case "$found" in
      *INVALID:*) ga_billing_refuse "설정 파일을 JSON 객체로 읽을 수 없습니다: $(echo "$found" | grep '^INVALID:' | head -1 | sed 's/^INVALID://')"; return 4 ;;
    esac
    ga_billing_refuse "설정에 API 과금 키가 있습니다: $(echo "$found" | tr '\n' ' ')"
    return 4
  fi

  cmd=$(jq -r '.command' "$rec")
  command -v "$cmd" >/dev/null 2>&1 || { ga_billing_refuse "실행기 명령을 찾을 수 없습니다: $cmd"; return 4; }
  local -a envargs=() preargs=()
  while IFS= read -r v; do [ -n "$v" ] && envargs+=(-u "$v"); done <<EOF
$(jq -r '.strip_env[]' "$rec")
EOF
  while IFS= read -r v; do preargs+=("$v"); done <<EOF
$(jq -r '.preflight[]' "$rec")
EOF
  pre=$(env ${envargs[@]+"${envargs[@]}"} "$cmd" ${preargs[@]+"${preargs[@]}"} </dev/null 2>/dev/null) \
    || { ga_billing_refuse "로그인 상태 점검 명령이 실패했습니다"; return 4; }
  method=$(printf '%s' "$pre" | jq -r '.authMethod // empty' 2>/dev/null)
  [ -n "$method" ] || { ga_billing_refuse "authMethod를 읽을 수 없습니다"; return 4; }
  jq -e --arg m "$method" '.allowed_auth_methods | index($m) != null' "$rec" >/dev/null 2>&1 \
    || { ga_billing_refuse "구독 로그인이 아닙니다 (authMethod=$method). 허용: $(jq -r '.allowed_auth_methods|join(", ")' "$rec")"; return 4; }
  echo "ok: authMethod=$method"
  return 0
}

ga_runner_exec() { # RUNNER ARGS...
  local runner=$1 rec cmd a f v
  shift
  ga_billing_check "$runner" >/dev/null || return 4
  rec=$(ga_billing_record "$runner")
  for a in "$@"; do
    while IFS= read -r f; do
      if [ -n "$f" ] && [ "$a" = "$f" ]; then
        ga_billing_refuse "금지된 플래그입니다: $a"
        return 4
      fi
    done <<EOF
$(jq -r '.forbidden_flags[]' "$rec")
EOF
  done
  cmd=$(jq -r '.command' "$rec")
  local -a envargs=()
  while IFS= read -r v; do [ -n "$v" ] && envargs+=(-u "$v"); done <<EOF
$(jq -r '.strip_env[]' "$rec")
EOF
  env ${envargs[@]+"${envargs[@]}"} "$cmd" "$@"
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
