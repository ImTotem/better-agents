test_init_creates_files() { r=$(mk_project); ga --root "$r" init >/dev/null
  assert_eq inputs "$(jq -r .phase "$r/docs/architecture/.state/state.json")"
  assert_eq 0 "$(jq '.items|length' "$r/docs/architecture/.state/ledger.json")"
  assert_contains "$(cat "$r/docs/architecture/architecture.md")" "<!-- ga:begin ledger -->"; }
test_init_twice_exit1() { r=$(mk_project); ga --root "$r" init >/dev/null; assert_status 1 ga --root "$r" init; }
test_init_mode_greenfield() { r=$(mk_project); assert_contains "$(ga --root "$r" init)" "mode=greenfield"; }
test_init_mode_brownfield() { r=$(mk_project brownfield); assert_contains "$(ga --root "$r" init)" "mode=brownfield"; }
test_status_json_fields() { r=$(mk_project); ga --root "$r" init >/dev/null
  assert_eq '{"phase":"inputs","round":1,"open":0}' "$(ga --root "$r" status --json | jq -c '{phase,round,open}')"; }
test_init_in_subdir_inits_subdir() { r=$(mk_project); ga --root "$r" init >/dev/null
  mkdir "$r/sub"; ( cd "$r/sub" && ga init >/dev/null )
  [ -f "$r/sub/docs/architecture/.state/state.json" ] || _fail "sub not initialized"; }
test_init_ignores_inherited_ga_root() { p=$(mk_project); ga --root "$p" init >/dev/null; f=$(mk_project)
  ( cd "$f" && GA_ROOT="$p" ga init >/dev/null )
  [ -f "$f/docs/architecture/.state/state.json" ] || _fail "fresh dir not initialized"; }
