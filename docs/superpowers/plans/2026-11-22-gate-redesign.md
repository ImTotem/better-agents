# 게이트 재설계 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 셸 명령 글자 검사를 없애고, 운영체제 격리(쓰기 금지) + MCP 도구 + 결과 확인(파일 변경, 상태 지문)으로 게이트를 다시 만든다.

**Architecture:** 막는 일은 하네스의 운영체제 격리가 한다(Claude Code는 `sandbox.*` 설정). 에이전트가 상태를 바꾸는 `ga` 기능은 격리 밖에서 도는 MCP 서버 도구로만 준다. 단계 규칙과 상태 무결성은 실행 결과(바뀐 파일, 상태 지문)로 확인한다. 코어는 하네스를 모르고, 격리 설정은 어댑터의 `enforce.sh`가 맡는다(G6).

**Tech Stack:** bash 3.2, `/usr/bin/jq`, git(있으면), MCP stdio(JSON-RPC 2.0, 줄 단위)

**Spec:** `docs/specs/2026-11-21-grounded-architecture-design.md` 5.5 (2026-11-22 개정), 근거와 대안: `docs/specs/2026-11-22-gate-redesign.md`, 조사 노트 `docs/notes/2026-11-22-research-*.md`

## Global Constraints

이전 계획(`docs/superpowers/plans/2026-11-21-grounded-arch-v1.md`)의 Global Constraints를 그대로 따른다(런타임, 과금, 테스트, 훅, `.state/` 쓰기 규칙, 언어, ID 형식, 사용자 명령). 아래만 바뀌거나 더해진다.

- **셸 명령 글자 검사 금지.** 명령 문자열을 해석해 어떤 파일을 쓸지 추측하는 코드를 새로 만들지 않는다. Bash 훅은 격리 설정 상태만 본다.
- **격리 설정은 어댑터 몫.** 코어는 `adapters/<하네스>/enforce.sh`를 부르기만 한다. 코어에 Claude Code 설정 경로를 쓰지 않는다.
- **에이전트용 쓰기는 MCP로만.** MCP 도구 목록에 `user-command`, `gate`에 해당하는 도구를 절대 넣지 않는다. 테스트로 확인한다.
- **상태 지문 저장 위치:** `${GA_DATA_DIR:-$HOME/.local/state/grounded-arch}/<루트 경로의 sha256>.json`. 테스트는 `GA_DATA_DIR`을 임시 폴더로 둔다.
- **사용자 명령 추가:** `GA 상태승인` (지금 상태 폴더를 새 기준으로 받아들임, 사용자만).
- **성능:** 훅 한 번은 파일 1만 개 git 저장소에서 1초 안에 끝나야 한다(측정해서 보고).

## Review Focus

1. 격리 설정 파일을 합쳐 쓸 때 사용자가 이미 둔 설정(권한, 다른 sandbox 키, 배열)을 지우거나 덮지 않는다.
2. 워크트리 세션에서는 본 체크아웃의 `.claude/settings.local.json`에 써야 한다(Claude Code가 그 파일을 읽음). 워크트리 자신의 `.claude`에 쓰면 격리가 켜지지 않는다.
3. 결과 확인은 설계 단계 시작 전부터 바뀌어 있던 파일(사용자가 작업 중이던 파일)을 위반으로 잡지 않는다. 시작 때 기록한 해시와 같으면 통과다.
4. 에이전트가 커밋해 버린 변경도 잡는다(기준 커밋 대비 diff).
5. MCP 서버가 잘못된 JSON, 모르는 메서드, 모르는 도구에 JSON-RPC 오류로 답하고 죽지 않는다.

## 파일 구조

