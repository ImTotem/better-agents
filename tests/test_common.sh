test_version() { assert_eq "grounded-arch 0.1.0" "$(ga version)"; }
test_find_root_from_subdir() { r=$(mk_project); mkdir -p "$r/docs/architecture/.state" "$r/a/b"; echo '{}' >"$r/docs/architecture/.state/state.json"
  ( cd "$r/a/b" && . "$CORE/lib/common.sh" && assert_eq "$(cd -P "$r" && pwd)" "$(ga_find_root "$PWD")" ); }
test_find_root_none_exit1() { r=$(mk_project); ( . "$CORE/lib/common.sh"; assert_status 1 ga_find_root "$r" ); }
test_canon_private_tmp() { d=$(mktemp -d /tmp/gaX.XXXX); ( . "$CORE/lib/common.sh"; assert_eq "/private$d/x/y.txt" "$(ga_canon "$d/x/y.txt")" ); }
test_write_json_atomic_invalid() { f=$(mktemp); echo '{"a":1}' >"$f"; ( . "$CORE/lib/common.sh"; echo 'not json' | assert_status 2 ga_write_json "$f" ); assert_eq '{"a":1}' "$(cat "$f")"; }
