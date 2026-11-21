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
_ga_lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Comparison is case-folded: APFS is case-insensitive, so docs/Architecture/.STATE is the
# same place as docs/architecture/.state (fail-closed direction for the .state deny).
_ga_under() { # X P
  local x y
  x=$(_ga_lc "${1%/}")
  y=$(_ga_lc "$2")
  [ "$y" = "$x" ] && return 0
  case "$y" in "$x"/*) return 0 ;; esac
  return 1
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

# R31c: the agent cannot repair state.json (it may not write under .state); the user can.
_ga_corrupt_reason() { # ROOT
  echo "설계 상태 파일을 읽을 수 없습니다: $1/docs/architecture/.state/state.json 이(가) 올바른 JSON이 아니거나 값이 잘못되었습니다. 에이전트는 이 파일을 고칠 수 없습니다. 사용자에게 알리세요: 사용자가 \`GA 일시정지\`를 입력하거나, state.json을 고치거나 백업에서 복원하면 풀립니다"
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

_ga_gate_write() {
  local p="" root proot d c ap st plug
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
  root=$(ga_find_root "$d") || root=""
  # R34d: the plugin (rules, gates, verifier, runner records) is read-only while a design is
  # active -- found from the path or from the session directory -- and not paused.
  plug=$(_ga_plugin_root)
  if [ -n "$plug" ] && _ga_under "$plug" "$c"; then
    proot=$root
    [ -n "$proot" ] || proot=$(ga_find_root "$PWD") || proot=""
    if [ -n "$proot" ] && ! ga_paused_marker "$proot" && { ! _ga_gate_state "$proot" || [ "$GS_PAUSED" != true ]; }; then
      _ga_gate_out deny "설계가 진행 중인 동안 grounded-arch 플러그인 파일($plug)은 고칠 수 없습니다. 플러그인을 고쳐야 하면 사용자에게 \`GA 일시정지\`를 요청하세요"
      return 0
    fi
  fi
  [ -n "$root" ] || { _ga_gate_out allow ""; return 0; }
  if ga_paused_marker "$root"; then _ga_gate_out allow ""; return 0; fi
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

# --- bash gate ---------------------------------------------------------------

# Shells and interpreters: a heredoc fed to one of them is code, so its body is scanned (R35-2).
_ga_is_shell() { case "$1" in bash | sh | zsh | dash | ksh | fish | python | python[0-9]* | node | perl | ruby | php) return 0 ;; esac; return 1; }

# True when any command word on LINE is a shell or interpreter (e.g. `bash <<EOF`, `cat <<EOF | sh`).
_ga_line_feeds_shell() { # LINE
  local seg CW CW_IDX
  local -a words
  while IFS= read -r seg; do
    words=($seg)
    [ ${#words[@]} -gt 0 ] || continue
    if _ga_cmdword && _ga_is_shell "$CW"; then return 0; fi
  done <<EOF
$(_ga_split_segments "$1")
EOF
  return 1
}

# Prints TEXT with heredoc bodies removed (marker line kept, terminator line dropped).
# A body fed to a shell or interpreter is kept and scanned like command lines.
_ga_strip_heredocs() { # TEXT
  local line tag="" dash=0 out="" nl=$'\n' t re
  # tag = identifier, optionally quoted; it must end at whitespace, ; | & < > ) or EOL
  # (so <<'END-OF' or <<EOF-1 are NOT treated as heredocs: the body stays scanned).
  re='(^|[^<])<<(-?)[[:space:]]*\\?(['"'"'"]?)([A-Za-z_][A-Za-z0-9_]*)(['"'"'"]?)([[:space:];|&<>)]|$)'
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -n "$tag" ]; then
      t=$line
      [ "$dash" = 1 ] && t=${t#"${t%%[!$'\t']*}"}
      [ "$t" = "$tag" ] && tag=""
      continue
    fi
    out=$out$line$nl
    # A line with (( is arithmetic (e.g. $((1<<n))), not a heredoc.
    if [[ $line != *'(('* ]] && [[ $line =~ $re ]] && [ "${BASH_REMATCH[3]}" = "${BASH_REMATCH[5]}" ]; then
      tag=${BASH_REMATCH[4]}
      if [ -n "${BASH_REMATCH[2]}" ]; then dash=1; else dash=0; fi
      _ga_line_feeds_shell "$line" && tag=""
    fi
  done <<EOF
$1
EOF
  printf '%s' "$out"
}

# Prints TEXT with one segment per line (split on ; && || | ( ) backtick newline).
_ga_split_segments() { # TEXT
  local t=$1 nl=$'\n' bt='`' p1=$'\001' p2=$'\002' p3=$'\003'
  t=${t//>|/>}
  t=${t//&&/$nl}
  # protect >& &> <& (fd duplication / both-redirect), then a lone & is a separator
  t=${t//>&/$p1}
  t=${t//&>/$p2}
  t=${t//<&/$p3}
  t=${t//&/$nl}
  t=${t//$p1/>&}
  t=${t//$p2/&>}
  t=${t//$p3/<&}
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
# git clean and git stash -u/-a (they delete untracked files such as .state) set T_GIT.
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
      case "$sub" in apply | checkout | restore | reset | rm | mv | stash | clean) SEG_MATCH="git $sub" ;; esac
      if [ "$sub" = clean ]; then
        T_GIT=${T_GIT:-"git clean"}
      elif [ "$sub" = stash ]; then
        while [ $j -lt ${#words[@]} ]; do
          case "${words[$j]//[\'\"]/}" in -u | --include-untracked | -a | --all | -[A-Za-z]*[ua]*) T_GIT=${T_GIT:-"git stash ${words[$j]}"} ;; esac
          j=$((j + 1))
        done
      fi ;;
  esac
}

# Sets TG (target words of a write command) and TG_KIND (w = writes, p = .state/plugin
# protection only). Returns 1 for commands whose targets are not determined here.
_ga_seg_targets() {
  local j=$((CW_IDX + 1)) w wc skip=0 optsv="" mode=all endopt=0 script=0 last="" tdir=0 nx
  local re_redir='^[0-9]*([<>]|&>)' re_redir_alone='^[0-9]*(>>?|<<?<?|&>>?|>&|<&)$'
  TG=(); TG_KIND=w
  if [ "$CW" = git ]; then
    # git checkout/restore PATHS rewrite files (including a tracked .state) from another revision.
    case "$SEG_MATCH" in "git checkout" | "git restore") ;; *) return 1 ;; esac
    local first=1 sub=0
    while [ $j -lt ${#words[@]} ]; do
      w=${words[$j]}; wc=${w//[\'\"]/}; j=$((j + 1))
      if [ $skip = 1 ]; then skip=0; continue; fi
      if [ $sub = 0 ]; then
        case "$wc" in -C | -c | --git-dir | --work-tree | --namespace) skip=1 ;; -*) ;; *) sub=1 ;; esac
        continue
      fi
      if [ $endopt = 0 ]; then
        case "$wc" in
          --) endopt=1; continue ;;
          -s | --source | -b | -B | --orphan) skip=1; continue ;;
          -*) continue ;;
        esac
        # checkout: the first operand before -- is the branch/commit
        if [ "$SEG_MATCH" = "git checkout" ] && [ $first = 1 ]; then first=0; continue; fi
      fi
      TG+=("$w")
    done
    return 0
  fi
  case "$CW" in
    tee | rm | touch | truncate | mv) ;;
    mkdir | rmdir) TG_KIND=p ;;
    cp | ln | install) mode=last ;;
    dd) mode=dd ;;
    sed) [ "$SEG_MATCH" = "sed -i" ] || return 1; mode=script ;;
    perl) [ "$SEG_MATCH" = "perl -i" ] || return 1; mode=script ;;
    *) return 1 ;;
  esac
  case "$CW" in
    truncate) optsv=" -s -r --size --reference " ;;
    cp | ln | mv) optsv=" -S --suffix " ;;
    install) optsv=" -m -o -g -S --mode --owner --group --suffix " ;;
    touch) optsv=" -t -d -r --date --reference " ;;
    mkdir) optsv=" -m --mode " ;;
  esac
  while [ $j -lt ${#words[@]} ]; do
    w=${words[$j]}
    j=$((j + 1))
    wc=${w//[\'\"]/}
    if [ $skip = 1 ]; then skip=0; continue; fi
    # Redirections are scanned separately; an operator alone takes the next word as operand.
    if [[ $wc =~ $re_redir ]]; then
      [[ $wc =~ $re_redir_alone ]] && skip=1
      continue
    fi
    if [ $endopt = 0 ]; then
      case "$wc" in
        --) endopt=1; continue ;;
        -t | --target-directory)
          case "$CW" in cp | ln | install | mv) TG+=("${words[$j]}"); tdir=1; skip=1; continue ;; esac ;;
        --target-directory=*) TG+=("${wc#*=}"); tdir=1; continue ;;
      esac
      case "$wc" in
        -*)
          if [ "$mode" = script ]; then
            # -e SCRIPT / -f FILE (also combined, e.g. -ne): the next word is not a file.
            if [[ $wc != --* ]] && { { [ "$CW" = sed ] && [[ $wc =~ ^-[A-Za-z]*[ef]$ ]]; } || { [ "$CW" = perl ] && [[ $wc =~ ^-[A-Za-z0-9]*[eE]$ ]]; }; }; then
              script=1; skip=1; continue
            fi
            case "$wc" in --expression=* | --file=*) script=1 ;; esac
            # BSD sed -i takes a separate suffix word ('' or .bak).
            if [ "$CW" = sed ] && [ "$wc" = -i ]; then
              nx=${words[$j]-}; nx=${nx//[\'\"]/}
              if [ -z "$nx" ] || [[ $nx == .* ]]; then skip=1; fi
            fi
            continue
          fi
          case "$optsv" in *" $wc "*) skip=1 ;; esac
          continue ;;
      esac
    fi
    case "$mode" in
      all) TG+=("$w") ;;
      last) last=$w ;;
      dd) case "$wc" in of=*) TG+=("${wc#of=}") ;; esac ;;
      script) if [ $script = 0 ]; then script=1; else TG+=("$w"); fi ;;
    esac
  done
  [ -n "$last" ] && [ $tdir = 0 ] && TG+=("$last")
  return 0
}

_ga_t_state() { T_STATE=${T_STATE:-$1}; }

# Classifies one write target RAW of a command (R32a/c, R34d). Uses ST (the .state dir),
# PLUG (plugin root), root, CD_SEEN, TMPDIR_REASSIGNED. Sets T_STATE (target is .state, inside
# it, or an ancestor of it), T_PLUGIN (inside or an ancestor of the plugin), T_UNRES (an
# unresolvable write target) and appends in-root, non-docs/architecture write targets to TL.
_ga_check_target() { # RAW KIND
  local raw=$1 t c p lc rel
  t=${raw//[\'\"]/}
  [ -n "$t" ] || return 0
  case "$t" in
    /dev/null | /dev/stdout | /dev/stderr) return 0 ;;
    '$TMPDIR/'* | '${TMPDIR}/'*) [ "$TMPDIR_REASSIGNED" = 1 ] || t=${TMPDIR:-/tmp}/${t#*/} ;;
    '$HOME/'*) t=$HOME/${t#\$HOME/} ;;
    '${HOME}/'*) t=$HOME/${t#\$\{HOME\}/} ;;
    '~/'*) t=$HOME/${t#\~/} ;;
    '~' | '$HOME' | '${HOME}') t=$HOME ;;
  esac
  case "$t" in
    *'$'* | *'*'* | *'?'* | *'['* | *'{'* | *'`'*)
      # Unexpandable: protect by text and by the literal directory prefix.
      lc=$(_ga_lc "$t")
      case "$lc" in *architecture*) _ga_t_state "$raw" ;; esac
      p=${t%%[\$\*\?\[\{\`]*}
      case "$p" in */*) p=${p%/*}; [ -n "$p" ] || p=/ ;; *) p=. ;; esac
      if [ "$CD_SEEN" = 1 ]; then case "$p" in /*) ;; *) _ga_t_state "$raw" ;; esac; fi
      c=$(ga_canon "$p" 2>/dev/null) || c=""
      if [ "$CD_SEEN" = 1 ]; then case "$p" in /*) ;; *) c="" ;; esac; fi
      if [ -n "$c" ]; then
        _ga_under "$c" "$ST" && _ga_t_state "$raw"
        { _ga_under "$c" "$PLUG" || _ga_under "$PLUG" "$c"; } && T_PLUGIN=${T_PLUGIN:-$raw}
        # a literal directory outside the project cannot expand into it
        _ga_under "$root" "$c" || _ga_under "$c" "$root" || return 0
      fi
      [ "$2" = w ] && T_UNRES=${T_UNRES:-$raw}
      return 0 ;;
  esac
  if [ "$CD_SEEN" = 1 ]; then
    case "$t" in
      /*) ;;
      *)
        # After cd/pushd a relative target cannot be resolved; refuse the obvious .state ancestors.
        rel=${t#./}; rel=${rel%/}; lc=$(_ga_lc "$rel")
        case "/$lc/" in */../* | /./ | //) _ga_t_state "$raw" ;; esac
        case "$lc" in
          docs | docs/architecture | architecture | .state | architecture/.state | docs/architecture/.state | */docs | */docs/architecture | */architecture | */.state) _ga_t_state "$raw" ;;
        esac
        [ "$2" = w ] && T_UNRES=${T_UNRES:-$raw}
        return 0 ;;
    esac
  fi
  c=$(ga_canon "$t" 2>/dev/null) || c=""
  if [ -z "$c" ]; then [ "$2" = w ] && T_UNRES=${T_UNRES:-$raw}; return 0; fi
  { _ga_under "$c" "$ST" || _ga_under "$ST" "$c"; } && _ga_t_state "$raw"
  { _ga_under "$PLUG" "$c" || _ga_under "$c" "$PLUG"; } && T_PLUGIN=${T_PLUGIN:-$raw}
  if [ "$2" = w ] && _ga_under "$root" "$c" && ! _ga_under "$root/docs/architecture" "$c"; then
    TL=$TL$c$'\n'
  fi
  return 0
}

# Scans redirects of segment $1. Sets (cumulatively) R_BAD (first non-exempt target),
# R_STATE (1 if a target is inside .state) and R_ANYBAD (1 if any non-exempt target), and
# feeds the same targets to the plugin/brownfield checks (T_PLUGIN, T_UNRES, TL).
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
      '$TMPDIR/'* | '${TMPDIR}/'*)
        # expanded from the gate's own env (the command may reassign TMPDIR: not exempt then)
        if [ "$TMPDIR_REASSIGNED" = 1 ]; then t='$TMPDIR_REASSIGNED'; else t=${TMPDIR:-/tmp}/${t#*/}; fi ;;
      '$HOME/'*) t=$HOME/${t#\$HOME/} ;;
      '${HOME}/'*) t=$HOME/${t#\$\{HOME\}/} ;;
      '~/'*) t=$HOME/${t#\~/} ;;
    esac
    # Unexpandable targets (variables, globs, braces, backticks) are never exempt.
    case "$t" in
      *'$'* | *'*'* | *'?'* | *'['* | *'{'* | *'`'*)
        [ -n "$R_BAD" ] || R_BAD="> $t"
        R_ANYBAD=1
        T_UNRES=${T_UNRES:-"> $t"}
        # a glob/variable inside docs/architecture/... may expand to .state: treat as a .state write
        case "$(_ga_lc "$t")" in *architecture/*) R_STATE=1 ;; esac
        continue ;;
    esac
    # After a cd/pushd in the same command, relative targets cannot be resolved: not exempt.
    if [ "$CD_SEEN" = 1 ]; then
      case "$t" in
        /*) ;;
        *) [ -n "$R_BAD" ] || R_BAD="> $t"; R_ANYBAD=1; T_UNRES=${T_UNRES:-"> $t"}; continue ;;
      esac
    fi
    if ! c=$(ga_canon "$t" 2>/dev/null) || [ -z "$c" ]; then
      [ -n "$R_BAD" ] || R_BAD="> $t"
      R_ANYBAD=1
      T_UNRES=${T_UNRES:-"> $t"}
      continue
    fi
    _ga_under "$PLUG" "$c" && T_PLUGIN=${T_PLUGIN:-"> $t"}
    if _ga_under "$root/docs/architecture/.state" "$c"; then
      [ -n "$R_BAD" ] || R_BAD="> $t"
      R_STATE=1; R_ANYBAD=1
    elif _ga_under "$root/docs/architecture" "$c"; then
      continue
    elif _ga_under "$root" "$c"; then
      [ -n "$R_BAD" ] || R_BAD="> $t"
      R_ANYBAD=1
      TL=$TL$c$'\n'
    fi
  done
}

# Scans one command segment (loop body of the bash gate; uses the gate's locals).
# DEPTH bounds the recursion into `bash -c STRING` / `eval STRING`.
_ga_bash_seg() { # SEG DEPTH
  local seg=$1 depth=${2:-0} k t sub skipcmd=0
  local -a words
  words=($seg)
  [ ${#words[@]} -gt 0 ] || return 0
  CW=""; SEG_MATCH=""
  # Segments without a command word (>file, X=1 >file) still get their redirects scanned.
  if _ga_cmdword; then
    case "$CW" in '$'* | '`'*) ga_seen=1 ;; esac
    if [ "$CW" = ga ]; then
      ga_seen=1
      local ga_sub=""
      k=$((CW_IDX + 1))
      while [ $k -lt ${#words[@]} ]; do
        case "${words[$k]}" in
          --root) k=$((k + 2)); continue ;;
          --root=*) k=$((k + 1)); continue ;;
        esac
        ga_sub=${words[$k]//[\'\"\\]/}
        break
      done
      case "$ga_sub" in
        user-command | hook) [ -n "$internal" ] || internal=$ga_sub ;;
        # R10: public ga segments skip only the command-word patterns.
        add | update | ask | resolve | render | check | status | verify | dispute | init | version | rule | billing | context | gate) skipcmd=1 ;;
      esac
    fi
    if [ $skipcmd = 0 ]; then
      _ga_seg_command_match
      if [ -n "$SEG_MATCH" ] && [ -z "$match" ]; then match=$SEG_MATCH; fi
      if _ga_seg_targets; then
        for t in ${TG[@]+"${TG[@]}"}; do _ga_check_target "$t" "$TG_KIND"; done
      fi
    fi
    # `sh -c STRING` and `eval STRING`: the string is a command line too.
    if [ "$depth" -lt 3 ]; then
      case "$CW" in
        bash | sh | zsh | dash | ksh | fish)
          k=$((CW_IDX + 1))
          while [ $k -lt ${#words[@]} ]; do
            if [[ ${words[$k]//[\'\"]/} =~ ^-[A-Za-z]*c$ ]]; then
              sub="${words[*]:$((k + 1))}"
              _ga_bash_seg "${sub//[\'\"]/}" $((depth + 1))
              break
            fi
            k=$((k + 1))
          done ;;
        eval)
          sub="${words[*]:$((CW_IDX + 1))}"
          _ga_bash_seg "${sub//[\'\"]/}" $((depth + 1)) ;;
      esac
    fi
  fi
  _ga_scan_redirects "$seg" "$root"
}

_ga_gate_bash() {
  local cmd="" root phase body segs seg corrupt=0 where
  local re_internal='(^|[;&|/[:space:]])ga[[:space:]]+(--root[= ][^[:space:]]+[[:space:]]+)?(user-command|hook)([^A-Za-z0-9_-]|$)'
  while [ $# -gt 0 ]; do
    case "$1" in
      --command) [ $# -ge 2 ] || break; cmd=$2; shift 2 ;;
      --command=*) cmd=${1#--command=}; shift ;;
      *) shift ;;
    esac
  done
  root=$(ga_find_root "$PWD") || { _ga_gate_out allow ""; return 0; }
  if ga_paused_marker "$root"; then _ga_gate_out allow ""; return 0; fi
  if ! _ga_gate_state "$root"; then
    # R31b: an unreadable state.json keeps read-only work possible (design-phase write rules).
    corrupt=1; GS_PHASE=corrupt; GS_MODE=""; GS_PAUSED=false
  fi
  if [ "$GS_PAUSED" = true ]; then _ga_gate_out allow ""; return 0; fi
  phase=$GS_PHASE
  where="현재 단계 $phase"
  [ "$corrupt" = 1 ] && where="설계 상태(state.json)를 읽을 수 없는 상태"

  # (a) internal commands and adapter hook scripts are never callable from Bash, in any phase.
  if [[ $cmd =~ $re_internal ]] || [[ $cmd == *adapters/*/hook.sh* ]]; then
    _ga_gate_out deny "$where: ga 내부 명령(user-command, hook)과 훅 스크립트는 직접 호출할 수 없습니다. 사용자만 'GA ...' 명령으로 호출합니다"
    return 0
  fi

  set -f
  body=$(_ga_strip_heredocs "$cmd")
  segs=$(_ga_split_segments "$body")

  local CW CW_IDX SEG_MATCH TG_KIND match="" state_hit="" mention_any=0 internal="" ga_seen=0
  local R_BAD="" R_STATE=0 R_ANYBAD=0 lbody CD_SEEN=0 TMPDIR_REASSIGNED=0
  local T_STATE="" T_PLUGIN="" T_UNRES="" T_GIT="" TL="" ST=$root/docs/architecture/.state PLUG
  local re_cd='(^|[^A-Za-z0-9_./-])(cd|pushd)([^A-Za-z0-9_./-]|$)'
  local -a TG
  PLUG=$(_ga_plugin_root) || PLUG=""
  [ -n "$PLUG" ] || PLUG=/nonexistent/grounded-arch-plugin-root
  lbody=$(_ga_lc "$body")
  # .state mention is computed over the whole command (assignment-only segments included).
  case "$lbody" in *.state*) mention_any=1 ;; esac
  if [[ $lbody =~ $re_cd ]]; then CD_SEEN=1; fi
  case "$body" in *TMPDIR=*) TMPDIR_REASSIGNED=1 ;; esac
  while IFS= read -r seg; do
    _ga_bash_seg "$seg" 0
  done <<EOF
