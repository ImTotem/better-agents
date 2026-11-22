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
# No subprocess: this runs for every target the bash gate classifies (R2#2).
_ga_under() { # X P
  local x=${1%/} nc=0 r=1
  shopt -q nocasematch && nc=1
  shopt -s nocasematch
  if [[ $2 == "$x" || $2 == "$x"/* ]]; then r=0; fi
  [ $nc = 1 ] || shopt -u nocasematch
  return $r
}

# R2#2: ga_canon / ga_find_root for the bash gate, memoized per gate call (CANON_MEMO, ROOT_MEMO:
# "key<TAB>value" lines; bash 3.2 has no associative arrays) and without per-component
# dirname/basename forks. _ga_canon_m sets CN (same result as ga_canon); only the deepest existing
# directory is resolved with cd -P, once per directory. GS_CANON / GS_LOOKUP count the misses.
_ga_canon_m() { # PATH
  local p=$1 rest="" d m c out="" oldifs=$IFS noglob=1
  case "$p" in /*) ;; *) p=$PWD/$p ;; esac
  while [[ $p == *//* ]]; do p=${p//\/\//\/}; done
  while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do p=${p%/}; done
  while [ ! -d "$p" ] && [ "$p" != / ]; do
    rest=${p##*/}${rest:+/$rest}
    p=${p%/*}; [ -n "$p" ] || p=/
  done
  m=$NL$CANON_MEMO
  case "$m" in
    *"$NL$p$TAB"*) m=${m#*"$NL$p$TAB"}; d=${m%%"$NL"*} ;;
    *) d=$(cd -P "$p" 2>/dev/null && pwd -P) || return 1
       CANON_MEMO=$CANON_MEMO$p$TAB$d$NL; GS_CANON=$((GS_CANON + 1)) ;;
  esac
  [ -n "$d" ] || return 1
  # the non-existent remainder: . and .. collapsed lexically, as in ga_canon
  if [ -n "$rest" ]; then
    case $- in *f*) ;; *) noglob=0; set -f ;; esac
    IFS=/
    for c in $rest; do
      case "$c" in
        "" | .) ;;
        ..) if [ -n "$out" ]; then
              case "$out" in */*) out=${out%/*} ;; *) out="" ;; esac
            else
              d=${d%/*}; [ -n "$d" ] || d=/
            fi ;;
        *) out=${out:+$out/}$c ;;
      esac
    done
    IFS=$oldifs
    [ "$noglob" = 1 ] || set +f
  fi
  if [ -z "$out" ]; then CN=$d; elif [ "$d" = / ]; then CN=/$out; else CN=$d/$out; fi
}

# Sets FR to the design root found from canonical existing directory DIR (as ga_find_root).
_ga_find_root_m() { # DIR
  local d=$1 m
  m=$NL$ROOT_MEMO
  case "$m" in *"$NL$1$TAB"*) m=${m#*"$NL$1$TAB"}; FR=${m%%"$NL"*}; [ -n "$FR" ]; return ;; esac
  GS_LOOKUP=$((GS_LOOKUP + 1)); FR=""
  while :; do
    if [ -f "$d/docs/architecture/.state/state.json" ]; then FR=$d; break; fi
    [ ! -e "$d/.git" ] || break
    [ "$d" != / ] || break
    d=${d%/*}; [ -n "$d" ] || d=/
  done
  ROOT_MEMO=$ROOT_MEMO$1$TAB$FR$NL
  [ -n "$FR" ]
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

# The same segments, each line prefixed with \037 and a letter naming the separator before it
# (A &&, O ||, P |, S ;, B &, L (, R ), T backtick); a line without the prefix follows a newline
# or starts the text. The bash gate uses the letters to tell whether a cd applies (_ga_cd_seg).
_ga_split_segments_sep() { # TEXT
  local t=$1 nl=$'\n' bt='`' p1=$'\001' p2=$'\002' p3=$'\003' m=$'\n\037'
  t=${t//>|/>}
  t=${t//&&/${m}A}
  t=${t//>&/$p1}
  t=${t//&>/$p2}
  t=${t//<&/$p3}
  t=${t//&/${m}B}
  t=${t//$p1/>&}
  t=${t//$p2/&>}
  t=${t//$p3/<&}
  t=${t//||/${m}O}
  t=${t//;/${m}S}
  t=${t//|/${m}P}
  t=${t//(/${m}L}
  t=${t//)/${m}R}
  t=${t//$bt/${m}T}
  printf '%s\n' "$t"
}

# Prints TEXT with each complete '...' or "..." string replaced by _ (at most 200), so a quoted
# cd, popd or CDPATH is not taken for shell syntax. An unbalanced quote stays.
_ga_unquoted() { # TEXT
  local t=$1 n=0 re='^([^'"'"'"]*)('"'"'[^'"'"']*'"'"'|"[^"]*")(.*)$'
  while [ $n -lt 200 ] && [[ $t =~ $re ]]; do
    t="${BASH_REMATCH[1]}_${BASH_REMATCH[3]}"
    n=$((n + 1))
  done
  printf '%s' "$t"
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
      local opt="" gdir="" gwt="" del=0 nf=0 x endo=0
      local -a ops
      j=$((CW_IDX + 1))
      while [ $j -lt ${#words[@]} ]; do
        w=${words[$j]}
        j=$((j + 1))
        if [ $skip = 1 ]; then
          skip=0; wc=${w//[\'\"]/}
          # -C DIR (each relative to the previous one) and --work-tree DIR: where git works (A2)
          case "$opt" in
            -C) case "$wc" in /*) gdir=$wc ;; *) gdir=${gdir:+$gdir/}$wc ;; esac ;;
            --work-tree) gwt=$wc ;;
          esac
          continue
        fi
        case "$w" in
          -C | -c | --git-dir | --work-tree | --namespace) skip=1; opt=$w; continue ;;
          --work-tree=*) gwt=${w#--work-tree=}; gwt=${gwt//[\'\"]/}; continue ;;
          -*) continue ;;
        esac
        sub=$w
        break
      done
      case "$sub" in apply | checkout | restore | reset | rm | mv | stash | clean) SEG_MATCH="git $sub" ;; esac
      if [ "$sub" = clean ]; then
        T_GIT=${T_GIT:-"git clean"}; del=1
        # git clean -ff (force twice) also removes nested repositories; the operands are pathspecs
        # (R2#4); -e/--exclude take a pattern.
        skip=0
        while [ $j -lt ${#words[@]} ]; do
          x=${words[$j]//[\'\"]/}
          j=$((j + 1))
          if [ $skip = 1 ]; then skip=0; continue; fi
          if [ $endo = 0 ]; then
            case "$x" in
              --) endo=1; continue ;;
              --force) nf=$((nf + 1)); continue ;;
              --exclude) skip=1; continue ;;
              --*) continue ;;
              -*) [[ $x != *e ]] || skip=1; x=${x//[^f]/}; nf=$((nf + ${#x})); continue ;;
            esac
          fi
          [ -z "$x" ] || ops+=("$x")
        done
        [ $nf -lt 2 ] || CLEAN_FORCE2=1
      elif [ "$sub" = stash ]; then
        while [ $j -lt ${#words[@]} ]; do
          case "${words[$j]//[\'\"]/}" in -u | --include-untracked | -a | --all | -[A-Za-z]*[ua]*) T_GIT=${T_GIT:-"git stash ${words[$j]}"}; del=1 ;; esac
          j=$((j + 1))
        done
      fi
      # A2: the directory git clean / git stash -u works in reaches the designs there. git clean
      # with pathspecs cleans those instead (R2#4): each is resolved like the directory (from
      # every directory the shell may be in), and :/ or :(top) start at the repository top.
      if [ $del = 1 ] && [ "$OWN" = 0 ]; then
        if [ -n "$gwt" ]; then case "$gwt" in /*) gdir=$gwt ;; *) gdir=${gdir:+$gdir/}$gwt ;; esac; fi
        _ga_reach_dir "${gdir:-.}"
        if [ "$sub" = clean ]; then
          if [ ${#ops[@]} = 0 ]; then CLEAN_DIRS=$CLEAN_DIRS$RD; else _ga_clean_ops "${gdir:-.}" "${ops[@]}"; fi
        fi
      fi ;;
  esac
}

# R2#4: git clean pathspec operands OPS (relative to DIR, the directory git works in) add the
# directories they name to CLEAN_DIRS and their designs to REACH_ROOTS. :/X and :(top)X are X at
# the top of the repository (found by walking up to .git); a magic the split cut short (the
# segment splitter breaks at parentheses) counts as the top too; excludes (:! :^ :(exclude)) do
# not clean anything.
_ga_clean_ops() { # DIR OPS...
  local dir=$1 op rest b top
  shift
  for op in "$@"; do
    case "$op" in
      ':!'* | ':^'* | ':(exclude'*) continue ;;
      ':/'*) rest=${op#:/} ;;
      ':(top)'*) rest=${op#:(top)} ;;
      ':'*) rest="" ;;
      *)
        # a glob cleans below its literal directory prefix
        rest=${op%%[\*\?\[]*}
        case "$rest" in "$op") ;; */*) rest=${rest%/*} ;; *) rest=. ;; esac
        case "$rest" in /*) ;; *) rest=$dir/$rest ;; esac
        _ga_reach_dir "$rest"; CLEAN_DIRS=$CLEAN_DIRS$RD
        continue ;;
    esac
    # top-relative: from every directory git may work in
    _ga_reach_dir "$dir"
    while IFS= read -r b; do
      [ -n "$b" ] || continue
      top=$b
      while [ ! -e "$top/.git" ] && [ "$top" != / ]; do top=${top%/*}; [ -n "$top" ] || top=/; done
      [ -e "$top/.git" ] || top=$b
      _ga_reach_dir "$top/$rest"; CLEAN_DIRS=$CLEAN_DIRS$RD
    done <<EOF
$RD
EOF
  done
}

# True when WORD is a literal path (not relative after a cd) to an existing directory.
_ga_is_dir() { # WORD
  _ga_tgt_norm "$1"
  case "$NT" in '' | *'$'* | *'*'* | *'?'* | *'['* | *'{'* | *'`'*) return 1 ;; esac
  if [ "$CD_SEEN" = 1 ]; then case "$NT" in /*) ;; *) return 1 ;; esac; fi
  [ -d "$NT" ]
}

# Sets INTO to the path SRC is written to inside directory DEST (N1 d). A source ending in /
# stands for its contents (BSD cp -R src/ dir), so it is written as DEST itself.
_ga_into() { # DEST SRC
  local d b
  _ga_tgt_norm "$1"; d=${NT%/}
  _ga_tgt_norm "$2"
  case "$NT" in */) b=. ;; *) b=${NT##*/} ;; esac
  INTO=$d/${b:-.}
}

# Sets TG (target words of a write command) and TG_KIND (w = writes, p = .state/plugin
# protection only). Returns 1 for commands whose targets are not determined here.
# cp/ln/install/mv into an existing directory target <dir>/<basename of each source> (N1 d).
_ga_seg_targets() {
  local j=$((CW_IDX + 1)) w wc skip=0 optsv="" mode=all endopt=0 script=0 nx tdw="" notdir=0 n INTO NT
  local re_redir='^[0-9]*([<>]|&>)' re_redir_alone='^[0-9]*(>>?|<<?<?|&>>?|>&|<&)$'
  local -a ops
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
    tee | rm | touch | truncate) ;;
    mkdir | rmdir) TG_KIND=p ;;
    cp | ln | install | mv) mode=copy ;;
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
  # install -d DIR...: every operand is a directory it creates (or changes the mode of).
  if [ "$CW" = install ]; then
    for w in "${words[@]:$j}"; do
      wc=${w//[\'\"]/}
      case "$wc" in
        --) break ;;
        --directory) mode=all ;;
        --*) ;;
        -*) if [[ $wc =~ ^-[A-Za-z]*d[A-Za-z]*$ ]]; then mode=all; fi ;;
      esac
    done
  fi
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
          case "$CW" in cp | ln | install | mv)
            if [ "$mode" = copy ]; then tdw=${words[$j]-}; else TG+=("${words[$j]-}"); fi
            skip=1; continue ;; esac ;;
        --target-directory=*) if [ "$mode" = copy ]; then tdw=${wc#*=}; else TG+=("${wc#*=}"); fi; continue ;;
        -T | --no-target-directory) notdir=1; continue ;;
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
          # short option clusters: -rT (no target directory), -rt DIR (target directory)
          if [ "$mode" = copy ] && [[ $wc != --* ]]; then
            if [[ $wc =~ ^-[A-Za-z]*T ]]; then notdir=1; fi
            if [[ $wc =~ ^-[A-Za-z]+t$ ]]; then tdw=${words[$j]-}; skip=1; continue; fi
          fi
          case "$optsv" in *" $wc "*) skip=1 ;; esac
          continue ;;
      esac
    fi
    case "$mode" in
      all) TG+=("$w") ;;
      copy) ops+=("$w") ;;
      dd) case "$wc" in of=*) TG+=("${wc#of=}") ;; esac ;;
      script) if [ $script = 0 ]; then script=1; else TG+=("$w"); fi ;;
    esac
  done
  if [ "$mode" = copy ]; then
    n=${#ops[@]}
    if [ -z "$tdw" ]; then
      [ "$n" -gt 0 ] || return 0
      n=$((n - 1)); tdw=${ops[$n]}
    fi
    # mv also removes its sources.
    if [ "$CW" = mv ] && [ "$n" -gt 0 ]; then TG+=("${ops[@]:0:$n}"); fi
    if [ "$n" -gt 0 ] && [ $notdir = 0 ] && _ga_is_dir "$tdw"; then
      j=0
      while [ $j -lt "$n" ]; do _ga_into "$tdw" "${ops[$j]}"; TG+=("$INTO"); j=$((j + 1)); done
    else
      TG+=("$tdw")
    fi
  fi
  return 0
}

