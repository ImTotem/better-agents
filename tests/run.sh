#!/bin/bash
# Usage: tests/run.sh [file...]
# Runs every test_* function of each file in its own subshell, with a fresh
# HOME and tests/fakes first on PATH (no real ~/.claude, no real model).
REPO=$(cd -P "$(dirname "$0")/.." && pwd)
if [ $# -eq 0 ]; then set -- "$REPO"/tests/test_*.sh; fi
fails=0
for f in "$@"; do
  if [ ! -f "$f" ]; then echo "FAIL $f (missing)"; fails=$((fails+1)); continue; fi
  fns=$( ( . "$REPO/tests/lib.sh" || exit 1; . "$f" || exit 1; compgen -A function test_ ) 2>&1 )
  lrc=$?
  if [ $lrc -ne 0 ]; then
    echo "FAIL $f (load error)"
    [ -n "$fns" ] && echo "$fns" | sed 's/^/    /'
    fails=$((fails+1)); continue
  fi
  if [ -z "$fns" ]; then
    echo "FAIL $f (no tests)"; fails=$((fails+1)); continue
  fi
  for fn in $fns; do
    home=$(mktemp -d)
    out=$( ( export HOME="$home"; PATH="$REPO/tests/fakes:$PATH"; export PATH
             . "$REPO/tests/lib.sh"; . "$f"; set -e; "$fn" ) 2>&1 )
    rc=$?
    rm -rf "$home"
    if [ $rc -eq 0 ]; then
      echo "PASS $fn"
    else
      echo "FAIL $fn"
      [ -n "$out" ] && echo "$out" | sed 's/^/    /'
      fails=$((fails+1))
    fi
  done
done
[ $fails -eq 0 ]
