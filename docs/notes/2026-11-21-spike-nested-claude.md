# 스파이크: Claude Code 세션 안에서 `claude -p` 중첩 실행 (2026-11-21)

설계 문서 5.6절의 "(가정) 중첩 실행 문제"를 확인한 기록이다. 결론은 **통과**다.

## 1. 인증 방식
- 명령: `claude auth status | jq -r .authMethod`
- 출력: `claude.ai` (구독 로그인)

## 2. 중첩 호출 (Claude Code 세션의 Bash 도구 안에서 실행)
- 명령:
  ```bash
  env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u CLAUDE_CODE_USE_BEDROCK -u CLAUDE_CODE_USE_VERTEX -u CLAUDE_CODE_USE_FOUNDRY claude -p "Reply with exactly the word OK" --model sonnet --allowedTools "Read" --output-format json
  ```
- exit 0
- 출력: `{"result":"OK","is_error":false}`
- 최상위 키: `api_error_status`, `duration_api_ms`, `duration_ms`, `fast_mode_disabled_reason`, `fast_mode_state`, `is_error`, `modelUsage`, `num_turns`, `permission_denials`, `result`, `session_id`, `stop_reason`, `subtype`, `terminal_reason`, `time_to_request_ms`, `total_cost_usd`, `ttft_ms`, `ttft_stream_ms`, `type`, `usage`, `uuid`
- `.result` 필드가 있으므로, 실행기 기록의 `result_path: ".result"`가 맞다.

## 3. 도구 제한
- 명령: 같은 환경에서 `--allowedTools "Read,Grep,Glob"`를 주고 "Create a file named x.txt containing hi"를 요청
- exit 0, `is_error:false`
- `permission_denials`에 Write 거부가 기록됨
- 디렉터리에는 `out.json`만 있고 **`x.txt`는 생성되지 않았다.**
- 참고: 거부된 도구의 `file_path`가 `/private/var/folders/...`로 표시되었다. macOS가 경로를 `/private` 접두가 붙은 형태로 바꾸는 실제 사례다. 계획의 Review Focus 2(경로 정규화)의 근거가 된다.

## 결론
- 중첩 구독 호출: **통과**
- 읽기 전용 도구 제한: **통과**
- Task 7~8은 계획대로 `claude -p` 실행기로 진행한다.