_ga_t_state() { T_STATE=${T_STATE:-$1}; }

# Sets NT to target word RAW with quotes removed and $TMPDIR/, $HOME, ~ expanded from the
# gate's own environment. $PWD is the shell's current directory, so $PWD/x becomes the
# relative ./x (B3): it then follows the cds before it like any relative target.
_ga_tgt_norm() { # RAW
  NT=${1//[\'\"]/}
  case "$NT" in
    '$TMPDIR/'* | '${TMPDIR}/'*) [ "$TMPDIR_REASSIGNED" = 1 ] || NT=${TMPDIR:-/tmp}/${NT#*/} ;;
    '$HOME/'*) NT=$HOME/${NT#\$HOME/} ;;
    '${HOME}/'*) NT=$HOME/${NT#\$\{HOME\}/} ;;
    '~/'*) NT=$HOME/${NT#\~/} ;;
    '~' | '$HOME' | '${HOME}') NT=$HOME ;;
    '$PWD/'* | '${PWD}/'*) [ "$PWD_REASSIGNED" = 1 ] || NT=./${NT#*/} ;;
    '$PWD' | '${PWD}') [ "$PWD_REASSIGNED" = 1 ] || NT=. ;;
  esac
}

# Sets PC to the canonical literal directory prefix of unexpanded target T ("" when it cannot
# be resolved: relative after a cd/pushd, or not canonicalizable).
_ga_prefix_canon() { # T
  local p=${1%%[\$\*\?\[\{\`]*}
  case "$p" in */*) p=${p%/*}; [ -n "$p" ] || p=/ ;; *) p=. ;; esac
  PC=""
  if [ "$CD_SEEN" = 1 ]; then case "$p" in /*) ;; *) return 0 ;; esac; fi
  if _ga_canon_m "$p"; then PC=$CN; fi
}

# N2: sets LR to the design root that governs canonical path C: ga_find_root from C's deepest
# existing directory (as the write gate does). When C is an existing directory containing the
# cwd (rm -rf ../../.. from a nested repository), a design between the cwd and C is inside C.
_ga_lookup_root() { # C
  local d=$1 p=$CWDP
  LR=""
  while [ ! -d "$d" ] && [ "$d" != / ]; do d=${d%/*}; [ -n "$d" ] || d=/; done
  if _ga_find_root_m "$d"; then LR=$FR; return 0; fi
  [ "$d" = "$1" ] && [ -n "$p" ] || return 1
  while _ga_under "$d" "$p"; do
    if [ -f "$p/docs/architecture/.state/state.json" ]; then LR=$p; return 0; fi
    [ "$p" != / ] || break
    p=${p%/*}; [ -n "$p" ] || p=/
  done
  return 1
}

_ga_add_root() { # ROOT  (adds a design found from a target or a cd to FOUND_ROOTS)
  [ -n "$1" ] && [ "$1" != "$ROOT0" ] || return 0
  case "$NL$FOUND_ROOTS" in *"$NL$1$NL"*) ;; *) FOUND_ROOTS=$FOUND_ROOTS$1$NL ;; esac
}

# N2: which pass checks a write target. C = its canonical path, or "" when it cannot be resolved
# (relative after a cd). The cwd pass (OWN=0) checks every target and records the designs found
# from them; DISC=1 (no active design at the cwd) only records. A pass for a design found that
# way (OWN=1, root = that design) checks only its own targets, and unresolved ones only when a
# cd/pushd went into it (OWN_CD); it sets OWN_HIT. Returns 1 when the caller should skip.
_ga_own() { # C|""
  local lr="" LR
  if [ -n "$1" ]; then _ga_lookup_root "$1"; lr=$LR; fi
  if [ "$OWN" = 1 ]; then
    if [ -n "$1" ]; then [ "$lr" = "$root" ] || return 1; else [ "$OWN_CD" = 1 ] || return 1; fi
    OWN_HIT=1
    return 0
  fi
  _ga_add_root "$lr"
  [ "$DISC" != 1 ]
}

# N2/B1: CD_PD lists every directory the shell may be in when it reaches the current segment
# (at most 16; a destination that does not exist yet is resolved lexically); CD_UNK=1 once a
# destination is unknown. A cd's destination replaces the list when the cd certainly runs and
# applies to what follows (R2 Minor): at the top level, not in ( ), $( ), backticks, bash -c or
# eval, not in a compound command (if, for, while, case, { }, a function), not a pipe element or
# a background job, not after || and with no prefix word except assignments, builtin and
# command. After &&, it applies to the rest of that && chain; the directories from before come
# back at the next ;, newline, ||, | or & (_ga_cd_merge, CD_BACK). A destination that is missing
# or not searchable may make the cd fail, so the directory it was resolved from comes back the
# same way. Anywhere else the destination is only added. Unknown: a variable, glob, backslash,
# cd -, ~user, a pushd/popd stack operation, or a name CDPATH may resolve. A design found from a
# destination makes the relative targets after it that design's (CD_ROOTS -> OWN_CD).
# Uses words/CW/CW_IDX and the segment context SEG_BEFORE, SEG_AFTER, SEG_NEST, CD_COMPOUND.
_ga_cd_seg() { # DEPTH
  local k=0 w="" c p d new="" back="" mode=rep unk=0 NT LR
  CD_SEEN=1
  if [ "${1:-0}" != 0 ] || [ "$SEG_NEST" = 1 ] || [ "$CD_COMPOUND" = 1 ]; then mode=add; fi
  case "$SEG_BEFORE" in P | O) mode=add ;; esac
  case "$SEG_AFTER" in P | B) mode=add ;; esac
  while [ $k -lt "$CW_IDX" ]; do
    case "${words[$k]//[\'\"\\]/}" in [A-Za-z_]*=* | builtin | command) ;; *) mode=add ;; esac
    k=$((k + 1))
  done
  [ "$SEG_BEFORE" != A ] || [ $mode = add ] || mode=chain
  k=$((CW_IDX + 1))
  while [ $k -lt ${#words[@]} ]; do
    case "${words[$k]}" in - | [+-][0-9]*) w=-; break ;; -*) k=$((k + 1)) ;; *) w=${words[$k]}; break ;; esac
  done
  if [ -z "$w" ] && [ "$CW" = pushd ]; then w=-; fi
  if [ -z "$w" ]; then c=$HOME; else _ga_tgt_norm "$w"; c=$NT; fi
  case "$c" in
    '' | - | *'$'* | *'*'* | *'?'* | *'['* | *'{'* | *'`'* | *\\* | '~'*) unk=1 ;;
    /* | . | .. | ./* | ../*) ;;
    *) if [ -n "${CDPATH:-}" ] || [ "$CDPATH_SEEN" = 1 ]; then unk=1; fi ;;
  esac
  if [ $unk = 1 ]; then
    CD_UNK=1
    [ $mode = add ] || { CD_BACK=$CD_BACK$CD_PD; CD_PD=""; CD_N=0; }
    return 0
  fi
  if [ -z "$CD_PD" ]; then
    # the shell's directory is already unknown: only an absolute destination is known
    case "$c" in /*) _ga_canon_m "$c" && _ga_pd_add "$CN" ;; esac
    return 0
  fi
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$c" in /*) d=$c ;; *) d=$p/$c ;; esac
    if ! _ga_canon_m "$d"; then CD_UNK=1; back=$back$p$NL; continue; fi
    new=$new$CN$NL
    [ $mode = rep ] && [ -d "$CN" ] && [ -x "$CN" ] || back=$back$p$NL
  done <<EOF
$CD_PD
EOF
  case $mode in
    add) _ga_pd_add "$new" ;;
    *) CD_BACK=$CD_BACK$back; CD_PD=""; CD_N=0; _ga_pd_add "$new" ;;
  esac
}

# Adds the directories in LIST (one per line) to CD_PD (deduplicated, at most 16 -- past that the
# shell's directory is unknown) and records the designs found from them (CD_ROOTS, FOUND_ROOTS).
_ga_pd_add() { # LIST
  local d LR
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    case "$NL$CD_PD" in *"$NL$d$NL"*) continue ;; esac
    if [ "$CD_N" -ge 16 ]; then CD_UNK=1; break; fi
    CD_PD=$CD_PD$d$NL; CD_N=$((CD_N + 1))
    _ga_lookup_root "$d" || continue
    _ga_add_root "$LR"
    case "$NL$CD_ROOTS" in *"$NL$LR$NL"*) ;; *) CD_ROOTS=$CD_ROOTS$LR$NL ;; esac
  done <<EOF
$1
EOF
}

# At a separator that ends an && chain, the directories a cd in it may not have left come back.
_ga_cd_merge() {
  [ -n "$CD_BACK" ] || return 0
  local b=$CD_BACK
  CD_BACK=""
  _ga_pd_add "$b"
}

# B1: classifies a relative target after a cd from every directory the shell may be in (CD_PD),
# exactly as a target given without a cd. ga_canon resolves a relative path against $PWD, so
# PWD is set to each of them in turn (the gate's process stays where it is). Two directories that
# give the same path classify it once. R2#2: at most 128 classifications per pass (B1_N); past
# that CD_OVER=1 and the remaining targets get only the name rules (_ga_anc_state, the cwd
# design's after-cd rule).
_ga_at_dirs() { # FN TARGET ARGS...
  local b PWD CD_SEEN=0 seen="" NT t
  _ga_tgt_norm "$2"; t=$NT
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    case "$t" in
      *'$'* | *'*'* | *'?'* | *'['* | *'{'* | *'`'*) ;;
      *) if _ga_canon_m "$b/$t"; then
           case "$NL$seen" in *"$NL$CN$NL"*) continue ;; esac
           seen=$seen$CN$NL
         fi ;;
    esac
    if [ "$B1_N" -ge 128 ]; then CD_OVER=1; return 0; fi
    B1_N=$((B1_N + 1)); GS_CLASSIFY=$((GS_CLASSIFY + 1))
    PWD=$b
    "$@" </dev/null
  done <<EOF
$CD_PD
EOF
}

# True when ROOT holds a design that is not paused (an unreadable state.json counts as active,
# as it does at the cwd). Sets AW to the deny-reason prefix naming its phase and location.
_ga_active() { # ROOT
  local GS_PHASE GS_MODE GS_PAUSED
  AW=""
  [ -f "$1/docs/architecture/.state/state.json" ] && ! ga_paused_marker "$1" || return 1
  if ! _ga_gate_state "$1"; then AW="설계 상태(state.json)를 읽을 수 없는 상태 ($1)"; return 0; fi
  [ "$GS_PAUSED" != true ] || return 1
  AW="현재 단계 $GS_PHASE ($1)"
}

# Active designs at or above the cwd, passing .git boundaries (unlike ga_find_root): the
# fallback when a cd destination or a ga/git directory is unknown. Computed once per gate call.
_ga_anc_roots() {
  local p=$CWDP AW
  [ "$ANC_DONE" != 1 ] || return 0
  ANC_DONE=1; ANC_ROOTS=""; ANC_W=""
  while [ -n "$p" ]; do
    if _ga_active "$p"; then ANC_ROOTS=$ANC_ROOTS$p$NL; [ -n "$ANC_W" ] || ANC_W=$AW; fi
    [ "$p" != / ] || break
    p=${p%/*}; [ -n "$p" ] || p=/
  done
}

# Relative names that may be .state or an ancestor of it when their directory is unknown
# (case-insensitive, as APFS is).
_ga_rel_names() { # REL (./ and a trailing / removed)
  local nc=0 r=1
  shopt -q nocasematch && nc=1
  shopt -s nocasematch
  case "/$1/" in */../* | /./ | //) r=0 ;; esac
  case "$1" in
    docs | docs/architecture | architecture | .state | architecture/.state | docs/architecture/.state | */docs | */docs/architecture | */architecture | */.state) r=0 ;;
  esac
  [ $nc = 1 ] || shopt -u nocasematch
  return $r
}

# B2: after a cd whose destination is unknown (or past the R2#2 bound), relative target T may lie
# anywhere. Every active design above the cwd protects its .state from it and only that rule
# applies (not the phase write rules: a worktree nested in a checkout with a design must keep
# working). T counts when a path component is `..` or `.state`, when it names docs,
# docs/architecture or .state (_ga_rel_names), or when a glob in it may reach .state; a
# substring such as notes.architecture.md does not (R2 Minor). Sets T_ANC.
_ga_anc_state() { # T RAW
  local rel c nc=0 hit=1 a
  local -a comps BX
  [ "$OWN" = 0 ] && { [ "$CD_UNK" = 1 ] || [ "$CD_OVER" = 1 ]; } && [ -z "$T_ANC" ] || return 0
  _ga_anc_roots
  [ -n "$ANC_ROOTS" ] || return 0
  rel=${1#./}; rel=${rel%/}
  if _ga_rel_names "$rel"; then T_ANC=$2; return 0; fi
  IFS=/ read -r -a comps <<<"$rel"
  shopt -q nocasematch && nc=1
  shopt -s nocasematch
  for c in ${comps[@]+"${comps[@]}"}; do case "$c" in .. | .state) hit=0; break ;; esac; done
  [ $nc = 1 ] || shopt -u nocasematch
  if [ $hit = 0 ]; then T_ANC=$2; return 0; fi
  case "$1" in
    *'*'* | *'?'* | *'['* | *'{'*)
      _ga_brace_alts "$1" || { T_ANC=$2; return 0; }
      for a in "${BX[@]}"; do _ga_glob_reaches "$a" && { T_ANC=$2; return 0; }; done ;;
  esac
  return 0
}

# A2: WORD names a directory the command makes ga or git work in (ga --root, GA_ROOT=,
# git -C/--work-tree). The designs found from it -- from every directory the shell may be in,
# for a relative one -- are reachable (REACH_ROOTS); RD lists the resolved directories. An
# operand that cannot be resolved makes the designs above the cwd reachable (REACH_UNK).
_ga_reach_dir() { # WORD
  local NT b c LR
  RD=""
  [ "$OWN" = 0 ] || return 0
  _ga_tgt_norm "$1"
  case "$NT" in
    '' | *'$'* | *'*'* | *'?'* | *'['* | *'{'* | *'`'*) REACH_UNK=1; return 0 ;;
    /*) b=/ ;;
    *) [ "$CD_UNK" != 1 ] && [ -n "$CD_PD" ] || REACH_UNK=1; b=$CD_PD ;;
  esac
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    case "$NT" in /*) c=$NT ;; *) c=$b/$NT ;; esac
    if ! _ga_canon_m "$c"; then REACH_UNK=1; continue; fi
    c=$CN
    RD=$RD$c$NL
    if _ga_lookup_root "$c"; then
      case "$NL$REACH_ROOTS" in *"$NL$LR$NL"*) ;; *) REACH_ROOTS=$REACH_ROOTS$LR$NL ;; esac
    fi
  done <<EOF
$b
EOF
}

# A2: git clean removes untracked files below the directory it runs in. True when an active
# design root lies at most two directories below DIR in the same repository (no .git on the
# way, unless git clean was forced twice). Bounded search, only for git clean, and only when DIR
# is inside a repository. Sets AW.
_ga_below_active() { # DIR
  local f r p=$1
  while [ ! -e "$p/.git" ]; do
    [ "$p" != / ] || return 1
    p=${p%/*}; [ -n "$p" ] || p=/
  done
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    r=${f%/docs/architecture/.state/state.json}
    if [ "$CLEAN_FORCE2" != 1 ]; then
      p=$r
      while [ ${#p} -gt ${#1} ]; do
        [ ! -e "$p/.git" ] || continue 2
        p=${p%/*}
      done
    fi
    _ga_active "$r" && return 0
  done <<EOF
$(find "$1" -mindepth 1 -maxdepth 6 \( -name node_modules -o -name .git -o -name vendor -o -name target -o -name build -o -name dist \) -prune -o -path '*/docs/architecture/.state/state.json' -print 2>/dev/null)
EOF
  return 1
}

# A2: true when the command reaches an active design other than the cwd's: one found from a
# write target or a cd destination (FOUND_ROOTS) or from ga --root, GA_ROOT= or git -C
# (REACH_ROOTS); one above the cwd when such a directory is unknown; and for git clean
# (CLEAN=1) one below the directories it runs in. Sets AW to the first one's deny prefix.
_ga_reach_active() { # CLEAN
  local r
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    _ga_active "$r" && return 0
  done <<EOF
$FOUND_ROOTS$REACH_ROOTS
EOF
  if [ "$REACH_UNK" = 1 ] || [ "$CD_UNK" = 1 ]; then
    _ga_anc_roots
    if [ -n "$ANC_ROOTS" ]; then AW=$ANC_W; return 0; fi
  fi
  [ "$1" = 1 ] || return 1
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    _ga_below_active "$r" && return 0
  done <<EOF
$CLEAN_DIRS
EOF
  return 1
}

# Brace expansion of S into BX (bash expands {a,b} lists before globbing, also in a redirect
# target). A {x..y} sequence becomes *, ${...} is left alone. Returns 1 past 64 alternatives.
_ga_brace_alts() { BX=(); _ga_bx "$1"; } # S
_ga_bx() { # S
  local s=$1 n=${#1} i=0 j d st alt
  local -a parts
  while [ $i -lt $n ]; do
    case "${s:$i:1}" in
      \\) i=$((i + 2)); continue ;;
      '{')
        d=0; j=$i; st=$((i + 1)); parts=()
        while [ $j -lt $n ]; do
          case "${s:$j:1}" in
            \\) j=$((j + 1)) ;;
            '{') d=$((d + 1)) ;;
            '}') d=$((d - 1)); [ $d -gt 0 ] || break ;;
            ,) if [ $d = 1 ]; then parts+=("${s:$st:$((j - st))}"); st=$((j + 1)); fi ;;
          esac
          j=$((j + 1))
        done
        if [ $j -lt $n ] && [ $i -gt 0 ] && [ "${s:$((i - 1)):1}" = '$' ]; then
          i=$((j + 1)); continue
        fi
        if [ $j -lt $n ]; then
          if [ ${#parts[@]} -gt 0 ]; then
            parts+=("${s:$st:$((j - st))}")
            for alt in "${parts[@]}"; do _ga_bx "${s:0:$i}${alt}${s:$((j + 1))}" || return 1; done
            return 0
          fi
          case "${s:$((i + 1)):$((j - i - 1))}" in
            *..*) _ga_bx "${s:0:$i}*${s:$((j + 1))}"; return ;;
          esac
        fi ;;
    esac
    i=$((i + 1))
  done
  [ ${#BX[@]} -lt 64 ] || return 1
  BX+=("$s")
}

# Glob walk over comps[] (from index S) against names[] (from index K), both of the caller.
# True when every component matches the name it lines up with (case-insensitive: APFS) up to
# the end of the pattern; past the last name (inside .state) anything matches. ** and .. fail
# closed; a component with $ or a backtick cannot be evaluated and matches one name.
_ga_walk() { # S K
  local i=$1 k=$2 c m=1 nc=0
  shopt -q nocasematch && nc=1
  shopt -s nocasematch
  while [ $i -lt ${#comps[@]} ]; do
    c=${comps[$i]}; i=$((i + 1))
    case "$c" in '' | .) continue ;; esac
    [ $k -lt ${#names[@]} ] || break
    case "$c" in
      *'**'* | ..) break ;;
      *'$'* | *'`'*) ;;
      *) [[ ${names[$k]} == $c ]] || { m=0; break; } ;;
    esac
    k=$((k + 1))
  done
  [ $nc = 1 ] || shopt -u nocasematch
  [ $m = 1 ]
}

# N1/O1 (R32a b): true when brace alternative A may name ST, something inside it or an
# ancestor of it. From A's literal directory prefix, the remaining components are matched
# against the path toward ST (_ga_walk). After a cd the prefix is unknown: any `..` fails closed
# and the pattern may line up anywhere with docs/architecture/.state. A without a glob that holds
# a variable, $(...) or backtick is not a .state target (limit (c)).
_ga_glob_reaches() { # A
  local a=$1 pre pdir rest P rel s k
  local -a comps names
  case "$a" in
    *'*'* | *'?'* | *'['*) ;;
    *'$'* | *'`'*) return 1 ;;
  esac
  pre=${a%%[\$\*\?\[\`]*}
  case "$pre" in
    */*) pdir=${pre%/*}; rest=${a:$((${#pdir} + 1))}; [ -n "$pdir" ] || pdir=/ ;;
    *) pdir=.; rest=$a ;;
  esac
  if [ "$CD_SEEN" = 1 ] && [ "${pdir#/}" = "$pdir" ]; then
    IFS=/ read -r -a comps <<<"$pdir/$rest"
    for s in "${comps[@]}"; do [ "$s" != .. ] || return 0; done
    names=(docs architecture .state)
    s=0
    while [ $s -lt ${#comps[@]} ]; do
      case "${comps[$s]}" in
        '' | .) ;;
        *) for k in 0 1 2; do _ga_walk $s $k && return 0; done ;;
      esac
      s=$((s + 1))
    done
    return 1
  fi
  _ga_canon_m "$pdir" || return 1
  P=$CN
  # a .. after the first pattern component can leave the prefix directory: fail closed
  case "/$rest/" in */../*) return 0 ;; esac
  _ga_under "$ST" "$P" && return 0
  _ga_under "$P" "$ST" || return 1
  if [ "$P" = / ]; then rel=${ST#/}; else rel=${ST:$((${#P} + 1))}; fi
  IFS=/ read -r -a comps <<<"$rest"
  IFS=/ read -r -a names <<<"$rel"
  _ga_walk 0 0
}

# Unexpanded target T (R32a): a .state target when (a) its text mentions architecture or .state,
# or (b) a brace alternative reaches .state (_ga_glob_reaches). Too many alternatives: fail closed.
_ga_unexp_state() { # T
  local a nc=0 r=1
  local -a BX
  shopt -q nocasematch && nc=1
  shopt -s nocasematch
  [[ $1 == *architecture* || $1 == *.state* ]] && r=0
  [ $nc = 1 ] || shopt -u nocasematch
  [ $r = 1 ] || return 0
  _ga_brace_alts "$1" || return 0
  for a in "${BX[@]}"; do _ga_glob_reaches "$a" && return 0; done
  return 1
}

# Classifies one write target RAW of a command (R32a/c, R34d). Uses ST (the .state dir),
# PLUG (plugin root), root, CD_SEEN, TMPDIR_REASSIGNED. Sets T_STATE (target is .state, inside
# it, or an ancestor of it), T_PLUGIN (inside or an ancestor of the plugin), T_UNRES (an
# unresolvable write target) and appends in-root, non-docs/architecture write targets to TL.
_ga_check_target() { # RAW KIND
  local raw=$1 t c lc rel PC NT
  _ga_tgt_norm "$raw"; t=$NT
  [ -n "$t" ] || return 0
  case "$t" in /dev/null | /dev/stdout | /dev/stderr) return 0 ;; esac
  # B1/B2: a relative target after a cd/pushd is also classified from every directory the shell
  # may be in; when a destination is unknown, the designs above the cwd protect their .state.
  if [ "$CD_SEEN" = 1 ]; then
    case "$t" in /*) ;; *) _ga_at_dirs _ga_check_target "$raw" "$2"; _ga_anc_state "$t" "$raw" ;; esac
  fi
  case "$t" in
    *'$'* | *'*'* | *'?'* | *'['* | *'{'* | *'`'*)
      # Unexpanded: .state by text or by a glob that reaches it; plugin and project membership
      # by the literal directory prefix.
      _ga_prefix_canon "$t"
      c=$PC
      _ga_own "$c" || return 0
      _ga_unexp_state "$t" && _ga_t_state "$raw"
      if [ -n "$c" ]; then
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
        _ga_own "" || return 0
        # After cd/pushd a relative target cannot be resolved; refuse the obvious .state ancestors.
        rel=${t#./}; rel=${rel%/}
        _ga_rel_names "$rel" && _ga_t_state "$raw"
        [ "$2" = w ] && T_UNRES=${T_UNRES:-$raw}
        return 0 ;;
    esac
  fi
  c=""
  if _ga_canon_m "$t"; then c=$CN; fi
  _ga_own "$c" || return 0
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
_ga_scan_redirects() { # SEG
  local rest=$1 re t amp
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
    _ga_redir_target "$t"
  done
}

# One redirect target T (quotes removed) of _ga_scan_redirects. Uses root, CD_SEEN, PLUG.
_ga_redir_target() { # T
  local t=$1 c PC
  case "$t" in
    /dev/null) return 0 ;;
    '$TMPDIR/'* | '${TMPDIR}/'*)
      # expanded from the gate's own env (the command may reassign TMPDIR: not exempt then)
      if [ "$TMPDIR_REASSIGNED" = 1 ]; then t='$TMPDIR_REASSIGNED'; else t=${TMPDIR:-/tmp}/${t#*/}; fi ;;
    '$HOME/'*) t=$HOME/${t#\$HOME/} ;;
    '${HOME}/'*) t=$HOME/${t#\$\{HOME\}/} ;;
    '~/'*) t=$HOME/${t#\~/} ;;
    '$PWD/'* | '${PWD}/'*) [ "$PWD_REASSIGNED" = 1 ] || t=./${t#*/} ;;
    '$PWD' | '${PWD}') [ "$PWD_REASSIGNED" = 1 ] || t=. ;;
  esac
  # B1/B2 (as for command targets): also from every directory the shell may be in after a cd.
  if [ "$CD_SEEN" = 1 ]; then
    case "$t" in /*) ;; *) _ga_at_dirs _ga_redir_target "$t"; _ga_anc_state "$t" "> $t" ;; esac
  fi
  # Unexpandable targets (variables, globs, braces, backticks) are never exempt.
  case "$t" in
    *'$'* | *'*'* | *'?'* | *'['* | *'{'* | *'`'*)
      _ga_prefix_canon "$t"
      _ga_own "$PC" || return 0
      [ -n "$R_BAD" ] || R_BAD="> $t"
      R_ANYBAD=1
      T_UNRES=${T_UNRES:-"> $t"}
      # O1: bash expands a single-match redirect glob, so classify it like a command target
      # (text, then the glob walk toward .state).
      _ga_unexp_state "$t" && R_STATE=1
      return 0 ;;
  esac
  # After a cd/pushd in the same command, relative targets cannot be resolved: not exempt.
  if [ "$CD_SEEN" = 1 ]; then
    case "$t" in
      /*) ;;
      *) _ga_own "" || return 0
         [ -n "$R_BAD" ] || R_BAD="> $t"; R_ANYBAD=1; T_UNRES=${T_UNRES:-"> $t"}; return 0 ;;
    esac
  fi
  c=""
  if _ga_canon_m "$t"; then c=$CN; fi
  if [ -z "$c" ]; then
    _ga_own "" || return 0
    [ -n "$R_BAD" ] || R_BAD="> $t"
    R_ANYBAD=1
    T_UNRES=${T_UNRES:-"> $t"}
    return 0
  fi
  _ga_own "$c" || return 0
  _ga_under "$PLUG" "$c" && T_PLUGIN=${T_PLUGIN:-"> $t"}
  if _ga_under "$root/docs/architecture/.state" "$c"; then
    [ -n "$R_BAD" ] || R_BAD="> $t"
    R_STATE=1; R_ANYBAD=1
  elif _ga_under "$root/docs/architecture" "$c"; then
    return 0
  elif _ga_under "$root" "$c"; then
    [ -n "$R_BAD" ] || R_BAD="> $t"
    R_ANYBAD=1
    TL=$TL$c$'\n'
  fi
  return 0
}

# R2#3: true when the segment runs a file named hook.sh: as the command word, or as the script
# operand of bash/sh/zsh/dash/ksh/source/. (bash -c strings and eval are scanned by recursion;
# env/command/exec/nohup/xargs/time are prefixes of _ga_cmdword). Uses words/CW/CW_IDX.
_ga_runs_hook() {
  local k=$((CW_IDX + 1)) w s=0
  case "$CW" in
    bash | sh | zsh | dash | ksh | source | .)
      while [ $k -lt ${#words[@]} ]; do
        w=${words[$k]//[\'\"\\]/}
        k=$((k + 1))
        if [ $s = 1 ]; then s=0; continue; fi
        case "$CW:$w" in
          *:--) w=${words[$k]-}; w=${w//[\'\"\\]/}; break ;;
          *:-c | *:-[A-Za-z]*c | *:-s | *:-[A-Za-z]*s) return 1 ;;
          *:-o | *:+o | *:-O | *:+O | *:--rcfile | *:--init-file) s=1; continue ;;
          *:-* | *:+*) continue ;;
        esac
        break
      done
      [ -n "$w" ] && _ga_is_hook "$w" ;;
    *)
      w=${words[$CW_IDX]//[\'\"\\]/}
      case "$w" in */*) _ga_is_hook "$w" ;; *) [ "$w" = hook.sh ] ;; esac ;;
  esac
}

# True when path WORD names a file called hook.sh, directly or through symlinks, from every
# directory the shell may be in.
_ga_is_hook() { # WORD (quotes removed)
  local b p n t
  case "${1##*/}" in hook.sh) return 0 ;; esac
  case "$1" in '' | *'$'* | *'`'* | *'*'* | *'?'* | *'['*) return 1 ;; esac
  case "$1" in /*) b=/ ;; *) b=$CD_PD ;; esac
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$1" in /*) p=$1 ;; *) p=$p/$1 ;; esac
    n=0
    while [ -L "$p" ] && [ $n -lt 8 ]; do
      t=$(readlink "$p") || break
      case "$t" in /*) p=$t ;; *) p=${p%/*}/$t ;; esac
      n=$((n + 1))
    done
    case "${p##*/}" in hook.sh) return 0 ;; esac
  done <<EOF
