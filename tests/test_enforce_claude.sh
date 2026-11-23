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
  # the temp file is a dotfile (.settings.local.json.XXXXXX): ls -A shows it if one is left behind
  assert_eq "settings.local.json" "$(ls -A "$r/.claude")"
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

# An unreadable or invalid lower-precedence file is skipped; a non-object sandbox value is not "on".
test_enforce_status_skips_bad_other_files() {
  local r out; r=$(phys "$(mk_project)"); "$ENF" install "$r" >/dev/null
  mkdir -p "$HOME/.claude"; echo 'garbage' >"$HOME/.claude/settings.json"; echo '{"sandbox":"x"}' >"$r/.claude/settings.json"
  out=$(GA_TEST_MANAGED_SETTINGS=/nonexistent "$ENF" status "$r"); assert_eq true "$(jq -r .active <<<"$out")"
  echo '{"sandbox":"x"}' >"$r/.claude/settings.local.json"
  out=$(GA_TEST_MANAGED_SETTINGS=/nonexistent "$ENF" status "$r"); assert_eq false "$(jq -r .active <<<"$out")"
}

# The write gate asks the adapter which paths are Claude Code settings files of the design.
test_enforce_protects_settings_files() {
  local m w h p; read -r m w <<<"$(mk_wt)"; h=$(phys "$HOME")
  for p in "$w/.claude/settings.local.json" "$w/.claude/settings.json" "$m/.claude/settings.local.json" "$m/.claude/Settings.Local.JSON" \
           "$h/.claude/settings.json" "$h/.claude/settings.backup.json"; do
    "$ENF" protects "$w" "$p" || _fail "not protected: $p"
  done
  for p in "$w/.claude/commands/x.md" "$w/settings.json" "$m/.claude/agents/settings.json" "$h/settings.json" "$w/src/a.c"; do
    ! "$ENF" protects "$w" "$p" || _fail "protected: $p"
  done
  assert_status 2 "$ENF" protects "$w"
}

# ---- ga enforce / ga init wiring ----

test_ga_enforce_installs_and_rebaselines() {
  local r out; r=$(phys "$(mk_project)")
  ga --root "$r" init >/dev/null 2>&1
  out=$(GA_HARNESS=claude-code ga --root "$r" enforce); assert_contains "$out" "$r/.claude/settings.local.json"
  assert_eq true "$(jq -r .sandbox.enabled "$r/.claude/settings.local.json")"
  # P19: the harness's settings files are never effect violations
  assert_eq '[]' "$(GA_HARNESS=claude-code ga --root "$r" effect check 2>/dev/null | jq -c .violations)"
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
  # P29: the per-file records live in snapshot.list ("STAT REF PATH")
  assert_contains "$(cat "$r/docs/architecture/.state/snapshot.list")" " .claude/settings.local.json"
}

# --- final fix wave ---
# T4: precedence across files (managed > local > project > user) and the in-project plugin entry.
test_enforce_status_precedence_local_over_project_and_user() {
  local r out; r=$(phys "$(mk_project)"); "$ENF" install "$r" >/dev/null; mkdir -p "$HOME/.claude"
  echo '{"sandbox":{"enabled":false,"allowUnsandboxedCommands":true}}' >"$r/.claude/settings.json"
  echo '{"sandbox":{"enabled":false,"allowUnsandboxedCommands":true}}' >"$HOME/.claude/settings.json"
  out=$(GA_TEST_MANAGED_SETTINGS=/nonexistent "$ENF" status "$r"); assert_eq true "$(jq -r .active <<<"$out")"
  # a key the local file does not set comes from the project file before the user file
  jq 'del(.sandbox.allowUnsandboxedCommands)' "$r/.claude/settings.local.json" >"$r/l.x"; mv "$r/l.x" "$r/.claude/settings.local.json"
  out=$(GA_TEST_MANAGED_SETTINGS=/nonexistent "$ENF" status "$r"); assert_eq false "$(jq -r .active <<<"$out")"
  echo '{"sandbox":{"allowUnsandboxedCommands":false}}' >"$r/.claude/settings.json"
  out=$(GA_TEST_MANAGED_SETTINGS=/nonexistent "$ENF" status "$r"); assert_eq true "$(jq -r .active <<<"$out")"
}
test_enforce_install_denies_in_project_plugin_folder() {
  local r s; r=$(phys "$(mk_project)"); mkdir -p "$r/vendor"; cp -R "$PLUGIN" "$r/vendor/ga-plugin"
  s=$("$r/vendor/ga-plugin/adapters/claude-code/enforce.sh" install "$r")
  assert_eq "[\"$r/docs/architecture/.state\",\"$r/vendor/ga-plugin\"]" "$(sget "$s" -c .sandbox.filesystem.denyWrite)"
  s=$("$ENF" install "$(phys "$(mk_project)")"); assert_eq 1 "$(sget "$s" '.sandbox.filesystem.denyWrite | length')"
}
# T4: ga init shows at once why the isolation could not be installed.
test_ga_init_shows_enforce_failure_reason() {
  local r out; r=$(phys "$(mk_project)"); mkdir -p "$r/.claude"; echo '{bad' >"$r/.claude/settings.local.json"
  out=$(GA_HARNESS=claude-code ga --root "$r" init 2>&1); assert_contains "$out" "올바른 JSON"
}

