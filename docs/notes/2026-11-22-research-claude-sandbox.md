# Claude Code sandbox research (fetched 2026-11-22)

Pages fetched OK: sandboxing, settings, settings-reference (index only; entries past char 100000 not read), permissions (via curl .md + grep), plugins-reference, plugins/components, hooks (via curl + grep), mcp (first 100k chars). The mcp page and hooks page were large; the mcp page's sandbox coverage is only via the sandboxing page. Note: the plugins-reference page now redirects/aliases to "Plugin manifest reference"; there is NO mention of a plugin-shipped settings.json (see Q8).

Base URLs: S = https://code.claude.com/docs/en/sandboxing ; ST = .../settings ; SR = .../settings-reference ; P = .../permissions ; PR = .../plugins-reference ; PC = .../plugins/components ; H = .../hooks ; M = .../mcp

## 1. What it enforces / OS / mechanism / children
- "The Bash sandbox is a boundary that the operating system enforces around the shell commands Claude runs on your machine." (S, intro)
- "The sandbox runs on macOS, Linux, and WSL2. On native Windows, Claude Code runs commands unsandboxed." (S)
- macOS "uses Seatbelt for sandbox enforcement"; Linux/WSL2 "uses bubblewrap for isolation" (S, OS-level enforcement). Built on `@anthropic-ai/sandbox-runtime`.
- Children: "the shell commands Claude runs start inside its boundary, and so do the processes they start." (S, What the sandbox restricts). Also: "These paths are enforced at the OS level, so all commands running inside the sandbox, including their child processes, respect them." (S, allowWrite section)
- Covers Bash, PowerShell, and Monitor tool commands and child processes (P, "How permissions interact with sandboxing"). Subagents use the same sandbox (S, Scope).

## 2. Default write scope
- "The working directory, a per-user temp directory, and directories you've added. Protected paths stay write-denied" (S, table in What the sandbox restricts). Yes: cwd (and subdirs) writable by default.
- Reads default: "Most of the machine, including credential files such as ~/.ssh" (same table).
- Protected paths (write-denied even if allowWrite/Edit allow covers them): ".claude settings files, .claude/skills, agents, commands, hooks, .mcp.json" (working dir and above); ".bashrc/.zshrc, .gitconfig, .vscode, .idea, hooks and config inside .git" (working dir) (S, Protected paths). "If you add an allowWrite entry or an Edit allow rule that covers one of these paths, the protection still applies."
- NOTE: "After a sandboxed command ends, a newer top-level HEAD, objects, or refs entry in your working directory is deleted unless it's a folder with contents." (S)

