#!/bin/bash
# End-to-end lifecycle: synthetic Claude Code hook events -> hook.sh -> ga core,
# plus the agent-side ga commands the design-architecture skill prescribes.
hk() { "$PLUGIN/adapters/claude-code/hook.sh" "$1"; }
pev() { # ROOT EVENT_NAME EXTRA_JQ_OBJECT
  jq -n --arg r "$1" --arg e "$2" --argjson x "$3" '{session_id:"sess-e2e",transcript_path:"/tmp/transcript.jsonl",cwd:$r,hook_event_name:$e,permission_mode:"default"} + $x'
}
wr() { pev "$1" PreToolUse "$(jq -n --arg p "$2" '{tool_name:"Write",tool_input:{file_path:$p,content:"x"}}')" | hk pre-write; }
say() { pev "$1" UserPromptSubmit "$(jq -n --arg p "$2" '{prompt:$p}')" | hk user-prompt; }
phase() { jq -r .phase "$1/docs/architecture/.state/state.json"; }
verify_ok() { ga --root "$1" render >/dev/null; ga --root "$1" verify >/dev/null; }
st() { ga --root "$1" status --json; }

test_e2e_greenfield_lifecycle() {
  use_fake_claude
  r=$(mk_project)
  # 1. no design started: session-start injects nothing
  assert_eq "" "$(pev "$r" SessionStart '{"source":"startup"}' | hk session-start)"
  # 2. init
  ga --root "$r" init >/dev/null
  assert_eq inputs "$(phase "$r")"
  # 3. drivers, assumption, question
  ga --root "$r" add driver >/dev/null <<'EOF'
{"driver_type":"purpose","statement":"할 일 목록을 관리하는 CLI","horizon":"current","priority":"medium","iteration":null,
 "source":{"type":"user","ref":"대화","quote":"할 일 목록 CLI를 만들고 싶어요"}}
EOF
  ga --root "$r" add driver >/dev/null <<'EOF'
{"driver_type":"functional","statement":"할 일을 추가하고 완료 처리한다","horizon":"current","priority":"medium","iteration":null,
 "source":{"type":"user","ref":"대화","quote":"추가하고 완료 표시를 할 수 있어야 해요"}}
EOF
  ga --root "$r" add driver >/dev/null <<'EOF'
{"driver_type":"quality","statement":"성능: 목록 조회","horizon":"current","priority":"high","iteration":1,
 "scenario":{"stimulus":"할 일이 1,000개 쌓인 상태에서 목록 명령을 실행한다","response":"목록을 출력한다","measure":"p95 응답 시간 0.5초 이하"},
 "source":{"type":"user","ref":"대화","quote":"천 개가 있어도 바로 떠야 해요"}}
EOF
  asm=$(ga --root "$r" add assumption <<'EOF'
{"statement":"데이터는 한 사용자의 로컬 파일에만 저장한다",
 "indirect_evidence":[{"type":"goal_inference","ref":"DRV-1의 사용자 발언 '할 일 목록 CLI'"}],
 "search_log":{"code":"해당 없음: 새 프로젝트라 코드가 없다",
   "docs":"README.md, CLAUDE.md, docs/ 확인: 저장소 언급 없음",
   "conversation":"저장 위치 언급 없음",
   "web":"해당 없음: 이 프로젝트 고유의 선택이라 일반 문헌으로 정할 수 없다"},
 "alternatives":[{"assumption":"원격 서버에 동기화한다","reason":"사용자가 CLI 단독 사용만 말했다"}]}
EOF
)
  assert_eq ASM-1 "$asm"
  q=$(ga --root "$r" add question <<'EOF'
{"question":"완료한 할 일은 언제까지 보관해야 하나요?",
 "search_log":{"code":"해당 없음: 새 프로젝트라 코드가 없다","docs":"README.md, CLAUDE.md, docs/ 확인: 보관 정책 없음","conversation":"보관 기간 언급 없음","web":"해당 없음: 이 프로젝트 고유의 정책이다"},
 "impact":"저장 형식과 정리 기능 요구사항이 달라진다"}
EOF
)
  assert_eq Q-1 "$q"
  ga --root "$r" ask Q-1 >/dev/null
  # negative: ungrounded assumption (no indirect evidence) is rejected
  assert_status 3 ga --root "$r" add assumption <<'EOF'
{"statement":"사용자는 나중에 웹 UI도 원할 것이다","indirect_evidence":[],
 "search_log":{"code":"해당 없음: x","docs":"해당 없음: x","conversation":"해당 없음: x","web":"해당 없음: x"},
 "alternatives":[{"assumption":"원하지 않는다","reason":"언급 없음"}]}
EOF
  # 4. writing source code in inputs is denied
  out=$(wr "$r" "$r/src/a.c")
  assert_eq deny "$(jq -r .hookSpecificOutput.permissionDecision <<<"$out")"
  # 5. approval blocked while ASM-1 is open (even with a fresh report)
  verify_ok "$r"
  out=$(say "$r" "GA 승인 입력")
  assert_eq block "$(jq -r .decision <<<"$out")"
  assert_contains "$(jq -r .reason <<<"$out")" "ASM-1"
  assert_eq inputs "$(phase "$r")"
  # 6. the user confirms and answers (own prompt) -> allowed
  out=$(say "$r" "$(printf 'GA 확인 ASM-1 로컬 파일 맞아요\nGA 답 Q-1 완료 후 30일 보관')")
  assert_eq "" "$(jq -r '.decision // empty' <<<"$out")"
  assert_contains "$(jq -r .hookSpecificOutput.additionalContext <<<"$out")" "기록됨"
  # negative: editing a driver after verify makes the report stale -> approval blocked
  ga --root "$r" update DRV-2 >/dev/null <<'EOF'
{"statement":"할 일을 추가, 수정하고 완료 처리한다"}
EOF
  out=$(say "$r" "GA 승인 입력")
  assert_eq block "$(jq -r .decision <<<"$out")"
  assert_eq inputs "$(phase "$r")"
  # 7. verify exits 0 on the fake panel
  ga --root "$r" render >/dev/null
  assert_status 0 ga --root "$r" verify
  assert_eq true "$(st "$r" | jq -r .report_fresh)"
  # 8. approve inputs -> iterating
  out=$(say "$r" "GA 승인 입력")
  assert_eq "" "$(jq -r '.decision // empty' <<<"$out")"
  assert_eq iterating "$(phase "$r")"
  # 9. decision + verify + approve iteration -> design-review
  dec=$(ga --root "$r" add decision <<'EOF'
{"element":"저장소","choice":"JSON 파일 하나에 목록을 저장한다",
 "rationale":[{"type":"user","ref":"대화","quote":"천 개가 있어도 바로 떠야 해요"}],
 "alternatives":[{"option":"SQLite 데이터베이스","reason":"DRV-3 시나리오는 1,000개 목록 조회뿐이라 파일 전체 읽기로 0.5초 안에 충분하고, 데이터베이스는 CLI 시작 비용만 늘린다"}],
 "drivers":["DRV-3"]}
EOF
)
  assert_eq DEC-1 "$dec"
  ga --root "$r" check >/dev/null
  verify_ok "$r"
  out=$(say "$r" "GA 승인 반복")
  assert_eq "" "$(jq -r '.decision // empty' <<<"$out")"
  assert_eq design-review "$(phase "$r")"
  # 10. design-review -> skeleton
  verify_ok "$r"
  out=$(say "$r" "GA 승인 설계")
  assert_eq "" "$(jq -r '.decision // empty' <<<"$out")"
  assert_eq skeleton "$(phase "$r")"
  # 11. greenfield skeleton: source writes are allowed (no output)
  assert_eq "" "$(wr "$r" "$r/src/a.c")"
  # 12. skeleton -> implement
  verify_ok "$r"
  out=$(say "$r" "GA 승인 뼈대")
  assert_eq "" "$(jq -r '.decision // empty' <<<"$out")"
  assert_eq implement "$(phase "$r")"
  assert_eq 4 "$(wc -l <"$r/docs/architecture/.state/approvals.jsonl" | tr -d ' ')"
}

