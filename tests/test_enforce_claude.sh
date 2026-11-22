#!/bin/bash
# Claude Code adapter: OS isolation settings (adapters/claude-code/enforce.sh) and `ga enforce`.
ENF=$PLUGIN/adapters/claude-code/enforce.sh
phys() { (cd -P "$1" && pwd -P); }
sget() { local f=$1; shift; if [ "$1" = -c ]; then jq -c "$2" "$f"; else jq -r "$1" "$f"; fi; } # FILE [-c] JQ

test_enforce_install_creates_settings() {
  local r s sd; r=$(phys "$(mk_project)")
  s=$("$ENF" install "$r"); assert_eq "$r/.claude/settings.local.json" "$s"
  sd=$r/docs/architecture/.state
  assert_eq true "$(sget "$s" .sandbox.enabled)"
  assert_eq true "$(sget "$s" .sandbox.failIfUnavailable)"
  assert_eq false "$(sget "$s" .sandbox.allowUnsandboxedCommands)"
  assert_eq "$sd" "$(sget "$s" '.sandbox.filesystem.denyWrite[0]')"
}

test_enforce_install_merges_existing() {
  local r s; r=$(phys "$(mk_project)"); mkdir -p "$r/.claude"
  echo '{"permissions":{"allow":["Bash(ls)"]},"sandbox":{"network":{"allowedDomains":["example.com"]},"filesystem":{"denyWrite":["/other"]}},"model":"x"}' >"$r/.claude/settings.local.json"
  s=$("$ENF" install "$r")
  assert_eq '["Bash(ls)"]' "$(sget "$s" -c .permissions.allow)"
  assert_eq '["example.com"]' "$(sget "$s" -c .sandbox.network.allowedDomains)"
  assert_eq x "$(sget "$s" .model)"
  assert_eq '["/other","'"$r"'/docs/architecture/.state"]' "$(sget "$s" -c .sandbox.filesystem.denyWrite)"
}

test_enforce_install_idempotent() {
  local r s; r=$(phys "$(mk_project)")
  "$ENF" install "$r" >/dev/null; s=$("$ENF" install "$r")
  assert_eq 1 "$(sget "$s" '.sandbox.filesystem.denyWrite | length')"
  assert_eq 0 "$(ls "$r/.claude" | grep -c tmp || true)"
}

test_enforce_install_rejects_broken_json() {
  local r; r=$(phys "$(mk_project)"); mkdir -p "$r/.claude"; echo '{bad' >"$r/.claude/settings.local.json"
  assert_status 2 "$ENF" install "$r"
  assert_eq '{bad' "$(cat "$r/.claude/settings.local.json")"
}

mk_wt() { # -> prints "MAIN WT" (git main checkout and a worktree-style checkout with .git file)
  local m w; m=$(phys "$(mk_project)"); w=$(phys "$(mk_project)")
  git -C "$m" init -q
  mkdir -p "$m/.git/worktrees/wt"
  echo "../.." >"$m/.git/worktrees/wt/commondir"
  echo "gitdir: $m/.git/worktrees/wt" >"$w/.git"
  echo "$m $w"
}

test_enforce_worktree_writes_main_checkout() {
  local m w s
  read -r m w <<<"$(mk_wt)"
  s=$("$ENF" install "$w"); assert_eq "$m/.claude/settings.local.json" "$s"
  [ ! -e "$w/.claude/settings.local.json" ] || _fail "worktree must not get its own file"
  assert_eq "$w/docs/architecture/.state" "$(sget "$s" '.sandbox.filesystem.denyWrite[0]')"
}

test_enforce_worktree_relative_gitdir() {
  local m w s
  read -r m w <<<"$(mk_wt)"
  mkdir -p "$m/.git/worktrees/rel"; echo "../.." >"$m/.git/worktrees/rel/commondir"
  # relative gitdir from a checkout located inside the main repo tree
  mkdir -p "$m/sub/wt2"; echo "gitdir: ../../.git/worktrees/rel" >"$m/sub/wt2/.git"
  s=$("$ENF" install "$m/sub/wt2"); assert_eq "$m/.claude/settings.local.json" "$s"
}

test_enforce_subfolder_uses_repo_top() {
  local m s; m=$(phys "$(mk_project)"); git -C "$m" init -q; mkdir -p "$m/pkg/a"
  s=$("$ENF" install "$m/pkg/a"); assert_eq "$m/.claude/settings.local.json" "$s"
}

