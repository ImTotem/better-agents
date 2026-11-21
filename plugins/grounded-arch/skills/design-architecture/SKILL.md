---
name: design-architecture
description: 새 프로젝트나 기존 코드베이스의 아키텍처를 ADD 3.0 절차로 위에서 아래로 설계한다. 사용자가 /design-architecture로 직접 호출할 때만 쓴다. 요구사항 정리, 반복 설계, 설계 검토, 코드 뼈대, 구현까지 모든 판단에 근거를 붙이고 ga CLI와 게이트로 단계를 강제한다.
disable-model-invocation: true
---

# 아키텍처 설계 (ADD 3.0 + 근거 규칙)

코드를 쓰기 전에 아키텍처를 위에서 아래로 설계한다. 단계는 `inputs` → `iterating`(반복 1..N) → `design-review` → `skeleton` → `implement` 순서다. 단계와 원장(드라이버, 제약, 사실, 결정, 가정, 질문, 대응표)은 `ga` CLI가 관리하고, 훅 게이트가 규칙을 강제한다.

- 사람이 읽는 문서: `docs/architecture/architecture.md` 하나
- 기계가 읽는 상태: `docs/architecture/.state/` (`ga`만 쓴다)

## 0. 원칙

**근거 3등급** (전문은 `grounding` 스킬)

| 등급 | 조건 | 처리 |
|---|---|---|
| 확정 | 직접 근거: 사용자 발언, 대상 코드·환경에서 확인한 사실(`경로:줄`, 명령 출력), 검증된 문헌(URL·서지), 측정 결과 | 완료 |
| 근거 있는 가정 | 간접 근거만: 기존 코드 관례, 프레임워크 기본값, 문헌상 일반적인 경우, 사용자 목표에서의 추론 | 미완료. `assumption`으로 올리고, 사용자 확인이나 직접 근거로 해결한다 |
| 근거 없는 가정 | 근거 없음 | 금지. `question`으로 묻는다 |

- **먼저 찾는다.** 가정이나 질문을 쓰기 전에 실제로 탐색한다: 대상 코드, 문서(README, CLAUDE.md, `docs/`, 메모리 디렉터리), 현재 대화, 웹(일반 지식에 관한 판단일 때). 직접 근거를 찾으면 그것은 확정이다. 가정으로 돌리지 않는다.
- `search_log`의 `code`, `docs`, `conversation`, `web` 네 칸에 어디서 무엇을 찾았고 결과가 무엇인지 쓴다. 해당하지 않는 칸은 `해당 없음: 이유`로 쓴다.
- 원장에 올리는 것: 아키텍처상 의미 있는 결정, 모든 가정, 모든 질문. 그 밖의 판단은 응답 안에서 근거 종류를 표시한다.
- 미래 기능: 사용자가 말한 로드맵은 드라이버(확정)로, 문헌상 흔한 확장은 `assumption`으로 올린다. 근거 없는 기능은 설계에 넣지 않는다.

**금지**

- `skeleton` 단계 전에는 `docs/architecture/` 밖에 코드나 파일을 쓰지 않는다.
- `docs/architecture/.state/` 아래 파일을 직접 쓰거나 고치거나 지우지 않는다. 읽기는 된다. 상태는 `ga` 명령으로만 바꾼다.
- `ga user-command`, `ga gate`, 훅 스크립트(`adapters/claude-code/hook.sh`)를 부르지 않는다.
- 사용자의 확인, 답, 승인, 기각, 판정을 대신 기록하지 않는다. "사용자가 확인했다"고 쓰지도 않는다. 이것들은 사용자가 `GA`로 시작하는 줄을 직접 입력해야만 기록된다. 사용자가 대화에서 "네, 맞아요"라고만 하면 기록되지 않는다. 이때는 해당 줄을 입력해 달라고 요청한다.
- 승인을 몰아서 받지 않는다. 가정과 질문은 항목마다 근거를 보여 주고, 사용자가 ID별로 답하게 한다. 승인 요청은 한 번에 하나만 하고, 남은 항목이 모두 해결된 뒤에 한다.
- `claude --bare`를 쓰지 않는다. API 키(`ANTHROPIC_API_KEY` 등)를 설정하지 않는다. 모든 모델 호출은 구독으로만 한다.
- superpowers의 brainstorming 같은 다른 기획 스킬을 부르지 않는다. 요구사항 정리는 이 스킬의 `inputs` 단계가 맡는다.
- `ga`의 거부, 게이트의 차단, 승인 거부 메시지에는 빠진 것이 나열된다. 그것을 채운다. 다른 경로로 우회하지 않는다. 설계와 관계없는 작은 수정이 필요하면 사용자에게 `GA 일시정지`를 요청하고, 끝나면 `GA 재개`를 요청한다.

