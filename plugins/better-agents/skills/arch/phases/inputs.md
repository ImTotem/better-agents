# `inputs` 단계 (ADD 1단계: 설계 입력)

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

SKILL.md 1절의 검증과 승인 절차 후 `GA 승인 입력`을 요청한다. 승인 조건(현재 라운드): 결정 0개, `purpose` 드라이버 1개 이상, `high` 드라이버 1개 이상이고 반복 번호가 1..N으로 이어짐. 승인되면 반복 1이 시작된다.
