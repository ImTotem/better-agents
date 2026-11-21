# grounded-arch gates: ga gate write|bash|stop. Sourced; bash 3.2 compatible.
# Every gate prints ONE JSON line {"decision":"allow|deny|block","reason":"..."} and exits 0.
# Internal errors fail closed (deny for write/bash, block for stop).

_ga_gate_out() { # DECISION REASON
  jq -cn --arg d "$1" --arg r "$2" '{decision:$d,reason:$r}'
}

# Runs a gate function in a subshell (so ga_die/exit cannot escape) and guarantees
# one valid decision line; anything else becomes the fail-closed decision.
_ga_gate_run() { # FAIL_DECISION FUNC ARGS...
  local fail=$1 fn=$2 out
  shift 2
  out=$( "$fn" "$@" 2>/dev/null )
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
    *) ga_die "사용법: ga gate write --path P | bash --command C | stop [--hook-active true|false]" 2 ;;
  esac
}

# True if P equals X or lies below X (component-wise: /a/docsX is not under /a/docs).
_ga_under() { # X P
  local x=${1%/}
  [ "$2" = "$x" ] && return 0
  case "$2" in "$x"/*) return 0 ;; esac
  return 1
}

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

_ga_corrupt_reason() { # ROOT
  echo "설계 상태 파일을 읽을 수 없습니다: $1/docs/architecture/.state/state.json 이(가) 올바른 JSON이 아니거나 값이 잘못되었습니다. \`docs/architecture/.state/state.json\`을 고치거나 \`paused\`를 true로 바꾸세요"
}

_ga_gate_write() {
  local p="" root d c ap st mp m
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
  c=$(ga_canon "$p") || { _ga_gate_out deny "경로를 정규화할 수 없어 막습니다: $p"; return 0; }
  d=$(dirname "$c")
  while [ ! -d "$d" ] && [ "$d" != / ]; do d=$(dirname "$d"); done
  root=$(ga_find_root "$d") || { _ga_gate_out allow ""; return 0; }
  if ! _ga_gate_state "$root"; then
    _ga_gate_out deny "$(_ga_corrupt_reason "$root")"
    return 0
  fi
  if [ "$GS_PAUSED" = true ]; then _ga_gate_out allow ""; return 0; fi
  ap=$root/docs/architecture
  st=$ap/.state
  if _ga_under "$st" "$c"; then
    _ga_gate_out deny "설계 상태 파일은 ga만 수정합니다 (docs/architecture/.state/). ga 명령(ga add, ga update 등)을 쓰세요"
    return 0
  fi
  if ! _ga_under "$root" "$c"; then _ga_gate_out allow ""; return 0; fi
  case "$GS_PHASE" in
    inputs | iterating | design-review)
      if _ga_under "$ap" "$c"; then
        _ga_gate_out allow ""
      else
        _ga_gate_out deny "현재 단계 $GS_PHASE: 설계 승인 전에는 docs/architecture/ 밖에 쓸 수 없습니다. 설계를 기록하거나 사용자에게 \`GA 일시정지\`를 요청하세요"
      fi
      ;;
    skeleton)
      if [ "$GS_MODE" = greenfield ] || _ga_under "$ap" "$c"; then
        _ga_gate_out allow ""
        return 0
      fi
      mp=$(jq -r '.items[] | select(.kind == "mapping" and (.change == "new" or .change == "changed")) | .path' "$st/ledger.json" 2>/dev/null) || {
        _ga_gate_out deny "원장(ledger.json)을 읽을 수 없어 대응표를 확인할 수 없습니다. 원장을 고치거나 사용자에게 \`GA 일시정지\`를 요청하세요"
        return 0
      }
      while IFS= read -r m; do
        [ -n "$m" ] || continue
        if [ "$(ga_canon "$root/$m" 2>/dev/null)" = "$c" ]; then
          _ga_gate_out allow ""
          return 0
        fi
      done <<EOF
$mp
EOF
      _ga_gate_out deny "현재 단계 skeleton: 대응표(mapping)에서 change가 new 또는 changed로 지정된 경로만 쓸 수 있습니다. 대응표에 경로를 추가하거나 사용자에게 \`GA 일시정지\`를 요청하세요"
      ;;
    *) _ga_gate_out allow "" ;;
  esac
}

# --- bash gate ---------------------------------------------------------------

# Prints TEXT with heredoc bodies removed (marker line kept, terminator line dropped).
_ga_strip_heredocs() { # TEXT
  local line tag="" dash=0 out="" nl=$'\n' t re
  re='(^|[^<])<<(-?)[[:space:]]*\\?['"'"'"]?([A-Za-z_][A-Za-z0-9_]*)'
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -n "$tag" ]; then
      t=$line
      [ "$dash" = 1 ] && t=${t#"${t%%[!$'\t']*}"}
      [ "$t" = "$tag" ] && tag=""
      continue
    fi
    out=$out$line$nl
    # A line with (( is arithmetic (e.g. $((1<<n))), not a heredoc.
    if [[ $line != *'(('* ]] && [[ $line =~ $re ]]; then
      tag=${BASH_REMATCH[3]}
      if [ -n "${BASH_REMATCH[2]}" ]; then dash=1; else dash=0; fi
    fi
  done <<EOF
$1
EOF
  printf '%s' "$out"
}

# Prints TEXT with one segment per line (split on ; && || | ( ) backtick newline).
_ga_split_segments() { # TEXT
  local t=$1 nl=$'\n' bt='`'
  t=${t//>|/>}
  t=${t//&&/$nl}
  t=${t//||/$nl}
  t=${t//;/$nl}
  t=${t//|/$nl}
  t=${t//(/$nl}
  t=${t//)/$nl}
  t=${t//$bt/$nl}
  printf '%s\n' "$t"
}

# Sets CW (command word, basename, quotes stripped) and CW_IDX for words[] (global array).
_ga_cmdword() {
  local i=0 w wc prefix=0
  CW=""; CW_IDX=-1
  while [ $i -lt ${#words[@]} ]; do
    w=${words[$i]}
    wc=${w//[\'\"\\]/}
    i=$((i + 1))
    if [[ $wc =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then continue; fi
    if [[ $wc =~ ^[0-9]*[\<\>] ]]; then continue; fi
    case "$wc" in
      '{' | '!' | then | do | else | elif | if | while | until) continue ;;
      sudo | doas | env | command | exec | nohup | time | builtin | xargs | nice) prefix=1; continue ;;
      -*) if [ $prefix = 1 ]; then continue; fi ;;
    esac
    CW=${wc##*/}
    CW_IDX=$((i - 1))
    return 0
  done
  return 1
}

