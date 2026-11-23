#!/bin/bash
# Billing preflight for the Claude Code runner (claude.json). Everything Claude-specific about
# subscription-only billing lives here, not in the core (spec 5.0/5.10, R33). bash 3.2 + jq only.
#
# Contract (core/verifier/runners/README.md):
#   claude.preflight.sh EXEC_DIR GA_ROOT         check: prints "ok: authMethod=<m>" (exit 0)
#                                                or one line with the reason (exit 4)
#   claude.preflight.sh --scan EXEC_DIR GA_ROOT  scan: prints billing-path names found in the
#                                                environment and settings (exit 0; 4 = cannot scan)
#   GA_RUNNER_RECORD  path of the record snapshot the core validated.
# The core runs the check with the record's strip_env variables already removed.

_cl_refuse() { echo "$1"; exit 4; }

# Settings files Claude Code reads: user, CLAUDE_CONFIG_DIR, managed, and the project settings of
# EXEC_DIR and GA_ROOT and every ancestor of both (deduplicated; relative starts terminate).
_cl_settings_files() { # EXEC_DIR [GA_ROOT]
  local d start p seen=$'\n'
  echo "$HOME/.claude/settings.json"
  echo "$HOME/.claude/settings.local.json"
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    echo "$CLAUDE_CONFIG_DIR/settings.json"
    echo "$CLAUDE_CONFIG_DIR/settings.local.json"
  fi
  echo "/Library/Application Support/ClaudeCode/managed-settings.json"
  echo "/etc/claude-code/managed-settings.json"
  for start in "${1:-}" "${2:-}"; do
    [ -n "$start" ] || continue
    d=$(cd -P "$start" 2>/dev/null && pwd -P) || d=$start
    while :; do
      case "$seen" in
        *$'\n'"$d"$'\n'*) ;;
        *)
          seen="$seen$d"$'\n'
          p=${d%/}
          echo "$p/.claude/settings.json"
          echo "$p/.claude/settings.local.json"
          ;;
      esac
      [ "$d" = / ] && break
      p=$(dirname "$d")
      [ "$p" = "$d" ] && break
      d=$p
    done
  done
}

