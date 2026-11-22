#!/bin/bash
# Claude Code adapter: OS isolation settings (spec 5.5 G-sandbox).
# Usage: enforce.sh install ROOT [--record]
#                                  merges the sandbox keys into .claude/settings.local.json at the
#                                  repository's main checkout; prints the settings path (and, with
#                                  --record, a second line: the JSON record of what it added, which
#                                  the core keeps in .state/enforce.json)
#        enforce.sh uninstall ROOT removes exactly what install added (P23; reads .state/enforce.json)
#        enforce.sh status ROOT    prints {"active":bool,"reason":"...","settings":"<path>","warnings":[...]}
#        enforce.sh protects ROOT PATH
#                                  exit 0 when canonical PATH is a Claude Code settings file
#                                  (.claude/settings*.json of ROOT, of the main checkout, of ~/.claude
#                                  or CLAUDE_CONFIG_DIR); exit 3 when Claude Code runs it outside the
#                                  sandbox (.mcp.json of the project, ~/.claude.json, ~/.claude/plugins);
#                                  1 if neither
#        enforce.sh protects ROOT --list
#                                  the same for paths on stdin: prints "0 PATH" or "3 PATH" lines
#        enforce.sh exec ROOT [--protect PATH]... -- CMD [ARG...]
#                                  runs CMD in an OS sandbox (macOS sandbox-exec, Linux bwrap) where
#                                  the state folder, the settings files, the plugin folder, the files
#                                  Claude Code runs outside the sandbox and each PATH are read-only;
#                                  exit 125 with "격리 실행 도구 없음" when there is no sandbox tool
# No git command is run. bash 3.2 + jq only. status runs on every shell command: one jq call.

# This runs outside the OS sandbox: no relative PATH entry is ever searched, jq by absolute path.
_p=""; _o=$IFS; IFS=:; set -f
for _e in $PATH; do case "$_e" in /*) _p=${_p:+$_p:}$_e ;; esac; done
set +f; IFS=$_o; PATH=$_p; export PATH; unset _p _o _e
GA_JQ=/usr/bin/jq
[ -x "$GA_JQ" ] || GA_JQ=$(type -P jq 2>/dev/null) || GA_JQ=/nonexistent/jq
if [ "${GA_TEST_MODE:-}" = 1 ] && [ -n "${GA_TEST_JQ:-}" ]; then GA_JQ=$GA_TEST_JQ; fi
jq() { "$GA_JQ" "$@"; }

_self=${BASH_SOURCE[0]}
while [ -L "$_self" ]; do
  _dir=$(cd -P "$(dirname "$_self")" && pwd)
  _self=$(readlink "$_self")
  case "$_self" in /*) ;; *) _self=$_dir/$_self ;; esac
done
PLUGIN_ROOT=$(cd -P "$(dirname "$_self")/../.." && pwd)

die() { echo "$1" >&2; exit "${2:-2}"; }

# Resolves PATH (absolute, or relative to BASE) to a physical absolute path; fails if not a directory.
resolve_dir() { # PATH BASE
  case "$1" in /*) (cd -P "$1" 2>/dev/null && pwd -P) ;; *) (cd -P "$2/$1" 2>/dev/null && pwd -P) ;; esac
}

# Canonical form of directory D, which need not exist (its parent is resolved instead).
canon_dir() { # D
  if [ -d "$1" ]; then (cd -P "$1" 2>/dev/null && pwd -P) && return 0; fi
  printf '%s/%s\n' "$(cd -P "$(dirname "$1")" 2>/dev/null && pwd -P)" "$(basename "$1")"
}

is_bare() { grep -Eiq '^[[:space:]]*bare[[:space:]]*=[[:space:]]*true[[:space:]]*$' "$1/config" 2>/dev/null; } # GITDIR

# Sets MAIN (the checkout whose .claude/settings.local.json Claude Code reads: the repository root, the
# main checkout for a worktree), COMMON (common git dir, "" when not git) and LAYOUT_ERR. P24: a layout
# where that file cannot be named with certainty (a bare repository, a .git file whose git dir has no
# commondir, a common dir that is not a checkout's .git) sets LAYOUT_ERR: install refuses, status is
# inactive.
find_main() { # ROOT
  local d=$1 gd cdir line
  MAIN=$1; COMMON=""; LAYOUT_ERR=""
  while :; do
    if [ -d "$d/.git" ]; then
      MAIN=$d; COMMON=$d/.git
      is_bare "$COMMON" && LAYOUT_ERR="${COMMON} 이(가) bare 저장소로 설정되어 있습니다"
      return 0
    elif [ -f "$d/.git" ]; then
      line=$(sed -n 's/^gitdir: *//p' "$d/.git" | head -n 1)
      gd=$(resolve_dir "$line" "$d") || { LAYOUT_ERR="${d}/.git 이 가리키는 git 폴더를 찾을 수 없습니다"; return 0; }
      if [ ! -f "$gd/commondir" ]; then
        LAYOUT_ERR="${d}/.git 이 가리키는 git 폴더(${gd})에 commondir 이 없습니다(서브모듈이나 --separate-git-dir 저장소)"; return 0
      fi
      cdir=$(resolve_dir "$(head -n 1 "$gd/commondir")" "$gd") || { LAYOUT_ERR="${gd}/commondir 이 가리키는 폴더를 찾을 수 없습니다"; return 0; }
      if [ "$(basename "$cdir")" != .git ]; then
        LAYOUT_ERR="공통 git 폴더(${cdir})가 일반 체크아웃의 .git 이 아닙니다(bare 저장소 등)"; return 0
      fi
      if is_bare "$cdir"; then LAYOUT_ERR="공통 git 폴더(${cdir})가 bare 저장소로 설정되어 있습니다"; return 0; fi
      COMMON=$cdir; MAIN=$(dirname "$cdir")
      return 0
    fi
    [ "$d" = / ] && return 0
    d=$(dirname "$d")
  done
}