## 1. 시작

1. 프로젝트 루트에서 `ga status`를 실행한다. 모든 `ga` 명령은 프로젝트 루트나 그 아래에서 실행한다.
   - "초기화된 프로젝트가 없습니다"(종료 2)가 나오면 `ga init`을 실행한다. 출력 `초기화: mode=… (근거: …)`의 모드와 근거를 사용자에게 그대로 보고한다. `greenfield`는 새 프로젝트, `brownfield`는 기존 코드 모드다.
   - 사용자가 모드가 틀렸다고 하면, `docs/architecture/.state/`를 사용자가 직접 지워 달라고 요청한다. 그 뒤 `ga init --mode greenfield` 또는 `ga init --mode brownfield`로 다시 시작한다.
   - 이미 초기화되어 있으면 `docs/architecture/architecture.md`를 읽어 진행 상황을 파악하고, 출력된 단계부터 이어 간다. `일시정지: true`면 먼저 사용자에게 `GA 재개`를 요청한다.
2. `ga`는 플러그인 `bin/`에 있어서 Bash에서 그냥 `ga`로 실행된다. `command -v ga`가 실패하면 `"${CLAUDE_PLUGIN_ROOT}/bin/ga"`를 대신 쓴다.

### 기록 방법

- 항목 추가: `ga add <kind> <<'EOF'` 다음 줄부터 JSON 객체 하나, 마지막 줄에 `EOF`. 출력은 새 ID(`DRV-3` 등)다.
- JSON을 파일로 만들지 않는다. heredoc으로 넘긴다.
- `ga add`는 형식 검사를 통과해야만 기록한다. 거부되면(종료 3) stderr의 이유대로 고쳐 다시 실행한다.
- `id`, `kind`, `round`, `phase_added`, `status`, `resolution`은 `ga`가 채운다. 드라이버가 아닌 항목의 `iteration`도 `ga`가 현재 반복으로 채운다.
- 고칠 때: `ga update ID <<'EOF'` 다음에 바꿀 필드만 담은 JSON을 준다. 최상위 필드 단위로 덮어쓴다(`scenario` 같은 객체는 통째로 다시 준다). `id`, `kind`, `status`, `resolution`, `round`, `phase_added`, `answer`, `deviation`은 바꿀 수 없다. 항목은 지울 수 없으므로 틀린 항목은 고친다.
- 직접 근거를 찾아 가정이나 질문을 해결할 때: `ga resolve ASM-n --source-type code --ref src/a.ts:12`. `--source-type`은 `code`, `literature`, `measurement` 중 하나다. 사용자 확인은 이 명령으로 기록할 수 없다.
- architecture.md의 1절(설계 목적)과 5절(반복별 설계)은 직접 쓴다. `<!-- ga:begin … -->`와 `<!-- ga:end … -->` 사이는 `ga render`가 덮어쓰므로 손대지 않는다.

### 검증과 승인 절차 (모든 승인 지점에서 같다)

1. `ga render`로 원장을 architecture.md에 반영한다.
2. `ga check`로 원장 전체를 검사한다. 오류가 나오면 `ga update`로 고친다(예: 결정의 `drivers`에 원장에 없는 DRV ID가 들어 있음). 턴을 끝낼 때 형식 오류가 남아 있으면 종료가 막힌다.
3. `ga verify`로 여러 모델의 검증 패널을 돌린다. 패널은 가정, 결정, 드라이버 연결, 입력 단계에 섞인 기술 선택을 검사하고 보고서를 쓴다. 수 분에서 수십 분 걸리므로 Bash 도구의 `run_in_background`로 실행하고 끝날 때까지 기다린다.
   - 종료 4: 과금 점검 실패다. 우회하지 말고 `ga billing check claude`의 출력을 사용자에게 보여 준다.
   - 종료 5: 일부 모델이 실패했다. 다시 실행한다.