| 파일 | 할 일 |
|---|---|
| `core/lib/effect.sh` (새) | 파일 변경 기록과 확인 |
| `core/lib/fingerprint.sh` (새) | 상태 지문 기록과 확인 |
| `core/mcp/server.sh` (새) | MCP stdio 서버, 도구 → `ga` 하위 명령 연결 |
| `core/lib/gates.sh` | 셸 글자 검사 삭제. `gate bash`는 격리 상태 확인만. 쓰기 게이트에 보호 경로 추가. stop에 결과 확인 추가 |
| `core/lib/usercmd.sh` | 단계 전환 때 스냅샷, 승인 전 결과 확인, `GA 상태승인` |
| `core/lib/state.sh`, `core/bin/ga` | `ga init`이 스냅샷, 지문, 어댑터 `enforce.sh install` 호출 |
| `adapters/claude-code/enforce.sh` (새) | `install ROOT`, `status ROOT` |
| `adapters/claude-code/hook.sh` | Bash 훅이 `ga gate bash` 결과(격리 상태)만 전달 |
| `.mcp.json` (플러그인 루트, 새) | MCP 서버 등록, `GA_HARNESS=claude-code` 전달 |
| `skills/design-architecture/SKILL.md` | 쓰기는 MCP 도구로, `GA 상태승인` 설명 |
| `adapters/claude-code/capabilities.json` | 한계 메모 갱신 |
| `tests/test_effect.sh`, `test_fingerprint.sh`, `test_mcp.sh`, `test_enforce_claude.sh` (새), `test_gates.sh`(대폭 축소), `test_usercmd.sh`, `test_e2e.sh` | |

---

### Task 1: 결과 확인 — 파일 변경

**Files:** Create `core/lib/effect.sh`, `tests/test_effect.sh`. Modify `core/lib/usercmd.sh`(전환 지점에서 스냅샷 호출), `core/lib/state.sh`(init에서 스냅샷).

**Interfaces:**
- Produces: `ga_effect_snapshot ROOT` → `.state/snapshot.json` 기록 (`{"kind":"git","base":"<커밋>","dirty":{"<경로>":"<해시>"}}` 또는 `{"kind":"files","files":{"<경로>":"<크기>:<mtime>"}}`)
- Produces: `ga_effect_check ROOT` → stdout JSON `{"changed":[…],"violations":[…]}`, 위반 있으면 rc 1
- Produces: `ga effect check` 하위 명령(사람과 훅이 쓰는 표시용)

- [ ] **Step 1: 실패하는 테스트**
  - `test_effect_design_phase_src_change_is_violation`: git 저장소, iterating, 스냅샷 뒤 `src/a.c` 수정 → violations에 `src/a.c`
  - `test_effect_docs_architecture_change_allowed`: 같은 조건에서 `docs/architecture/architecture.md` 수정 → violations 비어 있음
  - `test_effect_preexisting_dirty_file_not_violation`: 스냅샷 전부터 수정돼 있던 `src/b.c`가 그대로면 위반 아님, 그 뒤 더 바뀌면 위반
  - `test_effect_committed_change_caught`: 스냅샷 뒤 `src/a.c`를 커밋 → 위반
  - `test_effect_untracked_new_file_caught`: 새 파일 `src/new.c` → 위반
  - `test_effect_deleted_file_caught`: 추적 중인 `src/old.c` 삭제 → 위반
  - `test_effect_brownfield_skeleton_mapping_allowed`: 대응표 `src/x.c`(변경) 수정 허용, `src/y.c` 수정은 위반
  - `test_effect_implement_unrestricted_except_protected`: implement에서 `src/*` 자유, `.claude/settings.local.json` 변경은 위반
  - `test_effect_non_git_project`: git 없는 프로젝트에서 크기·mtime 비교로 같은 결과
  - `test_effect_ignores_build_dirs_non_git`: git 없을 때 `node_modules`, `.git`, `target`, `build`, `dist` 제외
  - `test_effect_speed_10k_files`: 파일 1만 개 git 저장소에서 `ga_effect_check` < 1초 (측정값 출력)
