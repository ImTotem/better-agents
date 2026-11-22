#!/bin/bash
# Tests for the G-effect file change check (core/lib/effect.sh).
load_ga() { GA_CORE=$CORE; . "$CORE"/lib/common.sh; . "$CORE"/lib/state.sh; . "$CORE"/lib/check.sh; . "$CORE"/lib/ledger.sh; . "$CORE"/lib/effect.sh; }
sj() { jq -r "$2" "$1/docs/architecture/.state/state.json"; }

# git project with src/a.c, src/b.c, src/old.c committed, designed (ga init) in phase $2 (default iterating).
git_proj() { # [mode] [phase]
  local r; r=$(mk_project)
  git -C "$r" init -q
  git -C "$r" config user.email t@example.com
  git -C "$r" config user.name t
  mkdir -p "$r/src"
  echo a >"$r/src/a.c"; echo b >"$r/src/b.c"; echo old >"$r/src/old.c"
  git -C "$r" add -A
  git -C "$r" commit -q -m base
  ga --root "$r" init --mode "${1:-greenfield}" >/dev/null
  set_state "$r" ".phase=\"${2:-iterating}\""
  echo "$r"
}
viol() { ga_effect_check "$1" 2>/dev/null | jq -c .violations; } # needs load_ga

test_effect_design_phase_src_change_is_violation() { load_ga; r=$(git_proj); ga_effect_snapshot "$r"
  echo changed >"$r/src/a.c"; out=$(ga_effect_check "$r") && _fail "expected rc 1"
  assert_eq '["src/a.c"]' "$(jq -c .violations <<<"$out")"; assert_eq '["src/a.c"]' "$(jq -c .changed <<<"$out")"; }
test_effect_docs_architecture_change_allowed() { load_ga; r=$(git_proj); ga_effect_snapshot "$r"
  echo more >>"$r/docs/architecture/architecture.md"; out=$(ga_effect_check "$r"); assert_eq '[]' "$(jq -c .violations <<<"$out")"
  assert_contains "$(jq -c .changed <<<"$out")" docs/architecture/architecture.md
  echo x >"$r/docs/architecture/.state/extra"; out=$(ga_effect_check "$r"); assert_not_contains "$out" ".state"; }
test_effect_preexisting_dirty_file_not_violation() { load_ga; r=$(git_proj); echo dirty >"$r/src/b.c"; ga_effect_snapshot "$r"
  assert_eq '[]' "$(viol "$r")"
  echo dirtier >"$r/src/b.c"; assert_eq '["src/b.c"]' "$(viol "$r")"; }
test_effect_committed_change_caught() { load_ga; r=$(git_proj); ga_effect_snapshot "$r"
  echo changed >"$r/src/a.c"; git -C "$r" commit -q -am edit; assert_eq '["src/a.c"]' "$(viol "$r")"; }
test_effect_untracked_new_file_caught() { load_ga; r=$(git_proj); ga_effect_snapshot "$r"
  echo n >"$r/src/new.c"; assert_eq '["src/new.c"]' "$(viol "$r")"; }
test_effect_deleted_file_caught() { load_ga; r=$(git_proj); ga_effect_snapshot "$r"
  rm "$r/src/old.c"; assert_eq '["src/old.c"]' "$(viol "$r")"; }
test_effect_brownfield_skeleton_mapping_allowed() { load_ga; r=$(git_proj brownfield skeleton); seed_map "$r" src/x.c changed; ga_effect_snapshot "$r"
  echo x >"$r/src/x.c"; assert_eq '[]' "$(viol "$r")"
  echo y >"$r/src/y.c"; assert_eq '["src/y.c"]' "$(viol "$r")"; }
test_effect_greenfield_skeleton_unrestricted() { load_ga; r=$(git_proj greenfield skeleton); ga_effect_snapshot "$r"
  echo x >"$r/src/new.c"; assert_eq '[]' "$(viol "$r")"; }
test_effect_implement_unrestricted_except_protected() { load_ga; r=$(git_proj brownfield implement); ga_effect_snapshot "$r"
  echo x >"$r/src/anything.c"; echo y >>"$r/src/a.c"; assert_eq '[]' "$(viol "$r")"
  mkdir -p "$r/.claude"; echo '{}' >"$r/.claude/settings.local.json"; assert_eq '[".claude/settings.local.json"]' "$(viol "$r")"; }
