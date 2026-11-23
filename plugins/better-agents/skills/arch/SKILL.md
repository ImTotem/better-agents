---
name: arch
description: 새 프로젝트나 기존 코드의 아키텍처를 ADD 3.0 절차로 위에서 아래로 설계한다(요구사항부터 구현까지). 모든 판단에 근거를 붙이고 ga MCP 도구와 게이트로 단계를 강제한다. 사용자가 /arch로 직접 호출할 때만 쓴다.
disable-model-invocation: true
---

# 아키텍처 설계 (ADD 3.0 + 근거 규칙)

**다시 읽기:** 단계를 시작할 때와 컨텍스트 압축 뒤에는(압축 뒤에는 이 문서의 앞부분만 남는다) `ga status`로 현재 단계를 확인하고 `${CLAUDE_SKILL_DIR}/SKILL.md`의 0절, 1절, 현재 단계 절을 Read로 다시 읽는다.

코드보다 먼저 아키텍처를 위에서 아래로 설계한다. 단계: `inputs` → `iterating`(반복 1..N) → `design-review` → `skeleton` → `implement`. 문서는 `docs/architecture/architecture.md` 하나다. 원장과 단계는 `docs/architecture/.state/`에 있고 `ga`만 쓴다.

**상태는 MCP 도구로만 바꾼다.** 도구 전체 이름은 `mcp__plugin_better-agents_ga__<도구>`이고 여기서는 `ga_add`처럼 줄여 쓴다. 셸(Bash)은 운영체제 격리 안에서 돌아 상태 폴더에 못 쓴다. 셸에서는 읽기 명령(`ga status`, `ga check`, `ga rule`, `ga effect check`)만 쓴다. 상태를 바꾸는 셸 `ga` 명령은 실패하며 대신 쓸 MCP 도구를 알려 준다.

## 0. 원칙

**근거** (등급과 근거 종류는 메시지마다 오는 [근거 규칙], 전문은 `grounding` 스킬)
- 근거 있는 가정은 미완료다. `assumption`으로 올리고 사용자 확인이나 직접 근거로 해결한다. 근거 없는 가정은 금지다. `question`으로 묻는다.
- 가정이나 질문을 쓰기 전에 실제로 찾는다. 직접 근거를 찾으면 확정이다.
- `search_log` 칸마다 어디서 무엇을 찾았고(검색어, URL) 결과가 무엇인지 쓴다: `code`(대상 코드), `docs`(README, CLAUDE.md, `docs/`, 메모리 디렉터리), `conversation`(현재 대화), `web`(일반 지식에 관한 판단일 때). 해당하지 않으면 `해당 없음: 이유`.
- 문헌 출처에는 이 세션에서 실제로 열어 본 URL만 쓴다. `literature`의 `ref`는 `https://`(또는 `http://`), `doi:`, `isbn:`으로 시작해야 한다.
- 원장에는 아키텍처상 의미 있는 결정, 모든 가정, 모든 질문을 올린다. 그 밖의 판단은 응답에서 근거 종류를 표시한다.

**금지**
- 단계가 허용하지 않는 파일을 바꾸지 않는다(1절 "결과 확인". `skeleton` 전에는 `docs/architecture/` 밖 전부). 셸로 바꾼 것도 걸린다.
- `.state/` 아래(읽기만 된다), 플러그인 폴더, `.claude/settings*.json`, 상태 지문 저장 위치(`~/.local/state/grounded-arch`)를 쓰거나 고치거나 지우지 않는다.
- `ga` 내부 명령(`user-command`, `gate`)과 훅 스크립트를 부르지 않는다.
- 사용자의 확인, 답, 승인, 기각, 판정은 사용자가 `GA`로 시작하는 줄을 직접 입력해야만 기록된다. 대신 기록하거나 "사용자가 확인했다"고 쓰지 않는다. 대화의 "네"는 기록되지 않으니 그 줄을 입력해 달라고 한다.
- 승인을 몰아서 받지 않는다. `GA 확인`·`GA 답` 줄을 미리 채운 묶음으로 건네지 말고, 항목마다 근거를 보여 주며 하나씩 묻는다. 승인 줄은 사용자가 검토를 마친 뒤 따로 요청한다.
- `claude --bare`를 쓰거나 API 키(`ANTHROPIC_API_KEY` 등)를 설정하지 않는다. 모델 호출은 구독으로만 한다.
- 게이트가 `state.json`을 읽을 수 없다고 하면 고치지 말고 알린다. 사용자가 고치거나 복원해야 풀린다(그 뒤 `GA 상태승인`이 필요할 수 있다). 그동안 `GA 일시정지`는 셸 명령만 풀어 준다.
- superpowers의 brainstorming 같은 다른 기획 스킬을 부르지 않는다. 요구사항 정리는 `inputs` 단계가 맡는다.
- 도구 거부, 게이트 차단, 승인 거부 메시지는 빠진 것을 나열한다. 그것을 채우고, 우회하지 않는다. 게이트는 쉬운 우회만 막고 `.git/hooks`, `.mcp.json`, `.claude/hooks` 같은 평범한 파일은 막지 않는다. 못 막는 우회(작정하고 짠 공격)도 하지 않는다.
- 설계와 관계없는 작은 수정은 `GA 일시정지`를 요청해서 하고, 끝나면 `GA 재개`를 요청한다. 일시정지는 단계 규칙과 셸 격리 확인만 끈다. 위 보호(상태 폴더, 상태 지문, 설정 파일, 플러그인 폴더)는 일시정지 중에도 그대로다.

