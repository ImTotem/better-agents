#!/bin/bash
# End-to-end lifecycle of the gate redesign (spec 5.5): the agent changes state through the MCP
# server, the hooks check isolation / changed files / state fingerprint, the user approves through
# UserPromptSubmit. Nothing here edits design state directly except the tamper test.
MCP_SERVER=$CORE/mcp/server.sh
INIT='{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"0"}}}'
INITD='{"jsonrpc":"2.0","method":"notifications/initialized"}'
export GA_TEST_MANAGED_SETTINGS=/nonexistent/ga-managed-settings.json

hk() { "$PLUGIN/adapters/claude-code/hook.sh" "$1"; }
pev() { # ROOT EVENT_NAME EXTRA_JQ_OBJECT
  jq -n --arg r "$1" --arg e "$2" --argjson x "$3" '{session_id:"sess-e2e",transcript_path:"/tmp/transcript.jsonl",cwd:$r,hook_event_name:$e,permission_mode:"default"} + $x'
}
say() { pev "$1" UserPromptSubmit "$(jq -n --arg p "$2" '{prompt:$p}')" | hk user-prompt; }
bash_hook() { pev "$1" PreToolUse '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | hk pre-bash; }
write_hook() { pev "$1" PreToolUse "$(jq -n --arg p "$2" '{tool_name:"Write",tool_input:{file_path:$p,content:"x"}}')" | hk pre-write; }
stop_hook() { pev "$1" Stop "{\"stop_hook_active\":${2:-false}}" | hk stop; }
phase() { jq -r .phase "$1/docs/architecture/.state/state.json"; }
decision() { jq -r '.decision // empty' <<<"$1"; }

# mc TOOL ARGS_JSON: one MCP tools/call through the real server; prints the text, fails on isError.
mc() {
  local out
  out=$(printf '%s\n' "$INIT" "$INITD" \
    "$(jq -nc --arg n "$1" --argjson a "$2" '{jsonrpc:"2.0",id:1,method:"tools/call",params:{name:$n,arguments:$a}}')" \
    | "$MCP_SERVER" 2>/dev/null | jq -c 'select(.id == 1)')
  printf '%s\n' "$out" | jq -r '.result.content[0].text'
  [ "$(printf '%s\n' "$out" | jq -r '.result.isError')" = false ]
}
add() { mc ga_add "$(jq -nc --arg k "$1" --argjson i "$2" '{kind:$k, item:$i}')"; } # KIND ITEM_JSON

e2e_env() { # sets r and the MCP environment
  use_fake_claude
  r=$(mk_project)
  export CLAUDE_PROJECT_DIR=$r GA_HARNESS=claude-code
}

DRV_PURPOSE='{"driver_type":"purpose","statement":"할 일 목록을 관리하는 CLI","horizon":"current","priority":"medium","iteration":null,"source":{"type":"user","ref":"대화","quote":"할 일 목록 CLI를 만들고 싶어요"}}'
DRV_FUNC='{"driver_type":"functional","statement":"할 일을 추가하고 완료 처리한다","horizon":"current","priority":"medium","iteration":null,"source":{"type":"user","ref":"대화","quote":"추가하고 완료 표시를 할 수 있어야 해요"}}'
DRV_QUAL='{"driver_type":"quality","statement":"성능: 목록 조회","horizon":"current","priority":"high","iteration":1,"scenario":{"stimulus":"할 일이 1,000개 쌓인 상태에서 목록 명령을 실행한다","response":"목록을 출력한다","measure":"p95 응답 시간 0.5초 이하"},"source":{"type":"user","ref":"대화","quote":"천 개가 있어도 바로 떠야 해요"}}'
DEC_STORE='{"element":"저장소","choice":"JSON 파일 하나에 목록을 저장한다","rationale":[{"type":"user","ref":"대화","quote":"천 개가 있어도 바로 떠야 해요"}],"alternatives":[{"option":"SQLite 데이터베이스","reason":"DRV-3 시나리오는 1,000개 목록 조회뿐이라 파일 전체 읽기로 0.5초 안에 충분하고, 데이터베이스는 CLI 시작 비용만 늘린다"}],"drivers":["DRV-3"]}'

# The agent starts a design through MCP and the user approves the inputs: ends in "iterating".
e2e_to_iterating() {
  local asm out
  mc ga_init '{}' >/dev/null
  assert_eq inputs "$(phase "$r")"
  # isolation settings were written by ga_init, so the shell hook lets a command through
  assert_eq "" "$(bash_hook "$r")"
  add driver "$DRV_PURPOSE" >/dev/null
  add driver "$DRV_FUNC" >/dev/null
  add driver "$DRV_QUAL" >/dev/null
  asm=$(add assumption "$(jq -c . "$FIX/asm.json")")
  assert_eq ASM-1 "$asm"
  mc ga_render '{}' >/dev/null
  mc ga_verify '{}' >/dev/null
  # the open assumption blocks approval until the user confirms it
  out=$(say "$r" "GA 승인 입력")
  assert_eq block "$(decision "$out")"
  assert_contains "$(jq -r .reason <<<"$out")" "ASM-1"
  assert_eq inputs "$(phase "$r")"
  out=$(say "$r" "GA 확인 ASM-1 맞아요")
  assert_eq "" "$(decision "$out")"
  assert_contains "$(jq -r .hookSpecificOutput.additionalContext <<<"$out")" "기록됨"
  out=$(say "$r" "GA 승인 입력")
  assert_eq "" "$(decision "$out")"
  assert_eq iterating "$(phase "$r")"
  [ -f "$r/docs/architecture/.state/snapshot.json" ] || _fail "no snapshot after approval"
}

test_e2e_out_of_scope_change_blocks_stop_until_reverted() {
  local out
  e2e_env
  e2e_to_iterating
  assert_eq "" "$(stop_hook "$r")"
  # in a design phase the shell hook still passes (the OS isolation is the gate); the write hook denies
  assert_eq "" "$(bash_hook "$r")"
  assert_eq deny "$(jq -r .hookSpecificOutput.permissionDecision <<<"$(write_hook "$r" "$r/src/b.c")")"
  mkdir -p "$r/src"; echo 'int a;' >"$r/src/a.c"
  out=$(stop_hook "$r")
  assert_eq block "$(decision "$out")"
  assert_contains "$(jq -r .reason <<<"$out")" "src/a.c"
  # the block holds on a repeated stop too (the agent can revert)
  assert_eq block "$(decision "$(stop_hook "$r" true)")"
  # approval of the iteration is refused while the change stands, and passes after the revert
  add decision "$DEC_STORE" >/dev/null
  mc ga_check '{}' >/dev/null
  mc ga_render '{}' >/dev/null
  mc ga_verify '{}' >/dev/null
  out=$(say "$r" "GA 승인 반복")
  assert_eq block "$(decision "$out")"
  assert_contains "$(jq -r .reason <<<"$out")" "src/a.c"
  assert_eq iterating "$(phase "$r")"
  rm -rf "$r/src"
  assert_eq "" "$(stop_hook "$r")"
  out=$(say "$r" "GA 승인 반복")
  assert_eq "" "$(decision "$out")"
  assert_eq design-review "$(phase "$r")"
}

test_e2e_user_accepts_change_with_state_approval() {
  local out
  e2e_env
  e2e_to_iterating
  mkdir -p "$r/src"; echo 'int a;' >"$r/src/a.c"
  assert_eq block "$(decision "$(stop_hook "$r")")"
  # the user accepts the file as it is
  out=$(say "$r" "GA 상태승인")
  assert_eq "" "$(decision "$out")"
  assert_contains "$(jq -r .hookSpecificOutput.additionalContext <<<"$out")" "받아들였습니다"
  assert_eq "" "$(stop_hook "$r")"
  assert_eq "" "$(bash_hook "$r")"
  assert_contains "$(cat "$r/docs/architecture/.state/approvals.jsonl")" 상태승인
}

test_e2e_pause_resume_rebaselines_files() {
  e2e_env
  e2e_to_iterating
  say "$r" "GA 일시정지" >/dev/null
  mkdir -p "$r/src"; echo 'int a;' >"$r/src/a.c"
  assert_eq "" "$(stop_hook "$r")"
  say "$r" "GA 재개" >/dev/null
  # what changed while paused is the user's: the baseline is taken again
  assert_eq "" "$(stop_hook "$r")"
  assert_eq iterating "$(phase "$r")"
}

test_e2e_tampered_state_fingerprint() {
  local out
  e2e_env
  e2e_to_iterating
  # an outside edit of state.json (not through ga)
  tamper_state "$r" '.round = 7'
  # the MCP write is refused while the fingerprint mismatches
  assert_status 1 mc ga_add "$(jq -nc --argjson i "$DRV_FUNC" '{kind:"driver", item:$i}')"
  # approval is refused with the fingerprint message
  out=$(say "$r" "GA 승인 반복")
  assert_eq block "$(decision "$out")"
  assert_contains "$(jq -r .reason <<<"$out")" "상태 지문"
  # Stop blocks once, then passes with a systemMessage for the user
  out=$(stop_hook "$r")
  assert_eq block "$(decision "$out")"
  assert_contains "$(jq -r .reason <<<"$out")" "GA 상태승인"
  out=$(stop_hook "$r" true)
  assert_eq "" "$(decision "$out")"
  assert_contains "$(jq -r .systemMessage <<<"$out")" "상태 지문"
  # the user accepts: writes work again
  say "$r" "GA 상태승인" >/dev/null
  assert_eq "" "$(stop_hook "$r")"
  add driver "$DRV_FUNC" >/dev/null
}

test_e2e_no_design_hooks_are_silent() {
  local out
  e2e_env
  assert_eq "" "$(bash_hook "$r")"
  assert_eq "" "$(write_hook "$r" "$r/src/a.c")"
  assert_eq "" "$(stop_hook "$r")"
  assert_eq "" "$(stop_hook "$r" true)"
  assert_eq "" "$(pev "$r" SessionStart '{"source":"startup"}' | hk session-start)"
  # a GA line without a design is ordinary text: no block
  out=$(say "$r" "GA 승인 입력")
  assert_eq "" "$(decision "$out")"
  [ ! -e "$r/docs/architecture/.state" ] || _fail "hooks created a state folder"
}
