# 컨텍스트 줄이기 검토 (34c8a1c → 98dcb74)

대상: `skills/arch/SKILL.md`(→ `SKILL.md` + `phases/*.md`), `explain/guide.md`, `explain/reminder.md`, `core/rules/inject.txt`, `core/rules/grounding.md`, `skills/grounding/SKILL.md`, `core/verifier/prompt.md`, `core/mcp/server.sh`.
줄 번호는 바꾸기 전 `SKILL.md`(34c8a1c) 기준이다. 그대로 살아남은 지시는 적지 않았다.

## 줄이면서 빠지거나 약해진 지시

| 전 위치 | 후 위치 | 바뀐 것 | 정도 |
|---|---|---|---|
| 2절 `assumption`·`question` 예시의 `search_log` 값(128~140줄) | `phases/inputs.md` 30~35줄 | 0절 규칙은 "어디서 **무엇을** 찾았고 결과가 무엇인지"인데, 예시가 무엇을 찾았는지를 뺐다. "트래픽 지속 시간 언급 없음" → "언급 없음", "점유 시간 언급 없음" → "언급 없음", "좌석 점유 정책 없음" → "정책 없음". 모델은 예시를 따라 쓰므로 탐색 기록이 더 엉성해질 수 있다 | 약해짐 |
| 0절 금지 31줄 "셸에서 상태를 바꾸는 `ga` 명령을 실행하지 않는다" | 머리말 13줄(0절 밖) | 금지 문장이 "실패하며 대신 쓸 MCP 도구를 알려 준다"는 설명이 됐고, 다시 읽는 범위(0절, 1절) 밖으로 나갔다. 머리말의 "셸에서는 읽기 명령만 쓴다"와 압축 뒤에도 남는 위치, 실제 실패 동작이 받쳐 준다 | 사소함 |
| 1절 검증 3번 "지적마다 하나로 처리한다"(78줄) | 1절 3번 "하나씩 처리한다" | "지적마다 아래 처리 중 하나를 고른다"는 뜻이 "차례로 처리한다"로 바뀌었다. 아래 하위 줄(고치기, 반박)은 그대로다 | 사소함 |
| 3절 "후보의 근거도 찾는다"(152줄) | `phases/iterating.md` 7줄 "근거와 함께 두 개 이상" | 후보마다 근거를 실제로 찾으라는 말이 근거를 붙이라는 말로 바뀌었다. 0절의 "실제로 찾는다"는 가정과 질문에만 걸린다 | 사소함 |

나머지 줄인 부분(0절 근거 등급 목록 → 메시지마다 오는 [근거 규칙], 7절 도구 설명 → 1절, `GA` 줄 표의 괄호 설명, `guide.md` 3절의 `## 지금 상황`·`## 정해 주실 것` 규칙 → 2절 양식 틀과 `reminder.md`, `prompt.md`, `grounding.md`, `inject.txt`, `reminder.md`)은 뜻이 같거나 더 강해졌다.
`[근거 규칙]`은 `hook.sh`의 `user-prompt`에서 메시지마다 조건 없이 들어온다(GA 줄이 막힌 메시지만 빼고). `server.sh`는 `GA_MCP_INSTRUCTIONS`와 설명 문자열(`root` 인자 설명 포함)만 바뀌었다. `enum`, `required`, `minLength`, 실행 코드는 그대로다.
예시 JSON을 `ga check --item`으로 돌려 보면 전과 후의 결과가 같다(driver, constraint, assumption, question 통과. fact는 `src/server.ts`가 없어서, decision은 `ga`가 채우는 `iteration`이 없어서 실패하는데, 전에도 같았다).

## 나누면서 깨진 것

