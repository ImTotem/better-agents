# grounded-arch gates: ga gate write|bash|stop. Sourced; bash 3.2 compatible.
# Every gate prints ONE JSON line {"decision":"allow|deny|block","reason":"..."} and exits 0; the
# stop gate may add "notice" (shown to the user, not to the agent). Internal errors fail closed
# (deny for write/bash, block for stop).
# Spec 5.5: shell commands run inside the harness's OS sandbox, so the bash gate never reads the
# command text; it only checks that the isolation is on. What changed is judged afterwards (Stop and
# approval: changed files, state fingerprint).

_ga_gate_out() { # DECISION REASON [NOTICE]
  if [ -z "$2" ] && [ -z "${3:-}" ]; then printf '{"decision":"%s","reason":""}\n' "$1"; return 0; fi
  jq -cn --arg d "$1" --arg r "$2" --arg n "${3:-}" '{decision:$d, reason:$r} + (if $n == "" then {} else {notice:$n} end)'
}

# Runs a gate function in a subshell (so ga_die/exit cannot escape) and guarantees
# one valid decision line; anything else becomes the fail-closed decision.
_ga_gate_run() { # FAIL_DECISION FUNC ARGS...
  local fail=$1 fn=$2 out
  shift 2
  out=$( "$fn" "$@" 2>/dev/null )
  case "$out" in '{"decision":"allow","reason":""}') printf '%s\n' "$out"; return 0 ;; esac
  if [ -n "$out" ] && printf '%s' "$out" | jq -e '.decision | IN("allow","deny","block")' >/dev/null 2>&1; then
    printf '%s\n' "$out"
  else
    _ga_gate_out "$fail" "ga 게이트 내부 오류로 판정할 수 없어 막습니다. 사용자에게 \`GA 일시정지\`를 요청하거나 docs/architecture/.state/ 상태를 확인하세요"
  fi
  return 0
}

cmd_gate() {
  local sub=${1:-}
  [ $# -gt 0 ] && shift
  case "$sub" in
    write) _ga_gate_run deny _ga_gate_write "$@" ;;
    bash) _ga_gate_run deny _ga_gate_bash "$@" ;;
    stop) _ga_gate_run block _ga_gate_stop "$@" ;;
    *) ga_die "사용법: ga gate write --path P | bash | stop [--hook-active true|false]" 2 ;;
  esac
}