## 1. 시작

1. 프로젝트 루트에서 `ga status`(셸)를 실행한다. `command -v ga`가 실패하면 `"${CLAUDE_PLUGIN_ROOT}/bin/ga" status`를 쓴다.
2. "초기화된 프로젝트가 없습니다"(종료 2)면 `ga_init`을 인자 없이 부른다. 출력된 모드와 근거, 격리 설정 경로를 보고하고, 2절 전에 모드가 맞는지 사용자에게 명시적으로 확인받는다.
   - `greenfield`(새 프로젝트)는 뼈대 단계의 대응표 쓰기 제한과 빌드 확인이 꺼지고, `brownfield`(기존 코드)는 켜진다.
   - 모드가 틀렸으면 사용자에게 `docs/architecture/.state/`를 직접 지워 달라고 한 뒤 `ga_init`을 `{"mode":"greenfield"}`나 `{"mode":"brownfield"}`로 부른다.
   - 종료 3(홈 디렉터리나 `/`, 같은 저장소의 상위 디렉터리에 이미 설계가 있음, 심볼릭 링크 폴더)이면 메시지를 보여 주고 어디서 설계할지 묻는다.
3. 이미 초기화됐으면 architecture.md를 읽고 출력된 단계부터 이어 간다. `일시정지: true`면 먼저 `GA 재개`를 요청한다.

### 격리와 결과 확인

- 격리는 Claude Code `sandbox` 설정이다(`ga_init`이 저장소 맨 위 `.claude/settings.local.json`에 쓴다). 설계 중 셸이 "격리가 꺼져 있어 막습니다"로 막히면 `ga_enforce`를 부르고 다시 실행한다. 그래도 막히면 이유를 보여 주고 `GA 일시정지`를 요청한다.
- 처음 설치할 때 알린다: 이 설정은 그 저장소의 모든 세션과 워크트리에 적용되고, 설계가 끝나거나 그만둘 때 사용자가 `GA 격리해제`를 입력하면 `ga`가 넣은 것만 지워진다.
- 세션 시작 때 `sandbox.excludedCommands` 경고(사용자도 본다)에 나온 명령은 격리 밖에서 돈다. 그 명령으로 상태 폴더를 건드리지 않는다.
- "ga의 임시 폴더 …가 이 사용자 소유의 권한 700 폴더가 아니어서"가 나오면(데이터 폴더 아래 `tmp`. 설계 중에는 쓰기, 프롬프트, 셸 명령이 막힌다) 직접 고치지 않는다. 메시지를 그대로 보여 주고, 사용자가 그 폴더를 확인하고 지우게 한다.
- **결과 확인:** 턴 종료와 승인 직전에 `ga`가 기준 이후 바뀐 파일을 본다. 기준은 단계 시작(초기화, 승인, `GA 되돌리기`, `GA 새라운드`)과 `GA 재개`, `GA 상태승인` 때의 파일 상태다. 허용 밖 변경이 있으면 턴 종료가 한 번 막히고 목록이 나온다. 목록이 빌 때까지 승인은 막힌다. 미리 보려면 `ga effect check`.
  - 허용: `inputs`, `iterating`, `design-review`는 `docs/architecture/` 아래(상태 폴더 제외)만. 기존 코드의 `skeleton`은 여기에 대응표의 `new`·`changed` 경로를 더한다. 새 프로젝트의 `skeleton`과 `implement`는 제한 없음(상태 폴더, 플러그인 폴더 제외). `.claude` 설정 파일은 어느 단계에서도 대상이 아니다.
  - 누가 바꿨는지는 알 수 없다. 목록을 그대로 보여 주고, 되돌릴지 `GA 상태승인`으로 받아들일지 묻는다. 답을 듣기 전에는 되돌리지 않는다. 같은 목록으로 턴 종료를 다시 막지는 않는다. 일시정지 중의 변경은 `GA 재개` 때 받아들여지고, 그 목록이 재개 메시지에 나온다(사용자도 본다).
  - 파일 내용을 직접 비교한다. git은 파일 목록에만 쓰고 git 색인과 `.git/info/exclude`는 믿지 않는다. `.gitignore`와 전역 git 제외 목록(`core.excludesFile`, 기본 `~/.config/git/ignore`)은 따르지만, 새로 만들거나 고친 `.gitignore`는 그 자체가 변경이다.
  - "결과 확인 불가"(git 없음·오류, 기준 커밋 사라짐, 저장소 위치나 `.git` 구조가 바뀌었거나 믿을 수 없음, 이름에 줄바꿈이 있는 파일)면 이유를 보여 준다. 원인을 고친 뒤 사용자가 `GA 상태승인`을 입력하면 새 기준이 기록된다. 서브모듈 안의 설계는 늘 이러므로 사용자에게 알린다.