test_enforce_git_exclude_added() {
  local m w
  read -r m w <<<"$(mk_wt)"
  "$ENF" install "$w" >/dev/null; "$ENF" install "$w" >/dev/null
  assert_eq 1 "$(grep -Fxc '.claude/settings.local.json' "$m/.git/info/exclude")"
}

test_enforce_status_active() {
  local r out; r=$(phys "$(mk_project)")
  "$ENF" install "$r" >/dev/null
  out=$(GA_TEST_MANAGED_SETTINGS=/nonexistent "$ENF" status "$r")
  assert_eq true "$(jq -r .active <<<"$out")"
  assert_eq "$r/.claude/settings.local.json" "$(jq -r .settings <<<"$out")"
}

test_enforce_status_inactive_when_user_disables() {
  local r out m; r=$(phys "$(mk_project)"); m=$r/managed.json
  "$ENF" install "$r" >/dev/null
  echo '{"sandbox":{"allowUnsandboxedCommands":true}}' >"$m"
  out=$(GA_TEST_MANAGED_SETTINGS=$m "$ENF" status "$r")
  assert_eq false "$(jq -r .active <<<"$out")"
  assert_contains "$(jq -r .reason <<<"$out")" allowUnsandboxedCommands
  # the override is honored only in test mode
  out=$(GA_TEST_MODE=0 GA_TEST_MANAGED_SETTINGS=$m "$ENF" status "$r")
  assert_eq true "$(jq -r .active <<<"$out")"
}

test_enforce_status_inactive_when_missing_or_incomplete() {
  local r out; r=$(phys "$(mk_project)")
  out=$("$ENF" status "$r"); assert_eq false "$(jq -r .active <<<"$out")"
  mkdir -p "$r/.claude"
  echo '{"sandbox":{"enabled":true,"allowUnsandboxedCommands":false}}' >"$r/.claude/settings.local.json"
  out=$("$ENF" status "$r"); assert_eq false "$(jq -r .active <<<"$out")"; assert_contains "$(jq -r .reason <<<"$out")" denyWrite
  echo '{"sandbox":{"enabled":false,"allowUnsandboxedCommands":false}}' >"$r/.claude/settings.local.json"
  out=$("$ENF" status "$r"); assert_contains "$(jq -r .reason <<<"$out")" sandbox.enabled
  echo 'garbage' >"$r/.claude/settings.local.json"
  out=$("$ENF" status "$r"); assert_eq false "$(jq -r .active <<<"$out")"
}

# ---- ga enforce / ga init wiring ----

test_ga_enforce_installs_and_rebaselines() {
  local r out; r=$(phys "$(mk_project)")
  ga --root "$r" init >/dev/null 2>&1
  out=$(GA_HARNESS=claude-code ga --root "$r" enforce); assert_contains "$out" "$r/.claude/settings.local.json"
  assert_eq true "$(jq -r .sandbox.enabled "$r/.claude/settings.local.json")"
  # the file is part of the baseline: the effect check does not flag it
  assert_not_contains "$(ga --root "$r" effect check 2>&1)" settings.local.json
}

test_ga_enforce_fails_without_harness() {
  local r; r=$(phys "$(mk_project)")
  ga --root "$r" init >/dev/null 2>&1
  assert_status 2 env -u GA_HARNESS "$CORE/bin/ga" --root "$r" enforce
  assert_status 2 env GA_HARNESS=nope "$CORE/bin/ga" --root "$r" enforce
}

test_ga_enforce_needs_design() {
  local r; r=$(phys "$(mk_project)")
  assert_status 2 env GA_HARNESS=claude-code "$CORE/bin/ga" --root "$r" enforce
}

test_ga_init_warns_without_harness() {
  local r out; r=$(phys "$(mk_project)")
  out=$(env -u GA_HARNESS "$CORE/bin/ga" --root "$r" init 2>&1); assert_contains "$out" "격리"
  [ -f "$r/docs/architecture/.state/state.json" ] || _fail "init must still succeed"
  [ ! -e "$r/.claude/settings.local.json" ] || _fail "no settings without harness"
}

test_ga_init_installs_isolation_before_snapshot() {
  local r; r=$(phys "$(mk_project)")
  GA_HARNESS=claude-code ga --root "$r" init >/dev/null
  assert_eq true "$(jq -r .sandbox.enabled "$r/.claude/settings.local.json")"
  assert_contains "$(jq -c .files "$r/docs/architecture/.state/snapshot.json")" ".claude/settings.local.json"
}