# Checks a command segment's command word for write patterns. Sets SEG_MATCH ("" if none).
_ga_seg_command_match() {
  local j w wc sub="" skip=0
  SEG_MATCH=""
  case "$CW" in
    tee | cp | mv | rm | touch | ln | dd | truncate | install | patch) SEG_MATCH=$CW ;;
    sed)
      for w in "${words[@]}"; do
        wc=${w//[\'\"]/}
        if [[ $wc =~ ^-[nEersuz]*i ]] || [[ $wc == --in-place* ]]; then SEG_MATCH="sed -i"; break; fi
      done ;;
    perl)
      for w in "${words[@]}"; do
        wc=${w//[\'\"]/}
        if [[ $wc =~ ^-[0-9lanpwsSTtuUWXcCdDfFhIvVxy]*i ]]; then SEG_MATCH="perl -i"; break; fi
      done ;;
    find)
      for w in "${words[@]}"; do
        case "${w//[\'\"]/}" in -delete | -exec | -execdir | -ok | -okdir) SEG_MATCH="find $w"; break ;; esac
      done ;;
    git)
      j=$((CW_IDX + 1))
      while [ $j -lt ${#words[@]} ]; do
        w=${words[$j]}
        j=$((j + 1))
        if [ $skip = 1 ]; then skip=0; continue; fi
        case "$w" in
          -C | -c | --git-dir | --work-tree | --namespace) skip=1; continue ;;
          -*) continue ;;
        esac
        sub=$w
        break
      done
      case "$sub" in apply | checkout | restore | reset | rm | mv | stash) SEG_MATCH="git $sub" ;; esac ;;
  esac
}