$b
EOF
  return 1
}

# Scans one command segment (loop body of the bash gate; uses the gate's locals).
# DEPTH bounds the recursion into `bash -c STRING` / `eval STRING`.
_ga_bash_seg() { # SEG DEPTH
  local seg=$1 depth=${2:-0} k t w sub skipcmd=0 OWN_HIT=0
  local -a words
  words=($seg)
  [ ${#words[@]} -gt 0 ] || return 0
  CW=""; SEG_MATCH=""
  # A2: GA_ROOT=DIR (an assignment or export) points ga at DIR, and so does --root DIR /
  # --root=DIR, wherever it stands (ga may run behind a wrapper such as timeout).
  if [ "$OWN" = 0 ]; then
    k=0
    while [ $k -lt ${#words[@]} ]; do
      w=${words[$k]//[\'\"]/}
      k=$((k + 1))
      case "$w" in
        GA_ROOT=*) _ga_reach_dir "${w#GA_ROOT=}" ;;
        --root) _ga_reach_dir "${words[$k]-}" ;;
        --root=*) _ga_reach_dir "${w#--root=}" ;;
      esac
    done
  fi
  # Segments without a command word (>file, X=1 >file) still get their redirects scanned.
  if _ga_cmdword; then
    case "$CW" in '$'* | '`'*) ga_seen=1 ;; esac
    # R2#3: running a file named hook.sh (an adapter's entry point) is an internal call, with or
    # without a design: the design it acts on comes from the cwd in its stdin, which the gate
    # cannot see. Mentions (cat, git add, grep) are not runs.
    if _ga_runs_hook; then [ -n "$internal" ] || internal=hook.sh; fi
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
        user-command | hook | gate) [ -n "$internal" ] || internal=$ga_sub ;;
        # R10: public ga segments skip only the command-word patterns.
        add | update | ask | resolve | render | check | status | verify | dispute | init | version | rule | billing | context) skipcmd=1 ;;
      esac
    fi
    if [ $skipcmd = 0 ]; then
      _ga_seg_command_match
      if _ga_seg_targets; then
        for t in ${TG[@]+"${TG[@]}"}; do _ga_check_target "$t" "$TG_KIND"; done
      fi
      # In a pass for a design found from the targets, a write command counts only with a
      # target in that design.
      if [ -n "$SEG_MATCH" ] && [ -z "$match" ] && { [ "$OWN" != 1 ] || [ "$OWN_HIT" = 1 ]; }; then match=$SEG_MATCH; fi
    fi
    case "$CW" in cd | pushd) _ga_cd_seg "$depth" ;; popd) CD_SEEN=1; CD_UNK=1 ;; esac
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
  _ga_scan_redirects "$seg"
}