- **상태 지문:** `ga`는 상태 폴더를 쓸 때마다 지문을 프로젝트 밖에 기록한다. 상태 폴더가 `ga` 밖에서 바뀌면 사용자가 확인할 때까지 상태를 바꾸는 도구, 쓰기, 승인이 막힌다(일시정지 중에도). 턴 종료는 알리도록 한 번만 막힌다. 지문 기록이 없거나 읽을 수 없어도 승인이 막힌다(새로 기록하는 것은 `ga_init`과 `GA 상태승인`뿐). 내가 풀 수 없으니 알리고, 사용자가 바뀐 내용을 확인한 뒤 `GA 상태승인`을 입력하게 한다(상태 폴더와 프로젝트 파일의 지금 상태가 새 기준이 된다).

### 기록 방법

- 추가: `ga_add`에 `{"kind": 종류, "item": 객체}` → 새 ID. 규칙 위반이면 오류(종료 3)와 이유가 나오니 고쳐 다시 부른다. `id`, `kind`, `round`, `phase_added`, `status`, `resolution`과 드라이버가 아닌 항목의 `iteration`(현재 반복)은 `ga`가 채운다.
- 수정: `ga_update`에 `{"id": "DRV-2", "patch": 바꿀 최상위 필드만}`. 객체 필드(`scenario` 등)는 통째로 준다. `id`, `kind`, `status`, `resolution`, `resolution_history`, `round`, `phase_added`, `answer`, `deviation`은 못 바꾸고, 항목은 지울 수 없다.
- 해결된 항목(사용자 확인, 답, 근거 해결, 확인된 이탈)을 고치면 다시 `open`이 되고, 이전 해결과 답은 `resolution_history`에 남는다. 출력 안내대로 다시 확인이나 답을 받는다.
- 직접 근거로 가정·질문 해결: `ga_resolve`에 `{"id":"ASM-n","source_type":"code","ref":"src/a.ts:12"}`(타입 `code`, `literature`, `measurement`). 결정(이탈 포함)에는 못 쓴다. 검증 패널이 그 근거를 다시 확인하므로 보고서가 낡는다.
- architecture.md의 1절(목적)과 5절(반복별 설계)은 Write나 Edit로 쓴다. `<!-- ga:begin … -->`~`<!-- ga:end … -->` 사이는 `ga_render`가 덮어쓰므로 손대지 않고, 표시 줄도 지우거나 옮기지 않는다. 표시 짝이 맞지 않으면 `ga_render`가 거부하고(종료 3) `ga check`가 `E_MARKERS`를 낸다.
- 도구가 실패하면 결과가 오류로 표시되고 끝에 `(ga 종료 코드 N)`이 붙는다.

### 검증과 승인 절차 (모든 승인 지점에서 같다)

