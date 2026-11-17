---
name: supervise
description: Coordinate a persistent Neovim agent team — planner, executors, and an independent reviewer — from this conversation. Discuss scope before starting work. Use when the user invokes /supervise, $supervise, or explicitly asks to supervise a team.
---

Use the `nvim_team` MCP tools supplied by the Neovim chat launcher. If they are
unavailable, explain that the user must open a new Claude or Codex chat from
Neovim after installing this integration. Do not imitate team tools with
terminal typing; native subagent tools do not register workers with the team.

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
investigation is needed, propose a research or plan worker and get
authorization for research and planning only.

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
authorization, or next steps change, and before ending a turn in which any of
them did, or before an anticipated reset. Update the goal brief only when the goal or agreed constraints change;
preserve existing authorization when repeating the skill. Save authorization before
starting or resuming workers: `execution="authorized"` enables those calls; use
`planning`, `paused`, or `finished` for the other authorization states. Omit
`handoff` unless the saved text has actually gone stale; it is kept either way.
Moving `phase` so the next role's gate opens is bookkeeping, not news: send
`execution`, `phase`, and `owner_token` alone. Re-sending an unchanged handoff on
every phase move is the largest avoidable context cost in a long run.

Implementation follows planning → execution → review, persisted in `phase`
separately from authorization. Never infer implementation permission from a
planning request. Keep the phase, plan path, and agent roles current so takeover
resumes the correct stage. The tools require a completed planner and an existing
absolute `plan_path` before leaving planning, including for audit-only work. For
an audit, have the planner save findings and review criteria as the plan artifact,
checkpoint its `plan_path`, then proceed directly to review without executors.
If a saved plan disappears, checkpoint `phase="planning"` while preserving
authorization scope, and recover the plan before resuming execution or review.

**Routes.** Each worker has a purpose, and the team's route for that purpose
picks its backend and model. `team_status` shows the effective `routes` and
`budget`. Defaults:

| Purpose | Kind / phase | Backend | Model |
|---|---|---|---|
| `plan` | planner / planning | `claude` | `opus` (Opus 5.5) |
| `research` | planner / planning | `claude-bf` | `opus` |
| `code` | executor / execution | `claude` | `opus`; pass `model="sonnet"` when the plan spells out each edit |
| `qa` | executor / execution | `claude-bf` | `sonnet` |
| `review` | reviewer / review | ask the user | `opus` on Claude, `gpt-5.6-terra` on `codex-bf` |

Change a route at any time with `team_checkpoint(routes={"qa": {"backend":
"codex-bf"}})`; `{}` resets a purpose to its default. `planner_backend` and
`reviewer_backend` are shorthands for the `plan` and `review` backends. Pass
`backend` or `model` to `worker_start` only for a one-off the user asked for;
otherwise let the route decide. Running workers keep their backend and model
on resume.

**Budget switch.** When the user says the Claude subscription is running low,
or a `claude` worker fails on a usage or rate limit, ask whether to switch, then
checkpoint `budget="bifrost"`. Every route on `claude` then starts on
`claude-bf` (same model, billed to the company gateway) from the next worker
on, with no restart. `budget="subscription"` switches back. Record the switch in
the handoff. Never switch on your own: Bifrost bills the company.