## 3. denyWrite / allowWrite semantics
- "You can also deny write or read access using sandbox.filesystem.denyWrite and sandbox.filesystem.denyRead, and re-allow specific paths within a denied region using sandbox.filesystem.allowRead. When read rules overlap, the rule with the narrower path applies" (S, Configure sandboxing; URL S).
- Arrays merge across scopes: "Claude Code merges them, combining the paths rather than replacing one scope's array" (S).
- Deny a subdirectory inside the project: docs show deny-inside-allow for READS ("The deny holds inside a wider allow", per fetch summary), and the default table lists denyWrite as the knob that narrows the cwd-writable default. Docs do not state write precedence in a sentence. Practical reading: denyWrite of `docs/architecture/.state` while cwd is writable is the documented use of the table row ("Change it with ... filesystem.denyWrite"). UNVERIFIED by docs: explicit allowWrite-vs-denyWrite precedence for writes; must be tested empirically (sandbox-runtime README says deny wins over allow, but not checked here).
- "Deny X, allow X/sub" for WRITES (deny whole project, allow docs/architecture): not documented. The documented narrower-wins rule is for READS only. The cwd is writable by default and there is no documented way to remove cwd from the default write set except denyWrite of it; precedence needs empirical test. Alternative with documented semantics: denyWrite specific siblings (can't enumerate generically).
- Path syntax: "Sandbox filesystem paths use standard conventions: /tmp/build is absolute and ~/.kube is relative to your home directory. This differs from Read and Edit permission rules, which use //path for absolute and /path for project-relative"; "the relative path . resolves to the project root when the configuration lives in project settings" (S).
- Edit rules feed the sandbox: "Edit allow rules: Grant write access to specific paths, the same way sandbox.filesystem.allowWrite does" and "Paths and domains from both sandbox settings and permission rules are merged into the final sandbox configuration." (S, Permission rules; also P, How permissions interact with sandboxing). Table row: "`Read` and `Edit` deny rules | Block access to specific files or directories". Explicit statement that an Edit deny becomes a denyWrite entry is only implied by the merge sentence.
- P also says: "Read and Edit deny rules apply to Claude's built-in file tools... They also don't apply to arbitrary subprocesses that read or write files indirectly... For OS-level enforcement on sandboxed shell commands, enable the sandbox and turn off the unsandboxed retry." (P, Read and Edit).
- Edits to lists mid-session are live: "When you edit these filesystem lists during a session, Claude Code applies the change to the running session, so the next sandboxed command runs under the new paths." (S).

## 4. dangerouslyDisableSandbox / allowUnsandboxedCommands
- "Claude analyzes the failure and may retry the command with the dangerouslyDisableSandbox parameter." "The retried command runs unsandboxed." (S, The unsandboxed retry escape hatch)
- "You can disable the unsandboxed retry by setting "allowUnsandboxedCommands": false in your sandbox settings. With the retry disabled, Claude Code ignores the dangerouslyDisableSandbox parameter. While the sandbox is running, commands Claude runs are then sandboxed unless they match an excludedCommands entry." (S, strict sandbox mode)
- Project settings: SR index lists scope "Any file" for allowUnsandboxedCommands, so project .claude/settings.json can set it. Precedence: "A false in your user settings, --settings, or managed settings holds even when a project's settings set true" (S). Project false is effective when nothing higher sets true (default true). Also an ask rule `Bash(dangerouslyDisableSandbox:true)` is possible (S).
- Gotcha: "If you or your administrator disable the retry in managed settings or with the --settings flag, the sandbox becomes admin-required. Claude Code then ignores the settings in a repository's files that loosen the sandbox, excludedCommands entries included." (S). Under project-only setting it is NOT admin-required, so project excludedCommands stay honored.
- Other unsandboxed paths: "Commands you type at the ! shell-mode prompt: keep running outside the sandbox." (S, Commands are refused...). Those are user-typed, not agent.
- failIfUnavailable: "By default, when the platform doesn't support the sandbox or the dependency check at startup fails, Claude Code runs commands without sandboxing. To make Claude Code exit at startup instead, set sandbox.failIfUnavailable to true" (S, Get started). Scope "Any file" (SR).

## 5. excludedCommands matching (S, "Run commands outside the sandbox with excludedCommands")
- "Claude Code checks your entries against each Bash and Monitor call. A call is the whole command line Claude sends, which can chain several commands."
- "entries use the same syntax as a Bash(...) permission rule, where a pattern with no wildcard is an exact match. docker matches only docker with no arguments."
- "Every command in the call has to match: npm ci && docker compose build stays sandboxed unless another entry covers npm ci"
- "Claude Code matches the text of the call: a script or make target that calls docker internally doesn't match, and neither does /usr/local/bin/docker"
- "Some calls stay sandboxed: a redirect to a file, a cd, or a command substitution such as $(...) keeps the whole call sandboxed."
- "A git clone needs relative paths" (absolute, ~, or .. destination stays sandboxed).
- "A command that begins with unshare stays sandboxed whatever excludedCommands pattern you list" (S).
- Excluded commands then go through normal permissions ("Bash command (unsandboxed)" prompt); "In bypassPermissions mode, an excluded command runs without a prompt unless an ask rule matches it."
- Warning: "An excluded command runs with your full access... Claude can write that file and then run it outside the sandbox." (S).
- DESIGN IMPLICATION: `ga` writing .state must NOT be an excluded command if you want the agent unable to write .state any other way; exclusion = full unsandboxed access to everything for that call, and matching is on command text (the thing we're trying to escape). Better: ga via plugin MCP server (runs outside sandbox) or a ga that is excluded with exact pattern, plus no way for the agent to pre-write the script it runs.

## 6. Project settings / live reload / hook or CLI changing them
- Sandbox keys scope "Any file" (SR index): sandbox.enabled, allowUnsandboxedCommands, excludedCommands, filesystem.allowWrite/denyWrite/allowRead/denyRead, failIfUnavailable, autoAllowBashIfSandboxed. Exceptions: `filesystem.disabled`: "Project settings in .claude/settings.json and .claude/settings.local.json can't set it."; allowAppleEvents, allowNestedUserNamespaces: not from project settings (S).
- Live reload: "Claude Code watches your settings files and reloads them when they change, so it applies most edits to the running session without a restart, including edits to permissions, hooks..." (ST, When edits take effect). "Claude Code runs the ConfigChange hook for direct edits to settings files". Sandbox enable via user settings: "The change takes effect in your running session at the next shell command Claude runs" (S, Troubleshooting).
- Hooks can block: "ConfigChange hooks can block configuration changes from taking effect... When blocked, the new settings are not applied to the running session." (H, ConfigChange decision control; policy_settings cannot be blocked). Hook events fire "When a configuration file changes during a session." (H)
- Can the agent change sandbox settings mid-session? Not stated as forbidden. Project settings files .claude/settings.json / settings.local.json are PROTECTED PATHS for sandboxed Bash writes ("the .claude settings files ..." S Protected paths), and Edit tool writes to them go via normal permission prompts. But the agent's Edit/Write tools run outside the sandbox (S: "Read, Edit, Write ... follow permission rules instead"). So add Edit deny rules for `.claude/settings*.json` or use a ConfigChange hook to block, or put the config in user/managed/--settings scope (higher precedence than project and cannot be edited by project-file writes).
- A CLI/hook mid-session: hooks run unsandboxed with full user access ("Hook commands themselves run unsandboxed." H DirectoryAdded), so a hook could rewrite settings; no documented API for hooks to set settings. /sandbox panel saves to settings.local.json.

## 7. Hooks / MCP in the sandbox?
- "Other processes Claude Code starts: command hooks, local MCP servers, plugin monitors, LSP servers, ... run with your full access" (S, What runs outside the sandbox).
- "The command runs in a shell... It runs with your full user permissions and outside the sandbox." (PC line 548, about plugin hooks/monitors command)
- "Hook commands themselves run unsandboxed." (H, DirectoryAdded)
- So both PreToolUse hooks and plugin MCP servers can write .state; the sandbox only confines Bash/PowerShell/Monitor tool commands.

## 8. Plugin shipping settings / MCP
- Plugin manifest fields (PR, Fields table): name, version, hooks, mcpServers, lspServers, skills, commands, agents, outputStyles, workflows, monitors, userConfig, network, ... There is NO `settings`, `sandbox`, or `permissions` field. `network` field: "The field doesn't allow or block any host." (PR). I found no doc text saying a plugin can ship sandbox config or permission rules; plugin-supplied settings are not documented. (Older docs mention a plugin root settings.json for `agent` key; not found in current plugins-reference/components pages searched.) Therefore sandbox/permissions must come from user/project/managed/--settings.
- Plugin hooks: "hooks/hooks.json at the plugin root... Claude Code merges whatever you declare" (PR/PC).
- Plugin MCP: "Plugins define MCP servers in .mcp.json at the plugin root or inline in plugin.json" and "When you enable a plugin, Claude Code starts its MCP servers automatically" (M, Plugin-provided MCP servers). Tool names: "mcp__plugin_<plugin-name>_<server-name>__<tool-name>" (M; PC).
- "Plugin bin/": "Files here are on the Bash tool's PATH while the plugin is enabled, so Claude runs them as bare commands." (PR Standard layout). `${CLAUDE_PLUGIN_ROOT}` etc. "aren't present in the environment of commands Claude runs through the Bash tool" (PR).
- Can plugin MCP tool be the ONLY way to call a capability? Docs give no exclusivity mechanism. MCP server runs outside sandbox (Q7), so it can write .state, while Bash sandbox denies .state; to make MCP the only path, deny writes to .state via sandbox.filesystem.denyWrite in settings (not shippable by plugin) and have MCP server not expose an "approve" tool (approval tool absent = unreachable by agent). Caveat: agent could still reach the server's binary/data via Bash (it is readable; and `~/.claude` etc. reads are open by default). Permission rules can deny/allow specific MCP tools: "Use this full name when referencing the tool in permission rules" (M); parentheses-argument rules on mcp__ tools are skipped (P).
- Plugin hook note: "PreToolUse hook decisions don't bypass permission rules" (P).

## 9. Warnings that Bash pattern rules are fragile (P)
- "Bash permission patterns that try to constrain command arguments are fragile. For example, Bash(curl http://github.com/ *) intends to restrict curl to GitHub URLs, but won't match variations like:" (P, Bash section)
- "so a deny or ask rule covers the invocation Claude usually produces and isn't a security boundary around the program." (P, what a Bash rule doesn't match)
- "For filesystem and network enforcement that doesn't depend on the command text, use sandboxing. To inspect the full command text with your own logic before it runs, use a PreToolUse hook." (P)
- "A rule like Bash(command:rm *) would be bypassable by a compound command" (P)
- "A deny rule doesn't match the same program by path or inside sh -c, so pair it with the sandbox network allowlist" (P)
- Wrapper warning: "a rule like Bash(devbox run *) matches whatever comes after run, including devbox run rm -rf ." (P)

## 10. On by default / how to enable
- "The sandbox is off by default. To turn it on, run /sandbox in a session ... or set sandbox.enabled to true in a settings file such as ~/.claude/settings.json." (S)
- "To enable the sandbox across all of your projects, set sandbox.enabled to true in your user settings at ~/.claude/settings.json." (S)
- Project settings may set sandbox.enabled (scope Any file), but /sandbox cannot change it if set above local: "Sandbox settings can't be changed here. Higher-priority settings override them." (S)
- Without failIfUnavailable, a missing dependency means silent unsandboxed runs (S). Linux needs bubblewrap dependency installed.

## Summary of design-relevant conclusions
1. OS enforcement exists for Bash child processes only; hooks, MCP, Read/Edit/Write tools are outside.
2. Documented knobs: denyWrite (subdir deny inside cwd), allowUnsandboxedCommands:false (+ failIfUnavailable), project settings can carry them (but a user/--settings/managed `true` wins over project `false` only for allowUnsandboxedCommands false? docs: false in higher scope wins over project true; project false works alone).
3. Not documented / must test: "deny all project writes except docs/architecture" semantics; denyWrite vs allowWrite precedence for writes.
4. A plugin cannot ship sandbox settings; the user (or a /setup step writing .claude/settings.json) must. Plugin could ship a SessionStart/ConfigChange hook to verify/enforce that settings are present.
5. Agent's Edit/Write tools bypass the sandbox; use Edit deny rules on .state and plugin dir plus hook checks for those tools.
