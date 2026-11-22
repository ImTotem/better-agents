# 게이트 다시 설계 — 제안

- 상태: 안 1로 결정 (사용자, 2026-11-22 "운영체제로 막기"). 설계서 5.5에 반영함.
- 바꾸는 곳: `docs/specs/2026-11-21-grounded-architecture-design.md` 5.5 게이트
- 근거 표시: (확정: 출처) 직접 근거 / (근거 있는 가정: …) 간접 근거, 다음 단계 전에 확인 / (추론) 내 판단
- 조사 원문: `docs/notes/2026-11-22-research-claude-sandbox.md`, `docs/notes/2026-11-22-research-harness-sandboxes.md`, `docs/notes/2026-11-22-research-shell-parsing-limits.md`

## 1. 왜 다시 설계하나

### 1.1 현상

- 셸 명령을 막는 코드(`gates.sh`)는 수정 네 번 사이에 420줄에서 1,579줄로 늘었다. (확정: `git show <커밋>:plugins/grounded-arch/core/lib/gates.sh | wc -l`, 커밋 a1a8deb → 645fb30)
- 수정할 때마다 다음 검토에서 새로운 빈틈이나 잘못 막는 문제가 중요 등급으로 나왔다. (확정: `final-rereview.md`, `targeted-rereview.md`, `remaining-rereview.md`)
  - 빈틈 예: `cd . && rm -rf ../../docs/architecture/.state`, `cd <플러그인 폴더> && bash hook.sh user-prompt`, `git clean -fdx ..`
  - 잘못 막는 예: `rm -f *.o`, `git commit -m "fix ga gate output"`
  - 속도 예: `cd`가 여러 번 나오는 스크립트 하나를 검사하는 데 최대 66초

### 1.2 원인

지금 게이트는 명령 글자를 읽고, 그 명령이 실행되면 어떤 파일을 쓸지 미리 맞히려 한다. 셸에서는 이것을 실행 전에 알 수 없다.

