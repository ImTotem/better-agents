# Research: is static reading of shell command text a sound write-boundary?

All quotes were fetched this session (2026-11-22) via WebFetch/pdftotext; each is under 25 words. Quotes returned by WebFetch's summarizer are marked (S) where the page was summarized rather than read raw; verify before citing in a formal doc.

## 1. Shell cannot be analyzed precisely statically

- Greenberg & Blatt, "Executable Formal Semantics for the POSIX Shell" (POPL 2020, Smoosh). arXiv https://arxiv.org/abs/1907.05308 ; PDF https://cs.pomona.edu/~michael/papers/popl2020_smoosh.pdf (read from arXiv PDF via pdftotext).
  - "pathname expansion is a dynamic search on the results of expansion and is not statically parsed." (Sec. on words/expansion)
  - Shell state includes the environment and "aliases", i.e. runtime state; there are "read/eval loops" for the shell itself, `.` and `eval` (Smoosh AST discussion).
  - "We have left parsing out of our scope for now" (related-work/limits). Note: parsing itself is declared a separate hard problem.
  - Aim stated: "a semantics against which to prove static analyses sound" (Sec 1). No claim there that such analysis is achievable for arbitrary command text.
  - NOT FOUND: the literal phrase "undecidable" in this paper (grep returned nothing). Do not claim "proved undecidable" from this source.
- Lazarek, Lamprou, Kapetanakis, ... Greenberg, Kallas, Vasilakis, "Ahead-of-Time Analysis of Shell Program Effects" (SaSh), SOSP '26, https://doi.org/10.1145/3830418.3843861 , PDF https://atlas-group.cs.brown.edu/pdf/sash:sosp:2026.pdf . Closest primary source on exactly our question (statically predicting a shell program's file effects).
  - "Shell programs, however, are prone to subtle, severe, and often irreversible effects that are difficult to predict." (abstract)
  - "its highly dynamic expansion semantics, and the complex interactions among these features" (abstract)
  - "expansion can invoke arbitrary code whose results recursively shape the program under evaluation." (Sec 5)
  - "their results are statically unknowable and unboundable." (Sec 5)
  - Needs heavy machinery: symbolic execution, SMT solver, filesystem model, per-command specs; "identifies all but one instance of unwanted behavior" on 61 programs (abstract) - i.e. even a research-grade analyzer is a bug-finder, not a sound enforcer, and it is "optimistic" (abstract: "optimistic symbolic execution engine ... limits path explosion").
  - Related work separates it from sandboxes: sandboxes "operate during execution, while SaSh identifies bugs ahead of execution" (Sec on related work). Sandboxes isolate "a single, concrete program execution", SaSh reasons about many.
  - Also: ShellCheck-style syntactic approach is "brittle", "syntactic linters behind mere syntactic variations" (Sec 7) - supports that text-pattern checks are defeated by trivial rewrites.
- Implication: the static analysis is only as good as per-command specs (`python -c`, `git clean`, `bash hook.sh` are external programs whose effects are not in the shell text). Inference from sources, labeled as inference.

## 2. Advisories: command-text parsing/allowlists bypassed in coding agents (official GHSA, all fetched from github.com)