# Scans redirects of segment $1. Sets (cumulatively) R_BAD (first non-exempt target),
# R_STATE (1 if a target is inside .state) and R_ANYBAD (1 if any non-exempt target).
# Quoted '>' characters (e.g. echo "a > b") can produce false denies; accepted (best effort).
_ga_scan_redirects() { # SEG ROOT
  local rest=$1 root=$2 re t amp c
  re='^[^>]*>(>?)(&?)[[:space:]]*([^[:space:]<>]*)(.*)$'
  while [[ $rest =~ $re ]]; do
    amp=${BASH_REMATCH[2]}
    t=${BASH_REMATCH[3]}
    rest=${BASH_REMATCH[4]}
    t=${t//[\'\"]/}
    if [ -n "$amp" ]; then
      if [ -z "$t" ] || [[ $t =~ ^([0-9]+|-)$ ]]; then continue; fi
    fi
    [ -n "$t" ] || continue
    case "$t" in
      /dev/null) continue ;;
      '$TMPDIR/'* | '${TMPDIR}/'*) continue ;;
      '$HOME/'*) t=$HOME/${t#\$HOME/} ;;
      '${HOME}/'*) t=$HOME/${t#\$\{HOME\}/} ;;
      '~/'*) t=$HOME/${t#\~/} ;;
    esac
    if ! c=$(ga_canon "$t" 2>/dev/null) || [ -z "$c" ]; then
      [ -n "$R_BAD" ] || R_BAD="> $t"
      R_ANYBAD=1
      continue
    fi
    if _ga_under "$root/docs/architecture/.state" "$c"; then
      [ -n "$R_BAD" ] || R_BAD="> $t"
      R_STATE=1; R_ANYBAD=1
    elif _ga_under "$root/docs/architecture" "$c"; then
      continue
    elif _ga_under "$root" "$c"; then
      [ -n "$R_BAD" ] || R_BAD="> $t"
      R_ANYBAD=1
    fi
  done
}

_ga_gate_bash() {
  local cmd="" root phase body segs seg nl=$'\n' ga_sub
  local re_internal='(^|[;&|/[:space:]])ga[[:space:]]+(--root[= ][^[:space:]]+[[:space:]]+)?(user-command|hook)([^A-Za-z0-9_-]|$)'
  while [ $# -gt 0 ]; do
    case "$1" in
      --command) [ $# -ge 2 ] || break; cmd=$2; shift 2 ;;
      --command=*) cmd=${1#--command=}; shift ;;
      *) shift ;;
    esac
  done
  root=$(ga_find_root "$PWD") || { _ga_gate_out allow ""; return 0; }
  if ! _ga_gate_state "$root"; then
    _ga_gate_out deny "$(_ga_corrupt_reason "$root")"
    return 0
  fi
  if [ "$GS_PAUSED" = true ]; then _ga_gate_out allow ""; return 0; fi
  phase=$GS_PHASE

  # (a) internal commands are never callable from Bash, in any phase.
  if [[ $cmd =~ $re_internal ]] || [[ $cmd == *adapters/claude-code/hook.sh* ]]; then
    _ga_gate_out deny "현재 단계 $phase: ga 내부 명령(user-command, hook)과 훅 스크립트는 직접 호출할 수 없습니다. 사용자만 'GA ...' 명령으로 호출합니다"
    return 0
  fi

  set -f
  body=$(_ga_strip_heredocs "$cmd")
  segs=$(_ga_split_segments "$body")

  local CW CW_IDX SEG_MATCH match="" state_hit="" mention_any=0 cd_seen=0
  local R_BAD="" R_STATE=0 R_ANYBAD=0 seg_state skipcmd=0
  local -a words
  while IFS= read -r seg; do
    words=($seg)
    [ ${#words[@]} -gt 0 ] || continue
    _ga_cmdword || continue
    skipcmd=0
    if [ "$CW" = ga ]; then
      ga_sub=""
      local k=$((CW_IDX + 1))
      while [ $k -lt ${#words[@]} ]; do
        case "${words[$k]}" in
          --root) k=$((k + 2)); continue ;;
          --root=*) k=$((k + 1)); continue ;;
        esac
        ga_sub=${words[$k]}
        break
      done
      case "$ga_sub" in
        add | update | ask | resolve | render | check | status | verify | dispute | init | version | rule | billing | context | gate) skipcmd=1 ;;
      esac
    fi
    seg_state=0
    case "$seg" in *.state*) seg_state=1; mention_any=1 ;; esac
    case "$CW" in cd | pushd) cd_seen=1 ;; esac
    # R10: public ga segments skip only the command-word patterns; redirects are still scanned.
    if [ $skipcmd = 1 ]; then SEG_MATCH=""; else _ga_seg_command_match; fi
    if [ -n "$SEG_MATCH" ]; then
      [ -n "$match" ] || match=$SEG_MATCH
      [ $seg_state = 1 ] && [ -z "$state_hit" ] && state_hit=$SEG_MATCH
    fi
    _ga_scan_redirects "$seg" "$root"
  done <<EOF