# P22: excludedCommands run outside the sandbox: status stays active but warns.
test_p22_status_warns_on_excluded_commands() {
  local r out; r=$(phys "$(mk_project)"); "$ENF" install "$r" >/dev/null; mkdir -p "$HOME/.claude"
  echo '{"sandbox":{"excludedCommands":["docker *"]}}' >"$r/.claude/settings.json"
  echo '{"sandbox":{"excludedCommands":["kubectl *"]}}' >"$HOME/.claude/settings.json"
  out=$(GA_TEST_MANAGED_SETTINGS=/nonexistent "$ENF" status "$r"); assert_eq true "$(jq -r .active <<<"$out")"
  assert_contains "$(jq -r '.warnings | join(" ")' <<<"$out")" "docker *"; assert_contains "$(jq -r '.warnings | join(" ")' <<<"$out")" "kubectl *"
  rm -f "$r/.claude/settings.json" "$HOME/.claude/settings.json"
  out=$(GA_TEST_MANAGED_SETTINGS=/nonexistent "$ENF" status "$r"); assert_eq 0 "$(jq '.warnings | length' <<<"$out")"
}

# P23: the user can remove the isolation; uninstall removes exactly what install added.
test_p23_uninstall_restores_previous_settings() {
  local r s before; r=$(phys "$(mk_project)"); mkdir -p "$r/.claude"; s=$r/.claude/settings.local.json
  before='{"model":"x","sandbox":{"enabled":false,"network":{"allowedDomains":["a.com"]},"filesystem":{"denyWrite":["/other"]}}}'
  echo "$before" >"$s"
  GA_HARNESS=claude-code ga --root "$r" init >/dev/null
  [ -f "$r/docs/architecture/.state/enforce.json" ] || _fail "no install record"
  assert_eq true "$(sget "$s" .sandbox.enabled)"
  GA_HARNESS=claude-code ga --root "$r" enforce >/dev/null # a second install must not forget what the first one set
  "$ENF" uninstall "$r" >/dev/null
  assert_eq "$(jq -cS . <<<"$before")" "$(jq -cS . "$s")"
}
test_p23_uninstall_removes_created_file_and_exclude_line() {
  local m w; read -r m w <<<"$(mk_wt)"
  GA_HARNESS=claude-code ga --root "$w" init >/dev/null
  [ -f "$m/.claude/settings.local.json" ] || _fail "install did not write the main checkout's file"
  "$ENF" uninstall "$w" >/dev/null
  [ ! -e "$m/.claude/settings.local.json" ] || _fail "a file ga created must go"
  assert_eq 0 "$(grep -Fxc '.claude/settings.local.json' "$m/.git/info/exclude" || true)"
}
test_p23_user_command_removes_isolation() {
  local r f out; r=$(phys "$(mk_project)"); GA_HARNESS=claude-code ga --root "$r" init >/dev/null
  f=$(mktemp); printf 'GA 격리해제' >"$f"
  out=$(GA_HARNESS=claude-code ga --root "$r" user-command --text-file "$f")
  assert_eq allow "$(jq -r .decision <<<"$out")"; assert_contains "$(jq -r .context <<<"$out")" "GA 일시정지"
  [ ! -e "$r/.claude/settings.local.json" ] || _fail "isolation settings left"
  [ ! -e "$r/docs/architecture/.state/enforce.json" ] || _fail "install record left"
  assert_eq false "$(GA_TEST_MANAGED_SETTINGS=/nonexistent "$ENF" status "$r" | jq -r .active)"
  # not an MCP tool
  assert_not_contains "$(cat "$CORE/mcp/server.sh")" "uninstall"
}

