# Test helpers. Sourced by tests/run.sh. bash 3.2 compatible.
REPO=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PLUGIN=$REPO/plugins/grounded-arch
CORE=$PLUGIN/core
FIX=$REPO/tests/fixtures

ga() { "$CORE/bin/ga" "$@"; }

use_fake_claude() {
  case ":$PATH:" in
    *":$REPO/tests/fakes:"*) ;;
    *) PATH="$REPO/tests/fakes:$PATH" ;;
  esac
  export PATH
}

_fail() { echo "  assertion failed: $*" >&2; exit 1; }

assert_eq() { # EXPECTED ACTUAL
  [ "$1" = "$2" ] || _fail "expected [$1] got [$2]"
}
assert_contains() { # HAYSTACK NEEDLE
  case "$1" in *"$2"*) ;; *) _fail "expected [$1] to contain [$2]" ;; esac
}
assert_not_contains() { # HAYSTACK NEEDLE
  case "$1" in *"$2"*) _fail "expected [$1] not to contain [$2]" ;; esac
}
assert_status() { # CODE cmd...   (stdin is passed through to cmd)
  local want=$1 got
  shift
  got=0
  ( "$@" ) >/dev/null 2>&1 || got=$?
  [ "$got" = "$want" ] || _fail "expected exit $want got $got: $*"
}

mk_project() { # [greenfield|brownfield] -> prints a fresh temp dir
  local d
  d=$(mktemp -d)
  if [ "${1:-greenfield}" = brownfield ]; then
    mkdir -p "$d/src"
    printf 'int main(void) {\n  return 0;\n}\n' >"$d/src/main.c"
  fi
  echo "$d"
}

_state_dir() { mkdir -p "$1/docs/architecture/.state"; echo "$1/docs/architecture/.state"; }

seed_ledger() { # ROOT FIXTURE|-   (test-only: writes ledger.json directly)
  local sd; sd=$(_state_dir "$1")
  if [ "$2" = - ]; then cat >"$sd/ledger.json"; else cp "$2" "$sd/ledger.json"; fi
}

set_state() { # ROOT JQ_EXPR   (test-only: edits state.json directly)
  local sd f tmp; sd=$(_state_dir "$1"); f=$sd/state.json
  [ -f "$f" ] || echo '{"version":1,"mode":"greenfield","phase":"inputs","paused":false,"round":1,"iteration":0,"iteration_count":0,"transcript_path":null}' >"$f"
  tmp=$f.tmp.$$
  jq "$2" "$f" >"$tmp" && mv "$tmp" "$f"
}
