test_runner_fails_on_syntax_error_file() {
  d=$(mktemp -d); printf 'test_x() { echo ok; \nif then fi (\n' >"$d/test_bad.sh"
  out=$("$REPO/tests/run.sh" "$d/test_bad.sh" 2>&1) && rc=0 || rc=$?
  assert_eq 1 "$rc"
  assert_contains "$out" "FAIL $d/test_bad.sh"
}
test_runner_fails_on_file_without_tests() {
  d=$(mktemp -d); printf 'helper() { :; }\n' >"$d/test_empty.sh"
  out=$("$REPO/tests/run.sh" "$d/test_empty.sh" 2>&1) && rc=0 || rc=$?
  assert_eq 1 "$rc"
  assert_contains "$out" "FAIL $d/test_empty.sh"
}
test_runner_fails_on_failing_source_line() {
  d=$(mktemp -d); printf 'test_x() { :; }\nfalse_cmd_that_returns_nonzero() { return 1; }\nfalse_cmd_that_returns_nonzero\n' >"$d/test_src.sh"
  out=$("$REPO/tests/run.sh" "$d/test_src.sh" 2>&1) && rc=0 || rc=$?
  assert_eq 1 "$rc"
  assert_contains "$out" "FAIL $d/test_src.sh"
}
test_runner_passes_good_file() {
  d=$(mktemp -d); printf 'test_ok() { :; }\n' >"$d/test_good.sh"
  out=$("$REPO/tests/run.sh" "$d/test_good.sh" 2>&1)
  assert_contains "$out" "PASS test_ok"
}
