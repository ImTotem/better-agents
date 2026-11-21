#!/bin/bash
# Claude Code adapter: translates hook events to `ga` calls and `ga` verdicts
# back to Claude Code output. No judgment lives here (all of it is in core).
# Usage: hook.sh EVENT   (stdin: Claude Code hook input JSON)
# EVENT: pre-write | pre-bash | stop | user-prompt | session-start
# bash 3.2 + jq only.

_self=${BASH_SOURCE[0]}
while [ -L "$_self" ]; do
  _dir=$(cd -P "$(dirname "$_self")" && pwd)
  _self=$(readlink "$_self")
  case "$_self" in /*) ;; *) _self=$_dir/$_self ;; esac
done
PLUGIN_ROOT=$(cd -P "$(dirname "$_self")/../.." && pwd)
GA=${GA_BIN:-$PLUGIN_ROOT/core/bin/ga}

event=${1:-}
input=$(cat)

jqi() { printf '%s' "$input" | jq -r "$1 // empty" 2>/dev/null; }

# R35-1: without a working jq, or with an event that is not a JSON object, the adapter cannot
# read the tool call. Writes and shell commands are then denied when a design is active for the
# session directory (`ga root --active` needs no jq); without a design they pass as before.
case "$event" in
  pre-write | pre-bash)
    if ! printf '%s' "$input" | jq -e 'type == "object"' >/dev/null 2>&1; then
      if "$GA" root --active >/dev/null 2>&1; then
        printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"grounded-arch: jq를 실행할 수 없거나 훅 입력을 읽을 수 없어 판정하지 못했으므로 막습니다. 사용자에게 알리세요: jq(/usr/bin/jq)가 동작하도록 고치거나, 사용자가 docs/architecture/.state/PAUSED 파일을 직접 만들면(touch) 게이트가 풀립니다."}}'
      fi
      exit 0
    fi
    ;;
esac

cwd=$(jqi '.cwd')
if [ -n "$cwd" ] && [ -d "$cwd" ]; then cd "$cwd" || true; fi

HOOK_ERR=""
VERDICT=""
V_DECISION=""
V_REASON=""
V_CONTEXT=""

# run_ga ARGS...: sets VERDICT (stdout), HOOK_ERR (first stderr line, if failed).
run_ga() {
  local errf rc=0
  errf=$(mktemp)
  VERDICT=$("$GA" "$@" 2>"$errf") || rc=$?
  HOOK_ERR=$(head -n 1 "$errf")
  rm -f "$errf"
  if [ $rc -eq 0 ] && printf '%s' "$VERDICT" | jq -e 'type == "object" and (.decision | type == "string")' >/dev/null 2>&1; then
    V_DECISION=$(printf '%s' "$VERDICT" | jq -r '.decision')
    V_REASON=$(printf '%s' "$VERDICT" | jq -r '.reason // ""')
    V_CONTEXT=$(printf '%s' "$VERDICT" | jq -r '.context // ""')
    return 0
  fi
  [ -n "$HOOK_ERR" ] || HOOK_ERR="종료 코드 $rc"
  return 1
}

emit_deny() { # REASON
  jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
}
emit_block() { # REASON
  jq -n --arg r "$1" '{decision:"block",reason:$r}'
}
emit_context() { # EVENTNAME TEXT
  jq -n --arg e "$1" --arg c "$2" '{hookSpecificOutput:{hookEventName:$e,additionalContext:$c}}'
}

ga_error_reason() {
  printf 'ga 오류: %s. 복구: 사용자에게 알리세요. 사용자가 `GA 일시정지`를 입력하거나 docs/architecture/.state/state.json을 확인하고 고치거나 복원하면 풀립니다' "$HOOK_ERR"
}

# Any verdict other than allow denies (fail-closed for writes and shell commands).
pre_gate() { # ga args...
  if run_ga "$@"; then
    [ "$V_DECISION" = allow ] || emit_deny "${V_REASON:-ga 판정이 allow가 아니어서 막습니다 (decision=${V_DECISION})}"
  else
    emit_deny "$(ga_error_reason)"
  fi
  return 0
}

case "$event" in
  pre-write)
    p=$(jqi '.tool_input.file_path')
    [ -n "$p" ] || p=$(jqi '.tool_input.notebook_path')
    [ -n "$p" ] || exit 0
    pre_gate gate write --path "$p"
    ;;
  pre-bash)
    c=$(jqi '.tool_input.command')
    [ -n "$c" ] || exit 0
    pre_gate gate bash --command "$c"
    ;;
  stop)
    active=$(jqi '.stop_hook_active')
    [ "$active" = true ] || active=false
    if run_ga gate stop --hook-active "$active"; then
      [ "$V_DECISION" = block ] && emit_block "$V_REASON"
    fi
    ;;
  user-prompt)
    tmp=$(mktemp)
    trap 'rm -f "$tmp"' EXIT
    printf '%s' "$(jqi '.prompt')" >"$tmp"
    tp=$(jqi '.transcript_path')
    if [ -n "$tp" ]; then
      run_ga user-command --text-file "$tmp" --transcript "$tp"
    else
      run_ga user-command --text-file "$tmp"
    fi
    rc=$?
    if [ $rc -eq 0 ] && [ "$V_DECISION" = block ]; then
      emit_block "$V_REASON"
    else
      ctx=$("$GA" rule 2>/dev/null)
      [ -n "$ctx" ] || ctx=$("$PLUGIN_ROOT/core/bin/ga" rule 2>/dev/null)
      if [ $rc -eq 0 ]; then
        [ -n "$V_CONTEXT" ] && ctx=$ctx$'\n'$V_CONTEXT
      else
        ctx=$ctx$'\n'"ga 오류: ${HOOK_ERR}"
      fi
      emit_context UserPromptSubmit "$ctx"
    fi
    ;;
  session-start)
    rc=0
    ctx=$("$GA" context session-start 2>/dev/null) || rc=$?
    if [ $rc -ne 0 ]; then
      ctx=$ctx$'\n'"ga 오류: 세션 컨텍스트를 만들지 못했습니다 (종료 코드 ${rc})"
    fi
    [ -n "$ctx" ] && emit_context SessionStart "$ctx"
    ;;
  *)
    echo "hook.sh: 알 수 없는 이벤트: $event" >&2
    exit 2
    ;;
esac
exit 0
