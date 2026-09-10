---
name: supervise
description: Turn the current Claude or Codex conversation into a persistent project supervisor with Claude or Codex workers and a Neovim team view. Use when the user invokes /supervise, $supervise, or explicitly asks to supervise a team.
---

Use the `nvim_team` MCP tools supplied by the Neovim chat launcher. If they
are unavailable, explain that the user must open a new Claude or Codex chat from Neovim
after installing this integration. Do not imitate team tools with terminal typing.
Invoke this skill as `/supervise project-name` in Claude or `$supervise project-name`
in Codex. Both use the same workflow. Use these team tools for registered workers;
native subagent tools do not register workers in this Neovim team view.

In Codex, first read `CODEX_THREAD_ID` from your shell environment (for example,
`printenv CODEX_THREAD_ID`) and pass it as `session_id` to `team_start`. Use the
actual value, never invent an ID or select the latest session. This records the
conversation to resume when its terminal exits, independently of hook support.
If it is unavailable, report that reconnect after process exit is not registered;
the current tmux terminal can still be reattached. Claude's ID is set by its launcher.

Promote this conversation with `team_start(name, brief)`. Derive the name from
the user's argument or topic. Write the brief from the actual conversation:
goals, scope, constraints, settled decisions, open questions, and what you may
decide without asking. Repeating the skill updates this same team. Keep its
brief current with `team_start`; it is the durable context supplied to workers.

Delegate only work the user has authorized. Use `worker_start` with a bounded
task, a descriptive name, and backend `codex-bf`, `codex`, `claude`, or
`claude-bf`. Prefer codex-bf for the first worker in this setup. The default
workspace is the supervisor's working directory; specify an existing separate
worktree for concurrent writers. Never assign overlapping writes in one
checkout. Start with one worker unless independent work warrants more.

Workers return either a result or a question. They do not have the supervisor's
whole conversation: include relevant context in the task and maintain the brief.
Use `team_status(wait_seconds=30)` while work is running; it wakes on a worker
update. This inbox loop is how questions reach you, including while Neovim is
closed. Do not end your turn with workers still running unless the user asks
you to pause or you need a decision from them. Give concise progress updates.

Answer questions grounded in the agreed brief using `agent_send(agent_id,
message)`, which resumes the same worker session. Ask the user about unresolved
scope or product decisions, then record the answer in the brief and reply to the
worker. Tool approvals are handled by each backend's permissions; a worker
question is never permission to bypass them. Error and blocked rows require
investigation, not an automatic retry loop. Stop a worker with `worker_stop`.

Review results before declaring success. Use `agent_send` for bounded revisions.
Report failures and unfinished work honestly. The Neovim team view is available
with `<leader>ct`; users can inspect worker transcripts and reopen this chat.
