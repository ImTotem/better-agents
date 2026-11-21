test_billing_ok() { use_fake_claude; assert_contains "$(ga billing check claude)" "authMethod=claude.ai"; }
test_billing_api_key_stripped() { use_fake_claude; export ANTHROPIC_API_KEY=x FAKE_ENV_DUMP=$(mktemp)
  ( . "$CORE/lib/common.sh"; . "$CORE/lib/billing.sh"; ga_runner_exec claude -p hi --model sonnet >/dev/null ); assert_not_contains "$(cat "$FAKE_ENV_DUMP")" ANTHROPIC_API_KEY; }
test_billing_apikeyhelper_refused() { use_fake_claude; export HOME=$(mktemp -d); mkdir -p "$HOME/.claude"; echo '{"apiKeyHelper":"x"}' >"$HOME/.claude/settings.json"; assert_status 4 ga billing check claude; }
test_billing_authmethod_api_key_refused() { use_fake_claude; FAKE_AUTH_METHOD=api_key assert_status 4 ga billing check claude; }
test_billing_preflight_failure_refused() { use_fake_claude; FAKE_AUTH_FAIL=1 assert_status 4 ga billing check claude; }
test_billing_record_missing_field_refused() { use_fake_claude; d=$(mktemp -d); jq 'del(.sources)' "$CORE/verifier/runners/claude.json" >"$d/claude.json"; GA_RUNNERS_DIR=$d assert_status 4 ga billing check claude; }
test_runner_exec_bare_flag_refused() { use_fake_claude; ( . "$CORE/lib/common.sh"; . "$CORE/lib/billing.sh"; assert_status 4 ga_runner_exec claude -p hi --bare ); }
test_billing_invalid_settings_json_refused() { use_fake_claude; mkdir -p "$HOME/.claude"; echo 'not json' >"$HOME/.claude/settings.local.json"; assert_status 4 ga billing check claude; }
test_billing_project_settings_local_refused() { use_fake_claude; r=$(mk_project); set_state "$r" '.'; mkdir -p "$r/.claude"; echo '{"apiKeyHelper":"x"}' >"$r/.claude/settings.local.json"
  ( cd "$r" && assert_status 4 ga billing check claude ); }
test_billing_scan_settings() { use_fake_claude
  ( . "$CORE/lib/common.sh"; . "$CORE/lib/billing.sh"; unset ANTHROPIC_API_KEY
    assert_eq "" "$(ga_billing_scan_settings "" claude)"
    export ANTHROPIC_API_KEY=x; assert_contains "$(ga_billing_scan_settings "" claude)" ANTHROPIC_API_KEY
    unset ANTHROPIC_API_KEY; mkdir -p "$HOME/.claude"; echo '{"apiKeyHelper":"x"}' >"$HOME/.claude/settings.json"
    assert_contains "$(ga_billing_scan_settings "" claude)" apiKeyHelper ); }
test_billing_check_without_root() { use_fake_claude; d=$(mktemp -d); ( cd "$d" && assert_status 0 ga billing check claude ); }
_bsrc() { . "$CORE/lib/common.sh"; . "$CORE/lib/billing.sh"; }
test_billing_settings_env_block_refused() { use_fake_claude; mkdir -p "$HOME/.claude"; echo '{"env":{"ANTHROPIC_API_KEY":"sk-x","CLAUDE_CODE_USE_BEDROCK":"1"}}' >"$HOME/.claude/settings.json"; assert_status 4 ga billing check claude; }
test_billing_settings_env_empty_value_refused() { use_fake_claude; mkdir -p "$HOME/.claude"; echo '{"env":{"ANTHROPIC_AUTH_TOKEN":""}}' >"$HOME/.claude/settings.local.json"; assert_status 4 ga billing check claude; }
test_billing_unrelated_env_ok() { use_fake_claude; mkdir -p "$HOME/.claude"; echo '{"env":{"FOO":"1"}}' >"$HOME/.claude/settings.json"; assert_status 0 ga billing check claude; }
test_billing_scan_reports_env_block() { use_fake_claude; mkdir -p "$HOME/.claude"; echo '{"env":{"ANTHROPIC_API_KEY":"x"}}' >"$HOME/.claude/settings.json"
  ( _bsrc; unset ANTHROPIC_API_KEY; assert_contains "$(ga_billing_scan_settings "" claude)" ANTHROPIC_API_KEY ); }
test_billing_claude_config_dir_refused() { use_fake_claude; d=$(mktemp -d); echo '{"apiKeyHelper":"x"}' >"$d/settings.json"; CLAUDE_CONFIG_DIR=$d assert_status 4 ga billing check claude
  ( _bsrc; export CLAUDE_CONFIG_DIR=$d; assert_contains "$(ga_billing_scan_settings "" claude)" apiKeyHelper ); }
