#!/bin/bash
# MCP stdio server (core/mcp/server.sh): JSON-RPC lines in, JSON-RPC lines out.
MCP_SERVER=$CORE/mcp/server.sh
MCP_TOOLS="ga_add ga_ask ga_check ga_dispute ga_enforce ga_init ga_render ga_resolve ga_rule ga_status ga_update ga_verify"
INIT='{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"0"}}}'
INITD='{"jsonrpc":"2.0","method":"notifications/initialized"}'

mcp() { printf '%s\n' "$@" | "$MCP_SERVER" 2>/dev/null; } # LINE... -> server stdout
mreq() { # ID METHOD [PARAMS_JSON]
  local p=${3:-}
  [ -n "$p" ] || p='{}'
  jq -nc --argjson id "$1" --arg m "$2" --argjson p "$p" '{jsonrpc:"2.0", id:$id, method:$m, params:$p}'
}
mcall() { # ID TOOL ARGS_JSON [PROGRESS_TOKEN_JSON]
  jq -nc --argjson id "$1" --arg n "$2" --argjson a "$3" --argjson t "${4:-null}" \
    '{jsonrpc:"2.0", id:$id, method:"tools/call", params:({name:$n, arguments:$a} + (if $t == null then {} else {_meta:{progressToken:$t}} end))}'
}
resp() { printf '%s\n' "$1" | jq -c --argjson id "$2" 'select(.id == $id)'; } # OUT ID -> that response
text() { resp "$1" "$2" | jq -r '.result.content[0].text'; }
iserr() { resp "$1" "$2" | jq -r '.result.isError'; }
progress_lines() { printf '%s\n' "$1" | jq -c 'select(.method == "notifications/progress")'; }
nlines() { printf '%s' "$1" | grep -c . || true; }
ledger() { jq -r "$2" "$1/docs/architecture/.state/ledger.json"; } # ROOT JQ
add_args() { jq -c --arg k "$1" '{kind:$k, item:.}' "$2"; }       # KIND FILE -> ga_add arguments

test_mcp_initialize() {
  local out
  iparams() { jq -nc --arg v "$1" '{protocolVersion:$v, capabilities:{}, clientInfo:{name:"t", version:"0"}}'; }
  out=$(mcp "$(mreq 1 initialize "$(iparams 2025-06-18)")" "$(mreq 2 initialize "$(iparams 2025-11-25)")" \
            "$(mreq 3 initialize "$(iparams 1999-01-01)")")
  assert_eq 2025-06-18 "$(resp "$out" 1 | jq -r .result.protocolVersion)"
  assert_eq 2025-11-25 "$(resp "$out" 2 | jq -r .result.protocolVersion)"
  # an unsupported request gets the server's latest supported version
  assert_eq 2025-11-25 "$(resp "$out" 3 | jq -r .result.protocolVersion)"
  assert_eq true "$(resp "$out" 1 | jq '.result.capabilities.tools | type == "object"')"
  assert_eq true "$(resp "$out" 1 | jq '.result.serverInfo.name | type == "string" and length > 0')"
  assert_eq 2.0 "$(resp "$out" 1 | jq -r .jsonrpc)"
}

test_mcp_tools_list_exact() {
  local out
  out=$(mcp "$INIT" "$INITD" "$(mreq 1 tools/list)")
  assert_eq "$MCP_TOOLS" "$(resp "$out" 1 | jq -r '[.result.tools[].name] | sort | join(" ")')"
  assert_eq 0 "$(resp "$out" 1 | jq '[.result.tools[].name | select(test("user|gate"; "i"))] | length')"
  assert_eq true "$(resp "$out" 1 | jq '.result.tools | all(.inputSchema.type == "object" and (.description | length > 0))')"
}

test_mcp_add_then_status() {
  local r out
  r=$(mk_project); export CLAUDE_PROJECT_DIR=$r
  out=$(mcp "$INIT" "$INITD" "$(mcall 1 ga_init '{}')" "$(mcall 2 ga_add "$(add_args assumption "$FIX/asm.json")")" \
            "$(mcall 3 ga_status '{}')" "$(mcall 4 ga_status '{"json":true}')")
  assert_eq false "$(iserr "$out" 1)"; assert_contains "$(text "$out" 1)" "초기화: mode=greenfield"
  assert_eq false "$(iserr "$out" 2)"; assert_eq ASM-1 "$(text "$out" 2)"
  assert_eq false "$(iserr "$out" 3)"; assert_contains "$(text "$out" 3)" "open=1"
  assert_eq 1 "$(text "$out" 4 | jq .open)"
  assert_eq "동시 사용자는 100명 이하다" "$(ledger "$r" '.items[0].statement')"
}

