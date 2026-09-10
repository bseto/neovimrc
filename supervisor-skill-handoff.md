# Supervisor skill handoff — findings from the DB-1585 run (2026-09-10)

Written by the Claude supervisor session that ran the `/supervise` flow end to end for a
Jira-only task (restructuring epic DB-1585 "Vitess In Valhalla"). This is a review of the
`supervise` skill, the `nvim_team` MCP tools (`nvim/scripts/agent-team.py`), the worker
launcher, and the docs (`nvim/scripts/agents.md`), with concrete change suggestions. Line
numbers refer to `nvim/scripts/agent-team.py` at commit `2552848`.

The task itself succeeded: 5 issues created, 8 edited, 18 links, two review rounds approved.
But it took ~11 hours wall-clock for ~20 minutes of actual model work, and almost all of the
lost time was tooling friction that the skill and server could prevent or at least surface.

## 1. Timeline in one screen

| When | Event | Root cause | Time lost |
|---|---|---|---|
| 00:39–01:35 | Planner #1 (Opus) "working", zero output | API stream reset 6× mid-generation (thinking counter dropped to 0, once after ~19k tokens); no stall signal in `team_status` | ~55 min |
| 01:03–01:33 | `team_status(wait_seconds=30)` blocked 302s, 311s, 933s, 923s; Claude Code backgrounded the calls | Server loop should cap at 30s (`:457`); something else blocks | recurring |
| 02:24–02:30 | Planner #2 with "write one file per response" instruction | finished in 6 min | — |
| 02:31 | Executor #1 exit code 1 | Codex: "Not inside a trusted directory and --skip-git-repo-check was not specified" — cwd was a non-git scratch dir | fixed with `git init` |
| 02:32–10:23 | Executor #2 "working" forever | Codex looping "Reconnecting... waiting for network": Bifrost host did not resolve because the WireGuard VPN was down | ~8 h (overnight) |
| 10:23 | Executor #2/#3 report `blocked` | Codex Atlassian Rovo plugin OAuth refresh failed at startup → zero Jira tools registered | user ran `codex mcp login atlassian-rovo` |
| 10:34–10:40 | Executor #4 does the work | — | 6 min |
| 10:37 | Executor #4 stops after "interim progress message" | Codex `exec` is one turn; an agent message that the model doesn't follow with a tool call ends the run | 1 `agent_send` |
| 10:42 | `team_checkpoint(phase=review)` refused | "Resolve executor work before review": blocked/error executors count as unresolved until `worker_stop` | 4 stops |
| 10:47 | Tool schemas + scratchpad announcement vanished mid-session | Claude Code environment event; team and files intact | minor |
| 10:59, 11:04 | `team_checkpoint(finished)` refused twice | "A reviewer must finish": I had `worker_stop`ped the done reviewer, so no reviewer had status `done` | 2 retries + an extra reviewer turn |

## 2. What worked and should be kept

- The planning → execution → review split and the authorization/phase separation were the
  right shape; the reviewer caught real drift (curly apostrophes, a dangling consumer
  reference) and a supervisor-side inconsistency, and the fix pass + re-review closed them.
- Structured worker end-states (`result` / `question` / `blocked`) were reliable. Every Codex
  executor that lacked Jira tools reported `blocked` cleanly instead of improvising.
- `agent_send` to resume the same session was excellent for both the stalled-turn executor
  and the round-2 re-review (the reviewer kept its full context; ~3 minutes).
- Owner token + checkpoint handoff meant the team survived a Claude Code environment hiccup.
- `activity.jsonl` / `events.jsonl` / `backend.log` per worker made every incident diagnosable
  from the supervisor with `grep`. Keep them.

## 3. Findings and suggested changes

### 3.1 Server: `team_status` does not honor `wait_seconds`

Observed: four calls with `wait_seconds=30` blocked 302–933 s and were backgrounded by the
harness. The loop at `:456-470` caps `timeout` at 30 and sleeps 0.2 s, so the delay is not in
that loop. Candidates: `snapshot()`/`read()` contending on `locked()` with the runner thread,
or the stdio MCP handler being serialized behind another request. Either way the harness
treats it as a hung tool.

Suggest:
- Add a monotonic timer around the whole handler and log `duration_ms` to a server log; fail
  loudly (return an `error` field) if the handler exceeded `wait_seconds + 5`.
- Make file reads in `snapshot()` lock-free (read-then-parse; retry on JSON error) so a
  runner thread holding a lock cannot stall the inbox.
- Consider a notification path instead of polling: write a `inbox-changed` file the harness
  can watch, or expose a `team_wait` tool that blocks server-side but returns a heartbeat
  every N seconds so the client never sees a silent 15-minute call.

### 3.2 Server: no liveness/stall signal for a "working" worker

Planner #1 showed `status: working` for 55 minutes while its API stream reset six times.
Executor #2 showed `working` for eight hours while Codex printed "Reconnecting... waiting for
network" every few seconds. `activity_at` only changes on status transitions, so the
supervisor cannot tell "thinking hard" from "dead".