test_billing_pwd_settings_without_root_refused() { use_fake_claude; d=$(mktemp -d); mkdir -p "$d/.claude"; echo '{"apiKeyHelper":"x"}' >"$d/.claude/settings.local.json"; ( cd "$d" && assert_status 4 ga billing check claude ); }
test_billing_ancestor_settings_refused() { use_fake_claude; d=$(mktemp -d); mkdir -p "$d/.claude" "$d/a/b"; echo '{"apiKeyHelper":"x"}' >"$d/.claude/settings.json"; ( cd "$d/a/b" && assert_status 4 ga billing check claude ); }
test_billing_exec_refusal_does_not_run_command() { use_fake_claude; export FAKE_ENV_DUMP=$(mktemp -u) FAKE_AUTH_METHOD=api_key
  ( _bsrc; assert_status 4 ga_runner_exec claude -p hi --model sonnet ); [ ! -e "$FAKE_ENV_DUMP" ] || _fail "command ran despite refusal"; }
test_billing_exec_strips_all_five() { use_fake_claude; export FAKE_ENV_DUMP=$(mktemp) ANTHROPIC_API_KEY=a ANTHROPIC_AUTH_TOKEN=b CLAUDE_CODE_USE_BEDROCK=1 CLAUDE_CODE_USE_VERTEX=1 CLAUDE_CODE_USE_FOUNDRY=1
  ( _bsrc; ga_runner_exec claude -p hi --model sonnet >/dev/null ); d=$(cat "$FAKE_ENV_DUMP"); [ -n "$d" ] || _fail "no dump"
  for v in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY; do assert_not_contains "$d" "$v="; done; }
test_billing_oauth_token_accepted() { use_fake_claude; FAKE_AUTH_METHOD=oauth_token assert_status 0 ga billing check claude; }
test_billing_exec_record_swap_refused() { use_fake_claude; d=$(mktemp -d); echo '{"command":"claude"}' >"$d/claude.json"; export FAKE_ENV_DUMP=$(mktemp -u) ANTHROPIC_API_KEY=x
  ( _bsrc; ga_billing_check() { return 0; }; ga_billing_check_rec() { return 0; }; GA_RUNNERS_DIR=$d assert_status 4 ga_runner_exec claude -p hi --bare ); [ ! -e "$FAKE_ENV_DUMP" ] || _fail "command ran"; }
test_billing_exec_bare_equals_refused() { use_fake_claude; ( _bsrc; assert_status 4 ga_runner_exec claude -p hi --bare=true; assert_status 4 ga_runner_exec claude -p hi --bare= ); }
test_billing_record_invoke_forbidden_flag_refused() { use_fake_claude; d=$(mktemp -d); jq '.invoke += ["--bare"]' "$CORE/verifier/runners/claude.json" >"$d/claude.json"; GA_RUNNERS_DIR=$d assert_status 4 ga billing check claude
  jq '.invoke += ["--bare=1"]' "$CORE/verifier/runners/claude.json" >"$d/claude.json"; GA_RUNNERS_DIR=$d assert_status 4 ga billing check claude; }
test_billing_hard_floor_api_key() { use_fake_claude; d=$(mktemp -d); jq '.allowed_auth_methods += ["api_key","none","third_party","api_key_helper"]' "$CORE/verifier/runners/claude.json" >"$d/claude.json"
  for m in api_key api_key_helper third_party none; do FAKE_AUTH_METHOD=$m GA_RUNNERS_DIR=$d assert_status 4 ga billing check claude; done; }
test_billing_bad_strip_env_name_refused() { use_fake_claude; d=$(mktemp -d); jq '.strip_env += ["a b;x"]' "$CORE/verifier/runners/claude.json" >"$d/claude.json"; GA_RUNNERS_DIR=$d assert_status 4 ga billing check claude; }
test_billing_subdir_of_root_settings_refused() { use_fake_claude; r=$(mk_project); set_state "$r" '.'; mkdir -p "$r/sub/.claude"; echo '{"env":{"ANTHROPIC_API_KEY":"sk-x"}}' >"$r/sub/.claude/settings.json"
  export FAKE_ENV_DUMP=$(mktemp -u)
  ( cd "$r/sub" && assert_status 4 ga billing check claude )
  ( cd "$r/sub" && _bsrc && GA_ROOT=$r && assert_status 4 ga_runner_exec claude -p hi ); [ ! -e "$FAKE_ENV_DUMP" ] || _fail "command ran"; }
test_billing_cwd_settings_with_other_root_refused() { use_fake_claude; r=$(mk_project); set_state "$r" '.'; d=$(mktemp -d); mkdir -p "$d/.claude"; echo '{"env":{"CLAUDE_CODE_USE_BEDROCK":"1"}}' >"$d/.claude/settings.local.json"
  ( cd "$d" && assert_status 4 ga --root "$r" billing check claude ); }