- 글롭은 실행할 때 파일을 찾아 펼쳐진다: "pathname expansion is a dynamic search on the results of expansion and is not statically parsed." (확정: Greenberg & Blatt, POPL 2020, https://arxiv.org/abs/1907.05308)
- 펼침의 결과는 "statically unknowable and unboundable" 하다. (확정: SaSh, SOSP '26 — 원문 위치는 조사 노트)
- 실제 파일 쓰기가 `git`, `python`, `bash hook.sh`처럼 다른 프로그램 안에서 일어나면 명령 글자에는 드러나지 않는다. (확정: 이번 검토의 `git clean ..` 사례, Codex 권고 GHSA-w5fx-fh39-j5rw의 `git show --output` 사례)
- Claude Code 자신도 같은 방식에서 같은 종류의 우회가 보안 권고로 나왔다: GHSA-mhg7-666j-cqg4(파이프로 이은 `sed`·`echo`로 쓰기 제한 우회), GHSA-xq4m-mc3c-vvg3(`$IFS` 우회). (확정: https://github.com/anthropics/claude-code/security/advisories)
- Claude Code 문서: "Bash permission patterns that try to constrain command arguments are fragile." 그리고 명령 글자에 기대지 않는 강제 수단으로 격리 실행(샌드박스)을 가리킨다. (확정: https://code.claude.com/docs/en/permissions)
- 보안 설계 원칙: "Every access to every object must be checked for authority.", "Base access decisions on permission rather than exclusion." (확정: Saltzer & Schroeder 1975) 명령 모양을 나열해 막는 방식은 "제외 목록"이고, 인터프리터나 자식 프로세스 안의 쓰기는 검사를 거치지 않는다.

결론 (추론): 빈틈이 매번 새로 나온 것은 패치를 덜 해서가 아니다. 이 방식에서는 원래 그렇게 될 수밖에 없다. 막는 일은 명령 글자가 아니라 실제 파일 접근 단계에서 해야 한다.

## 2. 게이트가 지켜야 할 것

| 번호 | 지킬 것 | 지금 설계서 근거 |
|---|---|---|
| 지킴 1 | 설계 상태 폴더(`docs/architecture/.state`)는 `ga`만 바꾼다 | 5.5 G-write, 5.4 |
| 지킴 2 | 승인과 확인은 사용자가 직접 입력한 프롬프트로만 기록된다 | 5.5 G-approval, "사용자 확정은 훅만 기록" |
| 지킴 3 | 설계 승인 전에는 `docs/architecture/` 밖 코드를 쓰지 않는다. 기존 코드 뼈대 단계에서는 매핑된 파일만 쓴다 | 5.3, 5.5 G-write |
| 품질 | 평소 명령을 잘못 막지 않는다. 검사가 빠르다. 다른 하네스로 옮길 수 있다(G6) | 2 목표, A1~A6 |

## 3. 대안

### 안 1 (추천): 운영체제가 막고, 결과를 확인한다

1. **설계 상태 폴더와 플러그인 폴더를 운영체제가 막는다.** Claude Code의 셸 격리 실행(샌드박스)을 켜고 `sandbox.filesystem.denyWrite`에 두 폴더를 넣는다. 셸 명령과 그 명령이 띄운 모든 프로세스가 이 제한을 받는다. (확정: https://code.claude.com/docs/en/sandboxing — "the processes they start" 포함, 작업 폴더 안 하위 폴더 쓰기 금지가 문서에 나온 용도)
   - `allowUnsandboxedCommands: false`로 격리 밖 실행을 막고, `failIfUnavailable: true`로 격리를 못 켜면 조용히 넘어가지 않게 한다. 두 설정 모두 프로젝트 설정 파일에 둘 수 있다. (확정: 같은 문서, 설정 참조)
   - 셸 명령은 `.claude` 설정 파일을 못 바꾼다. 격리 실행이 항상 보호하는 경로이기 때문이다. (확정: 같은 문서 "Protected paths")
2. **에이전트가 쓰는 `ga` 기능은 플러그인이 띄우는 MCP 도구로 준다.** 원장 추가, 수정, 검증 같은 기능이다. MCP 서버는 격리 밖에서 돌기 때문에 설계 상태 폴더에 쓸 수 있다. 승인을 기록하는 도구는 MCP에 아예 넣지 않는다. (확정: 같은 문서 "local MCP servers … run with your full access"; 플러그인이 `.mcp.json`으로 MCP 서버를 함께 배포 가능, https://code.claude.com/docs/en/plugins-reference)
   - 그러면 에이전트가 셸에서 `ga user-command`나 `bash hook.sh`를 실행해도, 설계 상태 폴더에 쓰는 순간 운영체제가 막는다. 내부 명령을 찾아내는 글자 검사가 필요 없다. (추론)
3. **승인은 지금처럼 사용자 프롬프트 훅만 기록한다.** 훅은 격리 밖에서 돈다. (확정: 같은 문서)
4. **파일 쓰기 도구(Write, Edit)는 지금 게이트를 그대로 쓴다.** 이 도구는 격리 밖에서 돌지만 쓸 경로가 정확히 주어지므로 판단이 정확하다. 막는 대상은 설계 상태 폴더, 플러그인 폴더, `.claude/settings*.json`, `~/.claude/settings*.json`, 그리고 단계별 허용 경로 밖이다. (확정: 같은 문서 "the Read, Edit and Write tools" 격리 밖)
5. **지킴 3은 셸 명령을 미리 막지 않고 결과로 확인한다.**
   - 단계가 시작될 때 프로젝트 파일 목록과 지문을 기록해 둔다. git이 있으면 `git status`와 추적하지 않는 파일 목록을 쓰고, 없으면 파일별 크기와 수정 시각을 쓴다.
   - 매 턴이 끝날 때(Stop 훅)와 승인 직전에, 그 뒤로 바뀐 파일을 단계 허용 목록과 비교한다.
   - 허용 밖 변경이 있으면 승인과 턴 종료를 막고 파일 목록을 보여 준다.
   - 이 방식은 실제로 바뀐 파일을 보므로 명령 모양과 상관없이 정확하다. (추론)
6. **설계 상태 폴더도 결과로 한 번 더 확인한다.** `ga`가 상태를 쓸 때마다 지문(해시)을 남긴다. 훅이 돌 때마다 지금 지문과 비교해서 다르면 상태를 잠그고 사용자에게 알린다. 격리 실행이 꺼져 있거나 뚫린 경우를 위한 장치다. Claude Code 격리 실행에도 탈출 권고(GHSA-7835-87q9-rgvv)가 있었다. (확정: 해당 권고)
7. **셸 명령 글자 검사(약 1,400줄)는 지운다.**

장점:
- 막는 일을 운영체제가 해서 명령 모양과 상관없이 막힌다.
- 평소 명령을 잘못 막는 일이 없다. 결과 검사는 실제로 바뀐 파일만 보기 때문이다.
- 명령마다 하던 글자 분석이 없어져 검사가 빨라진다.

비용:
- 이 설계 도구를 쓰는 프로젝트에서는 격리 실행을 켜야 한다. 기본은 꺼져 있다. (확정: "The sandbox is off by default.")
- 격리 실행이 켜지면 그 프로젝트의 모든 셸 명령이 격리 안에서 돈다. 네트워크도 허용 목록 기준이어서, `npm install`처럼 인터넷을 쓰는 명령은 처음에 허가를 물을 수 있다. (근거 있는 가정: 문서에 `network.allowedDomains`가 있고 허용 밖 도메인은 물어본다고 되어 있음. 실제 동작은 설치 후 확인)
- 윈도우(WSL 아님)에서는 격리 실행이 없다. 그런 환경에서는 결과 확인만 동작한다. (확정: 문서)
- MCP 서버를 새로 만들어야 한다. bash와 jq로 만들지 다른 언어로 만들지는 구현 계획에서 정한다.

다른 하네스로 옮길 때:
- Codex CLI와 Grok CLI에는 운영체제 격리, 경로별 쓰기 설정, 훅, MCP가 모두 있다. (근거 있는 가정: 공식 문서 요약을 통해 확인함. 원문 재확인 필요)
- Gemini CLI는 격리와 훅, MCP는 있지만, 하위 폴더 하나만 쓰기 금지하는 설정은 문서에서 찾지 못했다.
- OpenCode에는 운영체제 격리가 없다. 따라서 결과 확인만으로 동작한다. (확정: OpenCode 문서 "runs with the host user's filesystem, process, and network authority")

### 안 2: 결과만 확인한다

- 격리 실행을 쓰지 않는다. 쓰기 도구 게이트와 결과 확인(안 1의 4~6번)만 둔다.
- 장점: 설정이 필요 없고, 모든 하네스에서 똑같이 동작하고, 평소 명령을 잘못 막지 않는다.
- 단점: 설계 상태 폴더 삭제나 승인 위조를 막지 못하고, 일어난 뒤에 알아챌 뿐이다. 에이전트가 지문 기록까지 함께 고치면 알아채지도 못한다. 지운 상태를 되살릴 백업도 따로 필요하다.

### 안 3 (기각): 지금 방식을 계속 고친다

- 1.2의 근거대로, 이 방식은 고칠수록 빈틈, 잘못 막는 문제, 느려짐이 함께 늘어난다.

### 검토했지만 뺀 것

- 제대로 된 셸 구문 분석기(구문 트리)로 바꾸기: 글롭, 변수, 다른 프로그램 내부 동작은 실행할 때 정해지므로 같은 문제가 남는다. (확정: 1.2 Smoosh 인용)
- `ga`를 격리 예외 명령(`excludedCommands`)으로 빼기: 문서가 "An excluded command runs with your full access"라고 경고한다. 에이전트가 예외 명령으로 다른 일을 할 수 있다. (확정: 샌드박스 문서)

## 4. 다음 단계 전에 확인할 것

- 근거 있는 가정 1 — 네트워크 허용 목록 때문에 묻는 횟수가 실사용에 거슬리지 않는다.
  - 근거: Anthropic이 격리 실행 도입 후 허가 질문이 84% 줄었다고 보고함.
  - 확인 방법: 설치 후 실사용 테스트에서 질문 횟수를 센다.
  - 기각한 대안 가정: "매번 묻는다" → 그렇다면 자주 쓰는 도메인을 `ga init`이 미리 넣는다.
- 근거 있는 가정 2 — 결과 확인을 매 턴마다 해도 충분히 빠르다.
  - 근거: `git status`는 큰 저장소에서도 보통 1초 안쪽이다. 이 값은 측정이 필요하다.
  - 확인 방법: 구현 때 파일 1만 개짜리 저장소에서 잰다.
- 사용자 결정: 격리 실행을 켜는 일을 `ga init`이 프로젝트 설정 파일(`.claude/settings.local.json`)에 직접 써도 되는지.

## 5. 바뀌는 범위 (안 1 기준)

| 부분 | 바뀜 |
|---|---|
| `core/lib/gates.sh` 셸 명령 검사 | 삭제 |
| 쓰기 도구 게이트 | 유지. `.claude/settings*.json` 보호를 추가 |
| 결과 확인(파일 목록, 지문, 상태 지문) | 새로 만듦. Stop 훅과 승인 처리에서 호출 |
| MCP 서버(원장, 검증 기능) | 새로 만듦. 승인 기능은 넣지 않음 |
| `ga init` | 격리 실행 설정을 프로젝트 설정에 씀(사용자 결정에 따름) |
| 원장, 검증 패널, 과금 점검, 사용자 명령 처리 | 유지 |
| 설계서 5.5, 구현 계획 | 고쳐 씀 |
