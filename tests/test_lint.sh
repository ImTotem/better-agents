#!/bin/bash
# Lint: under a UTF-8 locale bash 3.2 reads high bytes right after $name as part of the name.
test_no_unbraced_var_before_nonascii() {
  local out
  out=$(find "$PLUGIN" \( -name '*.sh' -o -path '*/core/bin/ga' \) -type f -print0 | xargs -0 perl -ne 'print "$ARGV:$.: $_" if /\$[A-Za-z_][A-Za-z0-9_]*[\x80-\xff]/' 2>&1)
  [ -z "$out" ] || _fail "unbraced \$name before non-ASCII: $out"
}
