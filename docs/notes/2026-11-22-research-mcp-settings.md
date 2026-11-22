# Research: Claude Code MCP / settings / hooks / sandbox (fetched 2026-11-22)
Pages fetched OK (as .md): https://code.claude.com/docs/en/{mcp,settings,settings-reference,env-vars,hooks,plugins-reference,sandboxing}. None failed. Local copies in scratchpad/docs/. All answers are docs-only, not verified empirically.
Base URL prefix below: https://code.claude.com/docs/en/

## 1. MCP tool-call timeout (mcp#time-limits-on-mcp-tool-calls, env-vars)
- Default: `MCP_TOOL_TIMEOUT` "Timeout in milliseconds for MCP tool execution (default: 100000000, about 28 hours)" (env-vars). A 15-minute call is far inside it.
- Per-server override: "adding a `timeout` field in milliseconds to that server's `.mcp.json` entry ... overrides the `MCP_TOOL_TIMEOUT` environment variable for that server only" (mcp). Values below 1000 ignored.
- "The per-server `timeout` is a hard wall-clock limit per tool call, and progress notifications from the server don't extend it." (mcp)
- Idle timeout: "A tool call to an MCP server that sends no response and no progress notification for the idle window aborts with an error". Defaults 5 min for HTTP/SSE/WS, "30 minutes for stdio servers". Env `CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT` (ms; 0 disables). Stdio idle applies from v2.1.203 ("Before v2.1.203, stdio servers were exempt"). A per-server timeout >=1000 is a floor on the idle window.
- Exceeded -> the call aborts with an error (idle case wording given; wall-clock wording not given).
- Stdio servers have no per-request timer (only HTTP/SSE/claude.ai have the 60 s one).
- Auto-backgrounding: "An MCP tool call in the main conversation that is still running after two minutes moves to a background task instead of blocking the session. Claude receives the task ID immediately" and the result arrives as a task notification (mcp#automatic-backgrounding-of-long-tool-calls). `CLAUDE_CODE_MCP_AUTO_BACKGROUND_MS`=0 turns it off (then Claude waits). Task does not survive exiting the session. The timeouts still apply while backgrounded.
- Documented max: none beyond the ~28 h default.
- Startup timeout is separate: `MCP_TIMEOUT` default 30000 ms.

## 2. Plugin-bundled MCP server (mcp#plugin-provided-mcp-servers, plugins-reference)
- Declaration: "Plugins define MCP servers in `.mcp.json` at the plugin root or inline in `plugin.json`". plugin.json `mcpServers` takes path / inline map / array, "Loaded together with `.mcp.json`; a server name declared later replaces an earlier one" (plugins-reference). `.mcp.json` shape: `{"mcpServers": {"name": {"command": "${CLAUDE_PLUGIN_ROOT}/...", "args": [...], "env": {...}}}}`.
- Variables (plugins-reference#environment-variables): `${CLAUDE_PLUGIN_ROOT}` "Absolute path of the plugin's installed version"; `${CLAUDE_PLUGIN_DATA}` "`~/.claude/plugins/data/<id>/`, created on first reference and kept across plugin updates"; `${CLAUDE_PROJECT_DIR}` "The project root". Substituted in stdio `command`, `args`, `env`. "`${CLAUDE_PLUGIN_ROOT}` changes when the plugin updates, so don't write state there."
- Project dir in the server process: "Claude Code sets `CLAUDE_PROJECT_DIR` in the spawned server's environment to the project root, so your server can resolve project-relative paths without depending on the working directory." (mcp, Option 3). Plus MCP `roots/list` = launch dir + added dirs. "Plugin-provided MCP configurations substitute `${CLAUDE_PROJECT_DIR}` directly".
- cwd of the stdio server process: NOT documented in the fetched pages (the phrasing implies do not rely on it). Use CLAUDE_PROJECT_DIR / roots/list.
- Lifecycle: starts automatically when the plugin is enabled; a stdio plugin server whose connection failed <15 min earlier is skipped.

## 3. Creating settings.local.json mid-session (settings#when-edits-take-effect; sandboxing)
- "Claude Code watches your settings files and reloads them when they change, so it applies most edits to the running session without a restart".
- "Claude Code also loads a settings file you create mid-session if its folder existed when the session started. For the project's `.claude/` folder, it loads the file even when you create the folder in the same session." -> covered whether or not `.claude` existed.
- Sandbox: "When you edit these filesystem lists during a session, Claude Code applies the change to the running session, so the next sandboxed command runs under the new paths." And enabling sandbox: "The change takes effect in your running session at the next shell command Claude runs." (sandboxing)
- Keys read only at session start are listed (model, effortLevel, ...; removing `permissions.blockReadsOutsideWorkingDirectories` needs restart); sandbox.* is not among them.
- Caveats: `sandbox.enabled`/`autoAllowBashIfSandboxed`/`allowUnsandboxedCommands` set above local level win ("a value saved there can't override higher levels"). Repo/local sandbox.filesystem entries can be left out under admin "repository locks" or when `permissions.blockReadsOutsideWorkingDirectories` is on. `--setting-sources` excluding a source ignores its sandbox.filesystem. Local file "needs trust" if git-tracked.
- Worktree/subdir: "If you start Claude Code in a subdirectory of a git repository, it reads and writes that file at the repository root ... In a worktree, it uses the file at the main checkout's root." (settings, line ~85). Relevant: in a worktree session the local settings file is the MAIN checkout's, not the worktree's.
- `ConfigChange` hook fires for direct edits to settings files.

## 4. PreToolUse Bash input (hooks#pretooluse-input)
- Fields: common + `tool_name`, `tool_input`, `tool_use_id`.
- Bash `tool_input` table lists exactly: `command`, `description` (optional), `timeout` (optional ms), `run_in_background`. `dangerouslyDisableSandbox` is NOT listed in the hooks docs.
- It is a real tool parameter elsewhere: "Claude ... may retry the command with the `dangerouslyDisableSandbox` parameter" and rule `Bash(dangerouslyDisableSandbox:true)` matches on it (sandboxing#the-unsandboxed-retry-escape-hatch; permissions#match-by-input-parameter). Whether a hook sees it: undocumented; test empirically.
- No hook input field says whether the command will run sandboxed (no "sandbox" mention in input schemas). "Hook commands themselves run unsandboxed" (hooks, DirectoryAdded).

## 5. session_id / cwd in hook input (hooks#common-input-fields)
- Common fields: `session_id` "Current session identifier"; `cwd` "Current working directory when the hook is invoked"; also `transcript_path`, `hook_event_name`, `permission_mode` ("Not all events receive this field"), `scratchpad_dir`.
- JSON examples in the docs show both `session_id` and `cwd` for SessionStart, UserPromptSubmit, Stop and PreToolUse (Stop/UserPromptSubmit/PreToolUse also show permission_mode).
- cwd is the live working dir (can drift via cd); project root is the `CLAUDE_PROJECT_DIR` env var.

## 6. sandbox.filesystem.denyWrite paths (settings-reference#sandbox-path-prefixes)
- "`/` Absolute path from filesystem root"; "`~/` Relative to home directory"; "`./` or no prefix: Relative to the project root for project settings, or to `~/.claude` for user settings". `//path` also absolute. "sandbox filesystem paths use standard conventions, so `/tmp/build` is an absolute path" (unlike Read/Edit rules where `/path` is project-relative).
- Settings page: "Paths in the file don't anchor at the repository root: a permission rule that starts with `/` or a relative sandbox path anchors at the session's primary working directory instead" -> relative paths are ambiguous in subdir/worktree sessions; prefer absolute.
- Trailing slash stripped. Wildcards on Linux/WSL2 for allowWrite/denyWrite: only trailing `/**` works; macOS supports `*`, `?`, `**`.
- Nonexistent path: for allowWrite "On Linux and WSL2, an entry for a path that doesn't exist yet has no effect, so create the path first." For deny: "the sandbox holds a write denial on a file that doesn't exist yet by creating a 0-byte read-only placeholder there while a sandboxed command runs. The sandbox removes the placeholder afterward." (sandboxing troubleshooting; a placeholder can be left behind). macOS behavior for nonexistent deny paths not stated.
- Arrays merge (union) across scopes; `Edit(...)` deny rules are added to denyWrite. Protected paths (.git HEAD/objects/refs, etc.) are always write-denied.

## 7. Is settings.local.json git-ignored? (settings)
- Table: "Claude Code keeps it out of git when it creates the file; if you create it by hand, add it to `.gitignore` yourself".
- "The first time Claude Code writes the file in a git repository that doesn't already ignore it, it adds `**/.claude/settings.local.json` to your global git excludes file" (core.excludesFile, else $XDG_CONFIG_HOME/git/ignore or ~/.config/git/ignore).
- So a file created by the plugin's CLI is NOT auto-ignored (only Claude Code's own writes trigger it); the plugin must add an ignore entry itself.

## 8. Long-running / progress
- Yes. Progress notifications reset the idle timer and are shown in /tasks for backgrounded calls ("The task's entry shows the latest progress the server has reported"). They do not extend the per-server wall-clock `timeout`.
- Calls >2 min auto-background in the main conversation; result delivered later as a task notification. Also an "MCP tasks that run on the server" mode (mcp, ~line 575-600): "By default, a task in the background has no Claude Code time limit"; not studied deeply.
- For a 15-min panel: send progress notifications every few minutes (stdio idle default is 30 min anyway), and optionally set `"timeout"` above 900000 in the server entry (documented for .mcp.json entries; not separately confirmed for plugin-bundled entries, though plugin .mcp.json uses the same schema).