4. 지적은 `docs/architecture/.state/report.json`의 `findings`에서 읽는다(`jq .findings docs/architecture/.state/report.json`). 지적마다 아래 중 하나로 처리한다.
   - **맞다:** 고친다(`ga update`, `ga resolve`, 문서 수정). 고친 지적도 그 보고서에는 처리되지 않은 채 남는다. 고칠 것을 모두 고친 뒤 1로 돌아가 새 보고서를 받는다. 지적 번호는 보고서마다 1부터 다시 매겨진다.
   - **틀렸다:** `ga dispute FND-n --evidence "증거(경로:줄, URL, 탐색 결과)"`를 실행한다. 그다음 사용자에게 지적과 반박을 보여 주고 판정을 요청한다. 사용자는 `GA 판정 FND-n 반박인정` 또는 `GA 판정 FND-n 반박기각`을 입력한다. 반박이 기각되면 고치고 1로 돌아간다.
   - 사용자가 지적을 받아들이지 않기로 하면 `GA 기각 FND-n 사유`를 입력할 수 있다. 이 선택은 사용자가 한다.
5. 열린 가정과 질문을 해결한다. 직접 근거를 찾았으면 `ga resolve`로 해결한다. 아니면 사용자에게 요청한다.
   - 가정: 내용, 간접 근거, 탐색 기록, 다른 가능한 가정을 보여 주고 `GA 확인 ASM-n` 입력을 요청한다. 사용자가 틀렸다고 하면 그 말대로 `ga update`로 고친 뒤 다시 확인을 요청한다.
   - 질문: `GA 답 Q-n 답변` 입력을 요청한다.
   - 사용자 확인과 답만으로는 보고서가 낡지 않는다. 답 때문에 원장이나 문서를 고쳤다면 1로 돌아간다.
6. `ga status --json`에서 다음을 확인한다: `open`과 `asked`가 0, `report_fresh`와 `panel_ok`가 true, `findings_unprocessed`가 0. 모두 맞으면 사용자에게 승인 줄 하나만 요청한다(예: `GA 승인 입력`). 승인 줄 뒤에 다른 글자를 붙이면 거부된다고 알려 준다.
7. 사용자의 `GA` 줄이 성공하면, 그 턴의 컨텍스트에 `기록됨: …`과 `다음: …`이 들어온다. 실패하면 그 메시지 전체가 막히고 아무것도 바뀌지 않는다. 이유는 사용자 화면에만 보인다. 사용자에게 그 이유를 알려 달라고 하고, `ga status`로 상태를 확인한다.

승인은 검증 보고서가 현재 단계, 라운드, 반복의 것이고 최신일 때만 된다. 단계가 바뀌면 그 단계에서 `ga verify`를 다시 실행한다.

## 2. `inputs` 단계 (ADD 1단계: 설계 입력)

"무엇을, 왜"만 다룬다. "어떻게"는 다루지 않는다.

- 기술, 프레임워크, 모듈 구조, 패턴을 고르거나 제안하지 않는다.
- 사용자가 이미 정한 기술이나 구조는 `constraint`로 기록한다. 출처는 사용자 발언이다.
- 이 단계에서는 `decision`을 기록할 수 없다(`ga add`가 거부한다). `docs/architecture/` 밖에도 쓸 수 없다.

대화로 아래를 정리하면서, 확인된 것마다 바로 `ga add`로 기록한다. 한 번에 많이 묻지 않는다.

1. **설계 목적**(`driver_type: purpose`): 무엇을 왜 만드는지와 범위. 1개 이상 있어야 한다. architecture.md 1절에도 짧게 쓴다.
2. **기능**(`functional`): 현재 기능은 `horizon: current`로 기록한다. 미래 기능은 등급에 따른다.
   - 사용자가 말한 로드맵: `horizon: future` 드라이버
   - 문헌상 흔한 확장: `assumption`(`literature_norm`)
   - 근거 없는 기능: 넣지 않는다
