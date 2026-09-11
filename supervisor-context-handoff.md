# Supervisor context handoff — findings from team 6127958c (2026-09-11)

Written by a Claude Code session that reviewed the agent-team commits, addressed
`supervisor-skill-handoff.md` (the DB-1585 run), and then measured a real supervisor
session end to end. Companion to that file; read it first for the tool-friction
findings. This one is about **where a supervisor's context goes** and what to do
about it. Code changes below are uncommitted on top of `e09d951`. Line numbers refer
to `nvim/scripts/agent-team.py` in the working tree.

## 1. The example team

| field | value |
|---|---|
| team ID | `6127958c-9f2b-4da6-9d3b-45bdfae49609` |
| name | `valhalla-local-temporal` (Jira DB-1128) |
| supervisor backend | `codex-bf`, model `gpt-5.6-sol` from `~/.codex/config.toml` |
| supervisor Codex session | `01a089f0-906f-7860-aff3-fc4364d98bf0` |
| session log | `~/.codex/sessions/2026/09/10/rollout-2026-09-10T00-10-39-01a089f0-906f-7860-aff3-fc4364d98bf0.jsonl` |
| team state | `~/.local/state/nvim/agent-teams/6127958c-9f2b-4da6-9d3b-45bdfae49609/` |
| span | 2026-09-10 00:10 → 2026-09-11 01:43 local, roughly 11 active hours |
| context window | 190,000 tokens (`model_context_window` in the log) |
| final context | 129,533 input tokens on the last request, 68%; the TUI showed 65% |
| lifetime API usage | 20.2M input tokens, 97.7% cache hits, 28.7k output, 1.8k reasoning |

Workers, in order. Each has `agent.json`, `activity.jsonl`, `chat.md`, `events.jsonl`,
and `backend.log` under the team state directory.

| started | kind | backend | name | id | end |
|---|---|---|---|---|---|
| 09-10 00:17 | planner | claude | `recover-temporal-dev-plan` | `945b1956-d159-45aa-87bc-174d443445cf` | done |
| 09-10 00:26 | reviewer | claude | `review-temporal-dev` | `a5eae75b-1bf4-46eb-b25e-176cbc07e57e` | done, reused for every review (9 turns) |
| 09-10 10:01 | executor | codex-bf | `commit-temporal-dev` | `4dfdb118-ede6-4e62-996b-03e793889871` | done |
| 09-10 14:10 | executor | codex-bf | `add-make-help` | `650af1d2-4cbf-4438-a615-555516e0c863` | done |
| 09-10 14:39 | executor | codex-bf | `simplify-docker-dev-commands` | `c170c156-e7b2-41d4-a54f-d9c5daec18c7` | done |
| 09-10 14:49 | planner | claude | `plan-worker-restart` | `9b1a213e-b836-4ca5-8c17-d2c9f8bd11fa` | done, rev1 rejected, rev2 = Unix socket |
| 09-10 14:59 | executor | codex-bf | `implement-worker-restart` | `fb8ad4e6-6484-40a9-9163-3694fc70c429` | done |
| 09-10 15:16 | executor | codex-bf | `commit-dev-command-updates` | `217fe427-9cb2-4209-b2da-6888721c8ee8` | done |
| 09-10 15:26 | executor | codex-bf | `remove-python-launcher-test` | `4d5f5dad-c9f5-4938-9bfe-bf1188317a8a` | done |
| 09-11 00:37 | planner | claude | `plan-sighup-worker-restart` | `d4679c4e-5cd9-4cbf-9877-1a7100bdfa64` | done |
| 09-11 00:42 | executor | codex-bf | `implement-sighup-restart` | `7c163300-9d30-4e87-a08a-af5df9d1ee06` | done |
| 09-11 01:43 | executor | codex-bf | `commit-sighup-restart` | `c9e57b5f-dde9-4e8a-8641-03a9b2482c6b` | done |