- [ ] **Step 2: RED 확인** — `bash tests/run.sh tests/test_effect.sh` → 함수 없음으로 실패
- [ ] **Step 3: 구현.** git이면 `git rev-parse HEAD`, `git diff --name-only -z <base>`(작업 트리 포함), `git ls-files -o --exclude-standard -z`, 해시는 `git hash-object`. 스냅샷 때 이미 바뀐 파일은 해시를 기록해 두고 같으면 제외. git 없으면 `find … -prune` + `stat -f '%z:%m'`(macOS)/`stat -c`(Linux) 분기. 허용 목록은 설계서 5.5 G-effect 표 그대로.
- [ ] **Step 4: 전환 지점 연결.** `ga init`, `GA 승인 …`(모든 단계 전환), `GA 되돌리기`, `GA 새라운드`에서 전환 직후 `ga_effect_snapshot`.
- [ ] **Step 5: GREEN** — 해당 테스트 파일과 `tests/test_usercmd.sh`
- [ ] **Step 6: 커밋**

### Task 2: 결과 확인 — 상태 지문

**Files:** Create `core/lib/fingerprint.sh`, `tests/test_fingerprint.sh`. Modify `core/lib/common.sh`(상태 쓰기 끝에서 기록), `core/lib/usercmd.sh`(`GA 상태승인`, `GA_VERBS`).

**Interfaces:**
- Produces: `ga_fp_path ROOT`, `ga_fp_record ROOT`(상태 폴더 전체 파일 이름+내용 해시를 정렬해 sha256), `ga_fp_check ROOT` → rc 0 일치 / 1 불일치 / 2 기록 없음
- Produces: 사용자 명령 `GA 상태승인`(인자 없음, 뒤에 글자 있으면 막음) → `ga_fp_record` + approvals.jsonl에 기록

- [ ] **Step 1: 실패하는 테스트**
  - `test_fp_recorded_after_ga_write`: `ga add` 후 지문 파일이 `GA_DATA_DIR` 아래 생김
  - `test_fp_mismatch_after_direct_edit`: `state.json`을 jq로 직접 고치면 `ga_fp_check` rc 1
  - `test_fp_ledger_direct_edit_detected`: `ledger.json`, `approvals.jsonl` 직접 수정도 rc 1
  - `test_fp_user_accept_rebaselines`: `GA 상태승인` 후 rc 0, approvals.jsonl에 기록
  - `test_fp_accept_trailing_text_blocked`: `GA 상태승인 지금` → 막힘
  - `test_fp_store_outside_project`: 지문 경로가 루트 밖
- [ ] **Step 2: RED 확인**
- [ ] **Step 3: 구현.** 모든 상태 쓰기는 이미 `ga_write_json`과 잠금을 지난다. 잠금을 풀기 직전(`ga_unlock`에서 깊이가 0이 될 때)에 `ga_fp_record`를 부른다. 저장 위치 폴더가 없으면 만든다.
- [ ] **Step 4: GREEN, 커밋**

### Task 3: MCP 서버

**Files:** Create `core/mcp/server.sh`, `plugins/grounded-arch/.mcp.json`, `tests/test_mcp.sh`.

**Interfaces:**
- Consumes: `ga` 하위 명령 `init add update ask resolve render check status verify rule`
- Produces: 도구 이름 `ga_init ga_add ga_update ga_ask ga_resolve ga_render ga_check ga_status ga_verify ga_rule`. 각 도구 인자는 해당 하위 명령 인자를 JSON으로 받는다(예: `ga_add {"kind":"assumption","item":{…}}`, `ga_update {"id":"ASM-1","patch":{…}}`). 결과는 `content:[{type:"text",text:<stdout+stderr>}]`, 실패면 `isError:true`.
- 루트: 인자 `root`가 있으면 그것, 없으면 `CLAUDE_PROJECT_DIR`, 없으면 오류.
- `.mcp.json`: `{"mcpServers":{"ga":{"command":"${CLAUDE_PLUGIN_ROOT}/core/mcp/server.sh","env":{"GA_HARNESS":"claude-code"}}}}`

