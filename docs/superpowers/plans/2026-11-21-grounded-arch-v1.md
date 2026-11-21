# grounded-arch v1 빌드 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 아키텍처를 설계할 때 ADD 3.0 절차와 근거 등급 규칙을 강제하는 Claude Code 플러그인을 만든다. 구성은 코어 CLI `ga`, Claude Code 어댑터, 스킬 두 개다.

**Architecture:**
- **코어(`core/`):** 하네스를 모르는 bash 3.2 + jq CLI `ga`다. 상태, 원장, 형식 검사, 게이트 판정, 검증 패널, 과금 점검을 모두 맡는다.
- **Claude Code 어댑터(`adapters/claude-code/hook.sh`, `hooks/hooks.json`):** 훅 이벤트 JSON을 `ga` 호출로 번역하고, `ga`의 판정을 다시 Claude Code의 출력 JSON으로 번역하는 일만 한다.
- **원장의 원본:** `.state/ledger.json` 하나뿐이다. `architecture.md`의 표는 `ga render`가 원장에서 만든다.

**Tech Stack:**
- 런타임: `/bin/bash` 3.2, `/usr/bin/jq` 1.7, `shasum`, `realpath`, `git`
- 플러그인: Claude Code 플러그인(command 훅, 스킬)
- 테스트: 직접 만드는 bash 테스트 러너. 이 기기에는 `bats`가 없다.

**Spec:** `docs/specs/2026-11-21-grounded-architecture-design.md` (이하 "설계 문서"). 실행자는 이 계획과 설계 문서를 함께 읽는다.

**범위**
- 이 계획은 v1의 **빌드**까지만 다룬다.
- 설계 문서 6절의 시범 평가는 **별도 계획(Plan 2)**으로 이 계획이 끝난 뒤에 쓴다. 대상: Event Ticketing 평가, 기존 코드 평가, brainstorming 끼어듦 확인, 규칙 주입 효과 측정. 분리하는 이유는 사용자의 참여(기존 프로젝트 선택, 합격 기준 결정)가 필요하기 때문이다.
- v1 완료 = 이 계획 + Plan 2.

---

## Global Constraints

**런타임**
- 코어와 어댑터는 `/bin/bash` 3.2와 `/usr/bin/jq`만 쓴다.
- bash 4 기능(연관 배열, `${x,,}`, `mapfile`)은 금지한다.
- node, bun, python은 금지한다. (설계 문서 5.8)

**과금: 구독 전용** (설계 문서 5.10)
- 모델을 호출하는 자식 프로세스 환경에서 아래 변수를 제거한다: `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CODE_USE_BEDROCK`, `CLAUDE_CODE_USE_VERTEX`, `CLAUDE_CODE_USE_FOUNDRY`
- 설정에 `apiKeyHelper`가 있으면 호출을 거부한다.
- `claude auth status`의 `authMethod`가 `claude.ai` 또는 `oauth_token`일 때만 실행한다.
- `--bare`는 쓰지 않는다.
- 점검에 실패하면 실행하지 않는다.

**테스트**
- 단위 테스트는 실제 모델을 부르지 않는다. `PATH` 맨 앞에 `tests/fakes/claude`를 둔다.
- 실제 모델 호출은 Task 1과 Task 13에서 명시한 단계에서만 한다.

**훅**
- 훅은 `"type": "command"`만 쓴다.

**`.state/` 쓰기 규칙**
- `docs/architecture/.state/` 아래 파일은 `ga`만 쓴다.
- 모든 쓰기는 임시 파일에 쓴 뒤 `mv`로 바꾸고, `.state/.lock` 잠금 아래에서 한다.

**게이트 공통 규칙**
- 현재 경로에서 위로 올라가며 `docs/architecture/.state/state.json`을 찾는다. 없거나 `paused`가 true면 모든 게이트는 **allow**다. (설계 문서 5.5)
- `state.json`은 있는데 JSON으로 읽을 수 없으면 deny/block으로 막는다(fail-closed). 이유 메시지에 복구 방법을 적는다: "`docs/architecture/.state/state.json`을 고치거나 `paused`를 true로 바꾸세요". (계획 판단: 설계 문서 G3 "강제로 막는다")

**언어**
- 스킬, 규칙, 검증 프롬프트, 사용자에게 보이는 메시지는 한국어로 쓴다.
- JSON 키와 코드 식별자는 영어로 쓴다. (설계 문서 5.7)

**ID 형식**
- `DRV-n` 드라이버, `CON-n` 제약, `FACT-n` 현재 구조 사실, `DEC-n` 결정, `ASM-n` 가정, `Q-n` 질문, `MAP-n` 대응표, `FND-n` 검증 지적
- `n`은 종류별로 1부터 늘어나며 재사용하지 않는다. `FND-n`만 보고서마다 1부터 다시 센다.

**사용자 명령**
- 줄 맨 앞이 `GA `로 시작하는 줄만 사용자 명령으로 인식한다.

**커밋**
- 커밋 메시지 끝에 다음 줄을 붙인다: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`

## Review Focus

| # | 위험한 입력 | 기대 동작 | 테스트 |
|---|---|---|---|
| 1 | 공백이나 한글이 들어간 경로 (예: `src/결제 모듈/a.ts`) | 대응표와 쓰기 게이트가 정확히 일치를 판정한다 | Task 6 `test_write_korean_space_path` |
| 2 | macOS의 `/tmp`와 `/private/tmp`처럼 같은 위치를 가리키는 경로 | 같은 위치로 판정한다 | Task 6 `test_write_private_tmp_alias` |
| 3 | 도구 호출이 병렬로 일어나 `ga add`가 동시에 실행됨 | 두 항목이 모두 남고 JSON이 깨지지 않는다 | Task 5 `test_parallel_add_keeps_both` |
| 4 | 사람이 손으로 고치다 깨진 `state.json` | 게이트가 조용히 통과시키지 않고, 복구 방법을 담아 막는다 | Task 6 `test_write_corrupt_state_denies` |
| 5 | 일반 문장 중간에 나온 "GA 승인" | 명령으로 처리하지 않는다 | Task 9 `test_line_must_start_with_GA` |

---

## 공유 데이터 형식 (모든 Task가 따른다)

### `.state/state.json`

```json
{"version":1,"mode":"greenfield","phase":"inputs","paused":false,
 "round":1,"iteration":0,"iteration_count":0,"transcript_path":null}
```

- `mode`: `greenfield` 또는 `brownfield`
- `phase`: `inputs`, `iterating`, `design-review`, `skeleton`, `implement` 중 하나

### `.state/ledger.json`

`{"items":[ ... ]}` 형태다.

**모든 항목에 공통으로 있는 필드**
- `id`, `kind`, `round`, `phase_added`, `iteration`(숫자 또는 null)
- `status`: `"open"`, `"asked"`, `"resolved"`, null 중 하나
- `resolution`: null 또는 `{by:"user"|"evidence", ts, quote?, source?}`

**출처(`source`) 객체**
- 형식: `{type:"user"|"code"|"literature"|"measurement", ref, quote?}`
- `user`면 `quote`가 비어 있으면 안 된다.
- `code`면 `ref`가 `경로:줄` 형식이어야 하고, 그 파일과 줄이 실제로 있어야 한다.

**탐색 기록(`search_log`) 객체**
- 형식: `{code, docs, conversation, web}`
- 네 값 모두 비어 있지 않은 문자열이어야 한다.
- 탐색이 해당되지 않으면 `"해당 없음: <이유>"`로 쓴다. 콜론 뒤의 이유도 비어 있으면 안 된다. (설계 문서 3.5)

**종류별 필드**

| kind | 필드 | 초기 status |
|---|---|---|
| `driver` | `driver_type`(purpose\|functional\|quality\|concern), `statement`, `horizon`(current\|future), `priority`(high\|medium\|low), `iteration`(우선순위 high면 1 이상의 정수, 아니면 null), `scenario`{stimulus,response,measure}(quality일 때 필수, measure 비면 안 됨), `source` | null |
| `constraint` | `statement`, `source`(type은 user만 허용) | null |
| `fact` | `statement`, `source`(type은 code만 허용) | null |
| `decision` | `iteration`, `element`, `choice`, `rationale`[source, 1개 이상], `alternatives`[{option,reason}, 1개 이상] 또는 `[{"none":"user_constraint","source":{type:"user",quote}}]`, `drivers`[DRV id, 1개 이상], `deviation`(bool, 기본 false) | deviation이면 open, 아니면 null |
| `assumption` | `statement`, `indirect_evidence`[{type: code_convention\|framework_default\|literature_norm\|goal_inference, ref}, 1개 이상], `search_log`, `alternatives`[{assumption,reason}, 1개 이상] | open |
| `question` | `question`, `search_log`, `impact`, `answer`(해결 시) | open |
| `mapping` | `element`, `path`(루트 기준 상대 경로), `change`(new\|changed\|kept) | null |

- **드라이버 출처 규칙:** 드라이버의 `source.type`은 직접 근거 4종 중 하나여야 한다. 간접 근거뿐인 미래 기능은 드라이버가 아니라 `assumption`으로 기록한다. (설계 문서 3.6)

### `.state/report.json` (검증 보고)

```json
{"doc_hash":"<sha256>","phase":"inputs","round":1,"iteration":0,"ts":"...",
 "panel":[{"runner":"claude","model":"opus","status":"ok","kept":2,"dropped":1}],
 "build_check":null,
 "findings":[{"id":"FND-1","check":1,"target":"ASM-2","claims":["..."],
   "evidence":[{"type":"file","ref":"src/a.ts:12"}],"models":["opus","sonnet"],
   "disposition":null}]}
```

- 패널 구성원의 `status`: `ok`, `invalid_output`, `failed`, `timeout` 중 하나
- `build_check`: null 또는 `{command, exit, tail}`
- 지적의 `disposition`: null, `{type:"user_rejected",quote,ts}`, `{type:"disputed",evidence,ts,verdict:null|"accept"|"reject",verdict_quote?}` 중 하나

**문서 해시 (`doc_hash`) 계산**
- `architecture.md`에서 `<!-- ga:begin X -->`부터 `<!-- ga:end X -->`까지의 블록을 뺀 본문을 쓴다.
- 여기에, 원장 항목에서 `status`, `resolution`, `answer` 키를 지우고 `jq -S -c`로 정렬한 문자열을 이어 붙인다.
- 이 전체의 sha256이 해시다.
- 이렇게 하는 이유: 사용자가 항목을 확인할 때마다 검증을 다시 돌리지 않아도 되게 하기 위해서다. (계획 판단: 반목표 A4)

**지적이 "처리됨"인 조건**
- 사용자가 기각했다: `disposition.type == "user_rejected"`
- 또는, 반박했고 사용자가 반박을 인정했다: `type == "disputed"`이고 `verdict == "accept"`
- 설계 문서의 "수정함"은 별도 값으로 두지 않는다. 고치면 문서 해시가 바뀌어 다시 검증해야 하고, 새 보고서에서 그 지적이 사라지는 것으로 처리된다. (계획 판단)

### 기타 `.state/` 파일
- `approvals.jsonl`: 덧붙이기 전용. 한 줄 형식은 `{ts, point, phase_from, phase_to, round, iteration, quote}`다.
- `test_command`: 사용자가 지정한 빌드·테스트 명령 한 줄
- `panel.json`: 사용자가 직접 고치는 선택 파일. 있으면 기본 패널 설정을 대신한다.
- `.lock/`: 잠금 디렉터리

### 판정 출력 (코어 → 어댑터)
모든 `ga gate *`와 `ga user-command`는 stdout에 JSON 한 줄을 내고 exit 0으로 끝난다.

```json
{"decision":"allow|deny|block","reason":"...","context":"..."}
```

---

## 파일 구조

```
ai-tools/
├─ .gitignore
├─ .claude-plugin/marketplace.json
├─ docs/notes/                               # 수동 확인 기록 (Task 1, 13)
├─ plugins/grounded-arch/
│  ├─ .claude-plugin/plugin.json
│  ├─ bin/ga                                 # PATH용 래퍼 → core/bin/ga
│  ├─ hooks/hooks.json                       # Claude Code 어댑터 등록
│  ├─ adapters/claude-code/hook.sh           # 이벤트 번역만 함
│  ├─ core/
│  │  ├─ bin/ga                              # 디스패처
│  │  ├─ lib/common.sh                       # 루트 탐색, 경로 정규화, 원자적 쓰기, 잠금
│  │  ├─ lib/state.sh                        # init, status, 상태 읽기·쓰기
│  │  ├─ lib/check.jq + lib/check.sh         # 형식 검사
│  │  ├─ lib/ledger.sh                       # add, update, ask, resolve, render
│  │  ├─ lib/gates.sh                        # gate write, bash, stop
│  │  ├─ lib/billing.sh                      # 실행기 과금 확인 기록과 점검
│  │  ├─ lib/verify.sh                       # 검증 패널, 지적 통합, 보고서, dispute
│  │  ├─ lib/usercmd.sh                      # GA 명령, 승인, 단계 전환
│  │  ├─ lib/context.sh                      # rule, context session-start
│  │  ├─ rules/grounding.md                  # 공통 근거 규칙 전문 (단일 원본)
│  │  ├─ rules/inject.txt                    # 요청마다 주입하는 짧은 규칙
│  │  ├─ templates/architecture.md
│  │  └─ verifier/{prompt.md,panel.json,runners/claude.json}
│  └─ skills/{grounding,design-architecture}/SKILL.md
└─ tests/
   ├─ run.sh, lib.sh
   ├─ fakes/claude                           # 가짜 claude CLI
   ├─ fixtures/                              # 원장, 이벤트, 실행기 출력
   └─ test_*.sh