_ga_gate_bash() {
  local cmd="" ROOT0 FOUND_ROOTS="" CD_ROOTS="" EV_OUT="" NL=$'\n' TAB=$'\t' r CWDP AW="" ANC_DONE=0 ANC_ROOTS="" ANC_W=""
  local CANON_MEMO="" ROOT_MEMO="" CN FR GS_CANON=0 GS_LOOKUP=0 GS_CLASSIFY=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --command) [ $# -ge 2 ] || break; cmd=$2; shift 2 ;;
      --command=*) cmd=${1#--command=}; shift ;;
      *) shift ;;
    esac
  done
  ROOT0=$(ga_find_root "$PWD") || ROOT0=""
  CWDP=$(pwd -P) || CWDP=""
  _ga_bash_eval "$cmd" "$ROOT0" 0
  # N2: designs found from the write targets or a cd/pushd (the walk from the cwd stops at the
  # first .git, so a cwd in a nested repository does not see the design around it). Each applies
  # its rules to its own targets as if the cwd were inside it.
  if [ -z "$EV_OUT" ] && [ -n "$FOUND_ROOTS" ]; then
    while IFS= read -r r; do
      [ -n "$r" ] || continue
      _ga_bash_eval "$cmd" "$r" 1
      [ -z "$EV_OUT" ] || break
    done <<EOF
