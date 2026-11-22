# grounded-arch common helpers. Sourced; bash 3.2 compatible. No set -e here.

# --- code outside the OS sandbox (spec 5.5, P28) -------------------------------------------------
# Hooks, the MCP server, the adapter and ga run outside the sandbox. Each entry point starts by saving
# the caller's PATH as GA_USER_PATH and setting PATH=/usr/bin:/bin:/usr/sbin:/sbin, so every tool ga
# itself runs (tail, sed, mktemp, sha256sum ...) is a system tool. jq is /usr/bin/jq only; git is the
# developer tools' own binary (ga_git_resolve). Only the verifier runners, their preflight and the
# sandboxed build check use the user's PATH (ga_user_path). Nothing in the environment can point ga
# at other tools outside test mode (GA_TEST_MODE=1).

# The user's PATH (GA_USER_PATH, else PATH) without empty or relative entries and without entries
# inside any DIR given -- compared as typed and in their one physical spelling (ga_phys_dir), so a
# symlinked, firmlinked or differently cased entry cannot slip past: the agent can write those.
ga_user_path() { # [DIR...]
  local out="" e d p skip oldifs=$IFS noglob=1
  local -a dirs=() ents=()
  for d in "$@"; do
    case "$d" in "" | /) continue ;; esac # / holds everything: never a project
    dirs+=("${d%/}")
    p=$(ga_phys_dir "$d" 2>/dev/null) && dirs+=("${p%/}")
  done
  case $- in *f*) ;; *) noglob=0; set -f ;; esac
  IFS=:
  for e in ${GA_USER_PATH:-$PATH}; do ents+=("$e"); done
  IFS=$oldifs
  [ "$noglob" = 0 ] && set +f
  for e in ${ents[@]+"${ents[@]}"}; do
    case "$e" in /*) ;; *) continue ;; esac
    p=""; [ ${#dirs[@]} -eq 0 ] || p=$(ga_phys_dir "$e" 2>/dev/null) || p=""
    skip=0
    for d in ${dirs[@]+"${dirs[@]}"}; do
      case "${e%/}/" in "$d"/*) skip=1; break ;; esac
      [ -n "$p" ] || continue
      case "${p%/}/" in "$d"/*) skip=1; break ;; esac
    done
    [ "$skip" = 1 ] || out=${out:+$out:}$e
  done
  printf '%s' "$out"
}

# jq is /usr/bin/jq only (P28); without it the callers' jq-unusable paths apply. The test suite
# simulates a missing or broken jq (honored only in test mode).
GA_JQ=/usr/bin/jq
if [ "${GA_TEST_MODE:-}" = 1 ] && [ -n "${GA_TEST_JQ:-}" ]; then GA_JQ=$GA_TEST_JQ; fi
jq() { "$GA_JQ" "$@"; }

# git is resolved once, on first use, and never from the environment. On macOS /usr/bin/git is the
# xcrun shim, which reads $TMPDIR/xcrun_db and DEVELOPER_DIR and can run a program from there: the
# real binary under the selected developer folder is used instead (xcode-select without
# DEVELOPER_DIR), else the Command Line Tools one. Elsewhere /usr/bin/git. rc 1 when there is none.
GA_GIT=""
ga_git_resolve() {
  local d
  [ -z "$GA_GIT" ] || { [ -x "$GA_GIT" ]; return; }
  if [ "${GA_TEST_MODE:-}" = 1 ] && [ -n "${GA_TEST_GIT:-}" ]; then
    GA_GIT=$GA_TEST_GIT
  elif [ -x /usr/bin/xcode-select ]; then
    d=$(/usr/bin/env -u DEVELOPER_DIR /usr/bin/xcode-select -p 2>/dev/null) || d=""
    case "$d" in /*) GA_GIT=$d/usr/bin/git ;; *) GA_GIT="" ;; esac
    [ -n "$GA_GIT" ] && [ -x "$GA_GIT" ] || GA_GIT=/Library/Developer/CommandLineTools/usr/bin/git
  else
    GA_GIT=/usr/bin/git
  fi
  [ -x "$GA_GIT" ]
}

# The session's directory: the project root the harness gave the hook adapter (GA_SESSION_ROOT, which
# the agent cannot move with cd), else the current directory (CLI use).
ga_session_dir() { printf '%s\n' "${GA_SESSION_ROOT:-$PWD}"; }

ga_die() { # MSG [CODE]
  echo "$1" >&2
  exit "${2:-2}"
}

ga_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Walk up from START to the dir containing docs/architecture/.state/state.json.
# Never crosses a repository boundary: the walk stops after checking the first directory
# that contains .git (a directory in a checkout, a file in a worktree or submodule).
ga_find_root() { # START
  local d
  d=$(ga_phys_dir "$1") || return 1
  while :; do
    if [ -f "$d/docs/architecture/.state/state.json" ]; then
      echo "$d"
      return 0
    fi
    [ -e "$d/.git" ] && return 1
    [ "$d" = / ] && return 1
    d=$(dirname "$d")
  done
}

# Every command that needs an initialized design calls this first: GA_ROOT must hold
# docs/architecture/.state/state.json, else exit 2 with the one message the skill branches on.
ga_need_state() {
  [ -n "${GA_ROOT:-}" ] && [ -f "$GA_ROOT/docs/architecture/.state/state.json" ] ||
    ga_die "ga: 초기화된 프로젝트가 없습니다 (ga init 먼저)" 2
}

# True when the user's pause marker (GA 일시정지) exists. It works even when state.json is unreadable.
ga_paused_marker() { [ -e "$1/docs/architecture/.state/PAUSED" ]; } # ROOT

# P31: the one spelling of existing directory D: symlinks resolved, the letter case stored on disk
# (/bin/realpath; cd -P keeps the typed case), and no /System/Volumes/Data prefix when the path without
# it is the same folder (same device and inode; macOS firmlinks). Fingerprint keys and every prefix
# comparison see this spelling.
ga_phys_dir() { # D
  local p="" s ids
  if [ -x /bin/realpath ]; then p=$(/bin/realpath "$1" 2>/dev/null) || p=""; fi
  case "$p" in /*) [ -d "$p" ] || p="" ;; *) p="" ;; esac
  [ -n "$p" ] || p=$(cd -P "$1" 2>/dev/null && pwd -P) || return 1
  case "$p" in
    /System/Volumes/Data/?*)
      s=${p#/System/Volumes/Data}
      ids=$(stat -c '%d:%i' "$p" "$s" 2>/dev/null || stat -f '%d:%i' "$p" "$s" 2>/dev/null) || :
      case "$ids" in ?*$'\n'?*) if [ "${ids%%$'\n'*}" = "${ids#*$'\n'}" ]; then p=$s; fi ;; esac ;;
  esac
  printf '%s\n' "$p"
}

# Canonical absolute path; the file (and its parent dirs) need not exist.
# The deepest existing ancestor is resolved with ga_phys_dir; the rest is appended.
ga_canon() { # PATH
  local p=$1 rest="" base
  case "$p" in /*) ;; *) p=$PWD/$p ;; esac
  while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do p=${p%/}; done
  while [ ! -d "$p" ] && [ "$p" != / ]; do
    base=$(basename "$p")
    rest=$base${rest:+/$rest}
    p=$(dirname "$p")
  done
  p=$(ga_phys_dir "$p") || return 1
  # The non-existent remainder may contain . and .. (e.g. missing/../.state): collapse
  # them lexically so a path can never hide its real location.
  case "$rest" in
    *.*)
      local c out="" oldifs=$IFS noglob=1
      case $- in *f*) ;; *) noglob=0; set -f ;; esac
      IFS=/
      for c in $rest; do
        case "$c" in
          "" | .) ;;
          ..) if [ -n "$out" ]; then
                case "$out" in */*) out=${out%/*} ;; *) out="" ;; esac
              else
                p=$(dirname "$p")
              fi ;;
          *) out=${out:+$out/}$c ;;
        esac
      done
      IFS=$oldifs
      [ "$noglob" = 0 ] && set +f
      rest=$out
      ;;
  esac
  if [ -z "$rest" ]; then
    echo "$p"
  elif [ "$p" = / ]; then
    echo "/$rest"
  else
    echo "$p/$rest"
  fi
}

# Validate stdin as JSON, then atomically replace FILE. Invalid JSON: exit 2, FILE untouched.
ga_write_json() { # FILE
  local f=$1 tmp="$1.tmp.$$"
  if ! jq -e . >"$tmp" 2>/dev/null; then
    rm -f "$tmp"
    ga_die "ga: invalid JSON, not writing $f" 2
  fi
  mv "$tmp" "$f"
  # A state file was written: the command ends by recording the state fingerprint (fingerprint.sh).
  case "$f" in */docs/architecture/.state/*) : >"${f%/*}/.lock/dirty" 2>/dev/null ;; esac
  return 0
}

# The state folder cannot be written (the agent's shell runs inside the OS sandbox, which denies
# it): name the MCP tool that does the same thing outside the sandbox.
ga_mcp_hint() {
  case "${GA_SUB:-}" in
    init | add | update | ask | resolve | render | verify | enforce | dispute)
      echo "셸에서는 설계 상태 폴더에 쓸 수 없습니다(OS 격리). 같은 일을 하는 MCP 도구 \`ga_${GA_SUB}\`를 쓰세요" ;;
    *) echo "셸에서는 설계 상태 폴더에 쓸 수 없습니다(OS 격리). 상태를 바꾸는 일은 MCP 도구(ga_add, ga_update 등)로 하세요" ;;
  esac
}

# State-writing commands stop here, before any work (ga verify runs the panel for minutes before it
# writes), when the state folder cannot be written. The probe is a directory: never fingerprinted.
ga_need_writable_state() {
  local sd
  [ -n "${GA_ROOT:-}" ] || return 0
  sd=$GA_ROOT/docs/architecture/.state
  [ -d "$sd" ] || return 0
  if mkdir "$sd/.wcheck.$$" 2>/dev/null; then rmdir "$sd/.wcheck.$$"; return 0; fi
  ga_die "ga: 설계 상태 폴더에 쓸 수 없습니다: $sd. $(ga_mcp_hint)" 2
}

# Reentrant within one process: only the outermost ga_lock creates the lock dir and only the
# matching outermost ga_unlock removes it (GA_LOCK_DEPTH is deliberately not exported).
GA_LOCK_DEPTH=0
ga_lock() { # ROOT
  local sd=$1/docs/architecture/.state i=0
  if [ "${GA_LOCK_DEPTH:-0}" -gt 0 ]; then
    GA_LOCK_DEPTH=$((GA_LOCK_DEPTH + 1))
    return 0
  fi
  mkdir -p "$sd" 2>/dev/null || ga_die "ga: $sd 를 만들 수 없습니다. $(ga_mcp_hint)" 2
  while ! mkdir "$sd/.lock" 2>/dev/null; do
    # No lock dir there: not contention but a folder that cannot be written. Retried once, so a
    # lock released between the two looks is not mistaken for that.
    if [ ! -e "$sd/.lock" ]; then
      mkdir "$sd/.lock" 2>/dev/null && break
      [ -e "$sd/.lock" ] || ga_die "ga: 설계 상태 폴더에 쓸 수 없습니다: $sd. $(ga_mcp_hint)" 2
    fi
    # A lock left by a killed ga (older than 120 s) is moved aside atomically, then retried.
    if [ -n "$(find "$sd/.lock" -maxdepth 0 -mmin +2 2>/dev/null)" ] &&
       mv "$sd/.lock" "$sd/.lock.stale.$$" 2>/dev/null; then
      rm -rf "$sd/.lock.stale.$$"
      continue
    fi
    i=$((i + 1))
    [ "$i" -ge 50 ] && ga_die "ga: 잠금을 얻지 못했습니다: $sd/.lock. 다른 ga 명령이 실행 중이 아니라면 사용자가 이 디렉터리(docs/architecture/.state/.lock)를 지우고 다시 실행하세요 (2분이 지난 잠금은 자동으로 풀립니다)" 2
    sleep 0.1
  done
  GA_LOCK_DEPTH=1
  if type _ga_fp_begin >/dev/null 2>&1; then _ga_fp_begin "$1"; fi
}

ga_unlock() { # ROOT
  if [ "${GA_LOCK_DEPTH:-0}" -gt 1 ]; then
    GA_LOCK_DEPTH=$((GA_LOCK_DEPTH - 1))
    return 0
  fi
  if type _ga_fp_finish >/dev/null 2>&1; then _ga_fp_finish "$1"; fi
  rm -f "$1/docs/architecture/.state/.lock/dirty" "$1/docs/architecture/.state/.lock/force" "$1/docs/architecture/.state/.lock/premismatch"
  GA_LOCK_DEPTH=0
  rmdir "$1/docs/architecture/.state/.lock" 2>/dev/null
  return 0
}

GA_VERSION=0.1.0
cmd_version() { echo "grounded-arch $GA_VERSION"; }
