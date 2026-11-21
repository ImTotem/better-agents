# 설치 확인 기록

## 플러그인 `bin/`이 Bash 도구의 PATH에 들어가는가 (Task 11 Step 5)

결과: **들어간다.** 그래서 `ga context session-start`에 실행 경로 줄을 추가하지 않았다. `context.sh`는 바꾸지 않았다.

출처: https://code.claude.com/docs/en/plugins-reference.md (Executables 행)

인용: "Files here are on the Bash tool's `PATH` while the plugin is enabled, so Claude runs them as bare commands."

주의: 같은 문서에 따르면 claude.ai와 Cowork는 `bin/` 디렉터리가 있는 플러그인을 설치하지 않는다. Claude Code CLI/데스크톱에서만 `ga`가 PATH에 잡힌다.