3. **품질 속성 시나리오**(`quality`): `scenario`의 `stimulus`(환경 포함), `response`, `measure`를 채운다. `measure`는 측정할 수 있어야 한다(예: p95 응답 2초 이하, 월 중단 43분 이하, 새 결제 수단을 붙일 때 바뀌는 모듈 1개). "빠르게", "유지보수 쉽게"는 시나리오가 아니다. 수치를 사용자에게 묻는다.
4. **고려사항**(`concern`): 구조에 영향을 주는 관심사. 예: 오류 처리와 로깅의 일관성, 배포 환경, 팀이 익숙한 언어.
5. **제약**(`constraint`): 사용자가 못 박은 기술, 표준, 일정, 비용.
6. **우선순위와 반복 계획**: 드라이버마다 `priority`(high, medium, low)를 사용자와 정한다.
   - `high` 드라이버에만 `iteration`을 준다. 번호는 1부터 빠짐없이 이어져야 한다.
   - 반복 1은 보통 시스템 전체 구조를 정한다. 반복 수는 꼭 필요한 만큼만 둔다.
   - `medium`과 `low` 드라이버에는 `iteration`을 넣지 않는다.

드라이버의 출처는 직접 근거여야 한다. 대개 `"type":"user"`와 사용자 원문 `quote`를 쓴다. 간접 근거뿐이면 드라이버가 아니라 `assumption`이다.

**기존 코드 모드(brownfield)에서 더 할 일:** 현재 구조를 읽는다. 모듈, 의존 관계, 진입점, 코드에 이미 들어 있는 설계 결정, 빌드·테스트 방법을 본다.

- 코드로 확인한 것은 `fact`로 기록한다. 출처는 `code`이고 `ref`는 실제로 있는 `경로:줄`이어야 한다.
- 코드만 보고 짐작한 의도는 `assumption`(`code_convention`)으로 기록한다. 예: "이 계층 분리는 테스트를 위한 것으로 보인다."

**질문:** `ga add question`으로 기록하고, 출력된 ID로 `ga ask Q-n`을 실행한다. 그다음 사용자에게 질문, 탐색 기록, 답에 따라 바뀌는 것을 보여 주고 `GA 답 Q-n 답변` 형식으로 답해 달라고 한다. 답을 받으면 답에서 나온 드라이버나 제약을 `ga add`로 기록한다(출처는 `user`, `quote`는 사용자 원문).

**예시** (값은 예시다. 실제 대화와 탐색 결과로 채운다. `purpose`와 `functional` 드라이버는 `scenario` 없이 같은 모양이다.)

```bash
ga add driver <<'EOF'
{"driver_type":"quality","statement":"성능: 판매 개시 직후 좌석 조회","horizon":"current","priority":"high","iteration":1,
 "scenario":{"stimulus":"정상 운영 중 판매 개시 후 1분 동안 사용자 5,000명이 좌석 현황을 조회한다","response":"남은 좌석 목록을 돌려준다","measure":"p95 응답 시간 2초 이하"},
 "source":{"type":"user","ref":"대화","quote":"오픈 직후 5천 명이 몰려도 2초 안에 좌석이 떠야 해요"}}
EOF
```

```bash
ga add constraint <<'EOF'
{"statement":"DB는 PostgreSQL을 쓴다","source":{"type":"user","ref":"대화","quote":"DB는 회사 표준인 PostgreSQL이어야 해요"}}
EOF
```

```bash
ga add fact <<'EOF'
{"statement":"HTTP 라우트는 src/server.ts 한 곳에서 모두 등록한다","source":{"type":"code","ref":"src/server.ts:12"}}
EOF
```

```bash
ga add assumption <<'EOF'
{"statement":"좌석 조회 트래픽은 판매 개시 후 10분 안에 대부분 몰린다",
 "indirect_evidence":[{"type":"goal_inference","ref":"DRV-2의 사용자 발언 '오픈 직후 5천 명이 몰려도'"}],
 "search_log":{"code":"해당 없음: 새 프로젝트라 코드가 없다",
   "docs":"README.md, CLAUDE.md, docs/, 메모리 디렉터리 확인: 트래픽 지속 시간 언급 없음",
   "conversation":"사용자는 오픈 직후 집중만 말했고 지속 시간은 말하지 않았다",
   "web":"해당 없음: 이 서비스 고유의 트래픽 패턴이라 일반 문헌으로 정할 수 없다"},
 "alternatives":[{"assumption":"하루 내내 고르게 분산된다","reason":"사용자가 오픈 직후 집중을 명시했다"}]}
EOF
```