test_e2e_brownfield_skeleton() {
  use_fake_claude
  r=$(mk_project brownfield)
  # 1. brownfield project placed in the skeleton phase
  ga --root "$r" init --mode brownfield >/dev/null
  assert_eq brownfield "$(jq -r .mode "$r/docs/architecture/.state/state.json")"
  set_state "$r" '.phase="skeleton"'
  # 2. mapping MAP-1 for src/new.c
  m=$(ga --root "$r" add mapping <<'EOF'
{"element":"새 모듈","path":"src/new.c","change":"new"}
EOF
)
  assert_eq MAP-1 "$m"
  # 3. only the mapped file may be written
  out=$(wr "$r" "$r/src/old.c")
  assert_eq deny "$(jq -r .hookSpecificOutput.permissionDecision <<<"$out")"
  assert_eq "" "$(wr "$r" "$r/src/new.c")"
  # 4. test command
  out=$(say "$r" "GA 테스트명령 true")
  assert_eq "" "$(jq -r '.decision // empty' <<<"$out")"
  assert_eq true "$(cat "$r/docs/architecture/.state/test_command")"
  # 5. verify (runs the build check) then approve the skeleton
  verify_ok "$r"
  assert_eq true "$(st "$r" | jq -r .build_ok)"
  out=$(say "$r" "GA 승인 뼈대")
  assert_eq "" "$(jq -r '.decision // empty' <<<"$out")"
  assert_eq implement "$(phase "$r")"
}