1. `ga_render`로 원장을 문서에 반영하고 `ga check`(셸)로 원장 전체를 검사해 오류를 고친다(예: 결정의 `drivers`에 원장에 없는 DRV ID). 형식 오류가 남으면 턴 종료가 막힌다.
2. `ga_verify`로 여러 모델의 검증 패널을 돌린다. 15분까지 걸리고, 2분이 지나면 Claude Code가 백그라운드로 돌리니 끝날 때까지 기다린다. 종료 5(일부 모델 실패)면 두 번까지 다시 실행하고, 그래도 실패하면 알린다. 종료 4(과금 점검 실패)나 2(설정·내부 오류)면 다시 실행하지 말고 `ga billing check claude`(셸) 출력이나 오류를 바로 알린다.
3. 지적(`jq .findings docs/architecture/.state/report.json`)을 하나씩 처리한다. 지적과 증거는 있는 그대로 보여 준다.
   - 맞으면 고친다(`ga_update`, `ga_resolve`, 문서 수정). 고친 지적도 그 보고서에 남으므로 다 고친 뒤 1로 돌아가 새 보고서를 받는다. 지적 번호는 보고서마다 새로 매겨진다.
   - 틀렸다고 보면 `ga_dispute`로 증거를 붙여 반박한다(예: `{"id":"FND-1","evidence":"지적은 DRV-2의 기준을 p95 > 2초로 읽었지만 원장의 measure는 \"p95 응답 시간 2초 이하\"다"}`). 지적과 반박을 보여 주고 `GA 판정 FND-n 반박인정` 또는 `GA 판정 FND-n 반박기각`을 요청한다. 반박이 기각되면 고치고 1로 돌아간다.
   - 지적을 넘기려고 `GA 기각`을 권하지 않는다. 기각(`GA 기각 FND-n 사유`)은 사용자가 스스로 정한다.
4. 열린 가정과 질문: 직접 근거를 찾았으면 `ga_resolve`로 해결하고, 다 해결한 뒤 1로 돌아간다. 아니면 하나씩 요청한다.
   - 가정: 내용, 간접 근거, 탐색 기록, 다른 가능한 가정을 보여 주고 `GA 확인 ASM-n`을 요청한다. 사용자가 틀렸다고 하면 그 말대로 `ga_update`로 고쳐 다시 요청한다.
   - 질문: `GA 답 Q-n 답변`을 요청한다. 답 때문에 원장이나 문서를 고쳤으면 1로 돌아간다. 확인과 답만으로는 보고서가 낡지 않는다.
5. `ga status --json`의 `open`·`asked`가 0, `report_fresh`·`panel_ok`가 true, `findings_unprocessed`가 0이고 `ga effect check`에 위반이 없으면 승인 줄 하나만 요청한다(예: `GA 승인 입력`). 뒤에 글자를 붙이면 거부된다.
6. `GA` 줄이 성공하면 그 턴의 컨텍스트에 `기록됨: …`과 `다음: …`이 들어온다. 실패하면 메시지 전체가 막히고 아무것도 바뀌지 않으며, 이유는 사용자 화면에만 보인다. 사용자에게 이유를 묻고 `ga status`로 확인한다.

승인에는 현재 단계·라운드·반복의 최신 검증 보고서, 허용 밖 변경 없음, 맞는 상태 지문이 필요하다. 승인 조건은 **현재 라운드의 항목만** 센다. 단, 해결되지 않은 가정과 질문은 모든 라운드에서 승인을 막는다. `ga status`의 `open`·`asked`도 같은 기준으로 센다.

## 2. `inputs` 단계 (ADD 1단계: 설계 입력)

"무엇을, 왜"만 다룬다. 기술, 프레임워크, 모듈 구조, 패턴을 고르거나 제안하지 않는다(`decision` 기록 불가). 사용자가 이미 정한 기술이나 구조는 `constraint`(출처는 사용자 발언)로 기록한다.

대화로 아래를 정리하고, 확인된 것마다 바로 `ga_add`로 기록한다. 한 번에 많이 묻지 않는다.

