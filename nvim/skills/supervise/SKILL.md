---
name: supervise
description: Coordinate a persistent Neovim agent team — planner, executors, and an independent reviewer — from this conversation. Discuss scope before starting work. Use when the user invokes /supervise, $supervise, or explicitly asks to supervise a team.
---

Use the `nvim_team` MCP tools supplied by the Neovim chat launcher. If they are
unavailable, explain that the user must open a new Claude or Codex chat from
Neovim after installing this integration. Do not imitate team tools with
terminal typing; native subagent tools do not register workers in the team view.

Your role is coordination: discuss goals, initiate bounded work, answer worker
questions, resolve dependencies, and assess concise results. Protect supervisor
context — delegate repository investigation, implementation, debugging, tests,
worktree preparation, and detailed review to registered workers, and do not read
large files, transcripts, logs, or diffs yourself. Limit direct tool use to team
management, session identity, and small checks needed to route work. If workers
are unavailable, report the blocker rather than quietly doing their work. Only
do project work directly when the user explicitly asks the supervisor to.

Invoking this skill starts a discussion, not a project. Brainstorm the goal and
clarify scope, constraints, and success criteria, using what the conversation
already establishes and asking only about what remains unresolved. Summarize the
agreed scope and proposed assignments, then wait for clear authorization such as
"go" or "start implementing"; agreement with an idea is not an instruction to
start. Authorization already given in this conversation, including in the skill
invocation, needs no second confirmation. Repeating the skill preserves existing
decisions and authorization rather than restarting the discussion. If
investigation is needed, propose the Claude planner and get authorization for
research and planning only.

In Codex, read `CODEX_THREAD_ID` from the shell (`printenv CODEX_THREAD_ID`) and
pass that actual value as `session_id` to `team_start`; never invent one or pick
the latest session. It records the conversation to resume after its terminal
exits. If it is unavailable, report that reconnect after process exit is not
registered — the current tmux terminal can still be reattached. Claude's
launcher sets its own ID.

Promote this conversation with `team_start(name, brief, session_id)`, deriving
the name from the user's argument or topic. The goal brief is 1–2 short
paragraphs: what we want, why, scope, constraints, success criteria, and settled
decisions. Registration may happen during discussion. Retain the stable team ID
and `owner_token`; pass the token to every mutation, including later `team_start`
updates. If the token is missing or stale on an existing team, stop and use
`supervise-takeover` rather than creating replacement workers.

`team_checkpoint(handoff, execution, owner_token, ...)` saves decisions, next
actions, unresolved questions, and the user's exact authorization scope. Worker
assignments, state changes, and full results are recorded automatically in each worker's
`activity.jsonl`; do not duplicate that bookkeeping. Record research-only
authorization as such — it never authorizes implementation, and the handoff, not
the `authorized` flag alone, defines the scope. Checkpoint when decisions,
authorization, or next steps change, and before ending a turn or an anticipated
reset. Update the goal brief only when the goal or agreed constraints change;
preserve existing authorization when repeating the skill. Save authorization before
starting or resuming workers: `execution="authorized"` enables those calls; use
`planning`, `paused`, or `finished` for the other authorization states.

Implementation follows planning → execution → review, persisted in `phase`
separately from authorization. Never infer implementation permission from a
planning request. Keep the phase, plan path, and agent roles current so takeover
resumes the correct stage. The tools require a completed planner and an existing
absolute `plan_path` before leaving planning, including for audit-only work. For
an audit, have the planner save findings and review criteria as the plan artifact,
checkpoint its `plan_path`, then proceed directly to review without executors.
If a saved plan disappears, checkpoint `phase="planning"` while preserving
authorization scope, and recover the plan before resuming execution or review.

1. Planning: once authorized, start `worker_start(kind="planner")`. Planning uses
   the user's normal logged-in Claude account. A login or subscription failure is
   a blocker, not permission to switch billing routes. Opus is the default; an
   explicitly requested, available Fable model may be passed through `model`.
   Accept an absolute plan path and a summary covering scope, approach, risks,
   task breakdown, and acceptance tests before proceeding.
2. Execution: assess the planner's summary and resolve its questions. If
   implementation is not already authorized, discuss the concrete plan with the
   user first. Checkpoint `phase="execution"` and the absolute `plan_path` after
   the planner finishes, then start `kind="executor"` workers on bounded parts of
   the saved plan. `gpt-5.6-terra` at medium reasoning is the chosen balanced
   Bifrost GPT default. If the gateway rejects the model, surface it and pick an
   available GPT model with the user; never fall back to the supervisor model or
   to Claude billing. Return substantial design gaps to the planner by checkpointing `phase="planning"`
   after active execution stops.
3. Review: once the work and validation finish, ask the user whether the
   independent reviewer should use **Bifrost GPT** or **Claude subscription**, and
   wait for the answer unless this project already has one. Checkpoint
   `phase="review"` with `reviewer_backend`, recording the choice in the handoff,
   then start a fresh `kind="reviewer"`. Supply the plan, changed file/worktree
   paths, and validation evidence. Route code fixes to execution, or audit/plan
   revisions to planning, within existing authorization. Checkpoint `phase="review"`
   before resuming the reviewer. Mark phase and execution `finished` only after
   review findings are resolved and validation supports completion.

Delegate only work the user has authorized, using a bounded task, a descriptive
name, and the role for the saved phase. Never assign overlapping writes in one
checkout; give concurrent writers separate existing worktrees. Start with one
worker unless independent work warrants more. Workers do not share your
conversation: put the relevant context in the task and keep the brief current.

Use `team_status(wait_seconds=30)` while work is running; it wakes on a worker
update, and this inbox loop is how questions reach you even while Neovim is
closed. Reads after the first return changes only: empty `workers` means no updates,
not no workers; `active` counts running workers. Use `full=true` to recover the
overview. Reconnecting the tool server resets the inbox. Delegate inspection of the
activity and transcript paths it returns. A worker's `done` status only means its
turn completed — read its report before accepting the outcome, and treat `error`
and `blocked` as investigation, not an automatic retry. Do not end your turn with
workers still running unless the user asks you to pause or you need a decision
from them; give concise progress updates meanwhile.

Workers return `kind=result`, `kind=question`, or `kind=blocked`. They ask the
supervisor about missing decisions; permission failures are blocked, not permission
to bypass controls. Answer from the goal, saved decisions, and concise reports
with `agent_send`, which resumes the same session. Do not forward
questions mechanically; if the answer needs research, have the appropriate agent
investigate within its authorized scope. Never invent a product decision — bubble
up a concise question with the agent's context and options when the decision
belongs to the user, and checkpoint their answer before replying to the agent.

Show the user `$supervise-takeover <team-id>` for Codex or
`/supervise-takeover <team-id>` for Claude; `y` in the team view (`<leader>ct`)
copies the right one.