| GHSA / CVE | Product | Exact text | Fixed |
|---|---|---|---|
| GHSA-xq4m-mc3c-vvg3 / CVE-2025-66032 (High 8.7, CWE-77) https://github.com/anthropics/claude-code/security/advisories/GHSA-xq4m-mc3c-vvg3 | Claude Code | "Due to errors in parsing shell commands related to $IFS and short CLI flags, it was possible to bypass the Claude Code read-only validation" | v1.0.93 |
| GHSA-x56v-x2h6-7j34 / CVE-2025-54795 (High 8.7, CWE-78) https://github.com/anthropics/claude-code/security/advisories/GHSA-x56v-x2h6-7j34 | Claude Code | "Due to an error in command parsing, it was possible to bypass the Claude Code confirmation prompt to trigger execution of an untrusted command." | v1.0.20 |
| GHSA-mhg7-666j-cqg4 / CVE-2026-25723 (High 7.7) https://github.com/anthropics/claude-code/security/advisories/GHSA-mhg7-666j-cqg4 | Claude Code | "failed to properly validate commands using piped sed operations with the echo command, allowing attackers to bypass file write restrictions." ; "enabled writing to sensitive directories like the .claude folder" | v2.0.55 |
| GHSA-7835-87q9-rgvv / CVE-2026-55607 (High 7.7) https://github.com/anthropics/claude-code/security/advisories/GHSA-7835-87q9-rgvv | Claude Code | Sandbox escape via git worktree: "overwrite files in the user's home directory (such as .zshenv), leading to code execution outside of seatbelt sandbox restrictions" | 2.1.163 |
| GHSA-w5fx-fh39-j5rw https://www.pillar.security/blog/gitpwned-allowlist-to-rce | Codex CLI | Pillar: "Commands on this list bypass the sandbox, skip user approval, and execute with whatever privileges you have." Cause (search summary, not read in full): `git show --output` writes arbitrary files without shell metacharacters, so shell parsing gives no protection. Fixed v0.95.0. (Pillar's own text is inconsistent about which of two Codex escapes this ID names.) | v0.95.0 |
| GHSA-wpqr-6v78-jr5g https://osv.dev/vulnerability/GHSA-wpqr-6v78-jr5g | Gemini CLI | From search snippet only (advisory page NOT fetched directly): in --yolo mode the fine-grained allowlist `run_shell_command(echo)` was ignored, allowing any command; CWE-77/78; fixed 0.39.1. | 0.39.1 |