```

---

### Task 1: 중첩 구독 호출 확인 (스파이크)

설계 문서 5.6절의 "(가정) 중첩 실행 문제"를 확인하는 작업이다. 이 결과에 따라 Task 7~8의 방향이 정해진다.

**Files:**
- Create: `docs/notes/2026-11-21-spike-nested-claude.md`

**Interfaces:**
- Produces: 결과 기록. `claude -p --output-format json` 출력에 `.result`와 `.is_error` 필드가 있는지 확인한 사실을 Task 8이 쓴다.

- [ ] **Step 1: 인증 방식 확인**

Run: `claude auth status | jq -r .authMethod`

Expected: `claude.ai`

- [ ] **Step 2: Claude Code 세션의 Bash 도구 안에서 중첩 호출하기** (실제 구독 호출 1회)

Run:
```bash
cd "$(mktemp -d)" && env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u CLAUDE_CODE_USE_BEDROCK -u CLAUDE_CODE_USE_VERTEX -u CLAUDE_CODE_USE_FOUNDRY claude -p "Reply with exactly the word OK" --model sonnet --allowedTools "Read" --output-format json | jq '{result, is_error}'
```

Expected: `{"result":"OK","is_error":false}`

- [ ] **Step 3: 도구 제한이 실제로 지켜지는지 확인** (실제 구독 호출 1회)

Run:
```bash
d="$(mktemp -d)"; cd "$d" && env -u ANTHROPIC_API_KEY claude -p "Create a file named x.txt containing hi" --model sonnet --allowedTools "Read,Grep,Glob" --output-format json >/dev/null; ls "$d"
```

Expected: `x.txt`가 **없다**. 허용하지 않은 쓰기 도구는 실행되지 않아야 한다.

- [ ] **Step 4: 결과 기록**

노트 파일에 아래를 적는다:
- 실행한 명령
- 실제 출력
- 날짜
- 결론(통과 또는 실패)

- [ ] **Step 5: 판정**

- **통과:** 다음 Task로 간다.
- **실패:** 여기서 **멈추고** 사용자에게 보고한다. 이 경우 Task 8을 설계 문서 5.6절의 대안(서브에이전트 실행과 SubagentStop 포착)으로 다시 계획해야 한다.

---

### Task 2: 저장소 뼈대, 디스패처, 테스트 러너

**Files:**
- Create: `.gitignore`, `.claude-plugin/marketplace.json`, `plugins/grounded-arch/.claude-plugin/plugin.json`
- Create: `plugins/grounded-arch/core/bin/ga`, `plugins/grounded-arch/core/lib/common.sh`
- Create: `tests/run.sh`, `tests/lib.sh`, `tests/test_common.sh`

**Interfaces:**

Produces (`ga` 디스패처):
- `ga [--root DIR] <sub> [args]`
  - `lib/*.sh`를 모두 source한 뒤 `cmd_<sub>` 함수를 부른다. 하위 명령의 `-`는 `_`로 바꾼다.
  - 모르는 하위 명령이면 exit 2와 함께 사용법을 출력한다.
  - 루트 결정 순서: `--root`, 환경변수 `GA_ROOT`, `ga_find_root "$PWD"`
- `ga version` → `grounded-arch 0.1.0`

Produces (`common.sh`):
| 함수 | 동작 |
|---|---|
| `ga_die MSG [CODE]` | stderr에 출력하고 종료. CODE 기본값은 2 |
| `ga_find_root START` | `START`부터 위로 올라가며 `docs/architecture/.state/state.json`이 있는 디렉터리를 정규 경로로 출력. 없으면 exit 1 |
| `ga_canon PATH` | 파일이 없어도 정규 절대 경로를 출력. 상위 디렉터리를 `cd -P`로 해석하므로 `/tmp`는 `/private/tmp`가 된다. 상대 경로는 `$PWD` 기준 |
| `ga_write_json FILE` | stdin을 `jq -e .`로 검증한 뒤 `FILE.tmp.$$`에 쓰고 `mv`. JSON이 잘못되면 exit 2이고 원본은 그대로 둔다 |
| `ga_lock ROOT` / `ga_unlock ROOT` | `mkdir .state/.lock`으로 잠금. 0.1초 간격으로 최대 50번 재시도하고, 실패하면 exit 2 |
| `ga_now` | `date -u +%Y-%m-%dT%H:%M:%SZ` |

Produces (`tests/lib.sh`):
- 경로 변수: `REPO`(저장소 루트), `PLUGIN=$REPO/plugins/grounded-arch`, `CORE=$PLUGIN/core`, `FIX=$REPO/tests/fixtures`
- 단언: `assert_eq`, `assert_contains`, `assert_not_contains`, `assert_status CODE cmd...`
- 프로젝트 준비:
  - `mk_project [greenfield|brownfield]`: 빈 임시 디렉터리를 출력한다. brownfield면 `src/main.c`(3줄)를 넣는다.
  - `seed_ledger ROOT FIXTURE|-`: 테스트 전용. `.state/ledger.json`을 직접 쓴다. `-`면 stdin을 쓴다.
  - `set_state ROOT JQ_EXPR`
- 기타:
  - `ga`: 저장소의 `core/bin/ga`를 실행하는 함수
  - `use_fake_claude`: `PATH`에 `tests/fakes`를 앞에 붙인다.

Produces (`tests/run.sh [file...]`):
- 각 파일의 `test_*` 함수를 서브셸에서 실행한다. 함수 목록은 `compgen -A function test_`로 얻는다.
- `PASS name` 또는 `FAIL name`을 출력하고, 실패가 하나라도 있으면 exit 1이다.

- [ ] **Step 1: git 초기화**

Run: `git init && git branch -M main`

Expected: `.git/`가 생긴다.

- [ ] **Step 2: 실패하는 테스트 작성** (`tests/test_common.sh`)

```bash
test_version() { assert_eq "grounded-arch 0.1.0" "$(ga version)"; }
test_find_root_from_subdir() { r=$(mk_project); mkdir -p "$r/docs/architecture/.state" "$r/a/b"; echo '{}' >"$r/docs/architecture/.state/state.json"
  ( cd "$r/a/b" && . "$CORE/lib/common.sh" && assert_eq "$(cd -P "$r" && pwd)" "$(ga_find_root "$PWD")" ); }
test_find_root_none_exit1() { r=$(mk_project); ( . "$CORE/lib/common.sh"; assert_status 1 ga_find_root "$r" ); }
test_canon_private_tmp() { d=$(mktemp -d /tmp/gaX.XXXX); ( . "$CORE/lib/common.sh"; assert_eq "/private$d/x/y.txt" "$(ga_canon "$d/x/y.txt")" ); }
test_write_json_atomic_invalid() { f=$(mktemp); echo '{"a":1}' >"$f"; ( . "$CORE/lib/common.sh"; echo 'not json' | assert_status 2 ga_write_json "$f" ); assert_eq '{"a":1}' "$(cat "$f")"; }
```

- [ ] **Step 3: 실패 확인**

Run: `tests/run.sh tests/test_common.sh`

Expected: FAIL. 아직 `ga`와 `common.sh`가 없다.

- [ ] **Step 4: 구현**

- 위 Interfaces의 디스패처, `common.sh`, 테스트 러너를 만든다.
- `marketplace.json`과 `plugin.json`을 만든다:
  - 마켓플레이스 이름은 `ai-tools`, 플러그인 이름은 `grounded-arch`, 소스는 `./plugins/grounded-arch`, 버전은 `0.1.0`
  - 필드 이름은 https://code.claude.com/docs/en/plugins-reference.md 를 보고 맞춘다.
- `.gitignore`에 `.DS_Store`를 넣는다.

- [ ] **Step 5: 통과 확인**

Run: `tests/run.sh tests/test_common.sh`

Expected: 5 PASS

- [ ] **Step 6: 매니페스트 검증**

Run: `claude plugin validate .` (이 명령이 없으면 문서의 스키마와 직접 대조한다)

Expected: 오류 없음

- [ ] **Step 7: 커밋**

`git add -A && git commit -m "chore: scaffold grounded-arch plugin, ga dispatcher, test runner"`

---

### Task 3: init과 status

**Files:**
- Create: `core/lib/state.sh`, `core/templates/architecture.md`, `tests/test_state.sh`

**Interfaces:**

Consumes: `ga_find_root`, `ga_write_json`, `ga_lock`

Produces:
- **`ga init [--mode greenfield|brownfield]`**
  - 루트는 `--root`가 있으면 그것, 없으면 `$PWD`다.
  - 만드는 것: `docs/architecture/architecture.md`(템플릿, 이미 있으면 두기), `.state/state.json`(공유 형식의 초기값), `ledger.json`(`{"items":[]}`), 빈 `approvals.jsonl`
  - `--mode`가 없으면 자동 판정한다. 루트에 `docs/`, `.git/`, `.claude/`, `README*`, `LICENSE*`, `.gitignore` **외의** 파일이 하나라도 있으면 `brownfield`다.
  - 출력: `초기화: mode=<m> (근거: <판정 이유>)`
  - 이미 초기화되어 있으면 exit 1이다.
- **`ga status [--json]`**
  - JSON 필드: `{phase, mode, paused, round, iteration, iteration_count, open, asked}`. 숫자는 현재 round 항목만 센다.
  - Task 8이 `report_fresh`, `findings_unprocessed`, `panel_ok` 필드를 추가한다.
- **내부 함수:** `ga_state_get ROOT JQ_FILTER`, `ga_state_set ROOT JQ_EXPR`(잠금 + 원자적 쓰기), `ga_ledger_path ROOT`, `ga_state_dir ROOT`

**템플릿 `architecture.md`**
- 제목: `1. 설계 목적`, `2. 드라이버`, `3. 제약과 현재 구조`, `4. 반복 계획`, `5. 반복별 설계`, `6. 결정·가정·질문`, `7. 코드 대응표`
- 2, 3, 4, 6, 7 아래에는 `<!-- ga:begin drivers -->`/`<!-- ga:end drivers -->` 표식을 둔다. 블록 이름은 각각 `drivers`, `context`, `plan`, `ledger`, `mapping`이다.

- [ ] **Step 1: 실패하는 테스트 작성**

```bash
test_init_creates_files() { r=$(mk_project); ga --root "$r" init >/dev/null
  assert_eq inputs "$(jq -r .phase "$r/docs/architecture/.state/state.json")"
  assert_eq 0 "$(jq '.items|length' "$r/docs/architecture/.state/ledger.json")"
  assert_contains "$(cat "$r/docs/architecture/architecture.md")" "<!-- ga:begin ledger -->"; }
test_init_twice_exit1() { r=$(mk_project); ga --root "$r" init >/dev/null; assert_status 1 ga --root "$r" init; }
test_init_mode_greenfield() { r=$(mk_project); assert_contains "$(ga --root "$r" init)" "mode=greenfield"; }
test_init_mode_brownfield() { r=$(mk_project brownfield); assert_contains "$(ga --root "$r" init)" "mode=brownfield"; }
test_status_json_fields() { r=$(mk_project); ga --root "$r" init >/dev/null
  assert_eq '{"phase":"inputs","round":1,"open":0}' "$(ga --root "$r" status --json | jq -c '{phase,round,open}')"; }
```

- [ ] **Step 2: 실패 확인**

Run: `tests/run.sh tests/test_state.sh`

Expected: FAIL (`cmd_init` 없음)

- [ ] **Step 3: 구현**

위 Interfaces대로 `state.sh`와 템플릿을 만든다.

- [ ] **Step 4: 통과 확인**

Run: `tests/run.sh tests/test_state.sh`

Expected: 5 PASS

- [ ] **Step 5: 커밋**

`git commit -am "feat(core): ga init and status"` (새 파일은 `git add`로 먼저 추가한다)

---

### Task 4: 형식 검사 (`ga check`)

**Files:**
- Create: `core/lib/check.jq`, `core/lib/check.sh`, `tests/test_check.sh`, `tests/fixtures/ledger_valid.json`

**Interfaces:**

Consumes: 공유 데이터 형식

Produces:
- **`ga check [--json]`**
  - 현재 원장 전체를 검사한다.
  - `--json`이면 `{"errors":[{"id","code","message"}]}`를 출력한다. `message`는 한국어다.
  - 오류가 없으면 exit 0, 있으면 exit 1이다.
- **`ga check --item KIND`**
  - stdin으로 받은 항목 하나만 검사한다. 항목 단위 규칙만 적용한다.
  - Task 5의 `add`와 `update`가 이 명령을 쓴다.
- **오류 코드** (메시지는 한국어, 괄호 안은 핵심 문구)

| 코드 | 조건 |
|---|---|
| `E_FIELD_MISSING` | 필수 필드가 없거나 비어 있다 (메시지에 필드 이름 포함) |
| `E_ENUM` | 허용되지 않은 값이다 |
| `E_SOURCE_USER_NO_QUOTE` | 출처가 사용자 발언인데 인용이 없다 |
| `E_SOURCE_CODE_REF` | `경로:줄` 형식이 아니거나, 파일·줄이 실제로 없다. 루트 기준으로 확인하며, 이 부분은 jq가 아니라 `check.sh`가 검사한다 |
| `E_QUALITY_NO_MEASURE` | 품질 드라이버에 측정 기준이 없다 |
| `E_HIGH_NO_ITERATION` | 우선순위 high인 드라이버에 반복 번호가 없다 |
| `E_CONSTRAINT_NOT_USER` | 제약의 출처가 사용자 발언이 아니다 |
| `E_FACT_NOT_CODE` | 현재 구조 사실의 출처가 코드가 아니다 |
| `E_DECISION_IN_INPUTS` | (원장 단위) inputs 단계에서 추가된 결정이 있다 ("입력 단계에서는 아키텍처 결정을 기록할 수 없습니다") |
| `E_DECISION_NO_ALTERNATIVES` | 결정에 버린 대안이 없다 |
| `E_ALT_NONE_NO_USER_SOURCE` | "대안 없음"인데 사용자 발언 출처가 없다 |
| `E_DECISION_UNKNOWN_DRIVER` | (원장 단위) 결정이 존재하지 않는 드라이버를 가리킨다 |
| `E_ASM_NO_INDIRECT` | 가정에 간접 근거가 없다 ("근거 없는 가정은 금지입니다. 질문(question)으로 바꾸세요") |
| `E_SEARCHLOG_INCOMPLETE` | 탐색 기록의 네 칸 중 하나가 비었거나, "해당 없음:" 뒤에 이유가 없다 |
| `E_ASM_NO_ALTERNATIVES` | 가정에 다른 가능한 가정이 없다 |
| `E_Q_NO_IMPACT` | 질문에 "답에 따라 바뀌는 것"이 없다 |
| `E_DUP_ID` | (원장 단위) ID가 중복된다 |

- [ ] **Step 1: 실패하는 테스트 작성**

- 오류 코드마다 그 오류 하나만 일으키는 최소 원장을 만들고, 해당 코드가 나오는지 확인한다. 픽스처는 `ledger_valid.json`을 jq로 한 군데만 고쳐서 만든다.
- 함수 이름은 `test_<code 소문자>`로 한다. 예: `test_e_asm_no_indirect`
- 예시:

```bash
mk_checked() { r=$(mk_project brownfield); ga --root "$r" init >/dev/null; seed_ledger "$r" "$FIX/ledger_valid.json"; echo "$r"; }
test_valid_ledger_passes() { r=$(mk_checked); assert_status 0 ga --root "$r" check; }
test_e_asm_no_indirect() { r=$(mk_checked); jq '(.items[]|select(.id=="ASM-1")).indirect_evidence=[]' "$r/docs/architecture/.state/ledger.json" | seed_ledger "$r" -
  assert_contains "$(ga --root "$r" check --json | jq -r '.errors[].code')" E_ASM_NO_INDIRECT; }
test_searchlog_na_without_reason() { r=$(mk_checked); jq '(.items[]|select(.id=="ASM-1")).search_log.web="해당 없음:"' "$r/docs/architecture/.state/ledger.json" | seed_ledger "$r" -
  assert_contains "$(ga --root "$r" check --json | jq -r '.errors[].code')" E_SEARCHLOG_INCOMPLETE; }
test_source_code_ref_line_beyond_eof() { r=$(mk_checked); jq '(.items[]|select(.id=="FACT-1")).source.ref="src/main.c:99"' "$r/docs/architecture/.state/ledger.json" | seed_ledger "$r" -
  assert_contains "$(ga --root "$r" check --json | jq -r '.errors[].code')" E_SOURCE_CODE_REF; }
test_alt_none_user_constraint_ok() { r=$(mk_checked); jq '(.items[]|select(.id=="DEC-1")).alternatives=[{"none":"user_constraint","source":{"type":"user","ref":"대화","quote":"DB는 PostgreSQL"}}]' "$r/docs/architecture/.state/ledger.json" | seed_ledger "$r" -
  assert_status 0 ga --root "$r" check; }
```

- `ledger_valid.json`에는 다음이 모두 유효한 형태로 들어 있어야 한다:
  - 드라이버 3개: purpose, functional, quality(high, iteration 1, measure 있음)
  - `CON-1`, `FACT-1`(`src/main.c:2`)
  - `DEC-1`(`phase_added` iterating, drivers `[DRV-3]`)
  - `ASM-1`, `Q-1`, `MAP-1`

- [ ] **Step 2: 실패 확인**

Run: `tests/run.sh tests/test_check.sh`

Expected: FAIL

- [ ] **Step 3: 구현**

- 항목 단위 규칙과 원장 단위 규칙은 `check.jq`에 둔다.
- 파일·줄 존재 확인은 `check.sh`가 맡는다.

- [ ] **Step 4: 통과 확인**

Run: `tests/run.sh tests/test_check.sh`

Expected: 전부 PASS

- [ ] **Step 5: 커밋**

`git commit -m "feat(core): ledger format check"`

---

### Task 5: 원장 조작과 render

**Files:**
- Create: `core/lib/ledger.sh`, `tests/test_ledger.sh`

**Interfaces:**

Consumes: `ga check --item`, `ga_state_get`, `ga_lock`, `ga_write_json`

Produces:

**`ga add KIND`** (stdin: 종류별 필드만 담은 JSON 객체)
- 공통 필드를 채운다: `id`, `round`, `phase_added`, `iteration`(드라이버는 입력값, 그 외는 상태의 현재 반복), `status` 초기값, `resolution:null`
- `ga check --item`으로 검사한다.
- 성공하면 ID를 출력한다.
- 단계 규칙:
  - `decision`은 inputs 단계에서 exit 3 ("입력 단계에서는 아키텍처 결정을 기록할 수 없습니다")
  - `mapping`은 inputs, iterating 단계에서 exit 3
- 검사에 실패하면 exit 3과 함께 오류 메시지를 출력한다.

**`ga update ID`** (stdin: 고칠 필드만 담은 JSON 객체)
- 기존 항목에 얕게 병합한 뒤 다시 검사한다.
- `id`, `kind`, `status`, `resolution`, `round`, `phase_added`, `answer`는 고칠 수 없다. 고치려 하면 exit 3.

**`ga ask Q-ID`**
- 질문의 상태를 open에서 asked로 바꾼다.
- 질문이 아니거나 상태가 open이 아니면 exit 3.

**`ga resolve ID --source-type code|literature|measurement --ref REF`**
- 가정, 질문, 이탈 결정을 근거로 해결 처리한다. 결과는 `status:"resolved"`, `resolution:{by:"evidence", ts, source}`
- `--source-type user`는 exit 3 ("사용자 확인은 사용자의 GA 명령으로만 기록됩니다").
- `code`면 참조가 실제로 있는지 검사한다.

**내부 함수** (CLI 하위 명령으로는 노출하지 않음)
- `ga_ledger_resolve_by_user ROOT ID QUOTE [ANSWER]`: `resolution:{by:"user", ts, quote}`로 기록하고, 질문이면 `answer`도 넣는다.

**`ga render`**
- `architecture.md`의 표식 블록 5개를 원장으로 다시 만든다. 표식이 없으면 파일 끝에 블록을 추가한다.
- 표의 열:

| 블록 | 열 |
|---|---|
| drivers | ID\|유형\|내용\|시점\|우선순위\|반복\|측정 기준\|출처 |
| context | 제약 표 `ID\|내용\|출처`, 현재 구조 표 `ID\|내용\|출처` |
| plan | 반복\|드라이버 |
| ledger | 결정 표: `ID\|반복\|요소\|선택\|근거\|버린 대안\|드라이버\|이탈` (이탈 칸: deviation이 false면 공란, 해결 전이면 "미승인 이탈", 해결 후면 "승인된 이탈") |
| ledger | 가정 표: `ID\|가정\|간접 근거\|탐색 기록\|다른 가정\|상태` |
| ledger | 질문 표: `ID\|질문\|영향\|상태\|답` |
| mapping | ID\|요소\|경로\|구분 |

- 셀 안의 `|`는 `\|`로 이스케이프하고, 줄바꿈은 `<br>`로 바꾼다.
- 같은 입력이면 출력이 항상 같아야 한다(멱등).

- [ ] **Step 1: 실패하는 테스트 작성**

```bash
in_iter() { r=$(mk_project); ga --root "$r" init >/dev/null; set_state "$r" '.phase="iterating"|.iteration=1|.iteration_count=1'; echo "$r"; }
test_add_assigns_sequential_ids() { r=$(in_iter); a=$(ga --root "$r" add assumption <"$FIX/asm.json"); b=$(ga --root "$r" add assumption <"$FIX/asm.json"); assert_eq "ASM-1 ASM-2" "$a $b"; }
test_add_decision_in_inputs_exit3() { r=$(mk_project); ga --root "$r" init >/dev/null; assert_status 3 ga --root "$r" add decision <"$FIX/dec.json"; }
test_add_invalid_assumption_exit3() { r=$(in_iter); jq '.indirect_evidence=[]' "$FIX/asm.json" | assert_status 3 ga --root "$r" add assumption; }
test_update_forbidden_key_exit3() { r=$(in_iter); id=$(ga --root "$r" add assumption <"$FIX/asm.json"); echo '{"status":"resolved"}' | assert_status 3 ga --root "$r" update "$id"; }
test_resolve_user_source_exit3() { r=$(in_iter); id=$(ga --root "$r" add assumption <"$FIX/asm.json"); assert_status 3 ga --root "$r" resolve "$id" --source-type user --ref x; }
test_resolve_by_code_ok() { r=$(in_iter); mkdir -p "$r/src"; printf 'a\nb\n' >"$r/src/x.c"; id=$(ga --root "$r" add assumption <"$FIX/asm.json")
  ga --root "$r" resolve "$id" --source-type code --ref src/x.c:2; assert_eq resolved "$(jq -r ".items[]|select(.id==\"$id\").status" "$r/docs/architecture/.state/ledger.json")"; }
test_render_idempotent_and_escapes_pipe() { r=$(in_iter); jq '.statement="a|b"' "$FIX/asm.json" | ga --root "$r" add assumption >/dev/null
  ga --root "$r" render; h1=$(shasum "$r/docs/architecture/architecture.md"); ga --root "$r" render; assert_eq "$h1" "$(shasum "$r/docs/architecture/architecture.md")"
  assert_contains "$(cat "$r/docs/architecture/architecture.md")" 'a\|b'; }
test_parallel_add_keeps_both() { r=$(in_iter); ga --root "$r" add assumption <"$FIX/asm.json" & ga --root "$r" add assumption <"$FIX/asm.json" & wait
  assert_eq 2 "$(jq '.items|length' "$r/docs/architecture/.state/ledger.json")"; }
```

- [ ] **Step 2: 실패 확인**

Run: `tests/run.sh tests/test_ledger.sh`

Expected: FAIL

- [ ] **Step 3: 구현**

위 Interfaces대로 `ledger.sh`를 만든다. 픽스처 `asm.json`, `dec.json`(유효한 단일 항목)도 추가한다.

- [ ] **Step 4: 통과 확인**

Run: `tests/run.sh tests/test_ledger.sh`

Expected: 전부 PASS

- [ ] **Step 5: 커밋**

`git commit -m "feat(core): ledger add/update/ask/resolve/render"`

---

### Task 6: 게이트 판정 (write, bash, stop)

**Files:**
- Create: `core/lib/gates.sh`, `tests/test_gates.sh`

**Interfaces:**

Consumes: `ga_find_root`, `ga_canon`, `ga check --json`, 원장의 mapping 항목

Produces: 아래 세 명령 모두 공유 판정 JSON을 출력하고 exit 0으로 끝난다.

**`ga gate write --path P`**

판정 순서:
1. 루트는 `P`의 상위 디렉터리부터 위로 탐색해 찾는다. 없으면 allow.
2. 상태가 paused면 allow.
3. `state.json`을 읽을 수 없으면 deny (Global Constraints의 복구 안내 포함).
4. `P`가 `<root>/docs/architecture/.state/` 아래면, 단계와 관계없이 deny ("설계 상태 파일은 ga만 수정합니다").
5. `P`가 루트 밖이면 allow. (계획 판단: 설계 문서의 "docs/architecture 밖 금지"는 대상 프로젝트 안을 가리킨다)
6. 단계별 판정:

| 단계 | 판정 |
|---|---|
| inputs, iterating, design-review | `<root>/docs/architecture/` 아래면 allow, 아니면 deny. 이유: "현재 단계 `<phase>`: 설계 승인 전에는 docs/architecture/ 밖에 쓸 수 없습니다. 설계를 기록하거나 사용자에게 `GA 일시정지`를 요청하세요" |
| skeleton | greenfield면 allow. brownfield면 `change`가 new 또는 changed인 mapping의 `path`와 정규 경로가 같거나 `docs/architecture/` 아래일 때만 allow |
| implement | allow |

**`ga gate bash --command C`**

루트는 `ga_find_root "$PWD"`로 찾는다. 어댑터가 훅 입력의 `cwd`로 이동한 뒤 호출하기 때문이다. `ga gate stop`도 같은 방식이다.

판정 순서:
1. 상태가 없거나 paused면 allow.
2. 단계와 관계없이 deny하는 경우:
   - (a) 내부 명령 호출: `(^|[;&|[:space:]])ga[[:space:]]+(user-command|hook)` 또는 `adapters/claude-code/hook.sh`가 들어 있다
   - (b) `.state`를 언급하면서 쓰기 패턴이 함께 있다
3. inputs, iterating, design-review 단계에서는 쓰기 패턴이 있으면 deny한다. 쓰기 패턴은 다음과 같다:
   - 리다이렉션 `>`, `>>`: 대상이 `/dev/null`, `&N`, `/tmp/…`, `$TMPDIR/…`, 루트 밖 절대 경로, `docs/architecture/`(.state 제외) 중 하나면 예외로 허용한다.
   - 명령: `tee`, `sed -i`, `perl -i`, `cp`, `mv`, `rm`, `touch`, `ln`, `dd`, `truncate`, `install`, `patch`
   - git 명령: `git (apply|checkout|restore|reset|rm|mv|stash)`
4. 그 밖에는 allow.
5. `ga`의 공개 하위 명령(add, update, ask, resolve, render, check, status, verify, dispute, init, version, rule, billing, context, gate)은 쓰기 패턴 검사에서 제외한다.

**`ga gate stop [--hook-active true|false]`**
1. 상태가 없거나 paused면 allow.
2. `ga check` 오류가 있으면 block. 이유는 앞 10개 오류와 "형식 오류를 고치거나, 근거가 없는 항목은 질문(ga add question)으로 바꾸세요"다.
3. `--hook-active`는 판정에 쓰지 않는다. 형식 오류가 남아 있으면 계속 막는다. (설계 문서 5.5)

- [ ] **Step 1: 실패하는 테스트 작성**

```bash
dec() { jq -r .decision <<<"$1"; }
phase() { r=$(mk_project ${2:-greenfield}); ga --root "$r" init >/dev/null; set_state "$r" ".phase=\"$1\""; echo "$r"; }
test_write_no_state_allows() { r=$(mk_project); assert_eq allow "$(dec "$(ga gate write --path "$r/src/a.c")")"; }
test_write_inputs_src_denied() { r=$(phase inputs); assert_eq deny "$(dec "$(ga gate write --path "$r/src/a.c")")"; }
test_write_inputs_arch_doc_allowed() { r=$(phase inputs); assert_eq allow "$(dec "$(ga gate write --path "$r/docs/architecture/architecture.md")")"; }
test_write_state_dir_denied_in_implement() { r=$(phase implement); assert_eq deny "$(dec "$(ga gate write --path "$r/docs/architecture/.state/state.json")")"; }
test_write_paused_allows() { r=$(phase inputs); set_state "$r" '.paused=true'; assert_eq allow "$(dec "$(ga gate write --path "$r/src/a.c")")"; }
test_write_outside_root_allows() { r=$(phase inputs); assert_eq allow "$(dec "$(ga gate write --path "$HOME/.scratch-ga-test")")"; }
test_write_skeleton_brownfield_unmapped_denied() { r=$(phase skeleton brownfield); assert_eq deny "$(dec "$(ga gate write --path "$r/src/other.c")")"; }
test_write_skeleton_brownfield_mapped_allowed() { r=$(phase skeleton brownfield); seed_map "$r" "src/new.c" new; assert_eq allow "$(dec "$(ga gate write --path "$r/src/new.c")")"; }
test_write_korean_space_path() { r=$(phase skeleton brownfield); seed_map "$r" "src/결제 모듈/a.ts" new; assert_eq allow "$(dec "$(ga gate write --path "$r/src/결제 모듈/a.ts")")"; }
test_write_private_tmp_alias() { r=$(phase inputs); alias_path="/private${r#/private}"; assert_eq deny "$(dec "$(ga gate write --path "$alias_path/src/a.c")")"; assert_eq allow "$(dec "$(ga gate write --path "$alias_path/docs/architecture/x.md")")"; }
test_write_corrupt_state_denies() { r=$(phase inputs); echo '{bad' >"$r/docs/architecture/.state/state.json"; out=$(ga gate write --path "$r/src/a.c"); assert_eq deny "$(dec "$out")"; assert_contains "$out" "state.json"; }
test_write_implement_allows() { r=$(phase implement); assert_eq allow "$(dec "$(ga gate write --path "$r/src/a.c")")"; }
test_bash_redirect_src_denied_inputs() { r=$(phase inputs); assert_eq deny "$(cd "$r" && dec "$(ga gate bash --command 'echo x > src/a.c')")"; }
test_bash_redirect_devnull_allowed() { r=$(phase inputs); assert_eq allow "$(cd "$r" && dec "$(ga gate bash --command 'ls > /dev/null 2>&1')")"; }
test_bash_internal_usercommand_denied_implement() { r=$(phase implement); assert_eq deny "$(cd "$r" && dec "$(ga gate bash --command 'ga user-command --text-file /tmp/p')")"; }
test_bash_state_write_denied_implement() { r=$(phase implement); assert_eq deny "$(cd "$r" && dec "$(ga gate bash --command "jq . x > docs/architecture/.state/ledger.json")")"; }
test_bash_ga_add_allowed_inputs() { r=$(phase inputs); assert_eq allow "$(cd "$r" && dec "$(ga gate bash --command "ga add question <<'EOF'
{}
EOF")")"; }
test_stop_format_error_blocks_even_hook_active() { r=$(phase iterating); seed_ledger "$r" "$FIX/ledger_bad_asm.json"; assert_eq block "$(cd "$r" && dec "$(ga gate stop --hook-active true)")"; }
test_stop_asked_question_allows() { r=$(phase inputs); seed_ledger "$r" "$FIX/ledger_asked_q.json"; assert_eq allow "$(cd "$r" && dec "$(ga gate stop)")"; }
```

- `seed_map ROOT PATH CHANGE`는 `tests/lib.sh`에 추가하는 도우미다. `MAP-1` 항목 하나를 원장에 넣는다.
- 픽스처 `ledger_bad_asm.json`, `ledger_asked_q.json`도 추가한다.

- [ ] **Step 2: 실패 확인**

Run: `tests/run.sh tests/test_gates.sh`

Expected: FAIL

- [ ] **Step 3: 구현**

`gates.sh`를 만든다. 경로 비교는 반드시 `ga_canon` 결과끼리 한다.

- [ ] **Step 4: 통과 확인**

Run: `tests/run.sh tests/test_gates.sh`

Expected: 전부 PASS

- [ ] **Step 5: 커밋**

`git commit -m "feat(core): write/bash/stop gate decisions"`

---

### Task 7: 과금 점검과 실행기 등록

**Files:**
- Create: `core/lib/billing.sh`, `core/verifier/runners/claude.json`, `tests/fakes/claude`, `tests/test_billing.sh`

**Interfaces:**

Produces: `core/verifier/runners/claude.json` (아래 값을 그대로 쓴다. 설계 문서 5.10)

```json
{"name":"claude","command":"claude",
 "subscription_auth":"Claude 요금제 로그인(claude.ai OAuth) 또는 claude setup-token의 CLAUDE_CODE_OAUTH_TOKEN",
 "strip_env":["ANTHROPIC_API_KEY","ANTHROPIC_AUTH_TOKEN","CLAUDE_CODE_USE_BEDROCK","CLAUDE_CODE_USE_VERTEX","CLAUDE_CODE_USE_FOUNDRY"],
 "forbidden_settings":["apiKeyHelper"],
 "preflight":["auth","status"],
 "allowed_auth_methods":["claude.ai","oauth_token"],
 "forbidden_flags":["--bare"],
 "invoke":["-p","{{PROMPT}}","--model","{{MODEL}}","--allowedTools","Read,Grep,Glob,WebSearch,WebFetch","--output-format","json"],
 "result_path":".result",
 "sources":[{"url":"https://code.claude.com/docs/en/authentication.md","checked":"2026-11-21"},
            {"url":"https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan","checked":"2026-11-21"},
            {"url":"https://code.claude.com/docs/en/cli-reference.md","checked":"2026-11-21"}]}
```

**`ga billing check RUNNER`**
- 통과하면 exit 0과 `ok: authMethod=<m>`을 출력한다.
- 거부하면 exit 4와 한국어 이유를 출력한다. 거부 조건은 다음과 같다:
  - (a) 실행기 기록 파일이 없다.
  - (b) 필수 키 중 하나라도 없거나 비어 있다. 필수 키: `name`, `command`, `subscription_auth`, `strip_env`, `forbidden_settings`, `preflight`, `allowed_auth_methods`, `forbidden_flags`, `invoke`, `result_path`, `sources`. `sources`는 1개 이상이고 각각 `url`과 `checked`가 있어야 한다.
  - `invoke`와 `result_path`를 기록에 두는 이유: 실행기마다 다른 CLI 인자와 결과 위치를 코어 코드가 아니라 기록 파일에 둔다. 그래야 Codex 같은 실행기를 추가할 때 JSON 파일 하나만 더하면 된다. (설계 문서 G6)
  - (c) 설정 파일에 금지 키가 최상위로 있다. 검사하는 파일: `$HOME/.claude/settings.json`, `$HOME/.claude/settings.local.json`, `<root>/.claude/settings.json`, `<root>/.claude/settings.local.json`, `/Library/Application Support/ClaudeCode/managed-settings.json`
  - (d) `strip_env`를 제거한 환경에서 `command preflight…`를 실행했는데 실패했거나, `.authMethod`를 읽을 수 없거나, 그 값이 허용 목록에 없다.
- 실행기 기록 디렉터리는 환경변수 `GA_RUNNERS_DIR`로 바꿀 수 있다. 테스트용이다.

**`ga_billing_scan_settings ROOT RUNNER`** (내부 함수, Task 10이 사용)
- 위 (c)의 설정 파일 검사와, 현재 환경에 `strip_env` 변수가 있는지 검사한다.
- 발견한 이름을 한 줄에 하나씩 출력한다. 없으면 아무것도 출력하지 않는다.

**`ga_runner_exec RUNNER ARGS...`** (내부 함수)
- 먼저 `ga billing check`를 통과해야 한다.
- `ARGS`에 금지 플래그가 있으면 exit 4.
- `env -u <각 strip_env> <command> ARGS...`로 실행한다.

**`tests/fakes/claude`**
- `auth status`를 받으면 `{"authMethod":"${FAKE_AUTH_METHOD:-claude.ai}"}`를 출력한다. 단, `FAKE_AUTH_FAIL=1`이면 exit 1이다.
- `-p`를 받으면:
  - `FAKE_ENV_DUMP`가 있으면 `env`를 그 파일에 저장한다.
  - `--model M` 인자를 읽는다.
  - `$FAKE_P_DIR/M.json`이 있으면 그 내용을 출력한다. 없으면 `{"result":"{\"findings\":[]}","is_error":false}`를 출력한다.

- [ ] **Step 1: 실패하는 테스트 작성**

```bash
test_billing_ok() { use_fake_claude; assert_contains "$(ga billing check claude)" "authMethod=claude.ai"; }
test_billing_api_key_stripped() { use_fake_claude; export ANTHROPIC_API_KEY=x FAKE_ENV_DUMP=$(mktemp)
  ( . "$CORE/lib/common.sh"; . "$CORE/lib/billing.sh"; ga_runner_exec claude -p hi --model sonnet >/dev/null ); assert_not_contains "$(cat "$FAKE_ENV_DUMP")" ANTHROPIC_API_KEY; }
test_billing_apikeyhelper_refused() { use_fake_claude; export HOME=$(mktemp -d); mkdir -p "$HOME/.claude"; echo '{"apiKeyHelper":"x"}' >"$HOME/.claude/settings.json"; assert_status 4 ga billing check claude; }
test_billing_authmethod_api_key_refused() { use_fake_claude; FAKE_AUTH_METHOD=api_key assert_status 4 ga billing check claude; }
test_billing_preflight_failure_refused() { use_fake_claude; FAKE_AUTH_FAIL=1 assert_status 4 ga billing check claude; }
test_billing_record_missing_field_refused() { use_fake_claude; d=$(mktemp -d); jq 'del(.sources)' "$CORE/verifier/runners/claude.json" >"$d/claude.json"; GA_RUNNERS_DIR=$d assert_status 4 ga billing check claude; }
test_runner_exec_bare_flag_refused() { use_fake_claude; ( . "$CORE/lib/common.sh"; . "$CORE/lib/billing.sh"; assert_status 4 ga_runner_exec claude -p hi --bare ); }
```

- [ ] **Step 2: 실패 확인**

Run: `tests/run.sh tests/test_billing.sh`

Expected: FAIL

- [ ] **Step 3: 구현**

`billing.sh`, `claude.json`, 가짜 `claude`를 만든다.

- [ ] **Step 4: 통과 확인**

Run: `tests/run.sh tests/test_billing.sh`

Expected: 7 PASS

- [ ] **Step 5: 커밋**

`git commit -m "feat(core): subscription-only billing preflight and runner registry"`

---

### Task 8: 검증 패널 (`ga verify`, `ga dispute`)

**Files:**
- Create: `core/lib/verify.sh`, `core/verifier/prompt.md`, `core/verifier/panel.json`
- Create: `tests/test_verify.sh`, `tests/fixtures/runner_outputs/`

**Interfaces:**

Consumes:
- `ga_runner_exec`, `ga billing check` (Task 7)
- `ga_ledger_path`, `ga_state_get` (Task 3)
- Task 1에서 확인한 `--output-format json` 출력의 `.result` 필드

Produces:

**`panel.json` 기본값**

```json
{"members":[{"runner":"claude","model":"opus"},{"runner":"claude","model":"sonnet"},{"runner":"claude","model":"fable"}],"timeout_sec":900}
```

- 메인 모델(opus)을 포함한다. 설계 문서 5.6절과 사용자 결정을 따른 것이다.
- `<root>/docs/architecture/.state/panel.json`이 있으면 그 파일이 기본값을 대신한다.

**`ga_doc_hash ROOT`**
- 공유 데이터 형식의 "문서 해시" 정의대로 계산한다.

**`ga verify`** (순서대로)
1. 패널에 있는 모든 실행기에 대해 `ga billing check`를 한다. 하나라도 거부되면 exit 4로 끝내고 **보고서를 쓰지 않는다**.
2. 기존 코드 모드이고 skeleton 단계면 빌드 확인을 한다:
   - `.state/test_command`가 있으면 루트에서 `bash -c`로 실행하고 `build_check={command, exit, tail}`를 기록한다. `tail`은 출력의 마지막 40줄이다.
   - 파일이 없으면 `build_check=null`이다.
   - 계획 판단: 설계 문서는 "검증 에이전트가 실제 명령 출력으로 확인"이라고 했지만, 실행기에는 읽기 도구만 주므로 `ga`가 직접 실행한다.
3. 프롬프트를 만든다. `prompt.md`의 다음 자리표시자를 바꿔 넣는다: `{{ROOT}}`, `{{PHASE}}`, `{{MODE}}`, `{{ROUND}}`, `{{ITERATION}}`, `{{ARCH}}`(architecture.md 경로), `{{LEDGER}}`, `{{TRANSCRIPT}}`(`state.transcript_path` 또는 "없음"), `{{BUILD}}`
4. 패널 구성원마다 실행한다:
   - 명령: `ga_runner_exec <runner> <invoke 배열>`. 배열 안의 `{{PROMPT}}`와 `{{MODEL}}`만 치환한다. Claude 전용 인자는 코어 코드에 쓰지 않는다.
   - 작업 디렉터리는 루트다.
   - `timeout_sec`가 지나면 프로세스를 kill한다. 백그라운드 실행 + `sleep` 감시자로 구현한다(bash 3.2).
   - 결과 해석: 실행기 기록의 `result_path`(jq 경로)로 꺼낸 문자열에서 첫 `{`부터 마지막 `}`까지 잘라 `{"findings":[{check:1..6, target, claim, evidence:[{type:file|url|search|command, ref}]}]}` 형식인지 확인한다.
   - 상태: `ok`, `invalid_output`, `failed`, `timeout`
5. 지적마다 증거를 검사한다:
   - 증거가 0개면 버린다.
   - `file` 증거는 `경로:줄`이 실제로 있어야 한다. 없으면 버린다.
   - 버린 개수는 구성원별 `dropped`에 센다.
6. `check`와 `target`이 같은 지적은 하나로 합친다. `claims`와 `evidence`는 합치고, 발견한 모델은 `models`에 모두 기록한다.
7. 보고서를 원자적으로 쓰고, 한국어 요약을 출력한다: 구성원별 상태, 지적 수, 버린 수
8. exit 코드: 모든 구성원이 ok면 0, 아니면 5

**`ga dispute FND-ID --evidence TEXT`**
- 처리 결과를 `{type:"disputed", evidence, ts, verdict:null}`로 기록한다.
- 지적이 없거나 증거가 비어 있으면 exit 3.

**내부 함수** (Task 9가 사용)
- `ga_finding_user_reject ROOT FND QUOTE`
- `ga_finding_verdict ROOT FND accept|reject QUOTE`: 상태가 disputed일 때만 가능하다.

**`ga status --json` 확장**
- `report_fresh`: 보고서의 해시가 현재 `ga_doc_hash`와 같은가
- `findings_unprocessed`: 처리되지 않은 지적 수
- `panel_ok`: 모든 구성원의 상태가 ok인가
- `build_ok`: `build_check.exit==0`인가. 해당 없으면 null

**`prompt.md` 내용** (한국어)
- 설계 문서 5.6절의 검사 항목 1~6을 그대로 옮긴다.
- 6번은 inputs 단계에서만 검사한다.
- 읽기 전용이라고 명시한다.
- "증거 없는 지적은 쓰지 마라"
- "JSON 객체 하나만 출력하라"와 출력 스키마
- 대화 기록 경로를 읽어 사용자 발언 인용이 맞는지 확인하라는 지시

- [ ] **Step 1: 실패하는 테스트 작성**

```bash
vroot() { r=$(mk_project brownfield); ga --root "$r" init >/dev/null; seed_ledger "$r" "$FIX/ledger_valid.json"; set_state "$r" '.phase="iterating"|.iteration=1|.iteration_count=1'
  echo '{"members":[{"runner":"claude","model":"opus"},{"runner":"claude","model":"sonnet"}],"timeout_sec":5}' >"$r/docs/architecture/.state/panel.json"; echo "$r"; }
rep() { jq -r "$2" "$1/docs/architecture/.state/report.json"; }
test_verify_billing_refusal_no_report() { use_fake_claude; r=$(vroot); FAKE_AUTH_METHOD=api_key assert_status 4 ga --root "$r" verify; assert_status 1 test -f "$r/docs/architecture/.state/report.json"; }
test_verify_merges_same_target() { use_fake_claude; r=$(vroot); export FAKE_P_DIR=$FIX/runner_outputs/merge; ga --root "$r" verify >/dev/null
  assert_eq 1 "$(rep "$r" '.findings|length')"; assert_eq '["opus","sonnet"]' "$(rep "$r" '.findings[0].models|sort|tojson')"; }
test_verify_drops_no_evidence() { use_fake_claude; r=$(vroot); export FAKE_P_DIR=$FIX/runner_outputs/noevidence; ga --root "$r" verify >/dev/null; assert_eq 0 "$(rep "$r" '.findings|length')"; assert_eq 1 "$(rep "$r" '.panel[0].dropped')"; }
test_verify_drops_bad_file_ref() { use_fake_claude; r=$(vroot); export FAKE_P_DIR=$FIX/runner_outputs/badref; ga --root "$r" verify >/dev/null; assert_eq 0 "$(rep "$r" '.findings|length')"; }
test_verify_invalid_output_status() { use_fake_claude; r=$(vroot); export FAKE_P_DIR=$FIX/runner_outputs/garbage; assert_status 5 ga --root "$r" verify; assert_eq invalid_output "$(rep "$r" '.panel[0].status')"; }
test_hash_ignores_resolution() { use_fake_claude; r=$(vroot); ga --root "$r" verify >/dev/null
  ( . "$CORE/lib/common.sh"; for f in "$CORE"/lib/*.sh; do . "$f"; done; ga_ledger_resolve_by_user "$r" ASM-1 "GA 확인 ASM-1" )
  assert_eq true "$(ga --root "$r" status --json | jq .report_fresh)"; }
test_hash_changes_on_content() { use_fake_claude; r=$(vroot); ga --root "$r" verify >/dev/null; echo '{"statement":"바뀜"}' | ga --root "$r" update ASM-1
  assert_eq false "$(ga --root "$r" status --json | jq .report_fresh)"; }
test_dispute_sets_disposition() { use_fake_claude; r=$(vroot); export FAKE_P_DIR=$FIX/runner_outputs/merge; ga --root "$r" verify >/dev/null
  ga --root "$r" dispute FND-1 --evidence "src/main.c:1에 이미 있음"; assert_eq disputed "$(rep "$r" '.findings[0].disposition.type')"; }
test_verify_brownfield_skeleton_build_check() { use_fake_claude; r=$(vroot); set_state "$r" '.phase="skeleton"'; echo 'exit 3' >"$r/docs/architecture/.state/test_command"
  ga --root "$r" verify >/dev/null; assert_eq 3 "$(rep "$r" '.build_check.exit')"; }
```

- [ ] **Step 2: 실패 확인**

Run: `tests/run.sh tests/test_verify.sh`

Expected: FAIL

- [ ] **Step 3: 구현**

`verify.sh`, `prompt.md`, `panel.json`과 실행기 출력 픽스처를 만든다:
- `merge/`: `opus.json`, `sonnet.json`이 같은 target을 지적한다.
- `noevidence/`
- `badref/`: `src/main.c:99`
- `garbage/`: JSON이 아닌 결과

- [ ] **Step 4: 통과 확인**

Run: `tests/run.sh tests/test_verify.sh`

Expected: 전부 PASS

- [ ] **Step 5: 커밋**

`git commit -m "feat(core): multi-model verification panel with evidence filtering"`

---

### Task 9: 사용자 명령과 승인

**Files:**
- Create: `core/lib/usercmd.sh`, `tests/test_usercmd.sh`

**Interfaces:**

Consumes:
- `ga check`, `ga_ledger_resolve_by_user`, `ga_finding_user_reject`, `ga_finding_verdict`
- `ga status --json`(Task 8에서 확장한 필드 포함), `ga_state_set`

Produces: **`ga user-command --text-file F [--transcript P]`** (내부 명령. G-bash가 에이전트의 호출을 막는다)

**기본 동작**
1. 상태가 있고 `--transcript`가 주어지면 `transcript_path`를 기록한다.
2. `^GA[[:space:]]+([^[:space:]]+)(.*)$`에 맞는 줄만 명령으로 처리한다.
3. 명령 줄이 없으면 allow하고 `context`는 빈 값이다.
4. 상태가 없는데 명령 줄이 있으면 block ("설계가 시작되지 않았습니다. /design-architecture로 시작하세요").
5. 모든 명령 줄을 **먼저 전부 검사**한다. 하나라도 실패하면 block하고, 실패 이유를 모두 보여주며, 아무것도 적용하지 않는다(원자적).
6. 모두 통과하면 잠금 아래에서 차례로 적용하고 allow한다. `context`에는 한국어 요약을 넣는다. 예: "기록됨: ASM-3 사용자 확인 / 단계 inputs→iterating (반복 1/2)"

**동사**

| 명령 | 조건 | 결과 |
|---|---|---|
| `GA 승인 입력` | 현재 단계 inputs + 공통 전제 + 현재 round에 결정 0개 + purpose 드라이버 1개 이상 + high 드라이버가 모두 iteration ≥1 | iterating, `iteration=1`, `iteration_count`는 high 드라이버의 최대 iteration |
| `GA 승인 반복` | 현재 단계 iterating + 공통 전제 + 현재 iteration의 드라이버가 모두 같은 iteration의 결정 1개 이상에 연결됨 | 남은 반복이 있으면 `iteration+1`, 마지막이면 design-review |
| `GA 승인 설계` | 현재 단계 design-review + 공통 전제 + high 드라이버가 모두 결정 1개 이상에 연결됨 | skeleton |
| `GA 승인 뼈대` | 현재 단계 skeleton + 공통 전제 + (brownfield면 mapping 1개 이상, `build_ok == true`) | implement |
| `GA 확인 ID [메모]` | ASM, 또는 deviation인 DEC. 상태가 open 또는 asked | 사용자 확인으로 해결. 인용은 그 줄 전체 |
| `GA 답 Q-n 답변` | 답변이 비어 있지 않음. 상태가 open 또는 asked | 사용자 답으로 해결. `answer` 기록 |
| `GA 기각 FND-n [사유]` | 지적이 존재함 | `user_rejected` |
| `GA 판정 FND-n 반박인정\|반박기각` | 처리 결과가 disputed | verdict를 accept 또는 reject로 기록 |
| `GA 일시정지` / `GA 재개` | 없음 | `paused`를 true 또는 false로 |
| `GA 되돌리기` | design-review 또는 skeleton 단계 | iterating으로. `iteration_count+1`, `iteration`은 새 count |
| `GA 새라운드` | implement 단계 | inputs로. `round+1`, `iteration=0`, `iteration_count=0` |
| `GA 테스트명령 <명령>` | 명령이 비어 있지 않음 | `.state/test_command`에 저장 |

**승인 공통 전제** (설계 문서 5.5 G-approval)
- `ga check` 오류가 0개다.
- 현재 round에 status가 open 또는 asked인 항목이 0개다.
- `report_fresh`가 true다.
- `panel_ok`가 true다.
- `findings_unprocessed`가 0이다.

승인을 거부할 때는 실패한 조건마다 남은 ID 목록을 이유에 넣는다. 승인에 성공하면 `approvals.jsonl`에 한 줄을 추가한다.

알 수 없는 동사는 block하고, 이유에 동사 목록을 보여준다.

- [ ] **Step 1: 실패하는 테스트 작성**

```bash
uc() { f=$(mktemp); printf '%s' "$2" >"$f"; ga --root "$1" user-command --text-file "$f"; }
dec() { jq -r .decision <<<"$1"; }
ready_inputs() { use_fake_claude; r=$(mk_project); ga --root "$r" init >/dev/null; seed_ledger "$r" "$FIX/ledger_inputs_ready.json"; ga --root "$r" verify >/dev/null; echo "$r"; }
test_line_must_start_with_GA() { r=$(ready_inputs); assert_eq allow "$(dec "$(uc "$r" '이건 GA 승인 입력 이라는 뜻이 아니다')")"; assert_eq inputs "$(jq -r .phase "$r/docs/architecture/.state/state.json")"; }
test_unknown_verb_blocks() { r=$(ready_inputs); assert_eq block "$(dec "$(uc "$r" 'GA 아무거나')")"; }
test_approve_inputs_success() { r=$(ready_inputs); assert_eq allow "$(dec "$(uc "$r" 'GA 승인 입력')")"; assert_eq iterating "$(jq -r .phase "$r/docs/architecture/.state/state.json")"; assert_eq 1 "$(wc -l <"$r/docs/architecture/.state/approvals.jsonl" | tr -d ' ')"; }
test_approve_blocked_by_open_assumption() { use_fake_claude; r=$(mk_project); ga --root "$r" init >/dev/null; seed_ledger "$r" "$FIX/ledger_inputs_open_asm.json"; ga --root "$r" verify >/dev/null
  out=$(uc "$r" 'GA 승인 입력'); assert_eq block "$(dec "$out")"; assert_contains "$out" "ASM-1"; }
test_confirm_then_approve() { use_fake_claude; r=$(mk_project); ga --root "$r" init >/dev/null; seed_ledger "$r" "$FIX/ledger_inputs_open_asm.json"; ga --root "$r" verify >/dev/null
  assert_eq allow "$(dec "$(uc "$r" 'GA 확인 ASM-1 맞음')")"; assert_eq user "$(jq -r '.items[]|select(.id=="ASM-1").resolution.by' "$r/docs/architecture/.state/ledger.json")"
  assert_eq allow "$(dec "$(uc "$r" 'GA 승인 입력')")"; }
test_approve_blocked_stale_report() { r=$(ready_inputs); echo '{"statement":"변경"}' | ga --root "$r" update DRV-1; assert_eq block "$(dec "$(uc "$r" 'GA 승인 입력')")"; }
test_approve_blocked_unprocessed_finding() { use_fake_claude; r=$(mk_project); ga --root "$r" init >/dev/null; seed_ledger "$r" "$FIX/ledger_inputs_ready.json"; FAKE_P_DIR=$FIX/runner_outputs/merge ga --root "$r" verify >/dev/null
  assert_eq block "$(dec "$(uc "$r" 'GA 승인 입력')")"; uc "$r" 'GA 기각 FND-1 해당 없음' >/dev/null; assert_eq allow "$(dec "$(uc "$r" 'GA 승인 입력')")"; }
test_approve_wrong_phase_blocks() { r=$(ready_inputs); assert_eq block "$(dec "$(uc "$r" 'GA 승인 설계')")"; }
test_atomic_multi_line() { use_fake_claude; r=$(mk_project); ga --root "$r" init >/dev/null; seed_ledger "$r" "$FIX/ledger_inputs_open_asm.json"
  assert_eq block "$(dec "$(uc "$r" "GA 확인 ASM-1 맞음
GA 아무거나")")"; assert_eq open "$(jq -r '.items[]|select(.id=="ASM-1").status' "$r/docs/architecture/.state/ledger.json")"; }
test_pause_resume() { r=$(ready_inputs); uc "$r" 'GA 일시정지' >/dev/null; assert_eq true "$(jq .paused "$r/docs/architecture/.state/state.json")"; uc "$r" 'GA 재개' >/dev/null; assert_eq false "$(jq .paused "$r/docs/architecture/.state/state.json")"; }
test_back_from_skeleton() { r=$(ready_inputs); set_state "$r" '.phase="skeleton"|.iteration=2|.iteration_count=2'; uc "$r" 'GA 되돌리기' >/dev/null; assert_eq '"iterating" 3' "$(jq -c '.phase' "$r/docs/architecture/.state/state.json") $(jq .iteration "$r/docs/architecture/.state/state.json")"; }
test_new_round() { r=$(ready_inputs); set_state "$r" '.phase="implement"'; uc "$r" 'GA 새라운드' >/dev/null; assert_eq 2 "$(jq .round "$r/docs/architecture/.state/state.json")"; }
test_iteration_coverage_blocks() { use_fake_claude; r=$(mk_project); ga --root "$r" init >/dev/null; seed_ledger "$r" "$FIX/ledger_iter_uncovered.json"; set_state "$r" '.phase="iterating"|.iteration=1|.iteration_count=1'; ga --root "$r" verify >/dev/null
  out=$(uc "$r" 'GA 승인 반복'); assert_eq block "$(dec "$out")"; assert_contains "$out" "DRV-"; }
test_brownfield_skeleton_needs_build_ok() { use_fake_claude; r=$(mk_project brownfield); ga --root "$r" init >/dev/null; seed_ledger "$r" "$FIX/ledger_valid.json"; set_state "$r" '.phase="skeleton"'; ga --root "$r" verify >/dev/null
  out=$(uc "$r" 'GA 승인 뼈대'); assert_eq block "$(dec "$out")"; assert_contains "$out" "GA 테스트명령"; }
test_records_transcript_path() { r=$(ready_inputs); f=$(mktemp); echo hi >"$f"; ga --root "$r" user-command --text-file "$f" --transcript /x/t.jsonl >/dev/null; assert_eq /x/t.jsonl "$(jq -r .transcript_path "$r/docs/architecture/.state/state.json")"; }
```

추가할 픽스처:
- `ledger_inputs_ready.json`: inputs 단계, 해결되지 않은 항목 없음, purpose 드라이버 있음, high 드라이버의 iteration 1
- `ledger_inputs_open_asm.json`: 위와 같지만 ASM-1이 open
- `ledger_iter_uncovered.json`: iteration 1인 high 드라이버가 어떤 결정에도 연결되지 않음

- [ ] **Step 2: 실패 확인**

Run: `tests/run.sh tests/test_usercmd.sh`

Expected: FAIL

- [ ] **Step 3: 구현**

위 Interfaces대로 `usercmd.sh`를 만든다.

- [ ] **Step 4: 통과 확인**

Run: `tests/run.sh tests/test_usercmd.sh`

Expected: 전부 PASS

- [ ] **Step 5: 커밋**

`git commit -m "feat(core): GA user commands, approvals, phase transitions"`

---

### Task 10: 규칙 문서와 컨텍스트 출력

**Files:**
- Create: `core/rules/grounding.md`, `core/rules/inject.txt`, `core/lib/context.sh`, `tests/test_context.sh`

**Interfaces:**

Consumes:
- `ga_billing_scan_settings ROOT claude` (Task 7)
- `ga status --json`

Produces:

**`ga rule`**
- `inject.txt`를 출력한다.

**`ga context session-start`**
- 상태가 있으면 다음을 출력한다:
  - `설계 진행 중: 단계 <phase>, 반복 <i>/<n>, 미해결 <open+asked>개, 검증 보고 <최신|오래됨|없음>`
  - 미해결 ID 최대 10개
- 현재 환경에 claude 실행기의 `strip_env` 변수가 하나라도 있거나 금지 설정이 있으면 경고를 출력한다: `경고: 이 세션은 API 과금 경로(<변수나 설정 이름>)로 동작할 수 있습니다. 구독 로그인만 사용하세요.` (설계 문서 5.10 "메인 세션 점검")
- 둘 다 해당하지 않으면 아무것도 출력하지 않는다.

**`grounding.md`** (한국어)
- 설계 문서 3.1~3.6절의 내용을 규칙 문장으로 옮긴다.
- 들어가야 할 것: 세 등급, 직접 근거 4종, 간접 근거 종류, 기록 형식, 탐색 범위, 미래 기능 규칙
- 마지막에 "응답에서 판단마다 근거 종류를 표시한다"를 넣는다.

**`inject.txt`** (800자 이하)
- 반드시 들어가야 할 문장 요소:
  - "확정", "근거 있는 가정", "근거 없는 가정"
  - 직접 근거 4종의 이름
  - "근거 없는 가정 금지 → 질문"
  - "응답에서 판단마다 근거를 표시"

- [ ] **Step 1: 실패하는 테스트 작성**

```bash
test_inject_length_under_800() { n=$(ga rule | wc -m | tr -d ' '); [ "$n" -le 800 ] || { echo "len=$n"; return 1; }; }
test_inject_mentions_grades() { t=$(ga rule); for w in "확정" "근거 있는 가정" "근거 없는 가정" "질문"; do assert_contains "$t" "$w"; done; }
test_session_context_with_state() { r=$(mk_project); ga --root "$r" init >/dev/null; assert_contains "$(cd "$r" && ga context session-start)" "설계 진행 중: 단계 inputs"; }
test_session_context_billing_warning() { r=$(mk_project); assert_contains "$(cd "$r" && ANTHROPIC_API_KEY=x ga context session-start)" "ANTHROPIC_API_KEY"; }
test_session_context_empty_when_clean() { r=$(mk_project); export HOME=$(mktemp -d); assert_eq "" "$(cd "$r" && env -u ANTHROPIC_API_KEY ga context session-start)"; }
```

- [ ] **Step 2: 실패 확인**

Run: `tests/run.sh tests/test_context.sh`

Expected: FAIL

- [ ] **Step 3: 구현**

규칙 문서 두 개와 `context.sh`를 만든다.

- [ ] **Step 4: 통과 확인**

Run: `tests/run.sh tests/test_context.sh`

Expected: 5 PASS

- [ ] **Step 5: 커밋**

`git commit -m "feat(core): grounding rules and session context"`

---

### Task 11: Claude Code 어댑터

**Files:**
- Create: `plugins/grounded-arch/hooks/hooks.json`, `plugins/grounded-arch/adapters/claude-code/hook.sh`, `plugins/grounded-arch/adapters/claude-code/capabilities.json`, `plugins/grounded-arch/bin/ga`
- Create: `tests/test_adapter_claude.sh`, `tests/fixtures/claude_events/*.json`

**Interfaces:**

Consumes: `ga gate write|bash|stop`, `ga user-command`, `ga rule`, `ga context session-start`

Produces: **`hook.sh EVENT`** (stdin: Claude Code 훅 입력 JSON)
- `cwd`로 이동한 뒤 `ga`를 부른다.
- `ga` 경로는 환경변수 `GA_BIN`이 있으면 그것, 없으면 `<plugin>/core/bin/ga`다.

**이벤트별 처리**

| EVENT | `ga` 입력 | deny/block일 때 stdout | allow일 때 |
|---|---|---|---|
| `pre-write` | `tool_input.file_path`. NotebookEdit면 `tool_input.notebook_path` | `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":R}}` | **출력 없음.** 일반 권한 흐름을 유지하기 위해서다. "allow"를 출력하면 권한 확인을 건너뛰게 된다 |
| `pre-bash` | `tool_input.command` | 위와 같음 | 출력 없음 |
| `stop` | `stop_hook_active` | `{"decision":"block","reason":R}` | 출력 없음 |
| `user-prompt` | `prompt`를 임시 파일로 저장, `transcript_path` | `{"decision":"block","reason":R}` | `{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext": (ga rule) + "\n" + context}}` |
| `session-start` | 없음 | 해당 없음 | 컨텍스트가 비어 있지 않으면 `{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":ctx}}` |

**`ga`가 오류로 끝났을 때** (판정 JSON 없이 0이 아닌 코드로 끝남)
- `pre-write`, `pre-bash`: deny한다(fail-closed). 이유: "ga 오류: <stderr 첫 줄>. 복구: …"
- `stop`, `user-prompt`: 막지 않는다. 대신 `additionalContext`에 "ga 오류" 경고를 넣는다.
- 이유: stop과 user-prompt까지 막으면 사용자가 빠져나올 방법(`GA 일시정지`, 직접 수정)이 막힌다. (계획 판단)

**`hooks.json`**
- 이벤트 4개를 등록한다. PreToolUse는 matcher를 두 개 둔다: `Write|Edit|MultiEdit|NotebookEdit`와 `Bash`
- 명령 형식: `"\"${CLAUDE_PLUGIN_ROOT}/adapters/claude-code/hook.sh\" <event>"`

**`bin/ga`**
- `exec "<자기 위치>/../core/bin/ga" "$@"`. 심볼릭 링크를 따라가서 위치를 정한다.

**G6 경계 규칙**
- `hook.sh` 안에 단계 이름(`inputs`, `iterating`, `design-review`, `skeleton`, `implement`)이 나오면 안 된다. 판단 로직은 코어에만 둔다.

**`adapters/claude-code/capabilities.json`** (설계 문서 5.0 "어댑터별 강제력 선언")
```json
{"harness":"claude-code","write_block":true,"user_prompt_capture":true,"stop_check":true,"context_inject":true,
 "notes":"Bash 경유 쓰기는 최선 노력으로만 막는다. Stop 훅은 연속 8회 차단 후 해제된다."}
```

- [ ] **Step 1: 실패하는 테스트 작성**

이벤트 픽스처는 Hooks 레퍼런스의 입력 형식을 따른다. `cwd` 자리에는 `__ROOT__`를 두고 테스트에서 바꿔 넣는다.

```bash
ev() { sed "s#__ROOT__#$2#g" "$FIX/claude_events/$1.json"; }
hk() { "$PLUGIN/adapters/claude-code/hook.sh" "$1"; }
inputs_root() { r=$(mk_project); ga --root "$r" init >/dev/null; echo "$r"; }
test_pre_write_deny_shape() { r=$(inputs_root); out=$(ev write_src "$r" | hk pre-write); assert_eq deny "$(jq -r .hookSpecificOutput.permissionDecision <<<"$out")"; }
test_pre_write_allow_no_output() { r=$(inputs_root); assert_eq "" "$(ev write_archdoc "$r" | hk pre-write)"; }
test_notebook_path_used() { r=$(inputs_root); out=$(ev notebook_src "$r" | hk pre-write); assert_eq deny "$(jq -r .hookSpecificOutput.permissionDecision <<<"$out")"; }
test_pre_bash_deny_shape() { r=$(inputs_root); out=$(ev bash_redirect "$r" | hk pre-bash); assert_eq deny "$(jq -r .hookSpecificOutput.permissionDecision <<<"$out")"; }
test_stop_block_shape() { r=$(inputs_root); seed_ledger "$r" "$FIX/ledger_bad_asm.json"; assert_eq block "$(ev stop "$r" | hk stop | jq -r .decision)"; }
test_user_prompt_context_has_rule() { r=$(mk_project); out=$(ev prompt_plain "$r" | hk user-prompt); assert_contains "$(jq -r .hookSpecificOutput.additionalContext <<<"$out")" "근거 없는 가정"; }
test_user_prompt_block_shape() { r=$(inputs_root); assert_eq block "$(ev prompt_ga_unknown "$r" | hk user-prompt | jq -r .decision)"; }
test_session_start_shape() { r=$(inputs_root); assert_contains "$(ev session_start "$r" | hk session-start | jq -r .hookSpecificOutput.additionalContext)" "설계 진행 중"; }
test_adapter_fail_closed_on_ga_error() { r=$(inputs_root); s=$(mktemp); printf '#!/bin/bash\necho boom >&2; exit 9\n' >"$s"; chmod +x "$s"
  assert_eq deny "$(ev write_src "$r" | GA_BIN=$s hk pre-write | jq -r .hookSpecificOutput.permissionDecision)"; }
test_adapter_has_no_phase_logic() { assert_status 1 grep -E 'inputs|iterating|design-review|skeleton|implement' "$PLUGIN/adapters/claude-code/hook.sh"; }
test_adapter_declares_capabilities() { assert_eq 4 "$(jq '[.write_block,.user_prompt_capture,.stop_check,.context_inject]|map(type=="boolean")|map(select(.))|length' "$PLUGIN/adapters/claude-code/capabilities.json")"; }
```

- [ ] **Step 2: 실패 확인**

Run: `tests/run.sh tests/test_adapter_claude.sh`

Expected: FAIL

- [ ] **Step 3: 구현**

`hook.sh`, `hooks.json`, `bin/ga`를 만든다.

- [ ] **Step 4: 통과 확인**

Run: `tests/run.sh tests/test_adapter_claude.sh`

Expected: 11 PASS

- [ ] **Step 5: `bin/`이 PATH에 들어가는지 문서 확인**

- https://code.claude.com/docs/en/plugins-reference.md 에서 플러그인 `bin/`이 Bash 도구의 PATH에 추가되는지 확인하고, 결과를 `docs/notes/2026-11-21-install-check.md`에 적는다.
- **추가되지 않는다면:** `ga context session-start`가 상태 유무와 관계없이 `ga 실행 경로: <절대 경로>` 줄을 출력하도록 고친다. 그 동작을 확인하는 테스트(`test_session_context_prints_ga_path`)를 `tests/test_context.sh`에 추가한다.

- [ ] **Step 6: 전체 테스트**

Run: `tests/run.sh`

Expected: 모든 파일 PASS

- [ ] **Step 7: 커밋**

`git commit -m "feat(adapter): Claude Code hooks adapter"`

---

### Task 12: 스킬 두 개

**Files:**
- Create: `plugins/grounded-arch/skills/grounding/SKILL.md`, `plugins/grounded-arch/skills/design-architecture/SKILL.md`, `tests/test_skills.sh`

**Interfaces:**

Consumes:
- 모든 `ga` 공개 하위 명령
- Task 9의 GA 동사 목록. `usercmd.sh`에 `GA_VERBS` 변수(공백으로 구분한 문자열)로 정의해 두고 테스트가 읽는다.

Produces:

**`grounding/SKILL.md`**
- 머리말: `name: grounding`, `description`(한국어. 근거 규칙 전문을 볼 때 쓴다)
- 본문: `core/rules/grounding.md`와 **바이트 단위로 같아야** 한다. 원본은 하나만 두고, 같음을 테스트로 강제한다.

**`design-architecture/SKILL.md`**
- 머리말: `name: design-architecture`, `description`
- 명시적으로 호출할 때만 실행되게 하는 필드를 둔다. 필드 이름은 https://code.claude.com/docs/en/skills.md 에서 확인한다(예상: `disable-model-invocation: true`). 근거는 설계 문서 비목표 "명시적으로 호출할 때만 동작"이다.
- 본문(한국어)의 절:

| 절 | 내용 |
|---|---|
| 0. 원칙 | 근거 3등급 요약. 설계 단계에서는 코드를 쓰지 않는다. `.state`를 직접 고치지 않는다. 사용자 확인을 대신 기록하지 않는다. 승인을 몰아서 받지 않는다. `--bare`나 API 키를 쓰지 않는다 |
| 1. 시작 | `ga init` 실행 후 모드와 그 근거를 사용자에게 보고한다. `ga`가 PATH에 없으면 세션 시작 안내에 나온 경로를 쓴다 |
| 2. inputs | 설계 목적, 기능(현재와 미래, 3.6절 등급), 품질 속성 시나리오(측정 기준 필수), 고려사항, 제약을 각각 `ga add`로 기록한다. 기존 코드 모드면 현재 구조를 `fact`(`경로:줄`)와 `assumption`으로 기록한다. 반복 계획은 high 드라이버의 iteration으로 정한다. 이 단계에서 기술이나 구조를 고르지 않는다(설계 문서 5.3.0). 질문은 `ga ask`로 등록한 뒤 사용자에게 `GA 답 Q-n …` 형식으로 답해 달라고 안내한다. `ga render` → `ga verify` → 지적 처리(고치고 다시 verify, 또는 `ga dispute`) → 사용자에게 `GA 승인 입력`을 요청한다 |
| 3. iterating | 반복마다 ADD 2~7단계를 거친다. 설계 개념 후보를 2개 이상 비교해 `ga add decision`으로 기록한다(drivers 연결 필수). architecture.md 5절에 mermaid 구조도를 쓴다. 드라이버별 충족 여부를 분석한다. 반복이 끝나면 verify 후 `GA 승인 반복`을 요청한다 |
| 4. design-review | 전체 verify 후 `GA 승인 설계`를 요청한다 |
| 5. skeleton | 새 프로젝트: 폴더, 인터페이스, 빈 함수(본문은 미구현 표시)를 만든다. 기존 코드: `ga add mapping`으로 신규·변경 파일을 먼저 기록하고, 사용자에게 `GA 테스트명령 …` 지정을 요청한다. verify 후 `GA 승인 뼈대`를 요청한다 |
| 6. implement | 설계에서 벗어나면 `ga add decision`(`"deviation": true`)으로 기록하고, 사용자에게 `GA 확인 DEC-n`을 요청한다 |
| 7. 명령 표 | 에이전트용 `ga` 명령과 사용자용 `GA` 동사를 나눠서 정리한다 |

- [ ] **Step 1: 실패하는 테스트 작성**

```bash
test_skill_frontmatter() { for s in grounding design-architecture; do f="$PLUGIN/skills/$s/SKILL.md"; assert_eq "---" "$(head -1 "$f")"; assert_contains "$(sed -n '2,6p' "$f")" "name: $s"; assert_contains "$(sed -n '2,8p' "$f")" "description:"; done; }
test_grounding_skill_matches_rule_source() { body=$(awk 'f>=2{print} /^---$/{f++}' "$PLUGIN/skills/grounding/SKILL.md"); assert_eq "$(cat "$CORE/rules/grounding.md")" "$body"; }
test_skill_ga_commands_exist() { for c in $(grep -oE '\bga [a-z-]+' "$PLUGIN/skills/design-architecture/SKILL.md" | awk '{print $2}' | sort -u); do assert_status 0 grep -q "cmd_${c//-/_}()" "$CORE"/lib/*.sh "$CORE/bin/ga"; done; }
test_skill_user_verbs_exist() { . "$CORE/lib/usercmd.sh"; for v in $(grep -oE '\bGA [^ `.]+' "$PLUGIN/skills/design-architecture/SKILL.md" | awk '{print $2}' | sort -u); do assert_contains " $GA_VERBS " " $v "; done; }
```

- [ ] **Step 2: 실패 확인**

Run: `tests/run.sh tests/test_skills.sh`

Expected: FAIL

- [ ] **Step 3: 구현**

스킬 두 개를 작성한다. 호출 제한 필드는 Skills 문서로 확인한 이름을 쓴다.

- [ ] **Step 4: 통과 확인**

Run: `tests/run.sh tests/test_skills.sh`

Expected: 4 PASS

- [ ] **Step 5: 커밋**

`git commit -m "feat(skills): grounding and design-architecture skills"`

---

### Task 13: 전 과정 시험과 설치 확인

**Files:**
- Create: `tests/test_e2e.sh`, `docs/notes/2026-11-21-install-check.md`(Task 11에서 만들었으면 내용 추가)

**Interfaces:**

Consumes: 모든 것. 시험은 `hook.sh`에 합성 이벤트를 넣고, 가짜 claude를 쓴다.

- [ ] **Step 1: 실패하는 시험 작성** (`tests/test_e2e.sh`)

**`test_e2e_greenfield_lifecycle`** (단계마다 단언 한 줄씩)
1. session-start의 컨텍스트가 비어 있다.
2. `ga init`
3. 드라이버(purpose, functional, quality high, iteration 1)를 추가하고, `ASM-1`을 추가하고, `Q-1`을 추가한 뒤 ask한다.
4. pre-write로 `src/a.c`를 쓰려 하면 deny다.
5. `GA 승인 입력`이 block되고, 이유에 `ASM-1`이 있다.
6. `GA 확인 ASM-1 …`과 `GA 답 Q-1 …`을 보내면 allow다.
7. `ga verify`의 exit가 0이다.
8. `GA 승인 입력` 후 phase가 iterating이다.
9. `DEC-1`(drivers에 quality 드라이버 포함)을 추가하고, verify한 뒤 `GA 승인 반복` 후 phase가 design-review다.
10. verify한 뒤 `GA 승인 설계` 후 phase가 skeleton이다.
11. pre-write로 `src/a.c`를 쓰면 출력이 없다(allow).
12. verify한 뒤 `GA 승인 뼈대` 후 phase가 implement다.

**`test_e2e_brownfield_skeleton`**
1. brownfield 프로젝트를 skeleton 단계로 놓는다.
2. `MAP-1 src/new.c new`를 추가한다.
3. `src/old.c`는 deny, `src/new.c`는 출력 없음(allow).
4. `GA 테스트명령 true`를 보낸다.
5. verify 후 `GA 승인 뼈대`가 allow다.

- [ ] **Step 2: 실패 또는 통과 확인 후 고치기**

Run: `tests/run.sh tests/test_e2e.sh`

Expected: 2 PASS. 실패하면 원인 Task의 코드를 고치고, 그 Task의 테스트도 다시 실행한다.

- [ ] **Step 3: 로컬 설치** (수동)

Run:
```bash
claude plugin marketplace add /Users/sungbin/git/Mine/ai-tools && claude plugin install grounded-arch@ai-tools
```

- 명령이 다르면 Plugins 문서의 명령을 쓴다.

Expected: 설치 성공 메시지

- [ ] **Step 4: 실제 세션 확인** (수동, 실제 구독 호출 포함)

1. 임시 디렉터리에서 `claude`를 실행한다.
2. `/design-architecture`를 호출한다. 작은 목적("할 일 목록 CLI") 하나로 시작한다.
3. 아래 다섯 가지를 확인한다:
   - (a) `ga`를 찾아 실행할 수 있다.
   - (b) inputs 단계에서 `src/` 쓰기가 거부된다.
   - (c) `GA 승인 입력`이 미해결 항목 때문에 막힌다.
   - (d) `ga verify`가 실제 패널을 구독으로 실행한다. 실행 전 `claude auth status`의 authMethod를 기록한다.
   - (e) superpowers brainstorming이 끼어드는지 관찰만 한다. 정식 확인은 Plan 2에서 한다.
4. 결과를 노트에 기록한다.

Expected: (a)~(d) 모두 확인. (e)는 관찰 결과만 기록한다.

- [ ] **Step 5: 커밋**

`git commit -m "test: end-to-end lifecycle and install check"`

---

## 이 계획에서 내린 판단 (설계 문서에 없거나 바꾼 것)

| 판단 | 이유 |
|---|---|
| 시범 평가는 Plan 2로 분리 | 사용자 참여(기존 프로젝트 선택, 합격 기준)가 필요하다 |
| 기존 코드 뼈대 단계의 빌드·테스트는 `ga verify`가 직접 실행하고, 명령은 사용자가 `GA 테스트명령`으로 지정 | 실행기에는 읽기 도구만 준다 |
| "수정함" 처리는 다시 검증하는 것으로 대신함 | 고치면 문서 해시가 바뀐다 |
| 문서 해시에서 상태, 해결, 답, 렌더 블록을 뺌 | 사용자가 확인할 때마다 다시 검증하는 일을 막는다 |
| 기본 패널은 opus, sonnet, fable | 메인 모델을 포함한다. `.state/panel.json`으로 바꿀 수 있다 |
| 설계 단계에서도 프로젝트 루트 밖 쓰기는 허용 | 게이트는 대상 프로젝트 안의 코드 쓰기를 막는 장치다 |
| `GA` 여러 줄은 원자적으로 처리 | 일부만 적용된 상태를 남기지 않는다 |
| 어댑터에서 `ga`가 오류로 끝나면 쓰기는 막고, stop과 user-prompt는 막지 않음 | 사용자가 빠져나올 길(`GA 일시정지` 등)을 남긴다 |