- [ ] **Step 1: 실패하는 테스트** (서버에 JSON 줄을 파이프로 넣고 응답 줄을 jq로 본다)
  - `test_mcp_initialize`: `initialize` → `result.protocolVersion`이 요청한 버전, `capabilities.tools` 있음
  - `test_mcp_tools_list_exact`: 도구 이름 집합이 위 10개와 정확히 같고 `user`나 `gate`가 들어간 이름이 없음
  - `test_mcp_add_then_status`: `ga_init` → `ga_add` → `ga_status` 결과에 항목이 보임
  - `test_mcp_tool_error_is_iserror`: 잘못된 항목 → `isError:true`, 서버는 다음 요청에 계속 답함
  - `test_mcp_bad_json_and_unknown_method`: 깨진 JSON → `-32700`, 모르는 메서드 → `-32601`, 모르는 도구 → 오류
  - `test_mcp_notifications_no_reply`: `notifications/initialized`에는 답하지 않음
  - `test_mcp_verify_sends_progress`: 가짜 claude가 느리게 끝날 때 `progressToken`이 있으면 `notifications/progress`를 보냄 (가짜 `.sleep` 사용)
- [ ] **Step 2: RED 확인**
- [ ] **Step 3: 구현.** `while IFS= read -r line` 루프, 요청마다 jq로 메서드와 id를 뽑아 분기. `protocolVersion`은 MCP 명세의 현재 버전을 공식 문서에서 확인해 쓰고 출처를 보고서에 적는다. 도구 실행은 `ga --root <루트> <하위 명령>`을 자식 프로세스로 돌린다. 검증은 백그라운드로 돌리며 60초마다 진행 알림을 보낸다.
- [ ] **Step 4: GREEN, 커밋**

### Task 4: Claude Code 어댑터 — 격리 설정

**Files:** Create `adapters/claude-code/enforce.sh`, `tests/test_enforce_claude.sh`. Modify `core/lib/state.sh`(`ga init`이 `adapters/$GA_HARNESS/enforce.sh install`을 부름; `GA_HARNESS`가 없으면 부르지 않고 경고).

**Interfaces:**
- Produces: `enforce.sh install ROOT` → 설정 파일 경로를 출력, rc 0. `enforce.sh status ROOT` → `{"active":bool,"reason":"…","settings":"<경로>"}`
- 설정 파일 위치: ROOT가 속한 저장소의 본 체크아웃 맨 위(`.git`이 파일이면 그 안의 `gitdir` → `commondir`을 따라 본 저장소를 찾음; git 명령 호출 없이), git이 아니면 ROOT. 그 아래 `.claude/settings.local.json`.
- 합쳐 쓸 내용: 설계서 5.5 G-sandbox 목록. `denyWrite`는 기존 배열과 합집합.
- `status` 판단: 관리 설정(macOS `/Library/Application Support/ClaudeCode/managed-settings.json`, Linux `/etc/claude-code/managed-settings.json`), `~/.claude/settings.json`, 프로젝트 `.claude/settings.json`, 위 로컬 파일을 우선순위대로 읽어 `sandbox.enabled`가 참, `allowUnsandboxedCommands`가 거짓, `denyWrite`에 상태 폴더 절대 경로가 있으면 active.

- [ ] **Step 1: 실패하는 테스트**
  - `test_enforce_install_creates_settings`: 빈 프로젝트 → 설정 파일에 세 키와 denyWrite
  - `test_enforce_install_merges_existing`: 기존 `permissions.allow`, `sandbox.network.allowedDomains`, 다른 denyWrite 항목이 보존됨
  - `test_enforce_install_idempotent`: 두 번 실행해도 denyWrite 중복 없음
  - `test_enforce_worktree_writes_main_checkout`: `.git` 파일을 가진 워크트리 ROOT → 본 체크아웃의 `.claude/settings.local.json`에 씀, denyWrite는 워크트리의 상태 폴더 절대 경로
  - `test_enforce_git_exclude_added`: 본 저장소 `.git/info/exclude`에 `.claude/settings.local.json` 한 번만 추가
  - `test_enforce_status_inactive_when_user_disables`: 로컬 파일은 켜져 있어도 관리 설정이 `allowUnsandboxedCommands: true`면 inactive (관리 설정 경로는 테스트에서 `GA_TEST_MANAGED_SETTINGS`로 바꿈, `GA_TEST_MODE=1`일 때만)
  - `test_enforce_status_active`: install 직후 active