$segs
EOF
  set +f

  if [ -n "$internal" ]; then
    _ga_gate_out deny "$where: ga 내부 명령($internal)은 직접 호출할 수 없습니다. 사용자만 'GA ...' 명령으로 호출합니다"
    return 0
  fi

  # R34b: GA_* or PATH changed around a ga invocation (e.g. GA_RUNNERS_DIR=... ga verify,
  # PATH=/tmp/fake:$PATH ga verify) could redirect the verifier or its billing preflight.
  local re_word_ga='(^|[^A-Za-z0-9_-])ga([^A-Za-z0-9_-]|$)'
  local re_env='(^|[^A-Za-z0-9_])(GA_[A-Za-z0-9_]*|PATH)\+?='
  local re_exp='(^|[^A-Za-z0-9_])(export|declare|typeset|readonly|local)[[:space:]]+(-[A-Za-z]+[[:space:]]+)*(GA_[A-Za-z0-9_]*|PATH)([^A-Za-z0-9_]|$)'
  if [[ $body =~ $re_word_ga ]]; then ga_seen=1; fi
  if [ "$ga_seen" = 1 ] && { [[ $body =~ $re_env ]] || [[ $body =~ $re_exp ]]; }; then
    _ga_gate_out deny "$where: ga를 실행하는 명령에서 GA_ 변수나 PATH를 바꿀 수 없습니다 (검증 실행기와 과금 점검을 바꿀 수 있습니다). 변수 없이 ga만 실행하세요"
    return 0
  fi

  # (b) writing under .state in any phase: a redirect into .state, a write command whose target
  # is .state, inside it or an ancestor of it (R32a), or the command mentions .state together
  # with any command-word write or any non-exempt in-project redirect
  # (false denies are accepted; this is what catches L=.../.state/x; cp y "$L").
  if [ "$R_STATE" = 1 ]; then
    state_hit=$R_BAD
  elif [ -n "$T_STATE" ]; then
    state_hit=${match:+$match: }$T_STATE
  elif [ $mention_any = 1 ]; then
    if [ -n "$match" ]; then state_hit=$match
    elif [ "$R_ANYBAD" = 1 ]; then state_hit=$R_BAD
    fi
  fi
  if [ -n "$state_hit" ]; then
    _ga_gate_out deny "$where: 설계 상태(docs/architecture/.state/)나 그 상위 디렉터리를 쓰거나 지우는 명령은 막혀 있습니다 (감지된 패턴: $state_hit). 상태는 ga 명령으로만 바꿉니다. 필요하면 사용자에게 \`GA 일시정지\`를 요청하세요"
    return 0
  fi

  # R34d: the plugin is read-only while the design is active (targets, or a mention of it
  # together with a write).
  if [ -z "$T_PLUGIN" ] && { [ -n "$match" ] || [ "$R_ANYBAD" = 1 ]; }; then
    case "$lbody" in *"$(_ga_lc "$PLUG")"* | *grounded-arch/*) T_PLUGIN=$match ;; esac
  fi
  if [ -n "$T_PLUGIN" ]; then
    _ga_gate_out deny "$where: 설계가 진행 중인 동안 grounded-arch 플러그인($PLUG)은 고칠 수 없습니다 (감지된 대상: $T_PLUGIN). 필요하면 사용자에게 \`GA 일시정지\`를 요청하세요"
    return 0
  fi

  # R32b: git clean / git stash -u delete untracked files such as .state, in any phase.
  if [ -n "$T_GIT" ]; then
    _ga_gate_out deny "$where: $T_GIT 명령은 추적하지 않는 파일(docs/architecture/.state 포함)을 지우므로 설계 중에는 막혀 있습니다. 지울 파일을 직접 지정하거나 사용자에게 \`GA 일시정지\`를 요청하세요"
    return 0
  fi

  case "$phase" in
    inputs | iterating | design-review | corrupt)
      [ -n "$match" ] || match=$R_BAD
      if [ -n "$match" ]; then
        if [ "$corrupt" = 1 ]; then
          _ga_gate_out deny "$(_ga_corrupt_reason "$root") 그동안 파일을 쓰는 명령은 막고 읽기 명령만 허용합니다 (감지된 패턴: $match)"
        else
          _ga_gate_out deny "$where: 설계 승인 전에는 파일을 쓰는 명령을 실행할 수 없습니다 (감지된 패턴: $match). 설계는 docs/architecture/ 안에 기록하거나 사용자에게 \`GA 일시정지\`를 요청하세요"
        fi
        return 0
      fi
      ;;
    skeleton)
      # R32c: brownfield skeleton applies the mapping rule of the write gate to shell writes.
      if [ "$GS_MODE" = brownfield ]; then
        if [ -n "$T_UNRES" ]; then
          _ga_gate_out deny "$where (기존 코드): 쓰는 대상 경로를 확인할 수 없습니다 (감지된 대상: $T_UNRES). 대응표(mapping)의 경로를 그대로 쓰거나 사용자에게 \`GA 일시정지\`를 요청하세요"
          return 0
        fi
        local c rc
        while IFS= read -r c; do
          [ -n "$c" ] || continue
          _ga_mapped "$root" "$c"
          rc=$?
          if [ "$rc" = 2 ]; then
            _ga_gate_out deny "원장(ledger.json)을 읽을 수 없어 대응표를 확인할 수 없습니다. 원장을 고치거나 사용자에게 \`GA 일시정지\`를 요청하세요"
            return 0
          elif [ "$rc" != 0 ]; then
            _ga_gate_out deny "$where (기존 코드): 대응표(mapping)에서 change가 new 또는 changed로 지정된 경로만 쓸 수 있습니다 (감지된 대상: ${c#"$root"/}). 대응표에 경로를 추가하거나 사용자에게 \`GA 일시정지\`를 요청하세요"
            return 0
          fi
        done <<EOF
$TL
EOF
      fi
      ;;
  esac
  _ga_gate_out allow ""
}

# --- stop gate ---------------------------------------------------------------

_ga_gate_stop() {
  local root out rc msg
  # R24: never force a verifier runner (or anything it spawns) to continue.
  if [ "${GA_IN_RUNNER:-}" = 1 ]; then _ga_gate_out allow ""; return 0; fi
  root=$(ga_find_root "$PWD") || { _ga_gate_out allow ""; return 0; }
  if ga_paused_marker "$root"; then _ga_gate_out allow ""; return 0; fi
  # R31b: an unreadable state.json is the user's to repair; blocking the agent cannot help.
  if ! _ga_gate_state "$root"; then _ga_gate_out allow ""; return 0; fi
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