```bash
ga add question <<'EOF'
{"question":"결제가 끝나지 않은 좌석은 몇 분 동안 다른 사람이 못 사게 잡아 둬야 하나요?",
 "search_log":{"code":"해당 없음: 새 프로젝트라 코드가 없다","docs":"README.md, docs/ 확인: 좌석 점유 정책 없음",
   "conversation":"점유 시간 언급 없음","web":"예매 서비스마다 5~15분으로 달라 일반 지식으로 정할 수 없다"},
 "impact":"좌석 점유 시간 요구사항과 동시 예매 시나리오의 측정 기준이 달라진다"}
EOF
```

마지막으로 1절의 검증과 승인 절차를 거쳐 사용자에게 `GA 승인 입력`을 요청한다. 승인 조건은 다음과 같다.

- 결정이 0개다.
- `purpose` 드라이버가 1개 이상이다.
- `high` 드라이버가 1개 이상이고, 반복 번호가 1..N으로 이어진다.

승인되면 `iterating` 단계의 반복 1이 시작된다.

## 3. `iterating` 단계 (ADD 2~7단계, 반복마다)

`ga status`로 현재 반복 번호 n을 확인한다. 이번 반복의 드라이버는 architecture.md 4절(반복 계획)에서 반복 n에 배정된 `high` 드라이버다. architecture.md 5절에 `### 반복 n: 목표` 소절을 만들고 아래 순서로 채운다.

1. **반복 목표**(ADD 2): 이번에 다룰 드라이버 ID와 목표 한 줄.
2. **세분화할 요소**(ADD 3): 첫 반복은 시스템 전체다. 이후 반복은 앞 반복에서 정의한 요소 중 이번 드라이버와 관련된 것이다.
3. **설계 개념 비교와 결정**(ADD 4): 요소마다 실제로 성립하는 후보를 **두 개 이상** 놓고 드라이버 기준으로 비교한다. 후보는 참조 아키텍처, 패턴, 전술, 프레임워크나 외부 컴포넌트다. 후보의 근거도 찾는다(문헌 URL, 코드 `경로:줄`, 사용자 발언, 측정). 고른 것을 `ga add decision`으로 기록한다.
   - `choice`: 고른 것
   - `rationale`: 출처 1개 이상
   - `alternatives`: 버린 후보와 버린 이유, 1개 이상. 허수아비 대안은 검증에서 반려된다.
   - `drivers`: 이 결정이 다루는 DRV ID, 1개 이상
   - 사용자 제약 때문에 대안이 없으면 `alternatives`를 `[{"none":"user_constraint","source":{"type":"user","ref":"대화","quote":"사용자 원문"}}]`로 쓴다.
   - 결정을 추가한 뒤 `ga check`를 실행한다. 없는 드라이버를 가리키는지는 원장 전체 검사에서만 잡힌다.
4. **요소, 책임, 인터페이스**(ADD 5): 고른 개념을 구체화한다. 요소마다 책임과 공개 인터페이스(연산, 입력과 출력, 오류)를 표로 쓴다.
5. **구조도**(ADD 6): 같은 소절에 mermaid 코드 블록으로 구조도를 그린다. 요소 이름은 4의 표와 같게 쓴다.
6. **드라이버 분석**(ADD 7): 이번 반복의 드라이버와 영향을 받은 다른 드라이버마다 `충족`, `부분`, `미충족`과 근거(DEC-n, 시나리오의 측정 기준과의 관계)를 표로 쓴다. 부분이나 미충족이면 이유와 어느 반복에서 다룰지 적는다.
7. **검증과 승인**: 1절 절차를 거쳐 `GA 승인 반복`을 요청한다. 승인 조건은 다음과 같다.
   - 이번 반복의 결정이 1개 이상이다.
   - 이번 반복의 `high` 드라이버가 모두 이번 반복 결정의 `drivers`에 들어 있다.
   - 마지막 반복이 승인되면 `design-review`로 넘어간다.

