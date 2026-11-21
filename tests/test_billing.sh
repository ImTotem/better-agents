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
test_billing_unavailable_command_refused() { use_fake_claude; d=$(mktemp -d); jq '.command="no-such-cli-xyz"' "$CORE/verifier/runners/claude.json" >"$d/claude.json"; GA_RUNNERS_DIR=$d assert_status 4 ga billing check claude; }
