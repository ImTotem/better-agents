#!/bin/bash
# Tests for the G-effect file change check (core/lib/effect.sh).
load_ga() { GA_CORE=$CORE; . "$CORE"/lib/common.sh; . "$CORE"/lib/state.sh; . "$CORE"/lib/check.sh; . "$CORE"/lib/ledger.sh; . "$CORE"/lib/effect.sh; . "$CORE"/lib/enforce.sh; . "$CORE"/lib/fingerprint.sh; }
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
  # P19: the harness's settings files are not effect violations in any phase (enforce status checks them)
  mkdir -p "$r/.claude"; echo '{}' >"$r/.claude/settings.local.json"; assert_eq '[]' "$(viol "$r")"
  set_state "$r" '.phase="iterating"'; assert_eq '[]' "$(GA_HARNESS=claude-code viol "$r" | jq -c 'map(select(startswith(".claude")))')"; }
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

test_effect_settings_files_never_violations_non_git() { load_ga; r=$(mk_project brownfield); ga --root "$r" init >/dev/null; set_state "$r" '.phase="iterating"'; ga_effect_snapshot "$r"
  mkdir -p "$r/.claude"; echo '{}' >"$r/.claude/settings.local.json"; echo n >"$r/src/new.c"
  assert_eq '["src/new.c"]' "$(GA_HARNESS=claude-code viol "$r")"; }

test_effect_cli_check() { r=$(git_proj); ga --root "$r" effect check >/dev/null || _fail "init must snapshot"
  echo c >"$r/src/a.c"; rc=0; out=$(ga --root "$r" effect check 2>"$HOME/err") || rc=$?; assert_eq 1 "$rc"
  assert_eq '["src/a.c"]' "$(jq -c .violations <<<"$out")"; assert_contains "$(cat "$HOME/err")" "src/a.c"; }
test_effect_snapshot_after_init_and_transitions() { use_fake_claude; r=$(mk_project); ga --root "$r" init >/dev/null
  assert_status 0 test -f "$r/docs/architecture/.state/snapshot.json"
  seed_ledger "$r" "$FIX/ledger_inputs_ready.json"; ga --root "$r" verify >/dev/null
  echo c >"$r/docs/architecture/notes.md"; f=$(mktemp); printf 'GA 승인 입력' >"$f" # allowed in inputs; the baseline taken at the transition includes it
  out=$(ga --root "$r" user-command --text-file "$f"); assert_eq allow "$(jq -r .decision <<<"$out")"; assert_eq iterating "$(sj "$r" .phase)"
  assert_eq '[]' "$(ga --root "$r" effect check | jq -c .changed)"; }

test_effect_plugin_dir_inside_root_is_violation() { r=$(mk_project); mkdir -p "$r/vendor"; cp -R "$PLUGIN" "$r/vendor/ga-plugin"
  cga() { "$r/vendor/ga-plugin/core/bin/ga" --root "$r" "$@"; }
  cga init >/dev/null; set_state "$r" '.phase="implement"'; cga effect check >/dev/null
  echo "# x" >>"$r/vendor/ga-plugin/core/lib/common.sh"; echo y >"$r/src.c"
  rc=0; out=$(cga effect check 2>/dev/null) || rc=$?; assert_eq 1 "$rc"
  assert_eq '["vendor/ga-plugin/core/lib/common.sh"]' "$(jq -c .violations <<<"$out")"
  # plugin outside the project: a change in a same-named folder is not judged
  r2=$(mk_project); ga --root "$r2" init >/dev/null; set_state "$r2" '.phase="implement"'; ga --root "$r2" effect check >/dev/null
  mkdir -p "$r2/vendor"; echo z >"$r2/vendor/f"; ga --root "$r2" effect check >/dev/null || _fail "outside plugin must not restrict"
}

# --- final fix wave (P18): the effect check does not trust agent-writable git metadata and fails closed ---
test_p18_assume_unchanged_and_skip_worktree_caught() { load_ga; r=$(git_proj); ga_effect_snapshot "$r"
  git -C "$r" update-index --assume-unchanged src/a.c; echo y >>"$r/src/a.c"
  git -C "$r" update-index --skip-worktree src/b.c; echo y >>"$r/src/b.c"
  assert_eq '["src/a.c","src/b.c"]' "$(viol "$r")"; }
test_p18_flag_set_before_snapshot_judged_from_snapshot() { load_ga; r=$(git_proj)
  git -C "$r" update-index --skip-worktree src/b.c; echo early >>"$r/src/b.c"; ga_effect_snapshot "$r"
  assert_eq '[]' "$(viol "$r")"; echo late >>"$r/src/b.c"; assert_eq '["src/b.c"]' "$(viol "$r")"; }
test_p18_info_exclude_not_trusted() { load_ga; r=$(git_proj)
  echo 'gen/' >"$r/.gitignore"; git -C "$r" add .gitignore; git -C "$r" commit -qm ign; ga_effect_snapshot "$r"
  echo 'src/new.c' >>"$r/.git/info/exclude"; echo n >"$r/src/new.c"; mkdir -p "$r/gen"; echo g >"$r/gen/out.txt"
  assert_eq '["src/new.c"]' "$(viol "$r")"; }
test_p18_missing_base_fails_closed() { local sp rc out; load_ga; r=$(git_proj); ga_effect_snapshot "$r"; sp=$r/docs/architecture/.state/snapshot.json
  jq '.base = "1111111111111111111111111111111111111111"' "$sp" >"$sp.x"; mv "$sp.x" "$sp"; echo y >>"$r/src/a.c"
  rc=0; out=$(ga_effect_check "$r" 2>/dev/null) || rc=$?; assert_eq 1 "$rc"; assert_contains "$(jq -r '.violations[0]' <<<"$out")" "결과 확인 불가"; }
test_p18_git_failure_fails_closed() { local rc out; load_ga; r=$(git_proj); ga_effect_snapshot "$r"
  mv "$r/.git" "$r/.git.off"
  rc=0; out=$(ga_effect_check "$r" 2>/dev/null) || rc=$?; assert_eq 1 "$rc"; assert_contains "$(jq -r '.violations[0]' <<<"$out")" "결과 확인 불가"
  # a .git file that redirects the repository is not followed silently either
  echo "gitdir: $r/.git.off" >"$r/.git"
  rc=0; out=$(ga_effect_check "$r" 2>/dev/null) || rc=$?; assert_eq 1 "$rc"; assert_contains "$(jq -r '.violations[0]' <<<"$out")" "결과 확인 불가"; }
test_p18_repo_config_and_path_git_cannot_run_code() { local m d rc; [ -x /usr/bin/git ] || return 0
  r=$(git_proj); m=$HOME/ran; d=$(mktemp -d)
  printf '#!/bin/sh\n: >"%s"\nexit 1\n' "$m" >"$d/fsm"; chmod +x "$d/fsm"
  git -C "$r" config core.fsmonitor "$d/fsm"; git -C "$r" config core.hooksPath "$d"
  printf '#!/bin/bash\n: >"%s"\nexec /usr/bin/git "$@"\n' "$m" >"$d/git"; chmod +x "$d/git"
  echo y >>"$r/src/a.c"; rc=0; PATH="$d:$PATH" ga --root "$r" effect check >/dev/null 2>&1 || rc=$?
  assert_eq 1 "$rc"; [ ! -e "$m" ] || _fail "repository config or a PATH git ran code"; }