```bash
ga add decision <<'EOF'
{"element":"좌석 조회 경로","choice":"캐시 어사이드(cache-aside) 읽기 캐시를 둔다",
 "rationale":[{"type":"literature","ref":"https://learn.microsoft.com/en-us/azure/architecture/patterns/cache-aside"},
              {"type":"user","ref":"대화","quote":"오픈 직후 5천 명이 몰려도 2초 안에 좌석이 떠야 해요"}],
 "alternatives":[{"option":"DB 직접 조회와 인덱스","reason":"5,000명 동시 조회에서 p95 2초를 보장할 근거가 없다"},
                 {"option":"좌석 현황을 모든 클라이언트에 주기적으로 푸시","reason":"좌석이 바뀔 때마다 전체에 보내야 해 부하가 더 크다"}],
 "drivers":["DRV-2"]}
EOF
```

설계 중에 새로 생긴 가정과 질문도 0절 규칙대로 기록한다. 드라이버를 새로 알게 되면 `ga add driver`로 추가한다. 새 `high` 드라이버에는 현재 반복이나 남은 반복의 번호를 준다.

## 4. `design-review` 단계

1. architecture.md 전체를 다시 읽고 확인한다.
   - 결정끼리 모순이 없는가
   - 모든 `high` 드라이버가 어떤 결정에 연결되어 있는가
   - 반복별 드라이버 분석이 최신인가
   - 부분이나 미충족으로 남은 드라이버를 어떻게 처리하는가
2. 사용자에게 설계 요약을 보여 주고 검토를 받는다. 요약에는 구조도, 핵심 결정, 부분이나 미충족 드라이버를 넣는다.
3. 반복이 하나 더 필요하면 사용자에게 `GA 되돌리기`를 요청한다. 반복이 하나 추가되고 `iterating`으로 돌아간다. 그 뒤 새 반복에서 다룰 드라이버를 `ga update DRV-n`으로 `"priority":"high"`와 새 반복 번호(`ga status`의 현재 반복)로 바꾸고 3절을 따른다.
4. 1절 절차를 거쳐 `GA 승인 설계`를 요청한다. 승인 조건: 모든 `high` 드라이버가 어떤 결정에 연결되어 있다.

## 5. `skeleton` 단계

구조만 만들고 동작은 만들지 않는다.

1. **대응표를 먼저 쓴다.** `ga add mapping`으로 설계 요소와 코드 위치를 잇는다.
   - `element`: 설계 요소 이름(5절의 요소 이름과 같게)
   - `path`: 루트 기준 상대 경로
   - `change`: `new`(신규), `changed`(변경), `kept`(유지) 중 하나
   - 새 프로젝트: 설계 요소마다 그 코드 위치(파일이나 디렉터리)를 기록한다.
   - 기존 코드 모드: 만들거나 바꿀 **파일마다** 기록한다. `new`나 `changed`로 기록한 파일만 쓸 수 있고, 게이트는 파일 경로가 정확히 같은지 본다. 바꾸지 않는 관련 요소는 `kept`로 기록한다.
2. **뼈대를 만든다.** 폴더, 모듈, 인터페이스와 타입, 빈 함수를 만든다. 함수 본문에는 미구현 표시만 둔다(예: `throw new Error("not implemented")`, `raise NotImplementedError`). 로직은 쓰지 않는다.
3. **기존 코드 모드**
   - 새로 생기거나 바뀌는 모듈과 인터페이스만 만든다.
   - 기존 코드를 옮기거나 이름을 바꾸면 별도의 `ga add decision`으로 기록한다. 근거와 버린 대안을 함께 적는다.
   - 기존 빌드와 테스트가 계속 통과해야 한다. 프로젝트에서 빌드·테스트 명령을 찾는다(예: `package.json`의 scripts, `Makefile`). 찾은 위치와 함께 사용자에게 제안하고, `GA 테스트명령 명령` 형식으로 지정해 달라고 요청한다(예: `GA 테스트명령 npm test`).
   - 그 뒤 `ga verify`가 이 명령을 실행해 결과를 보고서에 넣는다. 실패하면 뼈대를 고치고 다시 검증한다.

```bash
ga add mapping <<'EOF'
{"element":"좌석 조회 서비스","path":"src/seat/query.ts","change":"new"}
EOF
```

