# 검증 실행기(runner) 추가 방법

검증 패널의 모델은 실행기로 부른다. 코어(`core/lib/*.sh`)는 특정 CLI를 모른다. 새 실행기(예: Codex, OpenCode, Gemini, Grok)는 이 디렉터리에 아래 두 파일만 추가하면 되고, 코어는 고치지 않는다. 패널에 넣으려면 `core/verifier/panel.json`이나 프로젝트의 `docs/architecture/.state/panel.json`의 `members`에 `{"runner":"<name>","model":"<model>"}`을 넣는다.

## 1. 과금 확인 기록 `<name>.json`

설계 문서 5.10절의 과금 확인 기록이다. 기록이 없거나 아래 필드 중 하나라도 비어 있으면 `ga`는 그 실행기를 실행하지 않는다(종료 4).

| 필드 | 형식 | 코어가 하는 일 |
|---|---|---|
| `name` | 문자열 | 기록 이름 (파일 이름과 같게) |
| `command` | 문자열 | 실행할 CLI. `PATH`에서 찾은 절대 경로로 실행하고, 그 경로를 `report.json`의 `panel[].command_path`와 승인 컨텍스트에 남긴다 |
| `subscription_auth` | 문자열 | 구독 인증 방식 설명 (5.10절 1) |
| `strip_env` | 문자열 배열 (환경변수 이름) | 실행 전 점검과 실행에서 이 변수들을 지운다 (5.10절 2) |
| `preflight_script` | 파일 이름 | 이 디렉터리의 실행 전 점검 스크립트 (5.10절 3, 아래 2절) |
| `allowed_auth_methods` | 문자열 배열 | 점검 결과가 이 중 하나일 때만 실행한다 |
| `refused_auth_methods` | 비어 있지 않은 문자열 배열 | API 과금·미로그인을 뜻하는 값. 허용 목록에 있어도 거부한다 (하한선) |
| `forbidden_flags` | 비어 있지 않은 문자열 배열 | `invoke`와 실행 인자에 있으면 거부한다 (`--flag`와 `--flag=값` 모두) |
| `invoke` | 문자열 배열 | 실행 인자 틀. `{{PROMPT}}`와 `{{MODEL}}`을 바꿔 넣는다. 실행기는 읽기·검색 도구만 쓰게 하고, 실행기 안에서 이 플러그인의 훅이 돌지 않게 한다 |
| `result_path` | jq 경로 | 실행기 stdout JSON에서 지적 JSON 문자열을 꺼내는 경로 (예: `.result`) |
| `sources` | `[{url, checked}]` | 위 내용을 확인한 공식 문서 URL과 확인 날짜 (5.10절 4). 과금 정책이 바뀔 수 있으므로 시범 평가 전에 다시 확인한다 |

그 밖의 필드(예: `claude.json`의 `forbidden_settings`, `auth_status_args`)는 그 실행기의 점검 스크립트만 읽는다.

실행기는 같은 입력 묶음(검증 프롬프트)을 받아 `{"findings":[{check, target, claim, evidence:[{type, ref}]}]}` 형식의 JSON을 돌려줘야 한다 (`core/verifier/prompt.md`).

## 2. 실행 전 점검 스크립트 `<name>.preflight.sh`

`/bin/bash`로 실행한다. bash 3.2와 jq만 쓴다. 코어는 `GA_RUNNER_RECORD`에 검증을 마친 기록 사본의 경로를 넣어 준다.

- **점검:** `<script> EXEC_DIR GA_ROOT`
  - 코어가 `strip_env`의 변수를 지운 환경으로 부른다. `EXEC_DIR`은 실행기가 돌 디렉터리, `GA_ROOT`는 설계 루트(없으면 빈 문자열)다.
  - 구독으로 처리되는 것이 확인되면 stdout에 정확히 한 줄 `ok: authMethod=<값>`을 쓰고 종료 0.
  - 아니면 이유 한 줄을 쓰고 종료 4. 확인할 수 없으면 거부한다 (점검이 안 되면 실행하지 않는다).
  - 이 CLI만의 API 과금 경로(설정 파일, 키 도우미, 제공자 전환 변수 등)를 여기서 모두 확인한다.
- **훑어보기:** `<script> --scan EXEC_DIR GA_ROOT`
  - 지우지 않은 현재 환경으로 부른다. 이 세션이 API 과금으로 돌 수 있게 하는 이름(환경변수, 설정 키)을 한 줄에 하나씩 쓰고 종료 0. 아무것도 없으면 아무것도 쓰지 않는다.
  - SessionStart 경고에 쓰인다 (`ga context session-start`가 유효 패널의 실행기마다 부른다).

## 3. 등록 전 확인

설계 문서 5.10절 표대로, 구독 경로가 공식 문서로 확인되지 않은 실행기(현재 Gemini, Grok)는 등록하지 않는다. 등록할 때 `tests/`에 거부 경로 테스트(과금 변수, 설정, 미로그인)를 함께 추가한다.