- [ ] **Step 2: RED 확인**
- [ ] **Step 3: 구현** (jq로 합치기, 임시 파일 + mv)
- [ ] **Step 4: GREEN, 커밋**

### Task 5: 게이트 다시 연결

**Files:** Modify `core/lib/gates.sh`, `adapters/claude-code/hook.sh`, `hooks/hooks.json`(필요하면), `core/lib/context.sh`, `core/lib/usercmd.sh`. 테스트 `tests/test_gates.sh`, `tests/test_adapter_claude.sh`, `tests/test_usercmd.sh`, `tests/test_context.sh`.

**Interfaces:**
- `ga gate bash`: 명령 글자를 읽지 않는다. 설계 진행 중(일시정지 아님)이면 `adapters/$GA_HARNESS/enforce.sh status`가 active일 때만 allow, 아니면 deny + 복구 안내("MCP 도구 `ga_init`을 다시 실행하거나 사용자에게 `GA 일시정지`를 요청"). `GA_HARNESS`는 훅 어댑터가 넘긴다.
- `ga gate write`: 지금 규칙 + 설계서 5.5 G-write 추가 경로.
- `ga gate stop`: 지금 형식 오류 검사 + `ga_effect_check` 위반 + `ga_fp_check` 불일치 → block, 이유에 파일 목록.
- 승인(`GA 승인 …`): 전제 조건에 effect 위반 없음, 지문 일치 추가.
- 지문 불일치 동안: 쓰기 게이트와 MCP 쓰기 도구도 거부(이유: "상태가 ga 밖에서 바뀌었습니다. 사용자가 확인 후 `GA 상태승인`").
- SessionStart 문맥: 격리 상태(active/inactive와 이유), 지문 상태를 한 줄로.

- [ ] **Step 1: 테스트 정리.** 셸 글자 검사를 확인하던 테스트를 지운다(목록을 보고서에 적는다). 새 테스트:
  - `test_gate_bash_ignores_command_text`: 격리 active면 `rm -rf docs/architecture/.state`, `bash hook.sh user-prompt`, `git clean -fdx ..` 모두 allow (막는 일은 운영체제 몫)
  - `test_gate_bash_denies_when_enforcement_inactive`: 설정 없음 → deny, 이유에 복구 안내
  - `test_gate_bash_allows_without_design_or_paused`
  - `test_gate_write_denies_settings_and_fp_store`
  - `test_gate_stop_blocks_on_effect_violation`, `test_gate_stop_blocks_on_fp_mismatch`
  - `test_approval_blocked_by_effect_violation`, `test_approval_blocked_by_fp_mismatch`
  - `test_gate_bash_speed`: 명령 100개 연속 처리 평균 < 100ms
  - `test_read_commands_write_nothing`: 상태 폴더를 `chmod -R a-w`로 막아도 `ga status`, `ga check`, `ga rule`이 성공한다(격리 안 셸에서 읽기 명령이 잠금 파일조차 만들지 않음)
  - `test_cli_write_permission_error_names_mcp_tool`: 상태 폴더가 쓰기 금지일 때 셸의 `ga add`가 실패하고 메시지에 `ga_add` 도구 이름이 나온다
- [ ] **Step 2: RED 확인**
- [ ] **Step 3: 구현.** `gates.sh`의 셸 글자 검사 함수들을 지운다. 쓰기 게이트와 stop은 남긴다.
- [ ] **Step 4: 전체 테스트 GREEN, 커밋**

### Task 6: 스킬과 문서

**Files:** `skills/design-architecture/SKILL.md`, `adapters/claude-code/capabilities.json`, `core/rules/grounding.md`(바뀌는 내용 있으면), `tests/test_skills.sh`.