- Relevance: GHSA-mhg7 is the same class as our hook (protected-directory write restriction by command-text validation) and was bypassed with a pipe of two benign commands (sed + echo). GHSA-xq4m is a variable/`$IFS` bypass (same family as our "variables"). The Codex `git show --output` case matches our `git clean` pathspec issue: the dangerous effect is internal to an allowed program, invisible in the text.
- Secondary-only (not primary, flagged): reports that Claude Code skipped deny rules for commands with more than 50 subcommands (fixed v2.1.90, no GHSA ID found); and a quote attributed to Anthropic that deny rules "are not designed as a security barrier" - I could NOT confirm this in Anthropic material. Do not rely on either. Source list: https://dev.to/gentic_news/claude-codes-deny-list-bypass-how-to-protect-your-codebase-from-compound-commands-3dk2 , https://itbrief.com.au/story/claude-code-flaw-leaves-deny-rules-vulnerable-in-long-workflows
- Anthropic advisory index (titles only, https://github.com/anthropics/claude-code/security/advisories) also lists GHSA-5xjx-9qx6-jcrv "TOCTOU Race in Edit Tool Allows File Writes Outside the Workspace" (not opened).

## 3. Vendor/standards guidance: OS-level enforcement over command filtering

- Anthropic engineering post, https://www.anthropic.com/engineering/claude-code-sandboxing (S):
  - Frequent prompts cause "approval fatigue" where users "might not pay close attention to what they're approving."
  - Sandboxing yields "drastically fewer permission prompts and increased safety."
  - Filesystem isolation: Claude "can only access or modify specific directories." Both fs and network isolation are needed (S paraphrase).
  - Internal result: 84% fewer permission prompts (S; the latency/false-deny angle).
- Claude Code docs, https://code.claude.com/docs/en/sandboxing (S, page truncated at char 100000):
  - "The operating system enforces the sandbox boundary on the running process, so it holds regardless of what the model chose to run"
  - "Sandboxing, permission rules, and permission modes are complementary layers."
  - "These paths are enforced at the OS level, so all commands running inside the sandbox, including their child processes, respect them."
  - macOS "uses Seatbelt"; Linux "uses bubblewrap".
  - Limits to design around: "The sandbox covers shell commands only. Claude's file tools, MCP servers, and hooks run outside it." ; "On native Windows, Claude Code runs commands unsandboxed." ; with fs isolation off and auto-allow, "a sandboxed command can write files that later commands run or read".
  - Caveat from advisory GHSA-7835: the OS sandbox itself had a bypass (worktree/fsmonitor/.zshenv), so sandbox needs deny-writes on config/startup files and is not infallible.
- OpenAI Codex, https://learn.chatgpt.com/docs/agent-approvals-security (redirected from developers.openai.com/codex/agent-approvals-security) (S):
  - "Locally, Codex uses an OS-enforced sandbox that limits what it can touch (typically to the current workspace)"
  - "plus an approval policy that controls when it must stop and ask you before acting."
  - "`deny` always wins over `allow`" (rules).
  - Limits: "Devcontainers provide substantial protection, but they do not prevent every attack."
- OWASP Top 10 for LLM Apps 2025, LLM06 Excessive Agency, https://genai.owasp.org/llmrisk/llm062025-excessive-agency/ (S):
  - "Limit the permissions that LLM extensions are granted to other systems to the minimum necessary"
  - "Implement authorization in downstream systems rather than relying on an LLM to decide if an action is allowed or not."
  - "Avoid the use of open-ended extensions where possible"
  - Note: an arbitrary bash tool is the canonical open-ended extension.

## 4. Reference monitor / complete mediation

- Saltzer & Schroeder, "The Protection of Information in Computer Systems" (1975), HTML copy https://www.cs.virginia.edu/~evans/cs551/saltzer/ :
  - Complete mediation: "Every access to every object must be checked for authority." (S)
  - Fail-safe defaults: "Base access decisions on permission rather than exclusion." (S) - argues against denylist-by-text design; a protected-dir denylist of command shapes is exclusion-based.
  - Economy of mechanism and least privilege were mentioned in the page but exact definition text not retrieved.
- Anderson, "Computer Security Technology Planning Study" (USAF ESD-TR-73-51, Oct 1972): https://csrc.nist.gov/csrc/media/publications/conference-paper/1998/10/08/proceedings-of-the-21st-nissc-1998/documents/early-cs-papers/ande72.pdf - FAILED to give text: PDF is scanned images (JBIG2), pdftotext/WebFetch got nothing. Used Wikipedia https://en.wikipedia.org/wiki/Reference_monitor (S, secondary) instead:
  - "The reference validation mechanism must be Tamper-proof."
  - "The reference validation mechanism must be Always invoked."
  - "must be Evaluable, i.e., amenable to analysis and tests, the completeness of which can be assured (verifiable)."
  - Wikipedia also lists "Non-bypassable"; says Anderson attributed; in 2008 Denning said Anderson's source was a 1972 Graham & Denning paper.
  - Mapping (inference): a PreToolUse hook that must parse arbitrary shell text fails "always invoked/complete mediation" on the write path (effects occur in interpreters, git, child processes, hook.sh not seen by the parser) and "evaluable" (needs a full shell semantics; SaSh-scale machinery). Kernel-enforced sandbox (Seatbelt/bubblewrap) mediates at the syscall/file-open point where every write must pass.

## Sources that failed / were limited
- Anderson 1972 original text: scan-only PDF, no text extracted.
- cs.columbia.edu Smoosh PDF: 404; used arXiv copy.
- Codex developers.openai.com and learn.chatgpt.com/docs/security: redirects; /docs/security page had no sandbox content; used agent-approvals-security page.
- Gemini CLI GHSA-wpqr-6v78-jr5g and Codex GHSA-w5fx-fh39-j5rw: known only through search snippets and the Pillar blog, not the GHSA pages.
- Claude sandboxing doc: last ~12k chars not read.
- No source found proving "parsing bash is undecidable" outright. Strongest primary claims are "statically unknowable and unboundable" (SaSh) and dynamic pathname expansion (Smoosh). Do not overstate as a formal impossibility theorem.

## Bottom line (grounded vs. inference)
- Grounded: vendors themselves ship OS sandbox as the boundary and treat permission rules as a complementary layer; command-text validators in Claude Code and Codex have repeatedly been bypassed with GHSA IDs above, including one protecting a config directory (GHSA-mhg7). Research shows shell effects depend on runtime expansion and external-command semantics.
- Inference: your observed pattern (every round new bypass) is the expected behavior of this design class; redesign = OS sandbox for enforcement (write-deny on protected dir, plus startup/config files) + post-hoc effect check (e.g. diff/hash of protected dir, git status) as detective control, with the text hook demoted to a fast UX/early-warning layer. Caveats: hooks and file tools run outside the Claude sandbox; native Windows unsandboxed; sandbox escapes exist (GHSA-7835).