Suggest adding to `worker_summary`:
- `last_event_at` (mtime of `events.jsonl`) and `events` (line count);
- `tool_calls` (count of tool_use / mcp_tool_call items) — a worker with 0 tool calls after
  10 minutes is almost certainly stuck;
- `stream_resets` (Claude: count of `thinking_tokens` decreases) and `api_retries`;
- `stalled: true` when no event for N minutes (default 5) or when the last M events are all
  `type: error` (Codex "Reconnecting..."). Surface the last error text in `message`.
The skill can then say: "treat `stalled` as investigation, stop after 15 min".

### 3.3 Launcher: Codex refuses a non-git, non-trusted cwd

`worker_command` (`:487-497`) passes no `--skip-git-repo-check` and no trust override, so
any cwd outside `~/.codex/config.toml [projects.*]` that is not a git repo dies at startup
with exit code 1. The status message was only "Backend exited with code 1. See backend.log."

Suggest:
- Pre-check in `worker_start` for codex backends: if `cwd` is not inside a git work tree and
  not a trusted project, either add `--skip-git-repo-check` or return a clear error before
  spawning.
- On non-zero exit, include the last ~5 lines of `backend.log` in the worker `message`.

### 3.4 Launcher: no connectivity/auth preflight for `codex-bf`

Two separate blockers looked identical from the supervisor's seat ("working" forever, then
`blocked`): Bifrost unreachable (VPN down) and Rovo OAuth expired. Both are checkable in
under a second before spawning.

Suggest a `preflight` step in `worker_start` (or a `team_preflight` tool the skill calls first):
- Resolve + `HEAD` the Bifrost `base_url` from `~/.codex/config.toml`; if it fails, return
  "Bifrost unreachable — is the VPN connected?" and do not spawn.
- Run `codex mcp list` and parse `Auth`; for OAuth servers, attempt a token refresh or check
  the token file age; if refresh fails, return "run `codex mcp login <server>`".
- Surface `backend.log` lines matching `ERROR .*oauth|Transport channel closed` into the
  worker `message` at startup rather than leaving them for a human to `cat`.

### 3.5 Codex one-turn semantics are undocumented

Codex `exec` is a single turn. Asking the executor for "interim progress messages" produced
exactly one message and the run ended (parsed as the final `result`). The skill and docs
should state: workers report once, at the end; use `agent_send` to continue. Consider having
the runner detect a `result` whose message contains "remaining:"/"partial" and mark the
worker `needs supervisor` instead of `done`, so a partial turn is obvious in the inbox.

### 3.6 Phase gates: surprising rules, unhelpful errors

- `:230-233` — blocked/error/needs-supervisor executors block the move to `review`. Reasonable,
  but the error should list the offending worker IDs and say "stop them with `worker_stop`".
- `:236-237` — "A reviewer must finish" checks for a reviewer with `status == "done"`.
  `worker_stop` on a finished reviewer flips it to `stopped` (`:385`, `:554`), so a tidy
  supervisor locks itself out of `finished`. Fix: record `finished_at`/`last_result_kind` on
  the worker and let the gate accept `stopped` workers whose last result was `result`; or have
  `worker_stop` on an already-done worker be a no-op that preserves `done`.
- `:238-242` — "Review the latest executor changes" compares reviewer `activity_at` with the
  max executor `activity_at`. `worker_stop` updates `activity_at` on executors, so stopping
  an executor *after* the reviewer finished makes an already-complete review look stale.
  `activity_at` should only move on real backend activity, not on supervisor stops.
- `worker_start` says "Match the saved phase" (`:671`) but the mapping is only in code
  (`:717`). Put the table in the tool description and in SKILL.md: planning→planner,
  execution→executor, review→reviewer.

### 3.7 Claude workers have no MCP servers

`worker_command` for Claude (`:501-507`) passes no `--mcp-config`, so a Claude planner or
reviewer only sees the user-level servers (here: grafana). It cannot read Jira, GitHub, or
anything the supervisor got from claude.ai connectors. I worked around it by having a native
subagent export live tickets to disk, which the skill explicitly discourages.

Suggest either: a `mcp_config` argument on `worker_start` (path or inline JSON) passed
through as `--mcp-config`; or inherit the supervisor's `--mcp-config` minus `nvim_team`; and
document the capability matrix per backend in SKILL.md (Codex: `~/.codex` MCP servers and
plugins; Claude: user-level servers only). Until then, the skill should sanction the
"export to disk with a read-only helper, review from files" pattern.

### 3.8 Response payloads are too large for the supervisor's context

`worker_start`, `worker_stop`, and `agent_send` echo the full `task` *and* `assignment`
text (3–4 KB each) back in every response; `team_status(full=true)` repeats them. The docs
promise a 1200-char cap for inbox reads, which held, but mutation responses are uncapped.
Return `{id, name, kind, backend, model, status, message[:300]}` from mutations; put the rest
behind `details`.

### 3.9 `team_checkpoint` forces a full handoff rewrite

