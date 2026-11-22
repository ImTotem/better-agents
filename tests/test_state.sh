test_init_creates_files() { r=$(mk_project); ga --root "$r" init >/dev/null
  assert_eq inputs "$(jq -r .phase "$r/docs/architecture/.state/state.json")"
  assert_eq 0 "$(jq '.items|length' "$r/docs/architecture/.state/ledger.json")"
  assert_contains "$(cat "$r/docs/architecture/architecture.md")" "<!-- ga:begin ledger -->"; }
test_init_twice_exit1() { r=$(mk_project); ga --root "$r" init >/dev/null; assert_status 1 ga --root "$r" init; }
test_init_mode_greenfield() { r=$(mk_project); assert_contains "$(ga --root "$r" init)" "mode=greenfield"; }
test_init_mode_brownfield() { r=$(mk_project brownfield); assert_contains "$(ga --root "$r" init)" "mode=brownfield"; }
test_status_json_fields() { r=$(mk_project); ga --root "$r" init >/dev/null
  assert_eq '{"phase":"inputs","round":1,"open":0}' "$(ga --root "$r" status --json | jq -c '{phase,round,open}')"; }
# R29: a design nested inside an already designed tree (same git root) is refused.
test_init_in_subdir_refused_when_ancestor_designed() { r=$(mk_project); ga --root "$r" init >/dev/null
  mkdir "$r/sub"; ( cd "$r/sub" && assert_status 3 ga init ); assert_status 3 ga --root "$r/sub" init
  [ ! -e "$r/sub/docs" ] || _fail "sub initialized"; }
test_init_ignores_inherited_ga_root() { p=$(mk_project); ga --root "$p" init >/dev/null; f=$(mk_project)
  ( cd "$f" && GA_ROOT="$p" ga init >/dev/null )
  [ -f "$f/docs/architecture/.state/state.json" ] || _fail "fresh dir not initialized"; }

# --- final review fixes ---
# I4 (R29): root discovery stops at the first git root / worktree root.
wt_layout() { # -> checkout dir with .git and a design; its worktree is $1/.claude/worktrees/x
  local p; p=$(mk_project); mkdir -p "$p/.git" "$p/src"; echo x >"$p/src/a.c"; ga --root "$p" init >/dev/null
  mkdir -p "$p/.claude/worktrees/x/src"; echo 'gitdir: /elsewhere' >"$p/.claude/worktrees/x/.git"; echo "$p"; }
test_i4_find_root_stops_at_worktree_boundary() { local p c out
  p=$(wt_layout); c=$p/.claude/worktrees/x
  ( . "$CORE/lib/common.sh"; assert_status 1 ga_find_root "$c/src" )
  out=$(cd "$c" && ga gate write --path "$c/src/b.c"); assert_eq allow "$(jq -r .decision <<<"$out")"
  out=$(cd "$c" && ga gate bash --command 'touch src/c.c'); assert_eq allow "$(jq -r .decision <<<"$out")"
  mkdir -p "$p/src/deep"; ( . "$CORE/lib/common.sh"; assert_eq "$(cd -P "$p" && pwd)" "$(ga_find_root "$p/src/deep")" ); }
test_i4_init_allowed_in_nested_worktree() { local p c; p=$(wt_layout); c=$p/.claude/worktrees/x
  ( cd "$c" && assert_status 0 ga init ); [ -f "$c/docs/architecture/.state/state.json" ] || _fail "worktree not initialized"; }
test_i4_init_refuses_home_and_filesystem_root() { ( cd "$HOME" && assert_status 3 ga init ); [ ! -e "$HOME/docs" ] || _fail "HOME initialized"
  assert_status 3 ga --root / init; }
# R35-3: open/asked counts include assumptions/questions of every round.
test_r35_status_counts_earlier_round_assumptions() { local r; r=$(mk_project); ga --root "$r" init >/dev/null
  seed_ledger "$r" "$FIX/ledger_inputs_open_asm.json"; set_state "$r" '.round=2'
  assert_eq 1 "$(ga --root "$r" status --json | jq .open)"; }
# I6 (R31a): status reports the PAUSED marker.
test_i6_status_reports_paused_marker() { local r; r=$(mk_project); ga --root "$r" init >/dev/null; : >"$r/docs/architecture/.state/PAUSED"
  assert_eq true "$(ga --root "$r" status --json | jq .paused)"; }
# R35-4: a stale lock (older than 120 s) is broken; a fresh one times out with recovery advice.
test_r35_stale_lock_is_broken() { local r l; r=$(mk_project); ga --root "$r" init >/dev/null; set_state "$r" '.phase="iterating"|.iteration=1|.iteration_count=1'
  l=$r/docs/architecture/.state/.lock; mkdir "$l"; touch -t "$(date -v-5M +%Y%m%d%H%M.%S)" "$l"
  assert_eq ASM-1 "$(ga --root "$r" add assumption <"$FIX/asm.json")"; assert_status 1 test -d "$l"; }
test_r35_fresh_lock_timeout_explains_recovery() { local r err; r=$(mk_project); ga --root "$r" init >/dev/null; set_state "$r" '.phase="iterating"|.iteration=1|.iteration_count=1'
  mkdir "$r/docs/architecture/.state/.lock"
  err=$(ga --root "$r" add assumption <"$FIX/asm.json" 2>&1 >/dev/null) || true
  assert_contains "$err" "docs/architecture/.state/.lock"; assert_contains "$err" "지우"; }

# MCP fix round 1: every design command with --root but no design says "ga init 먼저".
test_commands_before_init_say_ga_init() { local r c out rc
  r=$(mk_project)
  for c in "status" "status --json" "verify" "check" "check --json" "dispute FND-1 --evidence x" "effect check" "render" "ask Q-1"; do
    rc=0; out=$(ga --root "$r" $c 2>&1) || rc=$?
    assert_eq "2 $c" "$rc $c"
    assert_contains "$out" "초기화된 프로젝트가 없습니다 (ga init 먼저)"
    assert_not_contains "$out" "jq:"
  done
  [ ! -e "$r/docs" ] || _fail "a command before init created files"; }
# P11: ga init refuses a symlinked docs, docs/architecture or docs/architecture/.state.
test_init_refuses_symlinked_design_dirs() { local r t p out rc
  for p in docs docs/architecture docs/architecture/.state; do
    r=$(mk_project); t=$(mktemp -d)
    mkdir -p "$r/$(dirname "$p")"; ln -s "$t" "$r/$p"
    rc=0; out=$(ga --root "$r" init 2>&1) || rc=$?
    assert_eq "3 $p" "$rc $p"; assert_contains "$out" "심볼릭 링크"
    assert_eq "" "$(ls -A "$t")"
  done
  # a symlinked .state pointing at another design is refused too, not reported as "already initialized"
  r=$(mk_project); t=$(mk_project); ga --root "$t" init >/dev/null
  mkdir -p "$r/docs/architecture"; ln -s "$t/docs/architecture/.state" "$r/docs/architecture/.state"
  assert_status 3 ga --root "$r" init; }