1. **설계 목적**(`driver_type: purpose`): 무엇을 왜 만드는지와 범위. 1개 이상. architecture.md 1절에도 쓴다.
2. **기능**(`functional`): 현재 기능은 `horizon: current`. 미래 기능은 사용자가 말한 로드맵만 `horizon: future` 드라이버로 둔다. 문헌상 흔한 확장은 `assumption`(`literature_norm`)으로 두고, 근거 없는 기능은 넣지 않는다.
3. **품질 속성 시나리오**(`quality`): `scenario`의 `stimulus`(환경 포함), `response`, `measure`. `measure`는 측정할 수 있어야 한다(예: p95 2초 이하, 월 중단 43분 이하, 결제 수단 추가 시 바뀌는 모듈 1개). "빠르게"는 시나리오가 아니니 수치를 묻는다.
4. **고려사항**(`concern`): 구조에 영향을 주는 관심사(예: 오류 처리와 로깅의 일관성, 배포 환경, 팀이 익숙한 언어).
5. **제약**(`constraint`): 사용자가 못 박은 기술, 표준, 일정, 비용.
6. **우선순위와 반복 계획**: 드라이버마다 `priority`(high, medium, low)를 사용자와 정한다. `high`에만 `iteration`을 1부터 빈 번호 없이 준다. 반복 1은 보통 시스템 전체 구조를 정한다. 반복 수는 필요한 만큼만 둔다.

드라이버 출처는 직접 근거다(대개 `"type":"user"`와 사용자 원문 `quote`). 간접 근거뿐이면 `assumption`이다.

**기존 코드 모드:** 모듈, 의존 관계, 진입점, 이미 있는 설계 결정, 빌드·테스트 방법을 읽는다. 코드로 확인한 것은 `fact`(출처 `code`, 실제로 있는 `경로:줄`)로, 코드만 보고 짐작한 의도(예: "이 계층 분리는 테스트를 위한 것으로 보인다")는 `assumption`(`code_convention`)으로 기록한다.

**질문:** `ga_add`(kind `question`) 후 `ga_ask`에 `{"id":"Q-n"}`. 질문, 탐색 기록, 답에 따라 바뀌는 것을 보여 주고 `GA 답 Q-n 답변`을 요청한다. 답에서 나온 드라이버나 제약은 `ga_add`로 기록한다(출처 `user`, `quote`는 사용자 원문).

**`ga_add` 예시** (값은 예시다. `purpose`·`functional` 드라이버는 `scenario`만 빠진다.)

```json
{"kind":"driver","item":{"driver_type":"quality","statement":"성능: 판매 개시 직후 좌석 조회","horizon":"current","priority":"high","iteration":1,
 "scenario":{"stimulus":"정상 운영 중, 판매 개시 후 1분간 5,000명이 좌석 조회","response":"남은 좌석 목록","measure":"p95 응답 시간 2초 이하"},
 "source":{"type":"user","ref":"대화","quote":"오픈 직후 5천 명이 몰려도 2초 안에 좌석이 떠야 해요"}}}
{"kind":"constraint","item":{"statement":"DB는 PostgreSQL","source":{"type":"user","ref":"대화","quote":"DB는 회사 표준인 PostgreSQL이어야 해요"}}}
{"kind":"fact","item":{"statement":"HTTP 라우트는 한 곳에서 등록한다","source":{"type":"code","ref":"src/server.ts:12"}}}
{"kind":"assumption","item":{"statement":"좌석 조회는 판매 개시 후 10분 안에 대부분 몰린다",
 "indirect_evidence":[{"type":"goal_inference","ref":"DRV-2의 사용자 발언 '오픈 직후 5천 명이 몰려도'"}],
 "search_log":{"code":"해당 없음: 새 프로젝트","docs":"README.md, CLAUDE.md, docs/, 메모리 디렉터리: 언급 없음",
   "conversation":"오픈 직후 집중만 말함","web":"해당 없음: 이 서비스 고유의 패턴이라 문헌으로 못 정함"},
 "alternatives":[{"assumption":"하루 내내 고르게 분산된다","reason":"사용자가 오픈 직후 집중을 말했다"}]}}
{"kind":"question","item":{"question":"결제 전 좌석은 몇 분 동안 잡아 두나요?",
 "search_log":{"code":"해당 없음: 새 프로젝트","docs":"README.md, CLAUDE.md, docs/, 메모리 디렉터리: 정책 없음",
   "conversation":"언급 없음","web":"'ticket seat hold timeout' 검색: 서비스마다 달라 근거 없음"},
 "impact":"좌석 점유 요구사항과 동시 예매 시나리오의 측정 기준"}}
```

1절 절차 후 `GA 승인 입력`을 요청한다. 승인 조건(현재 라운드): 결정 0개, `purpose` 드라이버 1개 이상, `high` 드라이버 1개 이상이고 반복 번호가 1..N으로 이어짐. 승인되면 반복 1이 시작된다.