나누기 전에는 `/arch`를 부르면 `SKILL.md` 전체(2~6절 포함)가 들어왔다. 지금은 0~3절만 들어오고, 단계 파일은 지금 단계의 것 하나만 읽는다. 그래서 `/arch`를 `inputs`가 아닌 단계에서 새로 시작하면(예: 다음 날 이어서 설계할 때), 여러 단계에서 쓰는 기록 형식이 한 단계 파일에만 있어 들어오지 않는다.

| 지시 | 지금 있는 곳 | 필요한데 못 받는 단계 | 정도 |
|---|---|---|---|
| `assumption`·`question`·`driver`·`fact` 항목 모양과 예시. `indirect_evidence.type` 값(`goal_inference`, `literature_norm`, `code_convention`). 질문 절차(`ga_add` 다음 `ga_ask`, 질문·탐색 기록·답에 따라 바뀌는 것을 보여 주고 `GA 답` 요청). "드라이버 출처는 직접 근거, 간접 근거뿐이면 `assumption`". 코드로 확인한 것은 `fact`, 짐작한 의도는 `assumption`(`code_convention`) | `phases/inputs.md`만 | `iterating`(새 가정·질문·드라이버를 "0절 규칙대로" 기록하라고 함), `design-review`, `skeleton`, `implement` | 약해짐. 특히 `indirect_evidence.type`의 허용 값은 `SKILL.md`, MCP 스키마(`item`은 그냥 object), `check.jq` 오류 문구(105~106줄, 허용 값을 안 알려 줌) 어디에도 없어서 추측해야 한다 |
| `decision` 항목 모양(`element`, `choice`, `rationale`, `alternatives`의 `option`/`reason`, `drivers`), 대안 이유 쓰는 법(어떤 드라이버의 어떤 시나리오를 왜 못 맞추는지), 허수아비 대안 금지, `{"none":"user_constraint",…}`, 추가 뒤 `ga check` | `phases/iterating.md`만 | `skeleton`(기존 코드를 옮기거나 이름을 바꾸면 결정 기록), `implement`(이탈 결정. `implement.md`는 "근거, 버린 대안, 드라이버 포함"이라고만 함) | 약해짐. 필드가 빠지면 검사기가 잡지만, 대안의 질은 검증 패널에서야 잡힌다 |
| `mapping` 항목 모양과 `change` 값(`new`, `changed`, `kept`) | `phases/skeleton.md`만 | `implement`(대응표에 없는 위치를 쓰기 전에 기록) | 사소함. 검사기 오류가 필드 이름과 허용 값을 알려 준다 |

참고: 나누기 전에도 압축 뒤에는 "0절, 1절, 현재 단계 절"만 다시 읽었으므로 이 정보가 빠졌다. 나누면서 새로 생긴 손실은 새 세션에서 `/arch`를 처음 부를 때다.

깨지지 않은 것: 다시 읽기 줄(9줄)과 시작 2·3번이 `${CLAUDE_SKILL_DIR}/phases/<단계>.md`를 가리킨다. 파일 이름 5개가 `gates.sh`의 단계 이름, `ga status`의 `단계:` 출력과 같다. "SKILL.md 1절의 검증과 승인 절차", "SKILL.md 0절", "`phases/iterating.md`를 따른다", "architecture.md 5절"처럼 바꾼 참조는 모두 맞는 곳을 가리킨다. 코드(`usercmd.sh`의 `다음:` 문구, 훅, 세션 시작 문구)는 `SKILL.md`의 절 번호를 쓰지 않는다.

## 판정

고칠 것 있음. 기능 손실 0, 약해짐 3, 사소함 4.
고치는 방법 하나: 여러 단계에서 쓰는 기록 형식(`assumption`·`question`·`driver`·`fact`·`decision`·`mapping` 예시 한 줄씩, `indirect_evidence.type` 값, `ga_ask` 절차, 결정 대안 규칙)을 `SKILL.md` 1절 "기록 방법"으로 옮기거나 별도 파일로 두고 모든 단계에서 읽게 한다. 예시의 `search_log`에는 무엇을 찾았는지를 다시 넣는다.