test_mcp_tool_error_is_iserror() {
  local r out
  r=$(mk_project); export CLAUDE_PROJECT_DIR=$r; ga --root "$r" init >/dev/null
  out=$(mcp "$INIT" "$(mcall 1 ga_add '{"kind":"assumption","item":{"statement":"근거 없는 가정"}}')" "$(mcall 2 ga_status '{}')")
  assert_eq true "$(iserr "$out" 1)"
  assert_contains "$(text "$out" 1)" "search_log"
  assert_contains "$(text "$out" 1)" "종료 코드 3"
  assert_eq 0 "$(ledger "$r" '.items | length')"
  assert_eq false "$(iserr "$out" 2)"; assert_contains "$(text "$out" 2)" "open=0"
}

test_mcp_bad_json_and_unknown_method() {
  local out
  out=$(mcp '{"jsonrpc":"2.0","id":1,"method":"ping"' '[]' '' "$(mreq 2 no/such/method)" \
            "$(mcall 3 ga_gate '{}')" "$(mcall 4 ga_user_command '{}')" "$(mreq 5 tools/call '{"arguments":{}}')" "$(mreq 6 ping)")
  assert_eq '[-32700,-32600]' "$(printf '%s\n' "$out" | jq -sc '[.[] | select(.id == null) | .error.code]')"
  assert_eq -32601 "$(resp "$out" 2 | jq -r .error.code)"
  assert_eq -32602 "$(resp "$out" 3 | jq -r .error.code)"; assert_contains "$(resp "$out" 3 | jq -r .error.message)" ga_gate
  assert_eq -32602 "$(resp "$out" 4 | jq -r .error.code)"
  assert_eq -32602 "$(resp "$out" 5 | jq -r .error.code)"
  assert_eq '{}' "$(resp "$out" 6 | jq -c .result)"
  assert_eq 7 "$(nlines "$out")" # one reply per non-blank line, nothing else on stdout
}

test_mcp_notifications_no_reply() {
  local out
  out=$(mcp "$INITD" '{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":9}}' '{"jsonrpc":"2.0","method":"notifications/whatever"}')
  assert_eq "" "$out"
  out=$(mcp "$INITD" "$(mreq 1 ping)")
  assert_eq 1 "$(nlines "$out")"
}

verify_root() { # -> project in iterating with a one-member panel whose fake model sleeps SECS
  local r d
  r=$(mk_project brownfield); ga --root "$r" init >/dev/null; seed_ledger "$r" "$FIX/ledger_valid.json"
  set_state "$r" '.phase="iterating"|.iteration=1|.iteration_count=1'
  echo '{"members":[{"runner":"claude","model":"opus"}],"timeout_sec":30}' >"$r/docs/architecture/.state/panel.json"; _fp_sync "$r" # the user's panel, accepted
  d=$(mktemp -d); echo "$1" >"$d/opus.sleep"
  echo "$r $d"
}

test_mcp_verify_sends_progress() {
  local r d out prog n
  use_fake_claude
  set -- $(verify_root 3); r=$1; d=$2
  export FAKE_P_DIR=$d GA_MCP_PROGRESS_SEC=1 CLAUDE_PROJECT_DIR=$r
  out=$(mcp "$INIT" "$(mcall 1 ga_verify '{}' '"tok-1"')")
  prog=$(progress_lines "$out"); n=$(nlines "$prog")
  [ "$n" -ge 2 ] || _fail "expected at least 2 progress notifications, got $n: $out"
  assert_eq '["tok-1"]' "$(printf '%s\n' "$prog" | jq -sc '[.[].params.progressToken] | unique')"
  assert_eq true "$(printf '%s\n' "$prog" | jq -s '[.[].params.progress] | . == (sort | unique)')" # strictly increasing
  assert_eq 1 "$(printf '%s\n' "$out" | tail -n 1 | jq .id)" # the response comes after every notification
  assert_eq false "$(iserr "$out" 1)"; assert_contains "$(text "$out" 1)" "opus"
  [ -f "$r/docs/architecture/.state/report.json" ] || _fail "verify wrote no report"
  # without a progress token: no notifications
  out=$(mcp "$INIT" "$(mcall 2 ga_verify '{}')")
  assert_eq "" "$(progress_lines "$out")"; assert_eq false "$(iserr "$out" 2)"
}