Every checkpoint requires resending the entire handoff. Over a long run that is 1–2 KB of
retyping per state change and invites drift. Add `handoff_append` (or `handoff_path` pointing
at the team's `handoff.md`) and keep `handoff` as the replace-all form.

### 3.10 Team workspace should not live in the client's scratchpad

I used Claude Code's session scratchpad for the plan, exports and review. Mid-run the harness
declared that directory "no longer available" (it was still on disk). Have `team_start`
create `~/.local/state/nvim/agent-teams/<team>/workspace/` (git-initialised, so Codex will
start there) and return the path; the skill should tell supervisors to keep plans and
artifacts there. That also fixes 3.3 for the common case.

### 3.11 Planner prompt hygiene belongs in the skill, not in the supervisor's head

What made planner #2 succeed where #1 stalled was a paragraph of working-style instructions
(one file per response, write immediately, no extended deliberation). Put a default
"worker preamble" in SKILL.md (or have the launcher prepend it) covering:
- write outputs incrementally, one artifact per response; never hold a whole plan in one reply;
- compute counts and diffs with commands, never by hand (planner said "nine children", the
  true count was eleven, and the executor parroted it into its sweep report);
- Codex: single turn, no interim messages, one final structured report;
- after any create in an external system, re-fetch and verify defaults (Rovo's
  `createJiraIssue` silently applied a parent to a parentless bug).

### 3.12 Small-task path

For a 13-ticket Jira edit the mandatory planner run cost ~1 h of the wall-clock (including the
stall) for a plan I could have written from the findings I already held. The skill's
"audit-only" clause almost covers this. Suggest an explicit light mode: with the user's OK the
supervisor may register a supervisor-authored `plan_path` (still absolute, still on disk) and
go straight to execution; keep the mandatory reviewer.

## 4. SKILL.md edits (concrete)

1. Add a **Preflight** paragraph before the phase list: VPN/Bifrost reachability, `codex mcp
   list` auth state for any MCP the task needs, cwd is a git repo or trusted project, team
   workspace dir.
2. Add a **Worker capabilities** paragraph: backend → available MCP servers; Codex one-turn
   semantics; `agent_send` resumes; Claude planner needs incremental-write instructions.
3. Replace "Match the saved phase" with the explicit table (3.6).
4. State the gate rules the supervisor will hit: stop blocked/error executors before review;
   do **not** stop a done reviewer before `finished` (until 3.6 is fixed); a fix pass after
   review must be followed by a reviewer turn (resume the same reviewer via `agent_send`).
5. Add the default worker preamble (3.11) as a quotable block.
6. Add the sanctioned "export to disk for Claude reviewers" pattern (3.7) until MCP
   passthrough exists.
7. Add the light mode (3.12).
8. In the inbox-loop paragraph, note that Claude Code will background an MCP call that runs
   past ~5 minutes and deliver its result as a task notification; the supervisor should keep
   polling rather than assume the tool is broken.

## 5. Docs (`agents.md`) corrections

- "unchanged running teams wait up to 30 seconds" — not what was observed (3.1); soften or fix.
- Add the Codex trusted-dir/git-repo requirement and the `--skip-git-repo-check` decision.
- Add `codex mcp login <server>` as the remedy for OAuth-expired plugins, and where
  `backend.log` lives.
- Document that `worker_stop` changes `activity_at` and status, and what that does to the
  finish gates (or fix it and document the fixed behavior).

## 6. Open questions for the maintainer

- Is the >30 s `team_status` block reproducible with `check-team.py` under a fake long-running
  worker? If not, it may be harness-side (stdio MCP in Claude Code), which changes the fix.
- Should `blocked` executors really block the move to review, or only `working`/`starting`?
  A blocked worker that never mutated anything is arguably "resolved".
- Do you want the launcher to add `--skip-git-repo-check` universally, or only when the
  supervisor explicitly passes a scratch `cwd`?
- Is inheriting the supervisor's MCP servers into Claude workers acceptable from a
  permissions standpoint, given workers run with `--permission-prompts none`?

## 7. Where things are

- Team ID `a859757d-a295-4c6a-a3a6-20c52f58a661`, state under `~/.local/state/nvim/agent-teams/`.
  Left in phase `review`, execution `authorized`, last reviewer status `done` (FINAL: APPROVE).
  Not marked `finished` because the user asked to stop; `team_checkpoint(finished)` should
  succeed now that a reviewer is `done` and unstopped.
- Artifacts (throwaway git repo): `/private/tmp/claude-502/-Users-byron-seto-Documents-workspace-stackadapt-valhalla/a859757d-a295-4c6a-a3a6-20c52f58a661/scratchpad/db-1585-team/`
  — `findings-and-restructure.md`, `current-tickets/`, `PLAN.md` + `plan/` (incl.
  `fixes-round-2.md`), `live-tickets/`, `live-tickets-round2/`, `REVIEW.md`.
- Worker dirs for the incidents above: planner #1 `a29f379d…`, executor #1 `60575c67…`
  (git-repo error), executor #2 `774f8166…` (Reconnecting loop + OAuth), executor #4
  `ebdb9fd2…` (main work), reviewer `a89bb435…`.