# True if P equals X or lies below X (component-wise: /a/docsX is not under /a/docs).
# Comparison is case-folded: APFS is case-insensitive, so docs/Architecture/.STATE is the
# same place as docs/architecture/.state (fail-closed direction for the .state deny).
_ga_under() { # X P
  local x=${1%/} nc=0 r=1
  shopt -q nocasematch && nc=1
  shopt -s nocasematch
  if [[ $2 == "$x" || $2 == "$x"/* ]]; then r=0; fi
  [ $nc = 1 ] || shopt -u nocasematch
  return $r
}

# The plugin directory (the one containing core/). Protected while a design is active (R34d).
_ga_plugin_root() { cd -P "$GA_CORE/.." 2>/dev/null && pwd -P; }

# Loads state.json of ROOT into GS_PHASE/GS_MODE/GS_PAUSED. Returns 1 if unreadable/invalid.
_ga_gate_state() { # ROOT
  local f=$1/docs/architecture/.state/state.json line
  line=$(jq -r 'if type != "object" then error("not an object") else
      [(.phase // ""), (.mode // ""), ((.paused // false) | tostring)] | join("|") end' "$f" 2>/dev/null) || return 1
  IFS='|' read -r GS_PHASE GS_MODE GS_PAUSED <<EOF
$line
EOF
  case "$GS_PHASE" in inputs | iterating | design-review | skeleton | implement) ;; *) return 1 ;; esac
  case "$GS_MODE" in greenfield | brownfield) ;; *) return 1 ;; esac
  case "$GS_PAUSED" in true | false) ;; *) return 1 ;; esac
  return 0
}

# True when the design at ROOT is in force: no PAUSED marker and not paused in state.json. An
# unreadable state.json counts as in force (fail-closed; the user repairs it or pauses).
_ga_design_active() { # ROOT
  ga_paused_marker "$1" && return 1
  _ga_gate_state "$1" || return 0
  [ "$GS_PAUSED" != true ]
}

# R31c: the agent cannot repair state.json (it may not write under .state); the user can.
_ga_corrupt_reason() { # ROOT
  echo "설계 상태 파일을 읽을 수 없습니다: $1/docs/architecture/.state/state.json 이(가) 올바른 JSON이 아니거나 값이 잘못되었습니다. 에이전트는 이 파일을 고칠 수 없습니다. 사용자에게 알리세요: 사용자가 state.json을 고치거나 백업에서 복원하면 풀립니다(ga 밖에서 바뀐 것이므로 그 뒤 \`GA 상태승인\`도 필요할 수 있습니다). \`GA 일시정지\`는 단계 규칙과 셸 명령 차단만 풉니다"
}

# True when MAPPED (ledger mapping, change new|changed) contains canonical path C.
_ga_mapped() { # ROOT C
  local mp m
  mp=$(jq -r '.items[] | select(.kind == "mapping" and (.change == "new" or .change == "changed")) | .path' "$1/docs/architecture/.state/ledger.json" 2>/dev/null) || return 2
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    [ "$(ga_canon "$1/$m" 2>/dev/null)" = "$2" ] && return 0
  done <<EOF
$mp
EOF
  return 1
}

# --- write gate (Write, Edit, MultiEdit, NotebookEdit: they run outside the OS sandbox) -------

# P15: prints the root whose design state folder canonical path C is (or lies under): any
# docs/architecture/.state component (case-folded) with a state.json at that prefix. It does not walk
# up to a .git boundary, which the agent can plant.
_ga_state_component_root() { # C
  local c=$1 lc rest head off=0 n tail key=/docs/architecture/.state
  lc=$(printf '%s' "$c" | LC_ALL=C tr 'A-Z' 'a-z')
  while :; do
    rest=${lc:$off}
    case "$rest" in *"$key"*) ;; *) return 1 ;; esac
    head=${rest%%"$key"*}
    n=$((off + ${#head}))
    tail=${lc:$((n + ${#key}))}
    case "$tail" in
      "" | /*)
        if [ -f "${c:0:$n}$key/state.json" ]; then echo "${c:0:$n}"; return 0; fi ;;
    esac
    off=$((n + 1))
  done
}

# P20: true when canonical C is git configuration or a git hook (anything git runs outside the
# sandbox): .git/**/config, .git/**/config.worktree, .git/**/hooks/** (case-folded).
_ga_git_exec_path() { # C
  local lc
  lc=$(printf '%s' "$1" | LC_ALL=C tr 'A-Z' 'a-z')
  case "$lc" in
    */.git/config | */.git/*/config | */.git/config.worktree | */.git/*/config.worktree) return 0 ;;
    */.git/hooks | */.git/hooks/* | */.git/*/hooks | */.git/*/hooks/*) return 0 ;;
  esac
  return 1
}

_ga_gate_write() {
  local p="" root sroot sdir d c plug fpd t n=0 sr kind dr
  while [ $# -gt 0 ]; do
    case "$1" in
      --path) [ $# -ge 2 ] || break; p=$2; shift 2 ;;
      --path=*) p=${1#--path=}; shift ;;
      *) shift ;;
    esac
  done
  if [ -z "$p" ]; then
    _ga_gate_out deny "ga gate write: --path가 필요합니다"
    return 0
  fi
  # The tool writes through a symlink at the target: judge the file it points to.
  case "$p" in /*) ;; *) p=$PWD/$p ;; esac
  while [ -L "$p" ] && [ $n -lt 16 ]; do
    t=$(readlink "$p") || break
    case "$t" in /*) p=$t ;; *) p=${p%/*}/$t ;; esac
    n=$((n + 1))
  done
  c=$(ga_canon "$p") || { _ga_gate_out deny "경로를 정규화할 수 없어 막습니다: $p"; return 0; }
  d=$(dirname "$c")
  while [ ! -d "$d" ] && [ "$d" != / ]; do d=$(dirname "$d"); done
  root=$(ga_find_root "$d") || root=""
  sdir=$(ga_canon "$(ga_session_dir)") || sdir=""
  sroot=""
  [ -z "$sdir" ] || sroot=$(ga_find_root "$sdir") || sroot=""

  # 1. Always -- design or not, paused or not (P15, P20): nothing that guards a design and nothing
  #    that later runs outside the sandbox.
  fpd=$(ga_canon "$(ga_fp_dir)") || fpd=""
  if [ -n "$fpd" ] && _ga_under "$fpd" "$c"; then
    _ga_gate_out deny "상태 지문 저장 위치($fpd)는 ga만 씁니다. 쓰기 도구로는 고칠 수 없습니다"
    return 0
  fi
  if sr=$(_ga_state_component_root "$c"); then
    _ga_gate_out deny "설계 상태 폴더($sr/docs/architecture/.state)는 ga만 수정합니다. MCP 도구(ga_add, ga_update 등)를 쓰세요. 일시정지 중에도 막힙니다"
    return 0
  fi
  if _ga_git_exec_path "$c"; then
    _ga_gate_out deny "git 설정과 훅($c)은 격리 밖의 git이 실행하므로 쓰기 도구로 고칠 수 없습니다. 바꿔야 하면 사용자에게 직접 고쳐 달라고 요청하세요"
    return 0
  fi
  # The harness adapter names its own files: 3 = a file the harness runs outside the sandbox (always
  # protected), 0 = a settings file with the isolation settings (protected while a design exists).
  dr=${root:-${sroot:-$sdir}}
  kind=1
  [ -z "$dr" ] || { ga_enforce_protects "$dr" "$c"; kind=$?; }
  if [ "$kind" = 3 ]; then
    _ga_gate_out deny "하네스가 격리 밖에서 실행하는 파일($c)은 쓰기 도구로 고칠 수 없습니다. 바꿔야 하면 사용자에게 직접 고쳐 달라고 요청하세요"
    return 0
  fi

  # 2. While a design exists for the path or the session, paused or not (P21): the plugin (R34d)
  #    and the harness's settings files.
  if [ -n "$root$sroot" ]; then
    plug=$(_ga_plugin_root)
    if [ -n "$plug" ] && _ga_under "$plug" "$c"; then
      _ga_gate_out deny "설계가 있는 동안(일시정지 중에도) grounded-arch 플러그인 파일($plug)은 고칠 수 없습니다. 플러그인을 고쳐야 하면 사용자에게 직접 고쳐 달라고 요청하세요"
      return 0
    fi
    if [ "$kind" != 1 ]; then
      _ga_gate_out deny "설계가 있는 동안(일시정지 중에도) 하네스 설정 파일($c)은 고칠 수 없습니다(OS 격리 설정이 들어 있습니다). 격리 설정은 MCP 도구 \`ga_enforce\`가 씁니다. 다른 설정을 바꿔야 하면 사용자에게 직접 고쳐 달라고 요청하세요"
      return 0
    fi
  fi

  # 3. The path's own design.
  [ -n "$root" ] || { _ga_gate_out allow ""; return 0; }
  if _ga_under "$root/docs/architecture/.state" "$c"; then
    _ga_gate_out deny "설계 상태 파일은 ga만 수정합니다 (docs/architecture/.state/). MCP 도구(ga_add, ga_update 등)를 쓰세요"
    return 0
  fi
  # Spec 5.5 G-effect: while the state fingerprint mismatches, the design is locked -- paused too
  # (P21). The phase rules after it are off while paused.
  t=0
  ga_fp_check "$root" >/dev/null 2>&1 || t=$?
  if ga_paused_marker "$root"; then
    if [ "$t" = 1 ]; then _ga_gate_out deny "$(ga_fp_mismatch_reason)"; else _ga_gate_out allow ""; fi
    return 0
  fi
  if ! _ga_gate_state "$root"; then
    _ga_gate_out deny "$(_ga_corrupt_reason "$root")"
    return 0
  fi
  if [ "$t" = 1 ]; then _ga_gate_out deny "$(ga_fp_mismatch_reason)"; return 0; fi
  if [ "$GS_PAUSED" = true ]; then _ga_gate_out allow ""; return 0; fi
  if ! _ga_under "$root" "$c"; then _ga_gate_out allow ""; return 0; fi
  case "$GS_PHASE" in
    inputs | iterating | design-review)
      if _ga_under "$root/docs/architecture" "$c"; then
        _ga_gate_out allow ""
      else
        _ga_gate_out deny "현재 단계 $GS_PHASE: 설계 승인 전에는 docs/architecture/ 밖에 쓸 수 없습니다. 설계를 기록하거나 사용자에게 \`GA 일시정지\`를 요청하세요"
      fi
      ;;
    skeleton)
      if [ "$GS_MODE" = greenfield ] || _ga_under "$root/docs/architecture" "$c"; then
        _ga_gate_out allow ""
        return 0
      fi
      _ga_mapped "$root" "$c"
      case $? in
        0) _ga_gate_out allow "" ;;
        1) _ga_gate_out deny "현재 단계 skeleton: 대응표(mapping)에서 change가 new 또는 changed로 지정된 경로만 쓸 수 있습니다. 대응표에 경로를 추가하거나 사용자에게 \`GA 일시정지\`를 요청하세요" ;;
        *) _ga_gate_out deny "원장(ledger.json)을 읽을 수 없어 대응표를 확인할 수 없습니다. 원장을 고치거나 사용자에게 \`GA 일시정지\`를 요청하세요" ;;
      esac
      ;;
    *) _ga_gate_out allow "" ;;
  esac
}

# --- bash gate -----------------------------------------------------------------
# The command is not read (any arguments are ignored). With a design in force for the session
# directory, shell commands run only while the harness's OS isolation keeps them out of the state
# folder (adapters/$GA_HARNESS/enforce.sh status).

_ga_gate_bash() {
  local root st reason
  root=$(ga_find_root "$(ga_session_dir)") || { _ga_gate_out allow ""; return 0; }
  _ga_design_active "$root" || { _ga_gate_out allow ""; return 0; }
  if st=$(ga_enforce_status "$root"); then _ga_gate_out allow ""; return 0; fi
  reason=$(printf '%s' "$st" | jq -r '.reason // ""' 2>/dev/null)
  _ga_gate_out deny "설계가 진행 중이라 셸 명령은 OS 격리(상태 폴더 쓰기 금지) 안에서만 실행할 수 있는데, 지금 격리가 꺼져 있어 막습니다: ${reason:-격리 상태를 알 수 없음}. 복구: MCP 도구 \`ga_enforce\`로 격리 설정을 다시 설치하면 다음 명령부터 적용됩니다. 그래도 안 되면 사용자에게 알리고 \`GA 일시정지\`를 요청하세요"
}

# --- stop gate -------------------------------------------------------------------

_ga_gate_stop() {
  local root out rc msg ha=false frc erc reasons="" notice="" nl=$'\n'
  while [ $# -gt 0 ]; do
    case "$1" in
      --hook-active) [ $# -ge 2 ] || break; ha=$2; shift 2 ;;
      --hook-active=*) ha=${1#--hook-active=}; shift ;;
      *) shift ;;
    esac
  done
  # R24: never force a verifier runner (or anything it spawns) to continue.
  if [ "${GA_IN_RUNNER:-}" = 1 ]; then _ga_gate_out allow ""; return 0; fi
  root=$(ga_find_root "$(ga_session_dir)") || { _ga_gate_out allow ""; return 0; }
  # State fingerprint first: the snapshot below may write the state folder.
  frc=0
  ga_fp_check "$root" >/dev/null 2>&1 || frc=$?
  # P21: while paused only the phase rules are off -- the fingerprint check stays.
  if ga_paused_marker "$root"; then _ga_stop_fp_out "$frc" "$ha" "" ""; return 0; fi
  # R31b: an unreadable state.json is the user's to repair; blocking the agent cannot help.
  if ! _ga_gate_state "$root"; then _ga_gate_out allow ""; return 0; fi
  if [ "$GS_PAUSED" = true ]; then _ga_stop_fp_out "$frc" "$ha" "" ""; return 0; fi

  # Format errors: they keep blocking even with stop_hook_active (the agent can fix them).
  rc=0
  out=$( GA_ROOT=$root cmd_check --json 2>/dev/null ) || rc=$?
  case "$rc" in
    0) ;;
    1)
      msg=$(printf '%s' "$out" | jq -r '[.errors[0:10][] | "\(.id): \(.message)"] | join("\n")' 2>/dev/null)
      if [ -z "$msg" ]; then
        reasons="원장에 형식 오류가 있지만 목록을 읽지 못했습니다. ga check로 확인하고, 형식 오류를 고치거나, 근거가 없는 항목은 질문(MCP 도구 ga_add, kind question)으로 바꾸세요"
      else
        reasons="$msg
형식 오류를 고치거나, 근거가 없는 항목은 질문(MCP 도구 ga_add, kind question)으로 바꾸세요"
      fi
      ;;
    *) reasons="ga check가 내부 오류로 끝났습니다(원장을 읽을 수 없을 수 있습니다). docs/architecture/.state/ledger.json을 확인하거나 사용자에게 \`GA 일시정지\`를 요청하세요" ;;
  esac

  # G-effect: files changed since the phase began, against the phase allow-list. P19: the result
  # check cannot tell the user's edits from the agent's, so a violation set blocks once (the agent
  # shows it to the user and asks) and then reaches the user as a notice; approval stays blocked.
  erc=0
  out=$(ga_effect_check "$root" 2>/dev/null) || erc=$?
  if [ "$erc" != 0 ] && [ "$erc" != 1 ]; then
    if [ ! -f "$(ga_effect_snapshot_path "$root")" ]; then
      # P6: a design started before the check existed gets its baseline now, once.
      if ga_effect_snapshot "$root" >/dev/null 2>&1; then
        notice="파일 변경 기준(snapshot)이 없어서 지금 프로젝트 상태를 기준으로 기록했습니다. 그 전의 변경은 검사하지 않았습니다."
      else
        notice="파일 변경 기준(snapshot)이 없고 새로 기록하지도 못했습니다. 바뀐 파일을 검사할 수 없습니다. docs/architecture/.state/ 를 확인하세요."
      fi
      erc=0
    else
      out='{"changed":[],"violations":["결과 확인 불가: ga effect check 실패"]}'; erc=1
    fi
  fi
  if [ "$erc" = 0 ]; then
    ga_effect_reported_clear "$root"
  elif ga_effect_reported_is "$root" "$out"; then
    notice=${notice}${notice:+ }$(_ga_effect_violation_notice "$out")
  else
    reasons=${reasons}${reasons:+$nl}$(_ga_effect_violation_reason "$GS_PHASE" "$out")
    ga_effect_reported_set "$root" "$out"
  fi

  if [ -n "$reasons" ]; then
    _ga_stop_fp_out "$frc" "$ha" "$reasons" "$notice"
  else
    _ga_stop_fp_out "$frc" "$ha" "" "$notice"
  fi
}

# Adds the state fingerprint result to REASONS/NOTICE and prints the decision. Only the user can
# clear a mismatch (GA 상태승인), so it blocks once (the agent must tell the user) and then reaches
# the user as a notice.
_ga_stop_fp_out() { # FP_RC HOOK_ACTIVE REASONS NOTICE
  local reasons=$3 notice=$4 nl=$'\n'
  case "$1" in
    0) ;;
    1)
      if [ "$2" = true ]; then
        notice=${notice}${notice:+ }$(ga_fp_mismatch_reason)
      else
        reasons=${reasons}${reasons:+$nl}"$(ga_fp_mismatch_reason). 사용자만 풀 수 있으므로 종료는 이번 한 번만 막습니다: 사용자에게 알린 뒤 종료하세요"
      fi
      ;;
    2) notice=${notice}${notice:+ }"상태 지문 기록이 없습니다(설계 상태 폴더를 ga 밖에서 바꿨는지 확인할 기준이 없음). 사용자가 docs/architecture/.state/를 확인한 뒤 \`GA 상태승인\`을 입력하면 지금 상태가 기준이 됩니다. 그 전에는 승인이 막힙니다." ;;
    *) notice=${notice}${notice:+ }"shasum이나 sha256sum이 없어 상태 지문을 확인할 수 없습니다. 둘 중 하나를 설치하세요. 그 전에는 승인이 막힙니다." ;;
  esac
  if [ -n "$reasons" ]; then
    _ga_gate_out block "$reasons" "$notice"
  else
    _ga_gate_out allow "" "$notice"
  fi
}

# Block reason for changed files outside the phase allow-list (at most 20 listed). It never tells
# the agent to revert: the files may be the user's work (P19).
_ga_effect_violation_reason() { # PHASE CHECK_JSON
  local list
  list=$(ga_effect_list "$2")
  echo "현재 단계 ${1}의 허용 범위 밖에서 파일이 바뀌었습니다: ${list:-(목록을 읽지 못함)}. 누가 바꿨는지는 결과 확인으로 알 수 없습니다. 이 목록을 사용자에게 그대로 보여 주고, 되돌릴지 아니면 사용자가 'GA 상태승인'을 입력해 지금 파일 상태를 받아들일지 물어보세요. 사용자가 답하기 전에는 파일을 되돌리지 마세요. 그때까지 승인은 막힙니다. 같은 목록으로는 종료를 다시 막지 않습니다"
}

# The same set again: one line for the user.
_ga_effect_violation_notice() { # CHECK_JSON
  echo "허용 범위 밖 파일 변경이 남아 있습니다: $(ga_effect_list "$1"). 되돌리거나 'GA 상태승인'으로 받아들이기 전에는 승인이 막힙니다."
}
