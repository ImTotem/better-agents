#!/bin/bash
# Claude Code adapter: OS isolation settings (spec 5.5 G-sandbox).
# Usage: enforce.sh install ROOT   merges the sandbox keys into .claude/settings.local.json at the
#                                  repository's main checkout; prints the settings path.
#        enforce.sh status ROOT    prints {"active":bool,"reason":"...","settings":"<path>"}
# No git command is run. bash 3.2 + jq only.

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

[ $# -eq 2 ] || die "사용법: enforce.sh install|status ROOT" 2
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

do_status() {
  local managed files f merged
  if [ "$(uname -s)" = Darwin ]; then
    managed="/Library/Application Support/ClaudeCode/managed-settings.json"
  else
    managed=/etc/claude-code/managed-settings.json
  fi
  if [ "${GA_TEST_MODE:-}" = 1 ] && [ -n "${GA_TEST_MANAGED_SETTINGS:-}" ]; then managed=$GA_TEST_MANAGED_SETTINGS; fi
  if [ ! -f "$SETTINGS" ] || [ ! -r "$SETTINGS" ]; then out false "격리 설정 파일이 없거나 읽을 수 없습니다: $SETTINGS (ga enforce 로 설치하세요)"; fi
  jq -e 'type == "object"' "$SETTINGS" >/dev/null 2>&1 || out false "격리 설정 파일이 올바른 JSON이 아닙니다: $SETTINGS"
  # Highest precedence first: managed, local, project, user. Unreadable non-local files are skipped.
  files=""
  for f in "$managed" "$SETTINGS" "$ROOT/.claude/settings.json" "$HOME/.claude/settings.json"; do
    if [ -f "$f" ] && jq -e 'type == "object"' "$f" >/dev/null 2>&1; then files="$files$f
"; fi
  done
  merged=$(printf '%s' "$files" | while IFS= read -r f; do [ -n "$f" ] && cat "$f"; done | jq -s --arg sd "$SD" '
    def first_def(p): [.[] | p | select(. != null)] | .[0];
    { enabled: first_def(.sandbox.enabled),
      unsandboxed: first_def(.sandbox.allowUnsandboxedCommands),
      denied: ([.[] | .sandbox.filesystem.denyWrite[]?] | index($sd) != null) }') || out false "설정을 읽지 못했습니다"
  [ "$(jq -r .enabled <<<"$merged")" = true ] || out false "sandbox.enabled 가 true 가 아닙니다 (관리, 사용자, 프로젝트, 로컬 설정을 합쳐 본 결과)"
  [ "$(jq -r .unsandboxed <<<"$merged")" = false ] || out false "sandbox.allowUnsandboxedCommands 가 false 가 아닙니다 (격리 밖 실행이 허용됨)"
  [ "$(jq -r .denied <<<"$merged")" = true ] || out false "sandbox.filesystem.denyWrite 에 상태 폴더($SD)가 없습니다"
  out true "격리 설정이 켜져 있습니다"
}

case "$cmd" in
  install) do_install ;;
  status) do_status ;;
  *) die "사용법: enforce.sh install|status ROOT" 2 ;;
esac
