# grounded-arch common helpers. Sourced; bash 3.2 compatible. No set -e here.

ga_die() { # MSG [CODE]
  echo "$1" >&2
  exit "${2:-2}"
}

ga_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Walk up from START to the dir containing docs/architecture/.state/state.json.
ga_find_root() { # START
  local d
  d=$(cd -P "$1" 2>/dev/null && pwd -P) || return 1
  while :; do
    if [ -f "$d/docs/architecture/.state/state.json" ]; then
      echo "$d"
      return 0
    fi
    [ "$d" = / ] && return 1
    d=$(dirname "$d")
  done
}

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

ga_lock() { # ROOT
  local sd=$1/docs/architecture/.state i=0
  mkdir -p "$sd" || ga_die "ga: cannot create $sd" 2
  while ! mkdir "$sd/.lock" 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -ge 50 ] && ga_die "ga: could not acquire lock $sd/.lock" 2
    sleep 0.1
  done
}

ga_unlock() { # ROOT
  rmdir "$1/docs/architecture/.state/.lock" 2>/dev/null
  return 0
}

GA_VERSION=0.1.0
cmd_version() { echo "grounded-arch $GA_VERSION"; }