$segs
EOF
  set +f

  # (b) writing under .state in any phase: a command-word write in a segment that
  # mentions .state, a redirect into .state, or (after a cd) any redirect into the project.
  if [ -z "$state_hit" ]; then
    if [ "$R_STATE" = 1 ]; then state_hit=$R_BAD
    elif [ $mention_any = 1 ] && [ $cd_seen = 1 ] && [ "$R_ANYBAD" = 1 ]; then state_hit=$R_BAD
    fi
  fi
  if [ -n "$state_hit" ]; then
    _ga_gate_out deny "현재 단계 $phase: 설계 상태(docs/architecture/.state/)를 쓰는 명령은 막혀 있습니다 (감지된 패턴: $state_hit). 상태는 ga 명령으로만 바꿉니다. 필요하면 사용자에게 \`GA 일시정지\`를 요청하세요"
    return 0
  fi

  case "$phase" in
    inputs | iterating | design-review)
      [ -n "$match" ] || match=$R_BAD
      if [ -n "$match" ]; then
        _ga_gate_out deny "현재 단계 $phase: 설계 승인 전에는 파일을 쓰는 명령을 실행할 수 없습니다 (감지된 패턴: $match). 설계는 docs/architecture/ 안에 기록하거나 사용자에게 \`GA 일시정지\`를 요청하세요"
        return 0
      fi
      ;;
  esac
  _ga_gate_out allow ""
}

# --- stop gate ---------------------------------------------------------------

_ga_gate_stop() {
  local root out rc msg
  root=$(ga_find_root "$PWD") || { _ga_gate_out allow ""; return 0; }
  if ! _ga_gate_state "$root"; then
    _ga_gate_out block "$(_ga_corrupt_reason "$root")"
    return 0
  fi
  if [ "$GS_PAUSED" = true ]; then _ga_gate_out allow ""; return 0; fi
  # --hook-active is deliberately ignored: remaining format errors keep blocking.
  rc=0
  out=$( GA_ROOT=$root cmd_check --json 2>/dev/null ) || rc=$?
  case "$rc" in
    0) _ga_gate_out allow "" ;;
    1)
      msg=$(printf '%s' "$out" | jq -r '[.errors[0:10][] | "\(.id): \(.message)"] | join("\n")' 2>/dev/null)
      if [ -z "$msg" ]; then
        _ga_gate_out block "원장에 형식 오류가 있지만 목록을 읽지 못했습니다. ga check로 확인하고, 형식 오류를 고치거나, 근거가 없는 항목은 질문(ga add question)으로 바꾸세요"
      else
        _ga_gate_out block "$msg
형식 오류를 고치거나, 근거가 없는 항목은 질문(ga add question)으로 바꾸세요"
      fi
      ;;
    *) _ga_gate_out block "ga check가 내부 오류로 끝났습니다(원장을 읽을 수 없을 수 있습니다). docs/architecture/.state/ledger.json을 확인하거나 사용자에게 \`GA 일시정지\`를 요청하세요" ;;
  esac
}