test_mcp_progress_interval_override_needs_test_mode() {
  local r d out
  use_fake_claude
  set -- $(verify_root 2); r=$1; d=$2
  export FAKE_P_DIR=$d GA_MCP_PROGRESS_SEC=1 CLAUDE_PROJECT_DIR=$r
  out=$(unset GA_TEST_MODE; mcp "$INIT" "$(mcall 1 ga_verify '{}' 7)")
  assert_eq "" "$(progress_lines "$out")"
  assert_eq false "$(iserr "$out" 1)"
}

mcp_gone() { # PATTERN: true once no process matches (3 s at most)
  local i=0
  while [ $i -lt 30 ]; do [ -z "$(pgrep -f "$1" 2>/dev/null || true)" ] && return 0; sleep 0.1; i=$((i + 1)); done
  return 1
}

test_mcp_term_stops_running_command() {
  local r d f sp rc=0 i=0
  use_fake_claude
  set -- $(verify_root 41.25); r=$1; d=$2
  export FAKE_P_DIR=$d CLAUDE_PROJECT_DIR=$r TMPDIR=$(mktemp -d)
  f=$TMPDIR/in; mkfifo "$f"
  "$MCP_SERVER" <"$f" >"$TMPDIR/out" 2>/dev/null &
  sp=$!
  exec 9>"$f"
  mcall 1 ga_verify '{}' '"t"' >&9
  while [ -z "$(pgrep -f '^sleep 41[.]25$' 2>/dev/null || true)" ]; do
    i=$((i + 1)); [ $i -lt 100 ] || _fail "the fake model never started"; sleep 0.1
  done
  kill -TERM "$sp"; wait "$sp" || rc=$?
  exec 9>&-
  assert_eq 143 "$rc"
  mcp_gone '^sleep 41[.]25$' || _fail "the running ga verify outlived the server"
  [ ! -f "$r/docs/architecture/.state/report.json" ] || _fail "a report was written after TERM"
  assert_eq "" "$(ls "$TMPDIR" | grep '^ga-mcp' || true)"
}

test_mcp_json_declares_server() {
  local f=$PLUGIN/.mcp.json r out
  assert_eq '${CLAUDE_PLUGIN_ROOT}/core/mcp/server.sh' "$(jq -r '.mcpServers.ga.command' "$f")"
  assert_eq claude-code "$(jq -r '.mcpServers.ga.env.GA_HARNESS' "$f")"
  [ -x "$MCP_SERVER" ] || _fail "server.sh is not executable"
  # the server's working directory is undocumented: it must not matter
  r=$(mk_project); export CLAUDE_PROJECT_DIR=$r
  out=$(cd / && mcp "$INIT" "$(mcall 1 ga_init '{}')")
  assert_eq false "$(iserr "$out" 1)"; [ -f "$r/docs/architecture/.state/state.json" ] || _fail "init did not reach the project"
}

test_mcp_discover_falls_back_to_initialize() {
  local out
  # A dual-era client probes with server/discover; a non-modern error makes it fall back to initialize.
  out=$(mcp '{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}' "$INIT")
  assert_eq -32601 "$(resp "$out" 1 | jq -r .error.code)"
  assert_eq 2025-11-25 "$(resp "$out" 0 | jq -r .result.protocolVersion)"
}

rootarg() { jq -nc --arg r "$1" '{root:$r}'; } # PATH -> {"root":PATH}

# Without CLAUDE_PROJECT_DIR (other harnesses) the root argument is required and used as given.
test_mcp_root_argument_and_missing_root() {
  local a b out
  unset CLAUDE_PROJECT_DIR
  b=$(mk_project)
  out=$(mcp "$(mcall 1 ga_init "$(rootarg "$b")")")
  assert_eq false "$(iserr "$out" 1)"
  [ -f "$b/docs/architecture/.state/state.json" ] || _fail "root argument ignored"
  out=$(mcp "$(mcall 2 ga_status '{"root":"relative/dir"}')" "$(mcall 3 ga_status "$(rootarg "$b/missing")")" "$(mcall 4 ga_status '{}')")
  assert_eq true "$(iserr "$out" 2)"; assert_contains "$(text "$out" 2)" "절대 경로"
  assert_eq true "$(iserr "$out" 3)"
  assert_eq true "$(iserr "$out" 4)"; assert_contains "$(text "$out" 4)" "CLAUDE_PROJECT_DIR"
}