USAGE="사용법: enforce.sh install ROOT [--record] | uninstall ROOT | status ROOT | protects ROOT PATH|--list | exec ROOT [--protect PATH]... -- CMD..."
case "$1:$#" in
  install:2 | uninstall:2 | status:2 | protects:3) ;;
  install:3) [ "$3" = --record ] || die "$USAGE" 2 ;;
  exec:*) [ $# -ge 4 ] || die "$USAGE" 2 ;;
  *) die "$USAGE" 2 ;;
esac
cmd=$1
ROOT=$(resolve_dir "$2" "$PWD") || die "enforce: 디렉터리가 아닙니다: $2" 2
find_main "$ROOT"
SETTINGS=$MAIN/.claude/settings.local.json
SD=$ROOT/docs/architecture/.state
RECORD=$SD/enforce.json
LAYOUT_MSG="Claude Code가 어느 설정 파일을 읽는지 확실히 정할 수 없는 저장소 구조입니다"
WANT='{"enabled":true,"failIfUnavailable":true,"allowUnsandboxedCommands":false}'

do_install() {
  local obj created=false old tmp deny both excl=false
  [ -z "$LAYOUT_ERR" ] || die "enforce: 격리 설정을 쓰지 않았습니다. ${LAYOUT_MSG}: ${LAYOUT_ERR}" 2
  command -v jq >/dev/null 2>&1 || die "enforce: jq가 필요합니다" 2
  mkdir -p "$MAIN/.claude" || die "enforce: $MAIN/.claude 를 만들 수 없습니다" 2
  if [ -s "$SETTINGS" ]; then
    jq -e 'type == "object"' "$SETTINGS" >/dev/null 2>&1 || die "enforce: $SETTINGS 이(가) 올바른 JSON 객체가 아니어서 합칠 수 없습니다. 파일을 고친 뒤 다시 실행하세요" 2
    obj=$(cat "$SETTINGS")
  else
    [ -e "$SETTINGS" ] || created=true
    obj='{}'
  fi
  # The earlier record of this design (same settings file): what ga set stays recorded as ga's.
  old='{}'
  if [ -f "$RECORD" ]; then
    old=$(jq -c --arg s "$SETTINGS" 'if type == "object" and .settings == $s then . else {} end' "$RECORD" 2>/dev/null) || old='{}'
  fi
  deny=$(jq -nc --arg s "$SD" --arg p "$PLUGIN_ROOT" --arg r "$ROOT" \
    '[$s] + (if ($p | startswith($r + "/")) then [$p] else [] end)')
  # One jq call: the merged settings and the record (P23: keys ga set with their previous value,
  # keys found already set, denyWrite entries ga added, whether ga created the file).
  both=$(printf '%s' "$obj" | jq -c --argjson deny "$deny" --argjson old "$old" --argjson want "$WANT" --argjson created "$created" '
    (.sandbox // {}) as $sb
    | ($sb.filesystem.denyWrite // []) as $dw
    | {settings: (.sandbox = ($sb + $want)
        | .sandbox.filesystem = ((.sandbox.filesystem // {}) + {denyWrite: (($dw + $deny) | reduce .[] as $x ([]; if index($x) then . else . + [$x] end))})),
       record: {
         keys: (($old.keys // {}) + ([$want | to_entries[] | . as $e | select(($old.keys // {}) | has($e.key) | not)
                 | select($sb[$e.key] != $e.value) | {key: $e.key, value: {absent: ($sb | has($e.key) | not), previous: $sb[$e.key]}}] | from_entries)),
         found: [$want | to_entries[] | . as $e | select(($old.keys // {}) | has($e.key) | not) | select($sb[$e.key] == $e.value) | $e.key],
         deny_added: ((($old.deny_added // []) + [$deny[] | select(. as $x | $dw | index($x) | not)]) | unique),
         created: ($old.created // $created)}}') || die "enforce: 설정을 합치지 못했습니다" 2
  tmp=$(mktemp "$MAIN/.claude/.settings.local.json.XXXXXX") || die "enforce: 임시 파일을 만들 수 없습니다" 2
  if ! printf '%s' "$both" | jq '.settings' >"$tmp"; then rm -f "$tmp"; die "enforce: 설정을 합치지 못했습니다" 2; fi
  mv "$tmp" "$SETTINGS" || { rm -f "$tmp"; die "enforce: 설정 파일을 쓸 수 없습니다" 2; }
  if [ -n "$COMMON" ]; then
    mkdir -p "$COMMON/info" 2>/dev/null
    if ! grep -Fxq '.claude/settings.local.json' "$COMMON/info/exclude" 2>/dev/null; then
      if printf '%s\n' '.claude/settings.local.json' >>"$COMMON/info/exclude"; then
        excl=true
      else
        echo "enforce: 경고: $COMMON/info/exclude 에 추가하지 못했습니다. 설정 파일을 .gitignore 에 직접 추가하세요" >&2
      fi
    fi
  fi
  echo "$SETTINGS"
  if [ "${1:-}" = --record ]; then
    printf '%s' "$both" | jq -c --arg s "$SETTINGS" --argjson x "$excl" --argjson old "$old" \
      '.record + {settings: $s, exclude_added: (($old.exclude_added // false) or $x)}'
  fi
}

do_uninstall() {
  local rs obj new tmp
  [ -z "$LAYOUT_ERR" ] || die "enforce: ${LAYOUT_MSG}: ${LAYOUT_ERR}" 2
  [ -f "$RECORD" ] && jq -e 'type == "object"' "$RECORD" >/dev/null 2>&1 ||
    die "enforce: 설치 기록(${RECORD})이 없거나 읽을 수 없어 무엇을 지울지 알 수 없습니다" 2
  rs=$(jq -r '.settings // ""' "$RECORD")
  [ "$rs" = "$SETTINGS" ] || die "enforce: 설치 기록의 설정 파일(${rs})이 지금 Claude Code가 읽는 파일(${SETTINGS})과 달라 지우지 않았습니다" 2
  if [ -e "$SETTINGS" ]; then
    if [ -s "$SETTINGS" ]; then
      jq -e 'type == "object"' "$SETTINGS" >/dev/null 2>&1 || die "enforce: $SETTINGS 이(가) 올바른 JSON 객체가 아니어서 고칠 수 없습니다" 2
      obj=$(cat "$SETTINGS")
    else
      obj='{}'
    fi
    # A key goes back to its earlier value (or away) only while it still holds what ga set.
    new=$(printf '%s' "$obj" | jq -c --slurpfile r "$RECORD" --argjson want "$WANT" '
      $r[0] as $r
      | reduce (($r.keys // {}) | to_entries[]) as $e (.;
          if (.sandbox // {})[$e.key] == $want[$e.key] then
            (if $e.value.absent then del(.sandbox[$e.key]) else .sandbox[$e.key] = $e.value.previous end)
          else . end)
      | if (.sandbox.filesystem.denyWrite | type) == "array" then .sandbox.filesystem.denyWrite -= ($r.deny_added // []) else . end
      | if .sandbox.filesystem.denyWrite == [] then del(.sandbox.filesystem.denyWrite) else . end
      | if .sandbox.filesystem == {} then del(.sandbox.filesystem) else . end
      | if .sandbox == {} then del(.sandbox) else . end') || die "enforce: 설정을 고치지 못했습니다" 2
    if [ "$new" = '{}' ] && [ "$(jq -r '.created // false' "$RECORD")" = true ]; then
      rm -f "$SETTINGS" || die "enforce: $SETTINGS 를 지울 수 없습니다" 2
    else
      tmp=$(mktemp "$MAIN/.claude/.settings.local.json.XXXXXX") || die "enforce: 임시 파일을 만들 수 없습니다" 2
      if ! printf '%s' "$new" | jq . >"$tmp" || ! mv "$tmp" "$SETTINGS"; then rm -f "$tmp"; die "enforce: 설정 파일을 쓸 수 없습니다" 2; fi
    fi
  fi
  if [ -n "$COMMON" ] && [ "$(jq -r '.exclude_added // false' "$RECORD")" = true ] && [ -f "$COMMON/info/exclude" ]; then
    tmp=$(mktemp "$COMMON/info/.exclude.XXXXXX") &&
      awk '!d && $0 == ".claude/settings.local.json" { d = 1; next } { print }' "$COMMON/info/exclude" >"$tmp" &&
      mv "$tmp" "$COMMON/info/exclude" || { rm -f "$tmp"; echo "enforce: 경고: $COMMON/info/exclude 의 줄을 지우지 못했습니다" >&2; }
  fi
  echo "$SETTINGS"
}

out() { jq -nc --argjson a "$1" --arg r "$2" --arg s "$SETTINGS" '{active:$a, reason:$r, settings:$s, warnings:[]}'; exit 0; }

readable() { if [ -f "$1" ] && [ -r "$1" ]; then echo "$1"; else echo /dev/null; fi; } # FILE -> FILE or /dev/null

do_status() {
  local managed os=${OSTYPE:-}
  if [ "${GA_TEST_MODE:-}" = 1 ] && [ -n "${GA_TEST_OSTYPE:-}" ]; then os=$GA_TEST_OSTYPE; fi
  case "$os" in msys* | cygwin* | win32*) out false "윈도우(WSL 제외)에서는 Claude Code가 셸 명령을 격리 없이 실행합니다" ;; esac
  [ -z "$LAYOUT_ERR" ] || out false "${LAYOUT_MSG}: ${LAYOUT_ERR}"
  case "$os" in
    darwin*) managed="/Library/Application Support/ClaudeCode/managed-settings.json" ;;
    *) managed=/etc/claude-code/managed-settings.json ;;
  esac
  if [ "${GA_TEST_MODE:-}" = 1 ] && [ -n "${GA_TEST_MANAGED_SETTINGS:-}" ]; then managed=$GA_TEST_MANAGED_SETTINGS; fi
  if [ ! -f "$SETTINGS" ] || [ ! -r "$SETTINGS" ]; then out false "격리 설정 파일이 없거나 읽을 수 없습니다: $SETTINGS (ga enforce 로 설치하세요)"; fi
  # Highest precedence first: managed, local, project, user. Unreadable or invalid non-local files
  # are skipped; an invalid local file is reported. P22: excludedCommands (merged across files) run
  # outside the sandbox: still active, with a warning.
  jq -nc --rawfile m "$(readable "$managed")" --rawfile l "$SETTINGS" --rawfile p "$(readable "$ROOT/.claude/settings.json")" \
    --rawfile u "$(readable "$HOME/.claude/settings.json")" --arg sd "$SD" --arg s "$SETTINGS" '
    def obj: (try fromjson catch null) | if type == "object" then . else null end;
    ($l | obj) as $lo
    | ([($m | obj), $lo, ($p | obj), ($u | obj)] | map(select(. != null))) as $fs
    | ([$fs[] | try .sandbox.excludedCommands[] | strings] | unique) as $ex
    | def res($a; $r): {active: $a, reason: $r, settings: $s,
        warnings: (if ($ex | length) > 0 then ["sandbox.excludedCommands에 맞는 명령(\($ex | join(", ")))은 격리 밖에서 사용자 권한으로 실행되어 설계 상태 폴더도 바꿀 수 있습니다. 그런 변경은 상태 지문 확인이 잡습니다"] else [] end)};
      if $lo == null then res(false; "격리 설정 파일이 올바른 JSON이 아닙니다: \($s)")
      else
        ([$fs[] | try .sandbox.enabled | select(. != null)] | .[0]) as $en
        | ([$fs[] | try .sandbox.allowUnsandboxedCommands | select(. != null)] | .[0]) as $un
        | ([$fs[] | try .sandbox.filesystem.denyWrite[]] | index($sd) != null) as $dn
        | if $en != true then res(false; "sandbox.enabled 가 true 가 아닙니다 (관리, 사용자, 프로젝트, 로컬 설정을 합쳐 본 결과)")
          elif $un != false then res(false; "sandbox.allowUnsandboxedCommands 가 false 가 아닙니다 (격리 밖 실행이 허용됨)")
          elif ($dn | not) then res(false; "sandbox.filesystem.denyWrite 에 상태 폴더(\($sd))가 없습니다")
          else res(true; "격리 설정이 켜져 있습니다") end
      end' 2>/dev/null || out false "설정을 읽지 못했습니다"
}

# The directories and files protects and exec judge (physical paths).
protect_dirs() {
  local h
  h=$(cd -P "$HOME" 2>/dev/null && pwd -P) || h=$HOME
  HOME_P=$h
  HOME_C=$(canon_dir "$HOME/.claude")
  CFG_C=""; [ -n "${CLAUDE_CONFIG_DIR:-}" ] && CFG_C=$(canon_dir "$CLAUDE_CONFIG_DIR")
  ROOT_C=$(canon_dir "$ROOT/.claude"); MAIN_C=$(canon_dir "$MAIN/.claude")
  SESS_P=""; [ -n "${CLAUDE_PROJECT_DIR:-}" ] && SESS_P=$(resolve_dir "$CLAUDE_PROJECT_DIR" /) || SESS_P=""
}

# 0: a settings file with the isolation settings; 3: a file Claude Code runs outside the sandbox
# (P20); 1: neither. Case-folded: APFS is case-insensitive.
protect_kind() { # PATH (canonical)
  local p=$1 d n dir
  d=${p%/*}; n=${p##*/}
  shopt -s nocasematch
  for dir in "$HOME_C" "$CFG_C"; do
    [ -n "$dir" ] || continue
    [[ $p == "$dir/plugins" || $p == "$dir/plugins/"* ]] && return 3
  done
  [[ $p == "$HOME_P/.claude.json" ]] && return 3
  [ -n "$CFG_C" ] && [[ $p == "$CFG_C/.claude.json" ]] && return 3
  if [[ $n == .mcp.json ]]; then
    for dir in "$ROOT" "$MAIN" "$SESS_P"; do [ -n "$dir" ] && [[ $d == "$dir" ]] && return 3; done
  fi
  case "$n" in settings*.json) ;; *) return 1 ;; esac
  for dir in "$ROOT_C" "$MAIN_C" "$HOME_C" "$CFG_C"; do
    [ -n "$dir" ] && [[ $d == "$dir" ]] && return 0
  done
  return 1
}

do_protects() { # PATH | --list
  local p k
  protect_dirs
  if [ "$1" != --list ]; then protect_kind "$1"; exit $?; fi
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    k=0; protect_kind "$p" || k=$?
    [ "$k" = 1 ] || printf '%s %s\n' "$k" "$p"
  done
  exit 0
}

# SBPL string literal.
sb_str() { local s=$1; s=${s//\\/\\\\}; s=${s//\"/\\\"}; printf '"%s"' "$s"; }

do_exec() { # [--protect PATH]... -- CMD...
  local -a extra=() prot=() bw_args=()
  local p a seen=$'\n' prof sbx bw
  while [ $# -gt 0 ]; do
    case "$1" in
      --protect) [ $# -ge 2 ] || die "$USAGE" 2; extra+=("$2"); shift 2 ;;
      --) shift; break ;;
      *) die "$USAGE" 2 ;;
    esac
  done
  [ $# -gt 0 ] || die "$USAGE" 2
  protect_dirs
  prot=("$SD" "$PLUGIN_ROOT" "$HOME_C/settings.json" "$HOME_C/settings.local.json" "$HOME_C/plugins" "$HOME_P/.claude.json"
        "$ROOT_C/settings.json" "$ROOT_C/settings.local.json" "$MAIN_C/settings.json" "$MAIN_C/settings.local.json"
        "$ROOT/.mcp.json" "$MAIN/.mcp.json")
  [ -z "$CFG_C" ] || prot+=("$CFG_C/settings.json" "$CFG_C/settings.local.json" "$CFG_C/plugins" "$CFG_C/.claude.json")
  [ -z "$COMMON" ] || prot+=("$COMMON/config" "$COMMON/hooks")
  for p in ${extra[@]+"${extra[@]}"}; do prot+=("$(canon_dir "$p")"); done

  sbx=/usr/bin/sandbox-exec
  bw=/usr/bin/bwrap; [ -x "$bw" ] || bw=$(type -P bwrap 2>/dev/null) || bw=""
  # The test suite simulates a machine without a sandbox tool (honored only in test mode).
  if [ "${GA_TEST_MODE:-}" = 1 ] && [ -n "${GA_TEST_SANDBOX_EXEC:-}" ]; then sbx=$GA_TEST_SANDBOX_EXEC; bw=""; fi
  if [ -x "$sbx" ]; then
    # Seatbelt judges paths, so every parent folder of a protected path is protected from renames
    # too (writing files inside those folders stays allowed).
    prof="(version 1)(allow default)(deny file-write*"
    for p in "${prot[@]}"; do
      prof="$prof (subpath $(sb_str "$p"))"
      a=${p%/*}
      while [ -n "$a" ]; do
        case "$seen" in *$'\n'"$a"$'\n'*) ;; *) seen=$seen$a$'\n'; prof="$prof (literal $(sb_str "$a"))" ;; esac
        a=${a%/*}
      done
    done
    prof="$prof)"
    exec "$sbx" -p "$prof" "$@"
  elif [ -n "$bw" ]; then
    # Bind mounts follow the folder, so a renamed parent keeps them read-only.
    bw_args=(--dev-bind / /)
    for p in "${prot[@]}"; do bw_args+=(--ro-bind-try "$p" "$p"); done
    exec "$bw" "${bw_args[@]}" -- "$@"
  fi
  echo "격리 실행 도구 없음 (macOS sandbox-exec 나 Linux bwrap 이 필요합니다)" >&2
  exit 125
}

case "$cmd" in
  install) do_install "${3:-}" ;;
  uninstall) do_uninstall ;;
  status) do_status ;;
  protects) do_protects "$3" ;;
  exec) shift 2; do_exec "$@" ;;
esac