# jq filter over one settings object: forbidden top-level keys, billing env names, and GA_* env
# names (a settings env block must not steer the ga verifier).
_CL_SCAN_JQ='if type=="object" then
    (keys[] | select(. as $k | $forb | index($k))),
    ((.env // {}) | if type=="object" then keys[] | select(. as $k | ($strip | index($k)) or startswith("GA_")) else error("env not object") end)
  else error("not object") end'

# Prints findings of every existing settings file; "INVALID:<file>" (and rc 1) for unreadable ones.
_cl_scan_files() { # EXEC_DIR GA_ROOT FORB_JSON STRIP_JSON
  local f out rc=0
  while IFS= read -r f; do
    [ -e "$f" ] || continue
    if ! out=$(jq -r --argjson forb "$3" --argjson strip "$4" "$_CL_SCAN_JQ" "$f" 2>/dev/null); then
      echo "INVALID:$f"
      rc=1
      continue
    fi
    [ -n "$out" ] && echo "$out"
  done <<EOF
$(_cl_settings_files "$1" "$2")
EOF
  return $rc
}

_cl_lists() { # sets CL_REC CL_FORB CL_STRIP from GA_RUNNER_RECORD, or refuses
  CL_REC=${GA_RUNNER_RECORD:-}
  [ -n "$CL_REC" ] && [ -f "$CL_REC" ] || _cl_refuse "실행기 기록(GA_RUNNER_RECORD)을 읽을 수 없습니다"
  CL_FORB=$(jq -ce '.forbidden_settings | select(type=="array" and length>0 and all(type=="string"))' "$CL_REC" 2>/dev/null) \
    || _cl_refuse "실행기 기록의 forbidden_settings가 없거나 올바르지 않습니다"
  CL_STRIP=$(jq -ce '.strip_env | select(type=="array" and length>0 and all(type=="string"))' "$CL_REC" 2>/dev/null) \
    || _cl_refuse "실행기 기록의 strip_env가 없거나 올바르지 않습니다"
}

_cl_check() { # EXEC_DIR GA_ROOT
  local found rc=0 s bad out method v
  local -a args=()
  _cl_lists
  # 1. settings files (apiKeyHelper, billing env blocks)
  found=$(_cl_scan_files "${1:-}" "${2:-}" "$CL_FORB" "$CL_STRIP") || rc=$?
  case "$found" in
    *INVALID:*) _cl_refuse "설정 파일을 JSON 객체로 읽을 수 없습니다: $(printf '%s\n' "$found" | grep '^INVALID:' | head -1 | sed 's/^INVALID://')" ;;
  esac
  [ "$rc" -eq 0 ] || _cl_refuse "설정 점검에 실패했습니다"
  [ -z "$found" ] || _cl_refuse "설정에 API 과금 항목이나 GA_ 환경변수가 있습니다: $(printf '%s\n' "$found" | tr '\n' ' ')"
  # 2. inline --settings of the invoke template are settings too (highest non-managed level).
  out=$(jq -r '.invoke as $a | range(0; $a | length) as $i
      | if $a[$i] == "--settings" then ($a[$i + 1] // "")
        elif ($a[$i] | startswith("--settings=")) then ($a[$i] | ltrimstr("--settings="))
        else empty end | @json' "$CL_REC" 2>/dev/null) || _cl_refuse "실행기 기록의 invoke를 읽을 수 없습니다"
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    s=$(printf '%s' "$s" | jq -r .) || _cl_refuse "invoke의 --settings 값을 읽을 수 없습니다"
    bad=$(printf '%s' "$s" | jq -r --argjson forb "$CL_FORB" --argjson strip "$CL_STRIP" "$_CL_SCAN_JQ" 2>/dev/null) \
      || _cl_refuse "invoke의 --settings는 인라인 JSON 객체여야 합니다"
    [ -z "$bad" ] || _cl_refuse "invoke의 --settings에 API 과금 항목이 있습니다: $(printf '%s\n' "$bad" | tr '\n' ' ')"
  done <<EOF
$out
EOF
  # 3. claude auth status (the record's command and auth_status_args).
  out=$(jq -r '.auth_status_args | if type=="array" and length>0 and all(type=="string") then .[] else error("x") end' "$CL_REC" 2>/dev/null) \
    || _cl_refuse "실행기 기록의 auth_status_args가 없거나 올바르지 않습니다"
  while IFS= read -r v; do args+=("$v"); done <<EOF
$out
EOF
  v=$(jq -r '.command | strings' "$CL_REC" 2>/dev/null)
  [ -n "$v" ] || _cl_refuse "실행기 기록의 command를 읽을 수 없습니다"
  out=$("$v" "${args[@]}" </dev/null 2>/dev/null) || _cl_refuse "로그인 상태 점검 명령이 실패했습니다"
  method=$(printf '%s' "$out" | jq -r '.authMethod // empty' 2>/dev/null)
  [ -n "$method" ] || _cl_refuse "authMethod를 읽을 수 없습니다"
  case "$method" in
    api_key | api_key_helper | third_party | none) _cl_refuse "API 과금 또는 미로그인 상태입니다 (authMethod=$method)" ;;
  esac
  [[ $method =~ ^[A-Za-z0-9_.:-]+$ ]] || _cl_refuse "authMethod 값이 올바르지 않습니다"
  echo "ok: authMethod=$method"
  exit 0
}

_cl_scan() { # EXEC_DIR GA_ROOT
  local v
  _cl_lists
  for v in $(printf '%s' "$CL_STRIP" | jq -r '.[]'); do
    [[ $v =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    [ -n "${!v:-}" ] && echo "$v"
  done
  _cl_scan_files "${1:-}" "${2:-}" "$CL_FORB" "$CL_STRIP" | grep -v '^INVALID:'
  exit 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    --scan) shift; _cl_scan "$@" ;;
    *) _cl_check "$@" ;;
  esac
fi