## 3. `iterating` 단계 (ADD 2~7단계, 반복마다)

`ga status`로 현재 반복 n을 확인한다. 이번 드라이버는 architecture.md 4절(현재 라운드의 반복 계획)에서 반복 n의 `high` 드라이버다. 5절에 `### 반복 n: 목표` 소절(라운드 2부터 `### 라운드 r 반복 n: 목표`)을 만들고 순서대로 채운다.

1. **반복 목표**(ADD 2): 다룰 드라이버 ID와 목표 한 줄.
2. **세분화할 요소**(ADD 3): 첫 반복은 시스템 전체, 이후는 앞 반복의 요소 중 이번 드라이버와 관련된 것.
3. **설계 개념 비교와 결정**(ADD 4): 요소마다 실제로 성립하는 후보(참조 아키텍처, 패턴, 전술, 프레임워크, 외부 컴포넌트)를 근거와 함께 **두 개 이상** 놓고, 연결된 드라이버의 시나리오와 측정 기준에 비추어 비교한다. 고른 것을 `ga_add`(kind `decision`)로 기록한다.
   - `choice`: 고른 것. `rationale`: 출처 1개 이상. `drivers`: 다루는 DRV ID 1개 이상. `alternatives`: 버린 후보와 이유(어떤 드라이버의 어떤 시나리오를 왜 못 맞추는지). 허수아비 대안은 검증에서 반려된다.
   - 사용자 제약 때문에 대안이 없으면 `[{"none":"user_constraint","source":{"type":"user","ref":"대화","quote":"사용자 원문"}}]`.
   - 추가한 뒤 `ga check`를 실행한다. 없는 드라이버를 가리키는지는 원장 전체 검사에서만 잡힌다.
4. **요소, 책임, 인터페이스**(ADD 5): 요소마다 책임과 공개 인터페이스(연산, 입력과 출력, 오류)를 표로 쓴다.
5. **구조도**(ADD 6): 같은 소절에 mermaid 코드 블록으로 그린다. 요소 이름은 4의 표와 같게 쓴다.
6. **드라이버 분석**(ADD 7): 이번 드라이버와 영향받은 드라이버마다 `충족`, `부분`, `미충족`과 근거(DEC-n, 측정 기준과의 관계)를 표로 쓴다. 부분·미충족이면 이유와 다룰 반복을 적는다.
7. **검증과 승인**: 1절 절차 후 `GA 승인 반복`을 요청한다. 승인 조건(현재 라운드): 이번 반복의 결정 1개 이상, 이번 반복의 `high` 드라이버가 모두 이번 반복 결정의 `drivers`에 있음. 마지막 반복이 승인되면 `design-review`로 간다.

```json
{"kind":"decision","item":{"element":"좌석 조회 경로","choice":"캐시 어사이드(cache-aside) 읽기 캐시",
 "rationale":[{"type":"literature","ref":"https://learn.microsoft.com/en-us/azure/architecture/patterns/cache-aside"},{"type":"user","ref":"대화","quote":"오픈 직후 5천 명이 몰려도 2초 안에 좌석이 떠야 해요"}],
 "alternatives":[{"option":"DB 직접 조회와 인덱스","reason":"DRV-2 시나리오(1분에 5,000명 조회)의 요청이 모두 DB로 가 p95 2초를 맞추기 어렵다"},
                 {"option":"좌석 현황 푸시","reason":"DRV-2는 조회 응답 시간을 요구하는데, 푸시는 좌석이 바뀔 때마다 5,000명에게 보내 송신량이 더 크다"}],
 "drivers":["DRV-2"]}}
```

새로 생긴 가정과 질문도 0절 규칙대로 기록한다. 새로 알게 된 드라이버는 `ga_add`(kind `driver`)로 추가하고, `high`면 현재나 남은 반복 번호를 준다.

## 4. `design-review` 단계