test_billing_settings_files_relative_terminates() { n=$( ( . "$CORE/verifier/runners/claude.preflight.sh"; _cl_settings_files foo | head -300 | wc -l ) ); [ "$n" -lt 300 ] || _fail "relative start dir did not terminate"; }
test_billing_unavailable_command_refused() { use_fake_claude; d=$(mktemp -d); jq '.command="no-such-cli-xyz"' "$CORE/verifier/runners/claude.json" >"$d/claude.json"; GA_RUNNERS_DIR=$d assert_status 4 ga billing check claude; }

# --- final review fixes ---
# I8 (R33a): Claude-specific billing knowledge lives in the runner's preflight script, not in core.
test_i8_core_billing_has_no_claude_specifics() { local out
  out=$(grep -nE 'CLAUDE_CONFIG_DIR|\.claude/settings|ClaudeCode|apiKeyHelper|\.authMethod|adapters/claude-code|scan_settings[^#]* claude' "$CORE"/lib/billing.sh "$CORE"/lib/context.sh "$CORE"/lib/gates.sh "$CORE"/lib/verify.sh || true)
  [ -z "$out" ] || _fail "Claude-specific code in core: $out"
  assert_eq claude.preflight.sh "$(jq -r .preflight_script "$CORE/verifier/runners/claude.json")"
  assert_status 0 test -f "$CORE/verifier/runners/claude.preflight.sh"
  assert_contains "$(jq -c .refused_auth_methods "$CORE/verifier/runners/claude.json")" '"api_key"'
  assert_status 0 test -f "$CORE/verifier/runners/README.md"; }
test_i8_refused_auth_methods_required() { use_fake_claude; d=$(mktemp -d)
  jq '.refused_auth_methods=[]' "$CORE/verifier/runners/claude.json" >"$d/claude.json"; GA_RUNNERS_DIR=$d assert_status 4 ga billing check claude
  jq 'del(.preflight_script)' "$CORE/verifier/runners/claude.json" >"$d/claude.json"; GA_RUNNERS_DIR=$d assert_status 4 ga billing check claude
  jq '.preflight_script="../../lib/x.sh"' "$CORE/verifier/runners/claude.json" >"$d/claude.json"; GA_RUNNERS_DIR=$d assert_status 4 ga billing check claude; }
test_i8_record_refused_method_wins_over_allowed() { use_fake_claude; d=$(mktemp -d)
  jq '.allowed_auth_methods += ["sso"] | .refused_auth_methods += ["sso"]' "$CORE/verifier/runners/claude.json" >"$d/claude.json"
  FAKE_AUTH_METHOD=sso GA_RUNNERS_DIR=$d assert_status 4 ga billing check claude; }
test_i8_invoke_settings_with_api_billing_refused() { use_fake_claude; d=$(mktemp -d)
  jq '.invoke |= map(if ((try fromjson catch null) | type) == "object" then (fromjson + {apiKeyHelper:"x"} | tojson) else . end)' "$CORE/verifier/runners/claude.json" >"$d/claude.json"
  assert_contains "$(cat "$d/claude.json")" apiKeyHelper
  GA_RUNNERS_DIR=$d assert_status 4 ga billing check claude
  jq '.invoke |= map(if ((try fromjson catch null) | type) == "object" then (fromjson + {env:{ANTHROPIC_API_KEY:"k"}} | tojson) else . end)' "$CORE/verifier/runners/claude.json" >"$d/claude.json"
  GA_RUNNERS_DIR=$d assert_status 4 ga billing check claude; }
# I9 (R34a): GA_RUNNERS_DIR is a test-only override.
test_i9_runners_dir_only_in_test_mode() { use_fake_claude; d=$(mktemp -d); jq 'del(.sources)' "$CORE/verifier/runners/claude.json" >"$d/claude.json"
  GA_RUNNERS_DIR=$d assert_status 4 ga billing check claude
  ( unset GA_TEST_MODE; GA_RUNNERS_DIR=$d assert_status 0 ga billing check claude ); }
test_i9_settings_env_ga_variable_refused() { use_fake_claude; mkdir -p "$HOME/.claude"; echo '{"env":{"GA_RUNNERS_DIR":"/tmp/x"}}' >"$HOME/.claude/settings.local.json"
  assert_status 4 ga billing check claude; }
# C1 (R24): the runner child is marked so the core ignores its hooks.
test_c1_runner_exec_marks_child() { use_fake_claude; export FAKE_ENV_DUMP=$(mktemp)
  ( _bsrc; ga_runner_exec claude -p hi --model sonnet >/dev/null ); assert_contains "$(cat "$FAKE_ENV_DUMP")" "GA_IN_RUNNER=1"; }
