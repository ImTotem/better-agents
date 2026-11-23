#!/bin/bash
# Claude Code adapter: translates hook events to `ga` calls and `ga` verdicts
# back to Claude Code output. No judgment lives here (all of it is in core).
# Usage: hook.sh EVENT   (stdin: Claude Code hook input JSON)
# EVENT: pre-write | pre-bash | stop | user-prompt | session-start
# bash 3.2 + jq only.

# Hooks run outside the OS sandbox (spec 5.5, P28): only system tools run here. The caller's PATH is
# kept as GA_USER_PATH for the verifier runners and the sandboxed build check.
GA_USER_PATH=${GA_USER_PATH:-$PATH}
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export GA_USER_PATH PATH
# P35: jq from a fixed list, never PATH (the same list as core/lib/common.sh). The test suite can
# replace the list or simulate a missing or broken jq (honored only in test mode).
GA_JQ=/nonexistent/jq
_l=/usr/bin/jq:/opt/homebrew/bin/jq:/usr/local/bin/jq
if [ "${GA_TEST_MODE:-}" = 1 ] && [ -n "${GA_TEST_JQ_CANDIDATES:-}" ]; then _l=$GA_TEST_JQ_CANDIDATES; fi
_o=$IFS; IFS=:
for _j in $_l; do case "$_j" in /*) if [ -x "$_j" ]; then GA_JQ=$_j; break; fi ;; esac; done
IFS=$_o; unset _l _o _j
if [ "${GA_TEST_MODE:-}" = 1 ] && [ -n "${GA_TEST_JQ:-}" ]; then GA_JQ=$GA_TEST_JQ; fi
jq() { "$GA_JQ" "$@"; }
# P33: the hook's and ga's temp files go in ga's private folder (the user's own, mode 700, under the
# data dir; the same rule as ga_private_tmp in core/lib/common.sh), never in the user's TMPDIR, which
# the agent's sandboxed shell can write. The user's TMPDIR is kept as GA_USER_TMPDIR.
GA_USER_TMPDIR=${GA_USER_TMPDIR:-${TMPDIR:-}}
_t=${GA_DATA_DIR:-$HOME/.local/state/grounded-arch}/tmp
if [ ! -e "$_t" ] && [ ! -L "$_t" ]; then mkdir -p "${_t%/*}" 2>/dev/null; mkdir -m 700 "$_t" 2>/dev/null; fi
TMP_OK=0
if [ -d "$_t" ] && [ ! -L "$_t" ] && [ -O "$_t" ] &&
   [ "$(stat -c %a "$_t" 2>/dev/null || stat -f %Lp "$_t" 2>/dev/null)" = 700 ]; then
  TMP_OK=1; TMPDIR=$_t
else
  TMPDIR=/nonexistent/ga-private-tmp
fi
export TMPDIR GA_USER_TMPDIR
unset _t

_self=${BASH_SOURCE[0]}
while [ -L "$_self" ]; do
  _dir=$(cd -P "$(dirname "$_self")" && pwd)
  _self=$(readlink "$_self")
  case "$_self" in /*) ;; *) _self=$_dir/$_self ;; esac
done
PLUGIN_ROOT=$(cd -P "$(dirname "$_self")/../.." && pwd)
GA=$PLUGIN_ROOT/core/bin/ga
# The test suite replaces ga with a stub (honored only in test mode).
if [ "${GA_TEST_MODE:-}" = 1 ] && [ -n "${GA_BIN:-}" ]; then GA=$GA_BIN; fi
# The core asks this harness's adapter (adapters/claude-code/enforce.sh) about the OS isolation.
GA_HARNESS=claude-code
export GA_HARNESS

event=${1:-}
input=$(cat)

jqi() { printf '%s' "$input" | jq -r "$1 // empty" 2>/dev/null; }

# P15: the core finds the session's design from the project root Claude Code gives the hook
# (CLAUDE_PROJECT_DIR), never from the hook's cwd, which follows the agent's cd. Without it the cwd is
# the fallback (set below, once the input is read).
case "${CLAUDE_PROJECT_DIR:-}" in /*) GA_SESSION_ROOT=$CLAUDE_PROJECT_DIR ;; *) GA_SESSION_ROOT=$PWD ;; esac
export GA_SESSION_ROOT

# P33: without the private temp folder nothing can be judged (`ga root` needs no temp file). While a
# design exists for the session: writes and prompts are refused, shell commands while it is in force,
# Stop and SessionStart tell the user; the user's fix is to check and remove the folder. Without a
# design nothing changes.
if [ "$TMP_OK" != 1 ]; then
  _m="ga의 임시 폴더(GA_DATA_DIR 또는 ~/.local/state/grounded-arch 아래 tmp)가 이 사용자 소유의 권한 700 폴더가 아니어서 판정하지 못합니다. 사용자에게 알리세요: 사용자가 그 폴더를 확인하고 지우면 다음 호출에 다시 만들어집니다"
  case "$event" in
    pre-write) "$GA" root >/dev/null 2>&1 && printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"grounded-arch: %s"}}\n' "$_m" ;;
    pre-bash) "$GA" root --active >/dev/null 2>&1 && printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"grounded-arch: %s"}}\n' "$_m" ;;
    user-prompt) "$GA" root >/dev/null 2>&1 && printf '{"decision":"block","reason":"grounded-arch: %s. GA 줄은 기록되지 않았습니다"}\n' "$_m" ;;
    stop | session-start) "$GA" root >/dev/null 2>&1 && printf '{"systemMessage":"grounded-arch: %s"}\n' "$_m" ;;
  esac
  exit 0
fi

# R35-1: without a working jq, or with an event that is not a JSON object, the adapter cannot
# read the tool call (`ga root` needs no jq). Shell commands are denied while a design is in force
# for the session directory; a PAUSED marker opens them (the recovery). P21/P32: the write target is
# unknown, so writes stay denied while a design exists, paused or not -- a PAUSED marker never opens
# the state folder or the fingerprint store. Without a design both pass as before.
case "$event" in
  pre-write | pre-bash)
    if ! printf '%s' "$input" | jq -e 'type == "object"' >/dev/null 2>&1; then
      if [ "$event" = pre-bash ] && "$GA" root --active >/dev/null 2>&1; then
        printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"grounded-arch: jq를 실행할 수 없거나 훅 입력을 읽을 수 없어 판정하지 못했으므로 막습니다. 사용자에게 알리세요: jq(/usr/bin/jq, /opt/homebrew/bin/jq, /usr/local/bin/jq 중 하나)가 동작하도록 고치거나, 사용자가 docs/architecture/.state/PAUSED 파일을 직접 만들면(touch) 셸 명령이 풀립니다."}}'
      elif [ "$event" = pre-write ] && "$GA" root >/dev/null 2>&1; then
        printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"grounded-arch: jq를 실행할 수 없거나 훅 입력을 읽을 수 없어 어느 파일에 쓰는지 판정하지 못했으므로 막습니다. 설계 상태 폴더와 상태 지문 저장 위치를 지키기 위해 일시정지(PAUSED) 중에도 쓰기 도구는 막힙니다. 사용자에게 알리세요: jq(/usr/bin/jq, /opt/homebrew/bin/jq, /usr/local/bin/jq 중 하나)가 동작하도록 고쳐야 풀립니다(셸 명령은 일시정지로 풀 수 있습니다)."}}'
      fi
      exit 0
    fi
    ;;
esac

cwd=$(jqi '.cwd')
if [ -n "$cwd" ] && [ -d "$cwd" ]; then
  cd "$cwd" || true
  case "${CLAUDE_PROJECT_DIR:-}" in /*) ;; *) GA_SESSION_ROOT=$PWD ;; esac
fi

HOOK_ERR=""
VERDICT=""
V_DECISION=""
V_REASON=""
V_CONTEXT=""
V_NOTICE=""

# run_ga ARGS...: sets VERDICT (stdout), HOOK_ERR (first stderr line, if failed).
run_ga() {
  local errf rc=0
  errf=$(mktemp)
  VERDICT=$("$GA" "$@" 2>"$errf") || rc=$?
  HOOK_ERR=$(head -n 1 "$errf")
  rm -f "$errf"
  # The usual allow verdict needs no parsing (the bash gate runs before every shell command).
  if [ $rc -eq 0 ] && [ "$VERDICT" = '{"decision":"allow","reason":""}' ]; then
    V_DECISION=allow; V_REASON=""; V_CONTEXT=""; V_NOTICE=""
    return 0
  fi
  if [ $rc -eq 0 ] && printf '%s' "$VERDICT" | jq -e 'type == "object" and (.decision | type == "string")' >/dev/null 2>&1; then
    V_DECISION=$(printf '%s' "$VERDICT" | jq -r '.decision')
    V_REASON=$(printf '%s' "$VERDICT" | jq -r '.reason // ""')
    V_CONTEXT=$(printf '%s' "$VERDICT" | jq -r '.context // ""')
    V_NOTICE=$(printf '%s' "$VERDICT" | jq -r '.notice // ""')
    return 0
  fi
  [ -n "$HOOK_ERR" ] || HOOK_ERR="종료 코드 $rc"
  return 1
}

emit_deny() { # REASON
  jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
}
emit_block() { # REASON [NOTICE]  (systemMessage: shown to the user)
  jq -n --arg r "$1" --arg n "${2:-}" '{decision:"block",reason:$r} + (if $n == "" then {} else {systemMessage:$n} end)'
}
emit_context() { # EVENTNAME TEXT [NOTICE]  (systemMessage: shown to the user)
  jq -n --arg e "$1" --arg c "$2" --arg n "${3:-}" '{hookSpecificOutput:{hookEventName:$e,additionalContext:$c}}
    + (if $n == "" then {} else {systemMessage:$n} end)'
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
    # The command text is not passed: the OS sandbox decides what a command may write.
    pre_gate gate bash
    ;;
  stop)
    active=$(jqi '.stop_hook_active')
    [ "$active" = true ] || active=false
    if run_ga gate stop --hook-active "$active"; then
      if [ "$V_DECISION" = block ]; then
        emit_block "$V_REASON" "$V_NOTICE"
      elif [ -n "$V_NOTICE" ]; then
        jq -n --arg n "$V_NOTICE" '{systemMessage:$n}'
      fi
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
        ctx=$ctx$'\n'"ga 오류: ${HOOK_ERR}"; V_NOTICE=""
      fi
      # P32 (M3): what the user must see (GA 재개's accepted files, GA 격리해제) also goes to the user.
      emit_context UserPromptSubmit "$ctx" "$V_NOTICE"
    fi
    ;;
  session-start)
    rc=0; notice=""
    out=$("$GA" context session-start --json 2>/dev/null) || rc=$?
    if [ $rc -eq 0 ] && ctx=$(printf '%s' "$out" | jq -er '.context | strings' 2>/dev/null); then
      notice=$(printf '%s' "$out" | jq -r '.notice // ""' 2>/dev/null)
    else
      ctx="ga 오류: 세션 컨텍스트를 만들지 못했습니다 (종료 코드 ${rc})"
    fi
    [ -n "$ctx$notice" ] && emit_context SessionStart "$ctx" "$notice"
    ;;
  *)
    echo "hook.sh: 알 수 없는 이벤트: $event" >&2
    exit 2
    ;;
esac
exit 0