1. architecture.md 전체를 다시 읽고 확인한다: 결정끼리 모순이 없는지, 현재 라운드의 모든 `high` 드라이버가 결정에 연결됐는지, 드라이버 분석이 최신인지, 부분·미충족 드라이버를 어떻게 처리할지.
2. 구조도, 핵심 결정, 부분·미충족 드라이버를 요약해 보여 주고 사용자 검토를 받는다.
3. 반복이 더 필요하면 `GA 되돌리기`를 요청한다(반복이 하나 추가되고 `iterating`으로 돌아간다). 새 반복에서 다룰 드라이버는 `ga_update`로 `"priority":"high"`와 새 반복 번호(`ga status`의 현재 반복)로 바꾸고 3절을 따른다.
4. 1절 절차 후 `GA 승인 설계`를 요청한다. 승인 조건: 현재 라운드의 모든 `high` 드라이버가 어떤 결정에 연결됨.

## 5. `skeleton` 단계

구조만 만들고 동작은 만들지 않는다.

1. **대응표 먼저:** `ga_add`(kind `mapping`)로 설계 요소(`element`, 5절의 이름)와 위치(`path`, 루트 기준 상대 경로)를 잇고 `change`(`new`, `changed`, `kept`)를 쓴다. 예: `{"kind":"mapping","item":{"element":"좌석 조회 서비스","path":"src/seat/query.ts","change":"new"}}`
   - 새 프로젝트: 요소마다 코드 위치(파일이나 디렉터리)를 기록한다.
   - 기존 코드: 만들거나 바꿀 **파일마다** 기록한다. `new`·`changed` 파일만 쓸 수 있고 경로가 정확히 같아야 한다(셸로 바꾼 파일도 1절 결과 확인에서 같다). 바꾸지 않는 관련 요소는 `kept`로 둔다.
2. **뼈대:** 폴더, 모듈, 인터페이스와 타입, 빈 함수를 만든다. 함수 본문에는 미구현 표시만 둔다(예: `throw new Error("not implemented")`, `raise NotImplementedError`). 로직은 쓰지 않는다.
3. **기존 코드 모드**
   - 새로 생기거나 바뀌는 모듈과 인터페이스만 만든다. 기존 코드를 옮기거나 이름을 바꾸면 따로 결정(`ga_add`, kind `decision`)으로 기록한다.
   - 기존 빌드와 테스트가 계속 통과해야 한다. 빌드·테스트 명령을 찾아(예: `package.json`의 scripts, `Makefile`) 찾은 위치와 함께 제안하고, `GA 테스트명령 명령`으로 지정해 달라고 한다(예: `GA 테스트명령 npm test`). `ga_verify`가 이 명령을 운영체제 격리 안에서 사용자의 `PATH`와 실행마다 새로 만든 임시 폴더(`TMPDIR`)로 돌려 보고서에 넣는다. 실패하면 뼈대를 고치고 다시 검증한다.
   - 빌드는 0절의 보호 대상(상태 폴더, 상태 지문 저장 위치, `.claude` 설정 파일, 플러그인 폴더)만 쓸 수 없고, 나머지(홈 폴더의 빌드 캐시 포함)는 평소처럼 쓴다.
   - 격리 실행 도구(macOS `sandbox-exec`, Linux `bwrap`)가 없으면 빌드 확인을 건너뛰고 `GA 승인 뼈대`가 막히니 사용자에게 알린다.
4. 1절 절차 후 `GA 승인 뼈대`를 요청한다. 기존 코드 모드의 승인 조건(현재 라운드): 대응표 1개 이상, 빌드 확인 통과(`ga status --json`의 `build_ok`가 true).

## 6. `implement` 단계

프로젝트 파일을 쓸 수 있다(0절의 보호는 그대로). 설계 문서와 대응표대로 세부 로직을 구현한다.

- 대응표에 없는 새 요소나 위치는 쓰기 전에 `ga_add`(kind `mapping`)로 기록한다.
- **설계에서 벗어날 때:** 그 코드를 쓰기 전에 결정을 `"deviation": true`와 함께 `ga_add`로 기록한다(근거, 버린 대안, 드라이버 포함). architecture.md를 고치고 `ga_render`를 부른다. 사용자가 확인하기 전까지 문서에 "미승인 이탈"로 보이니, 내용과 이유를 보여 주고 `GA 확인 DEC-n`을 요청한다. 이탈 승인은 이것으로만 기록된다(이탈 결정에 `ga_resolve`는 거부된다).
- **새 기능이 들어오면:** 미승인 이탈과 해결되지 않은 가정·질문을 모두 먼저 해결한 뒤 `GA 새라운드`를 요청한다(남아 있으면 거부된다). 같은 architecture.md에서 라운드 번호가 1 올라 `inputs`부터 다시 시작한다. 새 라운드는 자기 `purpose` 드라이버와 1부터 번호를 매긴 자기 `high` 드라이버가 필요하다. 이전 라운드의 드라이버, 결정, 대응표는 승인 조건에 세지 않는다.

