# better-agents

AI 코딩 에이전트가 일을 제대로 하게 돕는 플러그인 모음입니다. 지금은 Claude Code용 플러그인 두 개가 있고, 다른 에이전트 도구(Codex, Gemini CLI, Grok CLI, OpenCode)용 어댑터는 나중에 붙일 수 있게 만들었습니다.

## 들어 있는 것

| 플러그인 | 하는 일 |
|---|---|
| `grounded-arch` | 코드를 쓰기 전에 아키텍처를 위에서 아래로 설계하게 합니다. 모든 판단에 근거 등급(확정, 근거 있는 가정, 근거 없는 가정)을 붙이고, 설계 단계마다 사용자 승인을 받아야 다음 단계로 갑니다. 여러 모델이 설계를 검증합니다. |
| `explain-clearly` | 에이전트가 사용자에게 승인이나 방향 선택을 물을 때 늘 같은 양식으로 쓰게 합니다. |

## 설치 (Claude Code)

```bash
claude plugin marketplace add ImTotem/better-agents
```

```bash
claude plugin install grounded-arch@better-agents
```

```bash
claude plugin install explain-clearly@better-agents
```

`grounded-arch`는 설치한 뒤 설계할 프로젝트에서 `/design-architecture`로 시작합니다. 자세한 동작은 `plugins/grounded-arch/skills/design-architecture/SKILL.md`에 있습니다.

## 필요한 것

- macOS(Seatbelt) 또는 Linux(bubblewrap). 셸 명령은 Claude Code의 운영체제 격리 안에서 돕니다. 윈도우는 WSL에서만 격리됩니다.
- bash 3.2 이상과 `jq`(`/usr/bin/jq`, `/opt/homebrew/bin/jq`, `/usr/local/bin/jq` 중 하나).
- 검증 패널은 구독 요금제로 쓰는 CLI(`claude` 등)만 부릅니다. API 키나 토큰별 과금 경로는 쓰지 않습니다.

## 무엇을 막고 무엇을 막지 않나

- 막는 것: 에이전트가 쉽게 할 수 있는 우회입니다. 셸이나 쓰기 도구로 설계 기록과 승인 기록을 지우거나 고치기, 설정 파일을 고쳐 격리 끄기, 플러그인 파일을 고쳐 게이트 끄기, 단계 밖 파일 쓰기, 사용자 대신 승인하기가 여기에 해당합니다.
- 막지 않는 것: 같은 사용자 권한으로 작정하고 짠 공격입니다. 완전히 막으려면 에이전트를 별도 사용자 계정이나 컨테이너에서 돌려야 합니다.

설계 문서: `docs/specs/2026-11-21-grounded-architecture-design.md`
