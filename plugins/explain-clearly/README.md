# explain-clearly

Claude가 사용자에게 승인이나 방향 선택을 물을 때 늘 같은 양식으로 쓰게 하는 플러그인입니다. 그 밖의 글(진행 상황, 정할 일 없는 결과, 짧은 답)은 양식 없이 짧게 씁니다(2026-11-22 사용자).

## 하는 일

- 세션을 시작할 때와 대화가 압축된 뒤에 설명 양식 전문(`rules/guide.md`)을 Claude에게 넣습니다.
- 사용자가 메시지를 보낼 때마다 짧은 알림(`rules/reminder.md`)을 넣습니다.

전문은 세션당 한 번만 넣고, 매 메시지에는 알림만 넣습니다. 전문을 매번 넣으면 대화가 길어질수록 같은 글이 쌓여 컨텍스트를 낭비하기 때문입니다.

## 양식을 이렇게 정한 근거

- 결론을 먼저 쓰고, 독자가 모르는 것을 채워 주고, 용어는 처음 나올 때 정의한다.
  - https://en.wikipedia.org/wiki/BLUF_(communication)
  - https://developers.google.com/tech-writing/one/audience
  - https://developers.google.com/tech-writing/one/words
- 한 문장에 생각 하나, 짧은 문단.
  - https://digital.gov/guides/plain-language/writing/clear-short
- 핵심은 셋 이내, 실제로 겪을 예를 든다, 제목에는 주제가 아니라 요점을 쓴다.
  - https://www.gsb.stanford.edu/insights/how-make-complex-ideas-more-accessible
  - https://mitsloan.mit.edu/ideas-made-to-matter/curse-knowledge-why-experts-struggle-to-explain-their-work
- 규칙을 추상적인 문장으로만 주면 양식이 매번 달라진다. 그래서 양식 틀과 예시 3개를 넣고, "하지 마라" 대신 "이렇게 써라"로 쓰고, 규칙 글 자체를 원하는 출력 모양으로 쓰고, 이유를 함께 적었다.
  - https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices
- 훅 동작(세션 시작 훅은 압축 뒤에도 실행됨, 훅 출력은 10,000자까지 그대로 들어감, 플러그인 훅은 사용자 훅과 함께 실행됨).
  - https://code.claude.com/docs/en/hooks
  - https://code.claude.com/docs/en/plugins-reference

## 설치와 끄기

- 설치: `claude plugin marketplace add <이 저장소 경로>` 다음 `claude plugin install explain-clearly@ai-tools`
- 끄기: `claude plugin disable explain-clearly@ai-tools`
- 양식 바꾸기: `rules/guide.md`와 `rules/reminder.md`를 고칩니다. 둘의 순서와 이름표를 같게 유지합니다.