$FOUND_ROOTS
EOF
  fi
  [ -n "$EV_OUT" ] || EV_OUT=$(_ga_gate_out allow "")
  # Test mode only: how much path work the call did (directory resolutions, design lookups,
  # per-directory classifications), for the R2#2 bound test.
  if [ "${GA_TEST_MODE:-}" = 1 ] && [ -n "${GA_GATE_STATS:-}" ]; then
    printf 'canon=%s lookup=%s classify=%s\n' "$GS_CANON" "$GS_LOOKUP" "$GS_CLASSIFY" >>"$GA_GATE_STATS"
  fi
  printf '%s\n' "$EV_OUT"
}

_ga_ev_deny() { EV_OUT=$(_ga_gate_out deny "$1"); } # REASON

# One pass of the bash gate for design ROOT. OWN=0: the design found from the cwd ("" = none):
# every target is checked and the designs found from targets are recorded (only recorded when
# there is no active design here); the internal-call, GA_*/PATH, git clean and B2 rules run in
# this pass for every reachable design (A1/A2). OWN=1: a design found from targets (N2): only its
# own targets are checked. Sets EV_OUT to a deny decision, or leaves it empty.
_ga_bash_eval() { # CMD ROOT OWN
  local cmd=$1 root=$2 OWN=$3 phase="" body segs seg corrupt=0 where="" DISC=0 OWN_CD=0
  local CD_PD CD_N=1 CD_UNK=0 CD_BACK="" CD_OVER=0 B1_N=0 REACH_ROOTS="" REACH_UNK=0 RD="" CLEAN_DIRS="" CLEAN_FORCE2=0 T_ANC=""
  local SEG_BEFORE=N SEG_AFTER=N SEG_NEST=0 CD_COMPOUND=0 CDPATH_SEEN=0 i n pdepth=0 btin=0 m=$'\037' w0
  local -a SG SP fw
  # The text net (R2#1): user-command and hook only (ga gate is caught by the parser), and only when
  # a design is reachable.
  local re_internal='(^|[;&|/[:space:]])ga[[:space:]]+(--root[= ][^[:space:]]+[[:space:]]+)?(user-command|hook)([^A-Za-z0-9_-]|$)'
  EV_OUT=""
  if [ -z "$root" ] || ga_paused_marker "$root"; then
    DISC=1
  elif ! _ga_gate_state "$root"; then
    # R31b: an unreadable state.json keeps read-only work possible (design-phase write rules).
    corrupt=1; GS_PHASE=corrupt; GS_MODE=""; GS_PAUSED=false
  fi
  if [ $DISC = 0 ] && [ "$GS_PAUSED" = true ]; then DISC=1; fi
  if [ $DISC = 1 ]; then
    [ "$OWN" = 0 ] || return 0
    root=/nonexistent/ga-no-design
  else
    phase=$GS_PHASE
    where="현재 단계 $phase"
    [ "$corrupt" = 1 ] && where="설계 상태(state.json)를 읽을 수 없는 상태"
    if [ "$OWN" = 1 ]; then case "$NL$CD_ROOTS" in *"$NL$root$NL"*) OWN_CD=1 ;; esac; fi
  fi

  set -f
  body=$(_ga_strip_heredocs "$cmd")
  segs=$(_ga_split_segments_sep "$body")

  local CW CW_IDX SEG_MATCH TG_KIND match="" state_hit="" mention_any=0 internal="" ga_seen=0
  local R_BAD="" R_STATE=0 R_ANYBAD=0 lbody CD_SEEN=0 TMPDIR_REASSIGNED=0 PWD_REASSIGNED=0
  local T_STATE="" T_PLUGIN="" T_UNRES="" T_GIT="" TL="" ST=$root/docs/architecture/.state PLUG
  local re_cd='(^|[^A-Za-z0-9_./-])(cd|pushd|popd)([^A-Za-z0-9_./-]|$)'
  local -a TG
  PLUG=""
  if [ $DISC = 0 ]; then PLUG=$(_ga_plugin_root) || PLUG=""; fi
  [ -n "$PLUG" ] || PLUG=/nonexistent/grounded-arch-plugin-root
  CD_PD=${CWDP:+$CWDP$NL}
  [ -n "$CWDP" ] || CD_UNK=1
  lbody=$(_ga_lc "$body")
  # .state mention is computed over the whole command (assignment-only segments included).
  case "$lbody" in *.state*) mention_any=1 ;; esac
  # A cd/pushd/popd anywhere outside quotes turns on the after-cd rules for the whole command
  # (a loop can run a target after a cd that comes later in the text); a quoted one does not
  # (R2 Minor). _ga_cd_seg also sets CD_SEEN for a cd found inside bash -c / eval.
  if [[ $(_ga_unquoted "$lbody") =~ $re_cd ]]; then CD_SEEN=1; fi
  case "$body" in *TMPDIR=*) TMPDIR_REASSIGNED=1 ;; esac
  case "$body" in *PWD=*) PWD_REASSIGNED=1 ;; esac
  case "$body" in *CDPATH*) CDPATH_SEEN=1 ;; esac
  # Segments with the separator before each; a reserved word starting any segment makes the
  # command compound, and a cd in it may not run (CD_COMPOUND).
  i=0
  while IFS= read -r seg; do
    case "$seg" in "$m"?*) SP[i]=${seg:1:1}; SG[i]=${seg:2} ;; *) SP[i]=N; SG[i]=$seg ;; esac
    fw=(${SG[i]})
    w0=${fw[0]-}; w0=${w0//[\'\"\\]/}
    case "$w0" in if | then | else | elif | fi | for | while | until | do | done | case | esac | select | function | '{' | '}' | coproc) CD_COMPOUND=1 ;; esac
    i=$((i + 1))
  done <<EOF