# P10: with CLAUDE_PROJECT_DIR the root is the design found walking up from it (else that dir);
# a root argument must canonicalize to that same path.
test_mcp_root_argument_must_match_session_root() {
  local a b out
  a=$(mk_project); b=$(mk_project); export CLAUDE_PROJECT_DIR=$a
  ln -s "$a" "$b/alias"
  out=$(mcp "$(mcall 1 ga_init "$(rootarg "$b")")" "$(mcall 2 ga_status "$(rootarg "$b/alias")")" \
            "$(mcall 3 ga_init "$(rootarg "$b/alias/.")")" "$(mcall 4 ga_status "$(rootarg "$a")")" "$(mcall 5 ga_status '{"root":"relative/dir"}')")
  assert_eq true "$(iserr "$out" 1)"; assert_contains "$(text "$out" 1)" "root"
  [ ! -e "$b/docs" ] || _fail "a root other than the session's was used"
  assert_eq true "$(iserr "$out" 2)"; assert_contains "$(text "$out" 2)" "초기화된 프로젝트가 없습니다" # same path, no design yet
  assert_eq false "$(iserr "$out" 3)"; [ -f "$a/docs/architecture/.state/state.json" ] || _fail "alias of the session root refused"
  assert_eq false "$(iserr "$out" 4)"
  assert_eq true "$(iserr "$out" 5)"; assert_contains "$(text "$out" 5)" "절대 경로"
}

test_mcp_subfolder_session_uses_design_above() {
  local r out
  r=$(mk_project); ga --root "$r" init >/dev/null; mkdir -p "$r/sub/deeper"
  export CLAUDE_PROJECT_DIR=$r/sub/deeper
  out=$(mcp "$(mcall 1 ga_add "$(add_args assumption "$FIX/asm.json")")" "$(mcall 2 ga_status '{}')" \
            "$(mcall 3 ga_status "$(rootarg "$r")")" "$(mcall 4 ga_status "$(rootarg "$r/sub/deeper")")")
  assert_eq ASM-1 "$(text "$out" 1)"; assert_eq 1 "$(ledger "$r" '.items | length')"
  assert_contains "$(text "$out" 2)" "open=1"
  assert_eq false "$(iserr "$out" 3)" # the design's root is the session root
  assert_eq true "$(iserr "$out" 4)"  # the subfolder is not
  [ ! -e "$r/sub/deeper/docs" ] || _fail "the subfolder got design files"
}

test_mcp_status_and_verify_before_init() {
  local r out i
  r=$(mk_project); export CLAUDE_PROJECT_DIR=$r
  out=$(mcp "$(mcall 1 ga_status '{}')" "$(mcall 2 ga_status '{"json":true}')" "$(mcall 3 ga_verify '{}')")
  for i in 1 2 3; do
    assert_eq true "$(iserr "$out" $i)"
    assert_contains "$(text "$out" $i)" "초기화된 프로젝트가 없습니다 (ga init 먼저)"
    assert_not_contains "$(text "$out" $i)" "jq:"
  done
}

test_mcp_arguments_are_not_shell_text() {
  local r m s out
  r=$(mk_project); export CLAUDE_PROJECT_DIR=$r; ga --root "$r" init >/dev/null
  m=$(mktemp -d)/pwned
  # one quoting style per call: a mix would be a syntax error to any shell that re-parsed it
  out=$(mcp "$(mcall 1 ga_add "$(jq -c --arg s "\$(touch $m)" '{kind:"assumption", item:(.statement = $s)}' "$FIX/asm.json")")" \
            "$(mcall 2 ga_update "$(jq -nc --arg s "\`touch $m\`" '{id:"ASM-1", patch:{statement:$s}}')")" \
            "$(mcall 3 ga_update "$(jq -nc --arg s "x'; touch $m; '" '{id:"ASM-1", patch:{statement:$s}}')")" \
            "$(mcall 4 ga_update "$(jq -nc --arg s "y\"; touch $m; \"" '{id:"ASM-1", patch:{statement:$s}}')")" \
            "$(mcall 5 ga_dispute "$(jq -nc --arg s "\$(touch $m)" '{id:"FND-1; touch '"$m"'", evidence:$s}')")")
  [ ! -e "$m" ] || _fail "argument text ran as a shell command"
  assert_eq false "$(iserr "$out" 4)"
  assert_eq "y\"; touch $m; \"" "$(ledger "$r" '.items[0].statement')"
  assert_eq true "$(iserr "$out" 5)"
}