# P24: layouts the adapter cannot resolve with certainty fail closed.
test_p24_uncertain_layouts_refused() {
  local b w out rc m
  b=$(phys "$(mk_project)"); w=$(phys "$(mk_project)"); mkdir -p "$b/x.git/worktrees/wt"; echo "../.." >"$b/x.git/worktrees/wt/commondir"
  printf '[core]\n\tbare = true\n' >"$b/x.git/config"; echo "gitdir: $b/x.git/worktrees/wt" >"$w/.git"
  rc=0; out=$("$ENF" install "$w" 2>&1) || rc=$?; assert_eq 2 "$rc"; assert_contains "$out" "저장소"
  [ ! -e "$b/.claude/settings.local.json" ] || _fail "wrote a file Claude Code does not read"
  out=$("$ENF" status "$w"); assert_eq false "$(jq -r .active <<<"$out")"; assert_contains "$(jq -r .reason <<<"$out")" "저장소"
  # a .git file whose gitdir has no commondir (submodule style)
  w=$(phys "$(mk_project)"); mkdir -p "$b/mods/m"; echo "gitdir: $b/mods/m" >"$w/.git"
  rc=0; "$ENF" install "$w" >/dev/null 2>&1 || rc=$?; assert_eq 2 "$rc"
  assert_eq false "$("$ENF" status "$w" | jq -r .active)"
  # a main checkout whose .git says bare = true
  read -r m w <<<"$(mk_wt)"; printf '[core]\n\tbare = true\n' >>"$m/.git/config"
  rc=0; "$ENF" install "$w" >/dev/null 2>&1 || rc=$?; assert_eq 2 "$rc"
}

# M4: native Windows has no sandbox.
test_enforce_status_inactive_on_native_windows() {
  local r; r=$(phys "$(mk_project)"); "$ENF" install "$r" >/dev/null
  assert_eq false "$(GA_TEST_OSTYPE=msys GA_TEST_MANAGED_SETTINGS=/nonexistent "$ENF" status "$r" | jq -r .active)"
}

# P16 (b): enforce.sh exec runs a command in the OS sandbox with the design's protected paths read-only.
test_enforce_exec_protects_state_and_parents() {
  local r dd rc; [ -x /usr/bin/sandbox-exec ] || command -v bwrap >/dev/null 2>&1 || return 0
  r=$(phys "$(mk_project)"); GA_HARNESS=claude-code ga --root "$r" init >/dev/null; dd=$(phys "$(mktemp -d)")
  cp "$r/docs/architecture/.state/state.json" "$HOME/s0"
  "$ENF" exec "$r" --protect "$dd" -- /bin/sh -c 'cd "$1"; echo x >docs/architecture/.state/state.json; mv docs/architecture docs/y; mv docs d2; echo x >.claude/settings.local.json; echo z >"$2/f"; echo ok >ok.txt' _ "$r" "$dd" >/dev/null 2>&1 || true
  cmp -s "$r/docs/architecture/.state/state.json" "$HOME/s0" || _fail "state written"
  [ -d "$r/docs/architecture" ] || _fail "parent renamed"; [ ! -e "$dd/f" ] || _fail "protected dir written"
  assert_eq true "$(jq -r .sandbox.enabled "$r/.claude/settings.local.json")"; [ -f "$r/ok.txt" ] || _fail "ordinary write failed"
  rc=0; GA_TEST_SANDBOX_EXEC=/nonexistent/sandbox-exec "$ENF" exec "$r" -- /bin/sh -c 'echo ran >"$1/ran"' _ "$r" 2>"$HOME/err" || rc=$?
  [ "$rc" != 0 ] || _fail "ran without a sandbox"; [ ! -e "$r/ran" ] || _fail "ran without a sandbox"; assert_contains "$(cat "$HOME/err")" "격리 실행 도구 없음"
}

