---
name: supervise-takeover
description: Take over an existing Neovim supervisor team by stable team ID after clearing context or opening a fresh Claude or Codex chat, preserving its goal, handoff, workers, and authorization scope.
---

`/supervise-takeover <team-id>` in Claude or `$supervise-takeover <team-id>` in
Codex explicitly authorizes transferring supervisor ownership; it does not expand
the project's execution authorization. The ID is the one the previous supervisor
showed the user. If no ID is supplied or it is ambiguous, ask; never guess the
latest team.

Use the `nvim_team` tools from a Neovim-launched chat. If `team_takeover` is
unavailable, open a fresh chat with the updated launcher; do not approximate a
takeover by creating a new team, rewriting records, or typing into terminals.
Read the sibling [supervise skill](../supervise/SKILL.md) for the coordination
rules, but skip its initial registration: do not call `team_start`.

In Codex, `team_takeover` requires `session_id`: read the actual
`CODEX_THREAD_ID` from the shell and pass it, never an invented or inferred
value. If it is unavailable, report the blocker. Claude may omit it: the launcher's
SessionStart hook records the current conversation, including after `/clear`.
Terminals created before that hook was installed need a fresh launch.

Take the new owner token from `team_takeover` and use it for every later
mutation. A replaced supervisor must stop issuing instructions; do not
automatically take ownership back after a stale-token error.

Read only the returned goal brief, handoff, execution state, and worker
summaries — never the previous supervisor's conversation or worker transcripts.
Preserve `phase`, `plan_path`, the `routes` and `budget` shown in
`team_status`, and each agent's `kind`, `purpose` and `model`, and reuse the existing workers and their sessions rather than restarting
the pipeline or launching duplicates. If the review backend choice is missing
when work reaches review, ask then. A legacy team with no phase or plan needs its
planning state reconciled before new execution; do not fabricate a plan.

`checkpoint_at` is absent when the previous supervisor never checkpointed
explicitly. Worker assignments and last reports are saved regardless — use them
to reconcile a stale handoff, but treat worker activity as history, not as new
authorization. Briefly state your understanding of the goal, progress,
authorization, and next step, then ask about anything missing. Continue without
another approval only within the recorded scope; preserve planning or paused state.
Save a refreshed handoff with `team_checkpoint`, then use the supervise inbox loop
to wait for active workers and handle their reports.
While paused, collect reports and checkpoint questions; wait for user authorization
before starting or resuming workers, including replies through `agent_send`.