## 7. 명령 표

**상태를 바꾸는 MCP 도구** (서버 `ga`. 모두 선택 인자 `root`를 받지만 보통 주지 않는다)

| 도구 | 인자 | 하는 일 |
|---|---|---|
| `mcp__plugin_better-agents_ga__ga_init` | `mode`(선택) | 설계 시작 |
| `mcp__plugin_better-agents_ga__ga_add` | `kind`, `item` | 항목 추가 |
| `mcp__plugin_better-agents_ga__ga_update` | `id`, `patch` | 항목 수정 |
| `mcp__plugin_better-agents_ga__ga_ask` | `id` | 질문을 물은 상태(asked)로 |
| `mcp__plugin_better-agents_ga__ga_resolve` | `id`, `source_type`, `ref` | 직접 근거로 가정·질문 해결 |
| `mcp__plugin_better-agents_ga__ga_render` | 없음 | 원장을 architecture.md의 ga 블록에 반영 |
| `mcp__plugin_better-agents_ga__ga_verify` | 없음 | 검증 패널 실행, 보고서 작성 |
| `mcp__plugin_better-agents_ga__ga_dispute` | `id`, `evidence` | 지적에 증거를 붙여 반박 |
| `mcp__plugin_better-agents_ga__ga_enforce` | 없음 | 격리 설정 다시 설치 |

같은 서버의 `ga_status`, `ga_check`, `ga_rule`은 아래 셸 명령과 같다.

**셸 읽기 명령** (Bash. 상태를 바꾸지 않는다)

| 명령 | 하는 일 |
|---|---|
| `ga status [--json]` | 단계, 모드, 라운드, 반복, 미해결 수(모든 라운드의 가정·질문 포함), 보고서 상태(`report_fresh`, `panel_ok`, `findings_unprocessed`, `build_ok`) |
| `ga check [--json] [--item KIND]` | 원장 형식 검사. `--item`이면 stdin의 항목 하나만 |
| `ga effect check` | 단계 시작 뒤 바뀐 파일과 그중 허용 밖인 것(`violations`). 위반이 있으면 종료 1 |
| `ga billing check claude` | 검증 실행기의 구독 과금 점검 |
| `ga rule` / `ga version` | 짧은 근거 규칙 / 버전 |

**사용자만 입력하는 `GA` 줄** (메시지에서 줄 맨 앞. 에이전트는 요청만 한다)

| 줄 | 하는 일 |
|---|---|
| `GA 승인 입력`, `GA 승인 반복`, `GA 승인 설계`, `GA 승인 뼈대` | 단계 승인. 뒤에 글자를 붙이면 거부 |
| `GA 확인 ASM-n` (메모 선택) | 가정 확인. 이탈 결정도 `GA 확인 DEC-n` |
| `GA 답 Q-n 답변` | 질문에 답 |
| `GA 기각 FND-n 사유` (사유 선택) | 사용자가 검증 지적을 기각 |
| `GA 판정 FND-n 반박인정`, `GA 판정 FND-n 반박기각` | 에이전트의 반박을 판정 |
| `GA 일시정지`, `GA 재개` | 단계 규칙과 셸 격리 확인을 끄고 켬(`.state/PAUSED` 표시 파일. `state.json`이 깨져도 동작. 재개는 1절 "결과 확인") |
| `GA 되돌리기` | `design-review`나 `skeleton`에서 반복 하나를 추가해 `iterating`으로 |
| `GA 새라운드` | `implement`에서 새 라운드의 `inputs`로 |
| `GA 테스트명령 명령` | 빌드·테스트 명령 지정(기존 코드 모드 뼈대 검증용) |
| `GA 상태승인` | 지금 상태를 모두 받아들임: 상태 지문 재기록, 지금 파일 상태를 새 기준으로 |
| `GA 격리해제` | `ga`가 넣은 OS 격리 설정(sandbox 키, denyWrite 항목, git 제외 줄)만 지움. 사용자가 바꾼 값은 남김. 결과는 사용자도 봄. 설계 중이면 그 뒤 셸 명령이 막히므로 `GA 일시정지`와 함께 씀 |

한 메시지의 `GA` 줄들은 모두 적용되거나 하나도 적용되지 않는다.