- [ ] **Step 1:** 스킬에서 상태를 바꾸는 `ga …` 셸 예시를 MCP 도구 호출로 바꾼다(도구 이름 `mcp__plugin_grounded-arch_ga__ga_add` 형식, 출처: plugins-reference). 읽기 명령은 셸 그대로 둔다. `GA 상태승인`과 결과 확인(왜 턴 종료가 막히는지)을 설명한다. 300줄 이하, 다시 읽기 안내는 맨 앞 15줄 안.
- [ ] **Step 2:** `test_skills.sh`의 "스킬에 나온 `ga` 하위 명령이 존재" 검사를 MCP 도구 이름 검사로 바꾼다(스킬에 나온 도구 이름이 서버 도구 목록에 모두 있음).
- [ ] **Step 3:** capabilities.json에 새 한계를 적는다: 윈도우 격리 없음, 격리 꺼지면 셸 차단, 에이전트가 Write로 쓰는 경로는 정확히 막힘, 셸 쓰기는 운영체제가 막고 결과 확인이 한 번 더 봄.
- [ ] **Step 4:** 전체 테스트, 커밋

### Task 7: 마무리

- [ ] **Step 1:** `tests/test_e2e.sh`를 새 흐름으로 고친다: MCP로 init → 항목 추가 → 사용자 승인 → 스냅샷 → 허용 밖 변경 → stop 막힘 → 되돌림 → 통과.
- [ ] **Step 2:** 전체 테스트 두 번 연속 PASS, 병렬 검증 반복(`par.sh` 방식) 실패 0.
- [ ] **Step 3:** 전체 브랜치 검토(가장 능력 있는 모델) → 수정 → 범위 한정 재검토.
- [ ] **Step 4 (사용자 확인 후):** 플러그인 설치와 실사용 테스트. 확인할 것: 격리가 실제로 `docs/architecture/.state` 쓰기를 막는가(예: 에이전트가 `rm -rf docs/architecture/.state` 시도), MCP 도구가 보이고 동작하는가, 네트워크 허가 질문 횟수, 결과 확인이 설계 단계 코드 변경을 잡는가.

## 이 계획에서 내린 판단

| 판단 | 이유 |
|---|---|
| MCP 서버를 bash+jq로 만든다 | 런타임 제약(bash 3.2, jq만). MCP stdio는 줄 단위 JSON이라 충분하다 |
| `ga gate`, `user-command`는 MCP에 없다 | 설계서 5.5: 사용자 명령은 훅만 처리 |
| 지문 기록 시점은 잠금 해제 직전 | 모든 상태 쓰기가 잠금을 지나므로 빠짐없이 한 곳에서 기록된다 |
| 결과 확인은 Stop과 승인에서만 한다 | 매 도구 호출마다 하면 느리다. 턴 단위로 잡아도 승인 전에는 반드시 걸린다 |
| 셸 글자 검사 테스트는 지운다 | 그 동작 자체를 없애는 것이 이번 결정이다 |
| (실행 전 점검) `ga`가 직접 쓴 어댑터 설정 파일은 스냅샷에서 그 경로만 새 기준으로 잡는다. `ga init`은 격리 설정을 먼저 쓰고 첫 스냅샷을 찍는다 | 설계서 표(에이전트의 `.claude` 설정 변경은 위반)를 지키면서 `ga`의 정당한 쓰기를 위반으로 잡지 않기 위해 |
| (실행 전 점검) `ga enforce` 하위 명령과 MCP 도구 `ga_enforce`를 더한다(Task 4, Task 3). 도구는 11개 | 격리 설정이 빠졌을 때 에이전트가 고칠 수단이 필요하다. `ga init`은 이미 있는 상태를 거부한다 |
| (실행 전 점검) 지문 불일치 때 쓰기 거부는 코어의 쓰기 명령들이 한다. `user-command`는 예외 | CLI와 MCP가 함께 따르고, 사용자는 `GA 상태승인`으로 풀 수 있다 |
| (실행 전 점검) 지문은 실제로 상태 파일을 쓴 명령만 기록한다 | 격리 안 셸의 읽기 명령이 프로젝트 밖 저장 위치를 건드리지 않게 |
| (실행 전 점검) 셸 글자 검사를 지워 깨지는 테스트는 Task 5가 모두 고친다 | 단계마다 전체 테스트가 통과해야 한다 |