4. 1절 절차를 거쳐 `GA 승인 뼈대`를 요청한다. 기존 코드 모드의 승인 조건은 다음과 같다.
   - 대응표가 1개 이상 있다.
   - 빌드 확인을 통과했다(`ga status --json`의 `build_ok`가 true).

## 6. `implement` 단계

게이트가 쓰기를 막지 않는다. 설계 문서와 대응표를 따라 세부 로직을 구현한다.

- 대응표에 없는 새 요소나 위치가 생기면 쓰기 전에 `ga add mapping`으로 기록한다.
- **설계에서 벗어날 때:** 그 코드를 쓰기 전에 `ga add decision`으로 기록하고 JSON에 `"deviation": true`를 넣는다. 근거, 버린 대안, 관련 드라이버를 함께 적는다. architecture.md의 해당 부분을 고치고 `ga render`를 실행한다.
  - 이 결정은 사용자가 확인하기 전까지 문서에 "미승인 이탈"로 보인다.
  - 사용자에게 이탈 내용과 이유를 보여 주고 `GA 확인 DEC-n` 입력을 요청한다.
- **새 기능이 들어오면:** 사용자에게 `GA 새라운드`를 요청한다. 같은 architecture.md에서 `inputs`부터 다시 시작하고, 라운드 번호가 1 오른다. 해결되지 않은 가정이나 질문이 남아 있으면 거부된다.

## 7. 명령 표

**에이전트가 실행하는 `ga` 명령** (Bash)

| 명령 | 하는 일 |
|---|---|
| `ga status [--json]` | 단계, 모드, 라운드, 반복, 미해결 수, 보고서 상태(`report_fresh`, `panel_ok`, `findings_unprocessed`, `build_ok`) |
| `ga init [--mode greenfield\|brownfield]` | 설계 시작. 모드를 정하고 근거를 출력한다 |
| `ga add KIND` (stdin JSON) | 항목 추가. KIND는 driver, constraint, fact, decision, assumption, question, mapping. 종료 3은 규칙 위반 |
| `ga update ID` (stdin JSON) | 항목 내용 수정 |
| `ga check [--json] [--item KIND]` | 원장 형식 검사. `--item`이면 stdin의 항목 하나만 검사 |
| `ga ask Q-n` | 질문을 사용자에게 물은 상태(asked)로 바꾼다 |
| `ga resolve ID --source-type T --ref REF` | 직접 근거(T는 code, literature, measurement)로 가정이나 질문을 해결 |
| `ga render` | 원장을 architecture.md의 ga 블록에 반영 |
| `ga verify` | 검증 패널 실행, 보고서 작성. 종료 4는 과금 점검 실패, 5는 일부 모델 실패 |
| `ga dispute FND-n --evidence TEXT` | 지적에 증거를 붙여 반박 |
| `ga billing check claude` | 검증 실행기의 구독 과금 점검 결과 |
| `ga rule` | 짧은 근거 규칙 출력 |
| `ga version` | 버전 |

**사용자만 입력하는 `GA` 줄** (메시지에서 줄 맨 앞에 쓴다. 에이전트는 요청만 한다)

| 줄 | 하는 일 |
|---|---|
| `GA 승인 입력`, `GA 승인 반복`, `GA 승인 설계`, `GA 승인 뼈대` | 단계 승인. 뒤에 다른 글자를 붙이면 거부 |
| `GA 확인 ASM-n` (메모 선택) | 가정 확인. 이탈 결정 `GA 확인 DEC-n`도 같다 |
| `GA 답 Q-n 답변` | 질문에 답 |
| `GA 기각 FND-n 사유` (사유 선택) | 검증 지적 기각 |
| `GA 판정 FND-n 반박인정`, `GA 판정 FND-n 반박기각` | 에이전트의 반박을 판정 |
| `GA 일시정지`, `GA 재개` | 모든 게이트를 끄고 켠다 |
| `GA 되돌리기` | `design-review`나 `skeleton`에서 반복 하나를 추가해 `iterating`으로 |
| `GA 새라운드` | `implement`에서 새 라운드의 `inputs`로 |
| `GA 테스트명령 명령` | 빌드·테스트 명령 지정(기존 코드 모드의 뼈대 검증용) |

한 메시지에 `GA` 줄이 여러 개 있으면 모두 적용되거나 하나도 적용되지 않는다.
