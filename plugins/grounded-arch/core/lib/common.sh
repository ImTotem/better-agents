# grounded-arch common helpers. Sourced; bash 3.2 compatible. No set -e here.

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
  d=$(cd -P "$1" 2>/dev/null && pwd -P) || return 1
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

# True when the user's pause marker (GA 일시정지) exists. It works even when state.json is unreadable.
ga_paused_marker() { [ -e "$1/docs/architecture/.state/PAUSED" ]; } # ROOT

# Canonical absolute path; the file (and its parent dirs) need not exist.
# The deepest existing ancestor is resolved with cd -P; the rest is appended.
ga_canon() { # PATH
  local p=$1 rest="" base
  case "$p" in /*) ;; *) p=$PWD/$p ;; esac
  while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do p=${p%/}; done
  while [ ! -d "$p" ] && [ "$p" != / ]; do
    base=$(basename "$p")
    rest=$base${rest:+/$rest}
    p=$(dirname "$p")
  done
  p=$(cd -P "$p" && pwd -P) || return 1
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
  mkdir -p "$sd" || ga_die "ga: cannot create $sd" 2
  while ! mkdir "$sd/.lock" 2>/dev/null; do
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
}

ga_unlock() { # ROOT
  if [ "${GA_LOCK_DEPTH:-0}" -gt 1 ]; then
    GA_LOCK_DEPTH=$((GA_LOCK_DEPTH - 1))
    return 0
  fi
  GA_LOCK_DEPTH=0
  rmdir "$1/docs/architecture/.state/.lock" 2>/dev/null
  return 0
}

GA_VERSION=0.1.0
cmd_version() { echo "grounded-arch $GA_VERSION"; }