Pattern throughout: plan → execute → review → fix → re-review, one Claude reviewer
session reused across all reviews. One full episode (SIGHUP: 00:37 → 00:53) cost the
supervisor about 15k tokens of context. Earlier episodes cost 10–15k each.

## 2. Where the 129k tokens went

Measured from the session log (chars ÷ 4 ≈ tokens; see §3 for how).

| component | chars | ≈ tokens | share | notes |
|---|---|---|---|---|
| `team_status` results | 131k | 33k | 25% | 107 parsed results, 49 empty, 58 worker rows |
| `worker_start` / `agent_send` results | 103k | 26k | 20% | 28 calls echoing the full record, avg 3.7k chars each |
| handoff + task text the supervisor wrote | 62k | 15k | 12% | 38 checkpoints, 11 worker starts, 17 sends |
| Codex `exec` wrapper + `wait` polls | 27k | 7k | 5% | Codex-side; each MCP call is a JS cell |
| supervisor narration to the user | 18k | 4.5k | 3.5% | 113 messages, ~1 per minute while workers ran |
| user messages | 17k | 4k | 3% | |
| shell output (4 transcript tails, first hour) | 17k | 4k | 3% | |
| baseline: system prompt, AGENTS, tool schemas, skill | — | 18.5k | 14% | first request of the session |
| reasoning | — | ~0 | — | 1.8k reasoning tokens over the whole session |

Inside the 58 worker rows (115k chars), by field:

| field | chars | share | verdict |
|---|---|---|---|
| `assignment` | 49.7k | 43% | echo of text the supervisor wrote — removed on repeat rows |
| `message` | 21.2k | 18% | the actual report — keep |
| `last_report` | 14.6k | 13% | the previous `message` again — removed on repeat rows |
| `details` + `transcript` paths | 12.8k | 11% | constant per worker — now first sight only, or when message truncated |
| `cwd` | 3.8k | 3% | constant — first sight only |
| `run_id` + `activity_at` | 4.6k | 4% | unused by the supervisor — dropped from summaries |
| `id`, `name`, `status`, `backend`, `model`, `kind` | 8.7k | 8% | identity — keep |

Plus 11k chars of supervisor summary re-sent after every checkpoint because
`checkpoint_at` changed. Now excluded from the diff.

## 3. How to reproduce the measurement

The Codex rollout is JSONL. Facts another agent needs:

- Each line is `{"timestamp": "...Z", "payload": {...}}`. Timestamps are UTC; use
  `datetime.fromisoformat(ts.replace("Z", "+00:00")).astimezone()` for local time.
- MCP calls are **not** `function_call`s. Codex wraps them in a JavaScript cell:
  payload type `custom_tool_call`, `name == "exec"`, `input` contains
  `tools.mcp__nvim_team__<tool>({...})`. One cell may hold several calls
  (`team_checkpoint` + `worker_start` was common). Shell commands appear inside the
  same cells as `tools.exec_command({cmd: "..."})`.
- Results are `custom_tool_call_output` matched by `call_id`. `output` is a list of
  `{"type": "input_text", "text": ...}`; the text is the MCP envelope
  `{"content": [{"type": "text", "text": "<JSON-encoded result>"}], "isError": bool}`,
  so parse twice.
- `wait` payloads (`function_call`, name `wait`, `cell_id`, `yield_time_ms`) are Codex
  polling a cell whose MCP call exceeded the yield; a 30 s `team_status` forces one.
- `token_count` payloads carry `info.last_token_usage.input_tokens` = context size at
  that request, `cached_input_tokens`, and `info.model_context_window`.

Skeleton:

```python
import json, re, collections
calls, sizes = {}, collections.Counter()
for line in open(ROLLOUT):
    p = json.loads(line)["payload"]; t = p.get("type")
    if t == "custom_tool_call":
        calls[p["call_id"]] = re.findall(r"nvim_team__(\w+)", p.get("input", ""))
    elif t == "custom_tool_call_output":
        for item in json.loads(p["output"]) if isinstance(p["output"], str) else p["output"]:
            text = item.get("text", "")
            if text.startswith('{"content"'):
                inner = json.loads(text)["content"][0]["text"]     # JSON string of the result
                sizes[tuple(calls.get(p["call_id"], []))] += len(inner)
    elif t == "token_count" and (p.get("info") or {}).get("last_token_usage"):
        print(p["info"]["last_token_usage"]["input_tokens"])      # context growth over time
```

Team-side data needs no parsing tricks: `activity.jsonl` per worker has one line per
assignment or state change with `assignment`, `status`, `message`, `updated`.

## 4. Behaviour observed

- **Polling.** 158 `team_status` calls. `wait_seconds` used: 30 ×100, 25 ×27, 20 ×16,
  15 ×8, 10 ×5, 0 ×1. The model shortened waits on its own, which only adds polls.
- **Checkpoints.** 37 handoff rewrites, 26 bundled with a `worker_start` or
  `agent_send`, because the tool text said to update "after decisions, assignments,
  results and blockers". Handoffs averaged ~1.6k chars.
- **Shell use.** 8 commands in 11 hours: `printenv CODEX_THREAD_ID`, `cat SKILL.md`,
  `ps`, `stat`, and four `tail -c` reads of worker transcripts, all before 00:42 on
  09-10. **None during either planner run.**
- **Narration is inferred, not observed.** Between empty polls the supervisor posted
  one sentence a minute such as "The planner is checking PID-file ownership" (00:38,
  three minutes before the planner reported). `team_status` carries no mid-turn
  content and no transcript was read, so these were extrapolated from the assignment.
  Real review happened only at report boundaries and was good: rejecting `pgrep` +
  SIGUSR1 for cross-checkout matching (14:54), relaying the SIGHUP terminal-hangup
  caveat (00:41), routing the overflow-PID finding back with the smallest fix (00:49).
  The skill line that produces the narration is `SKILL.md:123`
  ("give concise progress updates meanwhile").
- **Gate errors.** One: "Save a plan before leaving the planning phase." No wasted
  loops otherwise.
- **Cost vs context.** 97.7% cache hit rate means dollars are not the problem;
  the context window is.

## 5. Changes made (uncommitted, tests green)

Run `cd nvim && python3 scripts/check-team.py` and the two `nvim --headless -u NONE -l
scripts/check-*.lua` checks. Note: **a supervisor's MCP server runs the code it was
launched with.** Team 6127958c's server predates all of this; relaunching that chat
from Neovim picks it up.

Context:
- Mutations (`worker_start`, `agent_send`, `worker_stop`) return `worker_summary`
  minus `assignment` instead of the whole record (`dispatch`, :724). Worth ~26k tokens
  in the example session.
- Repeat worker rows carry id, name, status, and changed fields only
  (`changed_fields`, :466; `team_status`, :476). `details` is kept when `message`
  was truncated. `last_report` never repeats. Worth ~20k tokens.
- `checkpoint_at` excluded from the inbox diff so a supervisor's own checkpoint
  does not re-send its summary. `run_id` and `activity_at` dropped from summaries.
- `handoff` optional on `team_checkpoint` (:205); omit it to keep the saved text.

Reliability (from the DB-1585 handoff):
- Codex workers always get `--output-schema`, including on resume (`worker_command`,
  :510). Previously resumed turns had no schema and a prose-wrapped result errored.
- Codex workers pass `--skip-git-repo-check`; any existing directory works as `cwd`.
- `last_error` on the record from Codex `error` events and Claude `api_retry`
  events, written only when the text changes; surfaced in summaries.
- Non-zero backend exit puts the last three `backend.log` lines in the message.
- `worker_stop` on a `done` worker keeps it `done`. Finish gate compares `done_at`
  (set in `save()` on the transition into `done`) instead of `activity_at`.
- Review gate names the unresolved executors. Phase→role table in the tool text.
- `mcp_config` on `worker_start` for Claude workers (`--mcp-config`). claude.ai
  connectors are unavailable in headless mode regardless.
