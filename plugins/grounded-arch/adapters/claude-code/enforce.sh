#!/bin/bash
# Claude Code adapter: OS isolation settings (spec 5.5 G-sandbox).
# Usage: enforce.sh install ROOT   merges the sandbox keys into .claude/settings.local.json at the
#                                  repository's main checkout; prints the settings path.
#        enforce.sh status ROOT    prints {"active":bool,"reason":"...","settings":"<path>"}
#        enforce.sh protects ROOT PATH
#                                  exit 0 when canonical PATH is a Claude Code settings file
#                                  (.claude/settings*.json of ROOT, of the main checkout, or of
#                                  ~/.claude) -- the write gate keeps the agent's tools off them; 1 if not
# No git command is run. bash 3.2 + jq only. status runs on every shell command: one jq call.

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

# Sets MAIN (main checkout) and COMMON (common git dir, "" when not git) for ROOT.
find_main() { # ROOT
  local d=$1 gd cdir line
  MAIN=$1; COMMON=""
  while :; do
    if [ -d "$d/.git" ]; then
      MAIN=$d; COMMON=$d/.git; return 0
    elif [ -f "$d/.git" ]; then
      line=$(sed -n 's/^gitdir: *//p' "$d/.git" | head -n 1)
      gd=$(resolve_dir "$line" "$d") || return 0
      if [ -f "$gd/commondir" ]; then
        cdir=$(resolve_dir "$(head -n 1 "$gd/commondir")" "$gd") || return 0
        COMMON=$cdir; MAIN=$(dirname "$cdir")
      else
        COMMON=$gd; MAIN=$d   # submodule-style gitdir: the checkout is where .git lives
      fi
      return 0
    fi
    [ "$d" = / ] && return 0
    d=$(dirname "$d")
  done
}

USAGE="사용법: enforce.sh install|status ROOT | enforce.sh protects ROOT PATH"
case "$1:$#" in install:2 | status:2 | protects:3) ;; *) die "$USAGE" 2 ;; esac
cmd=$1
ROOT=$(resolve_dir "$2" "$PWD") || die "enforce: 디렉터리가 아닙니다: $2" 2
find_main "$ROOT"
SETTINGS=$MAIN/.claude/settings.local.json
SD=$ROOT/docs/architecture/.state