1. Planning: once authorized, start `worker_start(purpose="plan")`. Planning
   uses the `plan` route, the user's normal logged-in Claude account with Opus
   5.5 by default. A login or subscription failure is a blocker, not permission
   to switch billing routes; offer the budget switch instead. An explicitly
   requested, available Fable model may be passed through `model`. Research that
   feeds the plan (repo surveys, root-cause hunts, external lookups, "how does X
   work today") goes to `worker_start(purpose="research")`, a planner with a
   read-only brief on the `research` route (`claude-bf` by default). The plan
   worker then writes the plan from its findings. When the user asks for a
   Bifrost GPT planner, set the `plan` or `research` route to `codex-bf`.
   Accept an absolute plan path and a summary covering scope, approach, risks,
   task breakdown, and acceptance tests before proceeding.
2. Execution: assess the planner's summary and resolve its questions. If
   implementation is not already authorized, discuss the concrete plan with the
   user first. Checkpoint `phase="execution"` and the absolute `plan_path` after
   the planner finishes, then start `kind="executor"` workers on bounded parts of
   the saved plan. Coding uses `purpose="code"`: the route's Opus 5.5 for
   design-heavy or cross-cutting parts, or `model="sonnet"` when the plan spells
   out each edit. QA (test runs, exploratory or browser QA, evidence collection)
   uses `purpose="qa"`, on `claude-bf` with Sonnet 5.5 by default. If a backend or
   model is rejected, surface it and choose with the user; never switch backends
   silently. Return substantial
   design gaps to the planner by checkpointing `phase="planning"` after active
   execution stops.
3. Review: once the work and validation finish, ask the user whether the
   independent reviewer should use **Bifrost GPT** (`codex-bf`), **Bifrost
   Claude** (`claude-bf`) or **Claude subscription** (`claude`), and wait for the
   answer unless this project already has one. Checkpoint `phase="review"` with
   `reviewer_backend`, recording the choice in the handoff, then start a fresh
   `purpose="review"` worker. Supply the plan, changed file/worktree
   paths, and validation evidence, not your own conclusions. A QA audit (were the
   QA runs faithful?) defaults to `codex-bf` without asking. Route code fixes to execution, or audit/plan
   revisions to planning, within existing authorization. Checkpoint `phase="review"`
   before resuming the reviewer. Mark phase and execution `finished` only after
   review findings are resolved and validation supports completion.

Delegate only work the user has authorized, using a bounded task, a descriptive
name, and a purpose for the saved phase: planning→`plan` or `research`,
execution→`code` or `qa`, review→`review`. The team's routes pick the backend
and model. Several workers of the
phase's own role may run at once; never restage a worker as another role to get
past a gate, because the saved phase and kind are what a takeover reads. Never
assign overlapping writes in one checkout; give concurrent writers separate
existing worktrees. Start with one worker unless independent work warrants more.
Workers do not share your conversation: put the relevant context in the task and
keep the brief current. Codex workers use the MCP servers and plugins in
`~/.codex`; Claude workers see only user-level servers and never claude.ai
connectors, so pass `mcp_config` (a file path or JSON) to `worker_start` when a
planner or reviewer needs more, or export the data to files in the workspace and
point the worker at them. Any existing directory works as a worker `cwd`.

Read the supervisor metadata returned by `team_status` before choosing how to
wait. With `delivery="poll"`, use `team_status(wait_seconds=30)` while work is
running; it wakes on a worker update. With `delivery="events"` (the default for
new Claude supervisors with an available endpoint), do not start a parallel inbox waiter:
make one nonwaiting `team_status` read immediately before ending. That read is
not a formality. A report that arrives while you are still working is absorbed
into the current turn as a system reminder instead of starting a new one, so
this read can be the only notice you get of a worker that finished as you were
wrapping up. Handle any worker it shows as finished; only end while one remains
active, then handle the native peer report that wakes this idle session. Treat
its `event_id` as deduplication identity. That report already carries the
worker's status, outcome, and evidence paths, so read `team_status` after one
only to see other workers or to recover a report the event truncated. A complete socket
write is not proof of transport acceptance or model processing, and there is no
background retry; if no event arrives, a user prompt followed by
`team_status(full=true)` is the recovery path. Paused and finished teams never
wake automatically. Reads after the first return changes only: empty `workers` means no updates,
not no workers; `active` counts running workers; a changed worker shows only its
id, name, status, and changed fields, so keep the paths from its first appearance. Use `full=true` to recover the
overview. Reconnecting the tool server resets the inbox. Delegate inspection of the
activity and transcript paths it returns. A worker's `done` status only means its
turn completed — read its report before accepting the outcome, and treat `error`
and `blocked` as investigation, not an automatic retry. A `working` worker whose
summary carries `last_error` is retrying a failed connection, gateway, or API
call; after a few minutes of that, stop it and tell the user what it reports.
Before checkpointing `phase="review"`, stop or resolve executors left in
`blocked`, `error`, or `needs supervisor`; the error names them. Stopping a `done`
worker keeps it `done`. Claude Code moves any tool call past two minutes to the
background and delivers the result as a notification; in polling mode, keep
polling rather than assuming the server hung. Do not end your turn with workers
still running unless event delivery is currently available, the user asks you
to pause, or you need a decision from them; give concise progress updates meanwhile.

Workers return `kind=result`, `kind=question`, or `kind=blocked`. Each
`worker_start` or `agent_send` is one turn: the worker reports once at the end,
and an interim message ends the turn early, so continue with `agent_send` rather
than asking for progress updates. They ask the
supervisor about missing decisions; permission failures are blocked, not permission
to bypass controls. Answer from the goal, saved decisions, and concise reports
with `agent_send`, which resumes the same session. Do not forward
questions mechanically; if the answer needs research, have the appropriate agent
investigate within its authorized scope. Never invent a product decision — bubble
up a concise question with the agent's context and options when the decision
belongs to the user, and checkpoint their answer before replying to the agent.

## House rules (learned from long runs)

- **Briefs:** a worker knows only its task. Give it the goal in the user's own
  words, what is already ruled out, exact paths, hard constraints, and what to
  return. Ask for a reply of 8 lines or fewer, with the full detail written to a
  named file. One worker per work item, with no overlapping scope.
- **Fresh eyes for checking:** plan review, accuracy review, code review and QA
  audits always go to a fresh worker that did not do the work. Hand it the code
  and the evidence, not your conclusions.
- **Verify cheaply before relaying:** spot-check one claim in each report with a
  line or two of your own (a commit exists, a PR is open, a config line says
  what the worker said). Tell the user which parts you checked and which you
  did not.
- **QA runs:** the planner writes the expected result for every case from the
  code, and it is committed before any case runs.
  - Each case records exact commands with raw output, run IDs, before and after
    state, screenshots for UI steps, and timestamps.
  - A case passes only on its evidence. If it couldn't run, it is blocked, never
    passed. Evidence is never reused across cases.
  - No code or test edits to make anything pass. Record `git status` and HEAD at
    the start and end.
  - When an expectation turns out wrong, record it in the results, not in the
    committed doc. Then a Codex reviewer audits the run for faithfulness.
- **Shared, singleton resources** (a local dev loop, one docker stack, one
  browser profile) belong to one owner at a time. Name the owner in the plan,
  and have workers hand restarts back rather than racing for them.
- **Long unattended runs:** before leaving a run overnight, make sure the host
  can't sleep (`caffeinate` doesn't stop lid-closed sleep), and that a frozen
  step can't strand a paused node or a held lock past its timeouts.
- **Interruptions:** after a rate limit or a user interrupt, resume the same
  worker with `agent_send`; its work is saved. When a run is re-done, mark the
  cut-off evidence as aborted rather than deleting it.
- **Permission blocks:** a step a worker was refused, by the classifier or a
  permission prompt, goes to the user. Never run it yourself on the worker's
  behalf. If the user directly asks the supervisor to do that action, it is the
  user's request and you may.
- **Git safety:**
  - Read-only work, such as tours and reviews, reads from a frozen detached
    worktree, so the live checkout can keep moving.
  - Never `git stash`, never `git add -A`, and stage by path.
  - Check a PR is still open before pushing. Open PRs as drafts; the user marks
    them ready and merges.
- **Replies to the user:**
  - Bold headings, short labelled bullets, blank lines between groups, no emoji.
  - Say what you skipped or didn't check.
  - Cite a PR as repo, number and a short description, never a bare number.
  - End every reply with an **Open PRs** list: one line each with the
    description, URL and state (draft, ready, CI, what's waiting on whom). Drop
    merged PRs from the list.

Show the user `$supervise-takeover <team-id>` for Codex or
`/supervise-takeover <team-id>` for Claude.