- Every tool call appends `<epoch> <tool> <seconds>` to the team's `mcp.log`.
- Worker prompt preamble: one turn, incremental artifacts, counts by command,
  re-fetch after external writes.

Earlier round (committed in `e09d951`): dead status plumbing removed, Claude sidebar
status follows the recorded session ID after `/clear`, `codex` (non-Bifrost) dropped
as a backend.

## 6. Proposal: mailbox instead of polling (not implemented)

There is no push path into either model. MCP server→client notifications exist but
neither Claude Code nor Codex injects them into the conversation; a signal reaches the
Python server, not the model. The only primitive that wakes a model is a tool call
that returns. Claude Code's own subagents work the same way: the Agent call is parked
as a background task and a task notification re-invokes the model when it finishes.

So: make `team_status` block until a worker changes, capped at ~20 minutes, and drop
`wait_seconds` (`:477` is the only cap).

- **Claude supervisor.** Claude Code backgrounds any MCP call past 2 minutes
  (`CLAUDE_CODE_MCP_AUTO_BACKGROUND_MS`, default 120000) and delivers the result as a
  task notification; the MCP tool timeout defaults to ~28 hours (`MCP_TOOL_TIMEOUT`,
  ms). Docs: https://code.claude.com/docs/en/mcp.md. The supervisor calls once, may
  end its turn, and is woken on the next worker event. No configuration needed. The
  DB-1585 handoff's "302–933 s blocked calls" were this mechanism working.
- **Codex supervisor.** No cross-turn notification, but a blocking call costs nothing
  while blocked and keeps the turn open. Needs the per-server MCP timeout raised in
  `supervisor_command` (:89) via the `-c mcp_servers.nvim_team.*` flags already
  passed; the key is believed to be `tool_timeout_sec` with a 60 s default —
  **verify before relying on it**. Trade-off: typed messages wait until the call
  returns unless the user interrupts.
- Changes: cap at :477, Codex timeout flag at :89, skill wording from "poll" to
  "call once and handle the notification", the `< 1 s overrun` test assertion.

## 7. Open decisions for the maintainer

- Checkpoint frequency: reword the tool description and skill so the handoff is
  rewritten on decision, phase, or authorization changes and before ending a turn,
  not before every worker mutation. Would have saved most of the 15k.
- Narration: change `SKILL.md:123` to stay silent between empty polls. Small context
  win (3.5%); the real reason is that the narration misrepresents what the supervisor
  can see.
- Light mode from the DB-1585 handoff §3.12: one-line deletion of the
  planner-must-finish check in `team_checkpoint`; deliberately left alone.
- Two Codex model defaults: `gpt-5.6-terra` for executors in the script,
  `gpt-5.6-sol` for supervisors in `~/.codex/config.toml`.
- `alive()` is pid-liveness only; a pid recycled after reboot passes. Marked with a
  `ponytail:` comment.
- Codex `exec`/`wait` wrapper overhead (5%) is not actionable from this repo.

## 8. Where things are

- Team state: `~/.local/state/nvim/agent-teams/<id>/` for the team and each worker id
  in §1. `mcp.log` appears there once the supervisor is relaunched on the new code.
- Supervisor session log: path in §1. Other Codex rollouts from 09-10 14:59–15:07 are
  executor sessions.
- Claude worker sessions: `~/.claude/projects/-Users-byron-seto-Documents-workspace-stackadapt-valhalla/*.jsonl`
  (planner `9b1a213e` is `bad6f65f-…`).
- Plans and review artifacts: `~/Documents/workspace/stackadapt/valhalla/.planning/`
  (`DB-1128-temporal-worker-restart-plan.md`, `DB-1128-sighup-pidfile-plan.md`,
  `DB-1128-worker-restart-review-2026-09-10.md`, validation notes).
- Previous handoff: `supervisor-skill-handoff.md` (DB-1585 run, team `a859757d-…`).