test_effect_non_git_project() { load_ga; r=$(mk_project brownfield); ga --root "$r" init >/dev/null; set_state "$r" '.phase="iterating"'
  ga_effect_snapshot "$r"; assert_eq files "$(jq -r .kind "$r/docs/architecture/.state/snapshot.json")"; assert_eq '[]' "$(viol "$r")"
  echo "int x;" >>"$r/src/main.c"; echo n >"$r/src/new.c"; echo doc >>"$r/docs/architecture/architecture.md"
  assert_eq '["src/main.c","src/new.c"]' "$(viol "$r")"
  rm "$r/src/main.c"; assert_contains "$(viol "$r")" src/main.c; }
test_effect_ignores_build_dirs_non_git() { load_ga; r=$(mk_project brownfield); ga --root "$r" init >/dev/null; set_state "$r" '.phase="iterating"'
  ga_effect_snapshot "$r"
  for d in node_modules .git target build dist; do mkdir -p "$r/$d"; echo x >"$r/$d/f"; done
  assert_eq '[]' "$(viol "$r")"; }
test_effect_speed_10k_files() { load_ga; r=$(git_proj)
  mkdir -p "$r/gen"; i=0
  while [ $i -lt 100 ]; do mkdir -p "$r/gen/d$i"; j=0; while [ $j -lt 100 ]; do echo "$i$j" >"$r/gen/d$i/f$j.txt"; j=$((j+1)); done; i=$((i+1)); done
  git -C "$r" add -A; git -C "$r" commit -q -m many
  ga_effect_snapshot "$r"; echo z >"$r/src/a.c"
  t0=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000' 2>/dev/null || echo $(( $(date +%s) * 1000 )))
  out=$(ga_effect_check "$r") || true
  t1=$(perl -MTime::HiRes=time -e 'printf "%d", time*1000' 2>/dev/null || echo $(( $(date +%s) * 1000 )))
  ms=$((t1 - t0)); echo "  ga_effect_check on 10k files: ${ms} ms" >&2
  assert_eq '["src/a.c"]' "$(jq -c .violations <<<"$out")"
  [ "$ms" -lt 1000 ] || _fail "too slow: ${ms} ms"; }

test_effect_rebaseline_only_that_path() { load_ga; r=$(git_proj); ga_effect_snapshot "$r"
  mkdir -p "$r/.claude"; echo '{}' >"$r/.claude/settings.local.json"; echo n >"$r/src/new.c"
  ga_effect_rebaseline "$r" .claude/settings.local.json
  assert_eq '["src/new.c"]' "$(viol "$r")"
  echo '{"a":1}' >"$r/.claude/settings.local.json"; assert_contains "$(viol "$r")" settings.local.json; }
test_effect_rebaseline_non_git() { load_ga; r=$(mk_project brownfield); ga --root "$r" init >/dev/null; set_state "$r" '.phase="iterating"'; ga_effect_snapshot "$r"
  mkdir -p "$r/.claude"; echo '{}' >"$r/.claude/settings.local.json"; echo n >"$r/src/new.c"
  ga_effect_rebaseline "$r" .claude/settings.local.json; assert_eq '["src/new.c"]' "$(viol "$r")"; }

test_effect_cli_check() { r=$(git_proj); ga --root "$r" effect check >/dev/null || _fail "init must snapshot"
  echo c >"$r/src/a.c"; rc=0; out=$(ga --root "$r" effect check 2>"$HOME/err") || rc=$?; assert_eq 1 "$rc"
  assert_eq '["src/a.c"]' "$(jq -c .violations <<<"$out")"; assert_contains "$(cat "$HOME/err")" "src/a.c"; }
test_effect_snapshot_after_init_and_transitions() { use_fake_claude; r=$(mk_project); ga --root "$r" init >/dev/null
  assert_status 0 test -f "$r/docs/architecture/.state/snapshot.json"
  seed_ledger "$r" "$FIX/ledger_inputs_ready.json"; ga --root "$r" verify >/dev/null
  echo c >"$r/new.txt"; f=$(mktemp); printf 'GA 승인 입력' >"$f"
  out=$(ga --root "$r" user-command --text-file "$f"); assert_eq allow "$(jq -r .decision <<<"$out")"; assert_eq iterating "$(sj "$r" .phase)"
  assert_eq '[]' "$(ga --root "$r" effect check | jq -c .changed)"; }