do_install() {
  local base tmp deny
  command -v jq >/dev/null 2>&1 || die "enforce: jq가 필요합니다" 2
  mkdir -p "$MAIN/.claude" || die "enforce: $MAIN/.claude 를 만들 수 없습니다" 2
  if [ -s "$SETTINGS" ]; then
    jq -e 'type == "object"' "$SETTINGS" >/dev/null 2>&1 || die "enforce: $SETTINGS 이(가) 올바른 JSON 객체가 아니어서 합칠 수 없습니다. 파일을 고친 뒤 다시 실행하세요" 2
    base=$SETTINGS
  else
    base=""
  fi
  deny=$(jq -nc --arg s "$SD" --arg p "$PLUGIN_ROOT" --arg r "$ROOT" \
    '[$s] + (if ($p | startswith($r + "/")) then [$p] else [] end)')
  tmp=$(mktemp "$MAIN/.claude/.settings.local.json.XXXXXX") || die "enforce: 임시 파일을 만들 수 없습니다" 2
  if ! { if [ -n "$base" ]; then cat "$base"; else echo '{}'; fi; } | jq --argjson deny "$deny" '
      .sandbox = ((.sandbox // {}) + {enabled: true, failIfUnavailable: true, allowUnsandboxedCommands: false})
      | .sandbox.filesystem = ((.sandbox.filesystem // {}) + {denyWrite: (((.sandbox.filesystem.denyWrite // []) + $deny) | reduce .[] as $x ([]; if index($x) then . else . + [$x] end))})' >"$tmp"; then
    rm -f "$tmp"; die "enforce: 설정을 합치지 못했습니다" 2
  fi
  mv "$tmp" "$SETTINGS" || { rm -f "$tmp"; die "enforce: 설정 파일을 쓸 수 없습니다" 2; }
  if [ -n "$COMMON" ]; then
    mkdir -p "$COMMON/info" 2>/dev/null
    if ! grep -Fxq '.claude/settings.local.json' "$COMMON/info/exclude" 2>/dev/null; then
      printf '%s\n' '.claude/settings.local.json' >>"$COMMON/info/exclude" ||
        echo "enforce: 경고: $COMMON/info/exclude 에 추가하지 못했습니다. 설정 파일을 .gitignore 에 직접 추가하세요" >&2
    fi
  fi
  echo "$SETTINGS"
}

out() { jq -nc --argjson a "$1" --arg r "$2" --arg s "$SETTINGS" '{active:$a, reason:$r, settings:$s}'; exit 0; }

readable() { if [ -f "$1" ] && [ -r "$1" ]; then echo "$1"; else echo /dev/null; fi; } # FILE -> FILE or /dev/null

do_status() {
  local managed
  case "${OSTYPE:-}" in
    darwin*) managed="/Library/Application Support/ClaudeCode/managed-settings.json" ;;
    *) managed=/etc/claude-code/managed-settings.json ;;
  esac
  if [ "${GA_TEST_MODE:-}" = 1 ] && [ -n "${GA_TEST_MANAGED_SETTINGS:-}" ]; then managed=$GA_TEST_MANAGED_SETTINGS; fi
  if [ ! -f "$SETTINGS" ] || [ ! -r "$SETTINGS" ]; then out false "격리 설정 파일이 없거나 읽을 수 없습니다: $SETTINGS (ga enforce 로 설치하세요)"; fi
  # Highest precedence first: managed, local, project, user. Unreadable or invalid non-local files
  # are skipped; an invalid local file is reported.
  jq -nc --rawfile m "$(readable "$managed")" --rawfile l "$SETTINGS" --rawfile p "$(readable "$ROOT/.claude/settings.json")" \
    --rawfile u "$(readable "$HOME/.claude/settings.json")" --arg sd "$SD" --arg s "$SETTINGS" '
    def obj: (try fromjson catch null) | if type == "object" then . else null end;
    def res($a; $r): {active: $a, reason: $r, settings: $s};
    ($l | obj) as $lo
    | if $lo == null then res(false; "격리 설정 파일이 올바른 JSON이 아닙니다: \($s)")
      else
        ([($m | obj), $lo, ($p | obj), ($u | obj)] | map(select(. != null))) as $fs
        | ([$fs[] | try .sandbox.enabled | select(. != null)] | .[0]) as $en
        | ([$fs[] | try .sandbox.allowUnsandboxedCommands | select(. != null)] | .[0]) as $un
        | ([$fs[] | try .sandbox.filesystem.denyWrite[]] | index($sd) != null) as $dn
        | if $en != true then res(false; "sandbox.enabled 가 true 가 아닙니다 (관리, 사용자, 프로젝트, 로컬 설정을 합쳐 본 결과)")
          elif $un != false then res(false; "sandbox.allowUnsandboxedCommands 가 false 가 아닙니다 (격리 밖 실행이 허용됨)")
          elif ($dn | not) then res(false; "sandbox.filesystem.denyWrite 에 상태 폴더(\($sd))가 없습니다")
          else res(true; "격리 설정이 켜져 있습니다") end
      end' 2>/dev/null || out false "설정을 읽지 못했습니다"
}

# Canonical form of directory D, which need not exist (its parent is resolved instead).
canon_dir() { # D
  if [ -d "$1" ]; then (cd -P "$1" 2>/dev/null && pwd -P) && return 0; fi
  printf '%s/%s\n' "$(cd -P "$(dirname "$1")" 2>/dev/null && pwd -P)" "$(basename "$1")"
}

do_protects() { # PATH (canonical, from the core's write gate)
  local p=$1 d n dir
  d=${p%/*}; n=${p##*/}
  shopt -s nocasematch # APFS is case-insensitive: .CLAUDE/Settings.json is the same file
  case "$n" in settings*.json) ;; *) exit 1 ;; esac
  for dir in "$ROOT/.claude" "$MAIN/.claude" "$HOME/.claude"; do
    [[ $d == "$(canon_dir "$dir")" ]] && exit 0
  done
  exit 1
}

case "$cmd" in
  install) do_install ;;
  status) do_status ;;
  protects) do_protects "$3" ;;
esac
