# Test helpers. Sourced by tests/run.sh. bash 3.2 compatible.
REPO=$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PLUGIN=$REPO/plugins/better-agents
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

# The setup helpers below put a design into a given state as if ga had written it, so they record
# the state fingerprint afterwards (core refuses state writes while it mismatches). tamper_state is
# the one helper that edits a state file the way an outside writer would.
_fp_sync() { # ROOT
  ( GA_CORE=$CORE; . "$CORE/lib/common.sh"; . "$CORE/lib/state.sh"; . "$CORE/lib/fingerprint.sh"; ga_fp_record "$1" ) >/dev/null 2>&1 || true
}

tamper_state() { # ROOT JQ_EXPR   (test-only: edits state.json outside ga, fingerprint NOT re-recorded)
  local f tmp; f=$(_state_dir "$1")/state.json; tmp=$f.tmp.$$
  jq "$2" "$f" >"$tmp" && mv "$tmp" "$f"
}

seed_ledger() { # ROOT FIXTURE|-   (test-only: writes ledger.json directly)
  local sd; sd=$(_state_dir "$1")
  if [ "$2" = - ]; then
    local tmp="$sd/ledger.json.tmp.$$"
    cat >"$tmp" && mv "$tmp" "$sd/ledger.json"
  else cp "$2" "$sd/ledger.json"; fi
  _fp_sync "$1"
}

seed_map() { # ROOT PATH CHANGE   (test-only: appends mapping MAP-1 to the ledger)
  local sd lp; sd=$(_state_dir "$1"); lp=$sd/ledger.json
  [ -f "$lp" ] || echo '{"items":[]}' >"$lp"
  jq --arg p "$2" --arg c "$3" '.items += [{"id":"MAP-1","kind":"mapping","round":1,"phase_added":"skeleton","iteration":null,"status":null,"resolution":null,"element":"테스트 요소","path":$p,"change":$c}]' "$lp" | seed_ledger "$1" -
}

# P28: fake copies of the system tools ga uses, in DIR. Each appends its name to MARKER and runs the
# system tool. A verifier runner and its preflight (GA_IN_RUNNER, GA_RUNNER_RECORD) take their tools
# from the user's PATH by design, so their calls are not logged.
fake_tools() { # DIR MARKER
  local t x s
  for t in tail head sed awk grep mktemp stat find shasum sha256sum jq git sort tr cut paste cat rm mv mkdir \
           date dirname basename readlink env pgrep wc xargs uname realpath xcode-select sandbox-exec; do
    s=""; for x in /usr/bin /bin /usr/sbin /sbin; do [ -x "$x/$t" ] && { s=$x/$t; break; }; done
    [ -n "$s" ] || continue
    printf '#!/bin/bash\n[ -n "${GA_IN_RUNNER:-}${GA_RUNNER_RECORD:-}" ] || printf "%%s\\n" %s >>"%s"\nexec %s "$@"\n' "$t" "$2" "$s" >"$1/$t"
    chmod +x "$1/$t"
  done
}

# P33: a folder's mtime (seconds) after aging it to 2000-01-01, so any file created or removed in it
# afterwards shows as a different value.
aged_dir() { touch -t 200001010000 "$1"; dir_mtime "$1"; } # DIR -> its aged mtime
dir_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1"; }
# P33: ga's private temp folder for the test HOME.
priv_tmp() { echo "${GA_DATA_DIR:-$HOME/.local/state/grounded-arch}/tmp"; }

set_state() { # ROOT JQ_EXPR   (test-only: edits state.json directly)
  local sd f tmp; sd=$(_state_dir "$1"); f=$sd/state.json
  [ -f "$f" ] || echo '{"version":1,"mode":"greenfield","phase":"inputs","paused":false,"round":1,"iteration":0,"iteration_count":0,"transcript_path":null}' >"$f"
  tmp=$f.tmp.$$
  jq "$2" "$f" >"$tmp" && mv "$tmp" "$f"
  _fp_sync "$1"
}