test_mcp_invalid_arguments_are_tool_errors() {
  local r out i
  r=$(mk_project); export CLAUDE_PROJECT_DIR=$r; ga --root "$r" init >/dev/null
  out=$(mcp "$(mcall 1 ga_add '{"item":{}}')" "$(mcall 2 ga_add '{"kind":"assumption","item":{},"extra":1}')" \
            "$(mcall 3 ga_resolve '{"id":"ASM-1","source_type":"user","ref":"x"}')" "$(mcall 4 ga_ask '{"id":7}')" \
            "$(mcall 5 ga_check '{"item":{}}')" "$(mcall 6 ga_dispute '{"id":"FND-1","evidence":""}')")
  for i in 1 2 3 4 5 6; do assert_eq true "$(iserr "$out" $i)"; done
  assert_contains "$(text "$out" 1)" kind
  assert_contains "$(text "$out" 2)" extra
  assert_contains "$(text "$out" 3)" source_type
  assert_contains "$(text "$out" 4)" id
  assert_contains "$(text "$out" 5)" kind
  assert_contains "$(text "$out" 6)" evidence
  assert_eq 0 "$(ledger "$r" '.items | length')"
}

test_mcp_tools_reach_their_subcommands() {
  local r out
  r=$(mk_project brownfield); export CLAUDE_PROJECT_DIR=$r GA_HARNESS=claude-code # as .mcp.json passes it
  out=$(mcp "$(mcall 1 ga_init '{"mode":"greenfield"}')" "$(mcall 2 ga_add "$(add_args assumption "$FIX/asm.json")")" \
            "$(mcall 3 ga_resolve '{"id":"ASM-1","source_type":"code","ref":"src/main.c:1"}')" "$(mcall 4 ga_ask '{"id":"ASM-1"}')" \
            "$(mcall 5 ga_render '{}')" "$(mcall 6 ga_check '{"json":true}')" \
            "$(mcall 7 ga_check "$(add_args assumption "$FIX/asm.json")")" "$(mcall 8 ga_rule '{}')" \
            "$(mcall 9 ga_dispute '{"id":"FND-1","evidence":"src/main.c:1"}')" "$(mcall 10 ga_enforce '{}')")
  assert_contains "$(text "$out" 1)" "mode=greenfield"
  assert_eq resolved "$(ledger "$r" '.items[0].status')"; assert_eq code "$(ledger "$r" '.items[0].resolution.source.type')"
  assert_eq true "$(iserr "$out" 4)"; assert_contains "$(text "$out" 4)" "ga ask는 질문"
  assert_eq false "$(iserr "$out" 5)"; grep -q '<!-- ga:begin ledger -->' "$r/docs/architecture/architecture.md" || _fail "render did not run"
  assert_eq '[]' "$(text "$out" 6 | jq -c .errors)"
  assert_eq false "$(iserr "$out" 7)"
  assert_contains "$(text "$out" 8)" "[근거 규칙]"
  assert_eq true "$(iserr "$out" 9)"; assert_contains "$(text "$out" 9)" "검증 보고서가 없습니다"
  assert_eq false "$(iserr "$out" 10)"; assert_contains "$(text "$out" 10)" "격리 설정: "
  assert_eq true "$(jq -r .sandbox.enabled "$r/.claude/settings.local.json")"
}

# P3: while the state fingerprint mismatches, the MCP write tools refuse (core ga refuses); reads work.
test_mcp_write_tools_refuse_while_state_tampered() {
  local r out
  r=$(mk_project); export CLAUDE_PROJECT_DIR=$r; ga --root "$r" init >/dev/null; tamper_state "$r" '.x = 1'
  out=$(mcp "$(mcall 1 ga_add "$(add_args assumption "$FIX/asm.json")")" "$(mcall 2 ga_render '{}')" "$(mcall 3 ga_status '{}')")
  assert_eq true "$(iserr "$out" 1)"; assert_contains "$(text "$out" 1)" "GA 상태승인"
  assert_eq true "$(iserr "$out" 2)"; assert_eq false "$(iserr "$out" 3)"
  assert_eq 0 "$(ledger "$r" '.items | length')"
}

# P12: only the user's GA 재개 / GA 상태승인 move the file baseline; no MCP tool does.
test_mcp_tools_cannot_clear_effect_violation() {
  local r out rc=0
  r=$(mk_project); export CLAUDE_PROJECT_DIR=$r GA_HARNESS=claude-code; ga --root "$r" init >/dev/null
  mkdir -p "$r/src"; echo 'int x;' >"$r/src/agent.c"
  out=$(mcp "$(mcall 1 ga_add "$(add_args assumption "$FIX/asm.json")")" "$(mcall 2 ga_render '{}')" "$(mcall 3 ga_enforce '{}')" \
            "$(mcall 4 ga_check '{}')" "$(mcall 5 ga_status '{}')")
  for i in 1 2 3 5; do assert_eq false "$(iserr "$out" $i)"; done
  out=$(ga --root "$r" effect check 2>/dev/null) || rc=$?
  assert_eq 1 "$rc"; assert_eq '["src/agent.c"]' "$(jq -c .violations <<<"$out")"
}