# --- follow-up 3 (P38): the build sandbox denies only what turns the gates off ---
# Ordinary build writes (home caches, PATH folders, git internals, hook scripts, .mcp.json) work; the
# state folder, the settings files, the plugin folder and the data dir (fingerprint store) do not. The
# build gets its own temp folder (removed afterwards).
test_p38_exec_denies_only_gate_files() {
  local r o out rt p dd pp; [ -x /usr/bin/sandbox-exec ] || command -v bwrap >/dev/null 2>&1 || return 0
  r=$(phys "$(mk_project)"); git -C "$r" init -q; GA_HARNESS=claude-code ga --root "$r" init >/dev/null
  mkdir -p "$r/src" "$r/.claude/hooks" "$HOME/.claude" "$HOME/.local/bin" "$HOME/.cache" "$HOME/.npm"
  echo '{}' >"$HOME/.claude/settings.json"; dd=$(phys "$(mktemp -d)"); o=$(phys "${TMPDIR:-/tmp}"); pp=$(phys "$PLUGIN")/.ga-p38-probe
  out=$(GA_DATA_DIR=$dd "$ENF" exec "$r" --protect "$dd" -- /bin/bash -c '
    t() { if ( : >>"$1" ) 2>/dev/null; then echo "W $1"; else echo "D $1"; fi; }
    echo "TMP $TMPDIR"; t "$1/src/x"; t "$TMPDIR/x"; t "$HOME/.cache/x"; t "$HOME/.npm/x"; t "$HOME/.local/bin/x"
    t "$1/.git/hooks/pre-commit"; t "$1/.mcp.json"; t "$1/.claude/hooks/x.sh"; t "$2/ga-p38-probe"
    t "$1/docs/architecture/.state/x"; t "$1/.claude/settings.local.json"; t "$HOME/.claude/settings.json"; t "$3/f"; t "$4"' \
    _ "$r" "$o" "$dd" "$pp" 2>/dev/null)
  rm -f "$pp" "$o/ga-p38-probe"
  rt=$(sed -n 's/^TMP //p' <<<"$out"); case "$rt" in "$dd"/tmp/ga-build.*) ;; *) _fail "the build's TMPDIR is not its own folder: [$rt]" ;; esac
  for p in "$r/src/x" "$rt/x" "$HOME/.cache/x" "$HOME/.npm/x" "$HOME/.local/bin/x" "$r/.git/hooks/pre-commit" "$r/.mcp.json" \
           "$r/.claude/hooks/x.sh" "$o/ga-p38-probe"; do
    assert_contains "$out" "W $p"
  done
  for p in "$r/docs/architecture/.state/x" "$r/.claude/settings.local.json" "$HOME/.claude/settings.json" "$dd/f" "$pp"; do
    assert_contains "$out" "D $p"
  done
  [ ! -e "$rt" ] || _fail "the run's temp folder was not removed: $rt"
}


# --- P32 (M2): the texts do not claim the fingerprint catches what it cannot ---
test_p32_texts_do_not_overstate_the_fingerprint() {
  local c r out; c=$(cat "$PLUGIN/adapters/claude-code/capabilities.json")
  assert_not_contains "$c" "격리 밖에서 실행되는 파일은 읽기 전용"; assert_not_contains "$c" "상태 폴더는 지문이 지킨다"
  r=$(phys "$(mk_project)"); "$ENF" install "$r" >/dev/null
  echo '{"sandbox":{"excludedCommands":["docker *"]}}' >"$r/.claude/settings.json"
  out=$(GA_TEST_MANAGED_SETTINGS=/nonexistent "$ENF" status "$r" | jq -r '.warnings[0]')
  assert_contains "$out" "docker *"; assert_not_contains "$out" "상태 지문 확인이 잡습니다"
}