$segs
EOF
  n=$i; i=0
  while [ $i -lt $n ]; do
    SEG_BEFORE=${SP[i]}; SEG_AFTER=${SP[i+1]-N}
    case "$SEG_BEFORE" in
      L) pdepth=$((pdepth + 1)) ;;
      R) [ $pdepth = 0 ] || pdepth=$((pdepth - 1)) ;;
      T) btin=$((1 - btin)) ;;
    esac
    SEG_NEST=0; [ $pdepth = 0 ] && [ $btin = 0 ] || SEG_NEST=1
    # ;, newline, ||, | and & end an && chain (subshell marks do not)
    case "$SEG_BEFORE" in A | L | R | T) ;; *) _ga_cd_merge ;; esac
    _ga_bash_seg "${SG[i]}" 0
    i=$((i + 1))
  done
  set +f

  # R34b: GA_* or PATH changed around a ga invocation (e.g. GA_RUNNERS_DIR=... ga verify,
  # PATH=/tmp/fake:$PATH ga verify) could redirect the verifier or its billing preflight; so can
  # BASH_ENV / ENV, which bash sources when ga or a runner script starts (R2#5).
  local re_word_ga='(^|[^A-Za-z0-9_-])ga([^A-Za-z0-9_-]|$)'
  local re_env='(^|[^A-Za-z0-9_])(GA_[A-Za-z0-9_]*|PATH|BASH_ENV|ENV)\+?='
  local re_exp='(^|[^A-Za-z0-9_])(export|declare|typeset|readonly|local)[[:space:]]+(-[A-Za-z]+[[:space:]]+)*(GA_[A-Za-z0-9_]*|PATH|BASH_ENV|ENV)([^A-Za-z0-9_]|$)'
  if [[ $body =~ $re_word_ga ]]; then ga_seen=1; fi
  if [ "$OWN" = 0 ]; then
    # (a) internal calls are never callable from Bash, in any phase (A1, R2#1, R2#3). Parsed: a
    # command word that resolves to ga with user-command, gate or hook after its global options,
    # and any run of a file named hook.sh -- with or without a design.
    if [ "$internal" = hook.sh ]; then
      _ga_ev_deny "${where:+$where: }어댑터의 훅 스크립트(hook.sh)는 직접 실행할 수 없습니다. 훅은 하니스가 실행하고, 사용자만 'GA ...' 명령으로 상태를 바꿉니다"
      return 0
    elif [ -n "$internal" ]; then
      _ga_ev_deny "${where:+$where: }ga 내부 명령($internal)은 직접 호출할 수 없습니다. 사용자만 'GA ...' 명령으로 호출합니다"
      return 0
    fi
    # The text net for forms the parser does not know (timeout ga user-command, find -exec ...),
    # only when a design is reachable: without one, ga user-command changes nothing (R30), and a
    # text match would only deny mentions such as commit messages (R2#1).
    if [[ $cmd =~ $re_internal ]] && { [ $DISC = 0 ] || _ga_reach_active 0; }; then
      [ $DISC = 0 ] && AW=$where
      _ga_ev_deny "$AW: ga 내부 명령(user-command, hook)은 직접 호출할 수 없습니다. 사용자만 'GA ...' 명령으로 호출합니다"
      return 0
    fi
    # A2: R34b for the cwd's design and for every design the command can reach.
    if [ "$ga_seen" = 1 ] && { [[ $body =~ $re_env ]] || [[ $body =~ $re_exp ]]; }; then
      if [ $DISC = 0 ] || _ga_reach_active 0; then
        [ $DISC = 0 ] && AW=$where
        _ga_ev_deny "$AW: ga를 실행하는 명령에서 GA_ 변수나 PATH를 바꿀 수 없습니다 (검증 실행기와 과금 점검을 바꿀 수 있습니다). 변수 없이 ga만 실행하세요"
        return 0
      fi
    fi
    # B2: a relative target after an unknown cd that may be .state of a design above the cwd.
    if [ -n "$T_ANC" ]; then
      _ga_ev_deny "$ANC_W: 설계 상태(docs/architecture/.state/)나 그 상위 디렉터리를 쓰거나 지우는 명령은 막혀 있습니다 (감지된 패턴: $T_ANC). 상태는 ga 명령으로만 바꿉니다. 필요하면 사용자에게 \`GA 일시정지\`를 요청하세요"
      return 0
    fi
    # A2: R32b for every design the command can reach (the cwd's own is checked below).
    if [ $DISC = 1 ] && [ -n "$T_GIT" ] && _ga_reach_active 1; then
      _ga_ev_deny "$AW: $T_GIT 명령은 추적하지 않는 파일(docs/architecture/.state 포함)을 지우므로 설계 중에는 막혀 있습니다. 지울 파일을 직접 지정하거나 사용자에게 \`GA 일시정지\`를 요청하세요"
      return 0
    fi
  fi
  [ $DISC = 0 ] || return 0

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
    _ga_ev_deny "$where: 설계 상태(docs/architecture/.state/)나 그 상위 디렉터리를 쓰거나 지우는 명령은 막혀 있습니다 (감지된 패턴: $state_hit). 상태는 ga 명령으로만 바꿉니다. 필요하면 사용자에게 \`GA 일시정지\`를 요청하세요"
    return 0
  fi

  # R34d: the plugin is read-only while the design is active (targets, or a mention of it
  # together with a write).
  if [ -z "$T_PLUGIN" ] && { [ -n "$match" ] || [ "$R_ANYBAD" = 1 ]; }; then
    case "$lbody" in *"$(_ga_lc "$PLUG")"* | *grounded-arch/*) T_PLUGIN=$match ;; esac
  fi
  if [ -n "$T_PLUGIN" ]; then
    _ga_ev_deny "$where: 설계가 진행 중인 동안 grounded-arch 플러그인($PLUG)은 고칠 수 없습니다 (감지된 대상: $T_PLUGIN). 필요하면 사용자에게 \`GA 일시정지\`를 요청하세요"
    return 0
  fi

  # R32b: git clean / git stash -u delete untracked files such as .state, in any phase.
  if [ "$OWN" = 0 ] && [ -n "$T_GIT" ]; then
    _ga_ev_deny "$where: $T_GIT 명령은 추적하지 않는 파일(docs/architecture/.state 포함)을 지우므로 설계 중에는 막혀 있습니다. 지울 파일을 직접 지정하거나 사용자에게 \`GA 일시정지\`를 요청하세요"
    return 0
  fi

  case "$phase" in
    inputs | iterating | design-review | corrupt)
      [ -n "$match" ] || match=$R_BAD
      if [ -n "$match" ]; then
        if [ "$corrupt" = 1 ]; then
          _ga_ev_deny "$(_ga_corrupt_reason "$root") 그동안 파일을 쓰는 명령은 막고 읽기 명령만 허용합니다 (감지된 패턴: $match)"
        else
          _ga_ev_deny "$where: 설계 승인 전에는 파일을 쓰는 명령을 실행할 수 없습니다 (감지된 패턴: $match). 설계는 docs/architecture/ 안에 기록하거나 사용자에게 \`GA 일시정지\`를 요청하세요"
        fi
        return 0
      fi
      ;;
    skeleton)
      # R32c: brownfield skeleton applies the mapping rule of the write gate to shell writes.
      if [ "$GS_MODE" = brownfield ]; then
        if [ -n "$T_UNRES" ]; then
          _ga_ev_deny "$where (기존 코드): 쓰는 대상 경로를 확인할 수 없습니다 (감지된 대상: $T_UNRES). 대응표(mapping)의 경로를 그대로 쓰거나 사용자에게 \`GA 일시정지\`를 요청하세요"
          return 0
        fi
        local c rc
        while IFS= read -r c; do
          [ -n "$c" ] || continue
          _ga_mapped "$root" "$c"
          rc=$?
          if [ "$rc" = 2 ]; then
            _ga_ev_deny "원장(ledger.json)을 읽을 수 없어 대응표를 확인할 수 없습니다. 원장을 고치거나 사용자에게 \`GA 일시정지\`를 요청하세요"
            return 0
          elif [ "$rc" != 0 ]; then
            _ga_ev_deny "$where (기존 코드): 대응표(mapping)에서 change가 new 또는 changed로 지정된 경로만 쓸 수 있습니다 (감지된 대상: ${c#"$root"/}). 대응표에 경로를 추가하거나 사용자에게 \`GA 일시정지\`를 요청하세요"
            return 0
          fi
        done <<EOF
$TL
EOF
      fi
      ;;
  esac
  return 0
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
