# Mixed-worker supervisor event delivery

## Goal and authorization

Implement and try out delivery of Claude/Codex worker reports into the current
supervisor without repeated model-driven status polling. The user authorized
this plan and implementation by a separate GPT Sol agent on 2026-09-11.

Keep existing worker backends, saved reports, ownership/authorization checks,
takeover, and terminal access. Make the new delivery paths opt-in until their
client behavior is demonstrated. Do not migrate or interrupt existing teams,
change global client settings, commit changes, or contact external services on
the user's behalf. Use isolated temporary state for experiments. Tiny model
smoke tests directly necessary to verify delivery are within this task; never
substitute a billing route or model when a configured backend fails.

The working tree already contains another agent's changes to agent-team.py,
check-team.py, agents.md, and supervise/SKILL.md. Preserve them.

## Evidence and uncertainties

- Existing runner: nvim/scripts/agent-team.py; shared UI reads its persisted
  records. Workers already return result/question/blocked and durable artifacts.
- Existing team_status compares truncated worker_summary values. A second run
  with identical assignment/report can disappear if both transitions occur
  between reads. Compare full internal report/run identity, not display text.
- MCP stdin is processed synchronously. Do not turn its 30-second wait into a
  20-minute wait as part of this change.
- Claude 2.1.268 is installed. Official documentation exposes
  CLAUDE_CODE_MESSAGING_SOCKET and CLAUDE_CODE_MESSAGING_TOKEN to hooks/Bash,
  permits scripts to post, and describes an optional first-line auth object on
  macOS. Exact message payload, acknowledgement, MCP environment inheritance,
  idle wakeup, and inbound controls must be verified rather than guessed.
- Codex CLI 0.154.0 exposes app-server, --remote, Unix endpoints, and app-server
  proxy. Official docs describe turn/start with input: [] and toolOutput:
  {name, namespace, output}; this remains tool output and queues into an active
  turn. Verify the installed schema, Bifrost wrapper/config propagation, terminal
  attachment to the same thread, and approval routing before enabling delivery.
- These are experimental client interfaces. Unsupported behavior is a reason
  to retain polling for that backend, not to impersonate user keystrokes or
  write directly into client conversation/history files.

Sources:

- https://code.claude.com/docs/en/cross-session-messaging#the-sessions-inbox-socket
- https://developers.openai.com/codex/app-server/
- https://developers.openai.com/codex/mcp/

## Stage 1: prove the entry points

Read the full runner/control flow and existing checks before editing. Consult
Ponytail and OpenAI Docs for implementation; if changing a skill, read the
skill-creator instructions too. Do not activate supervise to supervise this
implementation: the user asked for one independent Codex implementation agent.

Build the smallest isolated, repeatable protocol experiment for each client.
Prefer existing CLI facilities and Python stdlib. Do not introduce a WebSocket
implementation, service framework, queue broker, or SDK until the installed
stdio/proxy/Unix facilities are shown insufficient.

1. Claude: establish how the SessionStart hook can capture the current endpoint
   and, when needed, its token. Determine the real message envelope and response
   from current documentation/local client evidence. Prove one harmless report
   reaches an idle isolated session; test a busy session when feasible. Keep the
   token out of ordinary records, summaries, transcripts, and logs. Never relax
   crossSessionInbound or sandbox policy globally to make the experiment pass.
2. Codex: inspect the installed app-server schema. Start an isolated app-server
   using the configured codex-bf route. Determine the simplest way for both the
   existing terminal UI and an event sender to address the same live thread.
   Verify report-as-tool-output while idle and active, session identity, and
   which client receives approval requests. Confirm disconnect/reconnect does
   not fork the conversation or start a second engine for one thread.
3. Record observed commands/versions/results, including any missing credentials
   or unverified interactive step. If a path is unsupported, do not build a
   speculative adapter for it: leave that backend on polling and deliver the
   reproducible experiment plus exact next step.

## Stage 2: minimal integration for proven paths

Prefer extending agent-team.py and its existing checks. A small separate helper
is justified only for an independently runnable protocol experiment or launcher.

- Add an explicit per-launch/per-team opt-in using one documented mechanism.
  Existing launches retain their current behavior. Report the effective delivery
  mode/capability in initial team metadata so the supervisor knows whether to
  await events or use team_status. Missing capability must be explicit.
- Save each worker report before attempting delivery. Use worker ID plus run ID
  and an event kind/revision as identity. Distinguish result, question, blocked,
  and backend failure. Do not publish token streams, every heartbeat, or every
  repeat retry error. Existing logs remain the source for detail.
- Reuse persisted records/activity; do not create a second authoritative task
  store. Reports should contain concise outcome, worker/run identity, and paths
  to complete evidence. Mark them as worker/tool reports, never user approval.
- Resolve the current owner/session at delivery time. Paused/finished teams must
  not be automatically restarted. Endpoint registration must refresh on session
  reset/reconnect; stale owners/endpoints cannot receive new work notifications.
- Bound transport operations and keep failures out of the worker result path:
  a delivery failure must not turn successfully completed work into error.
  Retain undelivered events for recovery and surface delivery failure separately.
- Track delivery acceptance with the smallest persisted cursor/receipt needed.
  Do not claim exactly-once processing: a crash between acceptance and saving a
  receipt can cause replay. Stable IDs let the supervisor recognize duplicates.
  Transport acceptance is not proof the model processed a report.
- Keep team_status/full takeover recovery correct and independent of push
  receipts. A manual status read must not consume a report before push delivery.
  Fix internal run/report comparison without increasing normal response size.
- For Codex, own the app-server lifecycle explicitly and preserve Bifrost,
  model, MCP, sandbox, approval, cwd, and hook configuration at the engine.
  Keep the terminal UI attached to that engine. Reuse the existing team process
  lifecycle; no unrelated global daemon changes.

## Stage 3: focused validation

Extend the existing runnable Python checks or add one small isolated check.
Use fake local receivers for deterministic delivery behavior, plus the real
client smoke tests from Stage 1. Minimum coverage:

- Two runs with identical visible results remain distinct; changed report text
  after the 1200-character display cutoff is detected.
- Successful report delivery; refused/unavailable receiver leaves work done
  and recoverable; token/payload errors do not leak credentials.
- A repeat delivery pass does not resend accepted events; recovery after an
  ambiguous failure preserves identity and does not silently discard reports.
- Pause prevents wakeup; takeover/reset routes to the new owner only.
- Ordinary polling remains usable with delivery disabled or unavailable.
- Codex UI and sender share the same thread; idle and active delivery preserve
  tool-output provenance; user messages and approval handling remain usable.

Run python3 scripts/check-team.py from nvim. Run the existing headless Lua
checks when launcher/UI integration warrants them. Do not weaken existing checks
to make the new path pass. Inspect the final diff for user changes preserved.

## Stage 4: instructions and handoff

Update agents.md with exact opt-in, restart requirements, how to run experiments,
fallback, and known limitations. Update supervise/SKILL.md only for implemented,
verified capabilities: use events when available, polling otherwise; do not
create parallel waiters or narrate imagined progress. Align checkpoint wording
with decisions/authorization/next actions rather than duplicated bookkeeping.

Add an implementation-results section below (or a short linked experiment file)
with each backend marked verified / protocol-only / blocked, evidence and checks,
and precise remaining interactive trials. Do not describe a mock receiver test
as a real client wakeup. Default enablement requires real-client evidence.

## Acceptance

A user can opt in to each proven path and receive a report from either worker
backend without model-driven waiting polls, while retaining terminal interaction,
authorization scope, takeover, and durable recovery. Unproven paths stay visibly
on polling with a runnable experiment and a concrete explanation. No new model
or billing fallback, global setting change, or live-team migration is needed.

## Implementation results — 2026-09-11

Claude Code 2.1.268 is verified for native idle and busy wakeup. An isolated
tmux session registered its `CLAUDE_CODE_MESSAGING_SOCKET`, token, and session ID
through `SessionStart`; the endpoint file was mode 0600. Sending the documented
auth line plus `type=user` peer envelope produced Claude's native cross-session
provenance banner. The idle trial replied `IDLE_PROBE_OK` after four seconds. In
the busy trial, the current turn completed its harmless `sleep 5` tool and
replied `BUSY_BASE_DONE`, then the queued peer event started a new turn and
replied `BUSY_EVENT_OK`. Existing inbound controls were not changed.

Claude event delivery is implemented as an explicit launch opt-in with
`NVIM_TEAM_DELIVERY=events`; the default is polling. It applies only to a newly
spawned Claude supervisor process. SessionStart atomically registers the private
endpoint sidecar and SessionEnd removes it. After saving a terminal worker
result, the runner resolves the stable team to its current owner and matching
session, gates on `execution == "authorized"`, and sends a concise peer/tool
report with worker ID, run ID, kind, result, and evidence paths. A dedicated
per-team delivery lock serializes the bounded local socket write with pause,
finish, takeover, reset, follow-up, stop, and deletion. Receipt metadata is
owner/session scoped and exposed in worker summaries without secrets. Delivery
failure never changes worker completion.

Receipts deliberately distinguish `socket_write=complete` from
`acceptance=unconfirmed` and `model_processed=unconfirmed`. There is no
background retry. A crash after socket write but before receipt persistence can
replay the stable event ID; an ambiguous failed write retains that same ID.
`team_status(full=true)` remains the authoritative recovery path and never
depends on delivery receipts.

Codex CLI/app-server 0.154.0 is protocol-only, not enabled for supervisor
wakeup. The runnable probe starts the configured Bifrost app-server on a private
loopback WebSocket and a persistent thread in an empty temporary cwd. The final
trial resumed that thread from a second client (`same_thread=true`), accepted
and completed a standalone tool-output turn, delivered the same completed turn
to the original observer, and found the stable event ID in `thread/read`:
thread `01a09180-5bf4-7612-9828-677ba2d960aa`, turn
`01a09180-6644-7412-9fcb-f16550aa6f05`. An earlier ephemeral-thread attempt
correctly failed resume with `no rollout found`. TUI attachment to this engine
and approval routing were not proven, so Codex remains visibly on polling.

`nvim/scripts/probe-event-delivery.py` preserves both repeatable experiments.
`check-team.py` now covers fake successful delivery and repeat suppression,
ambiguous failure identity, unchanged worker completion, pause gating,
takeover/reset routing, secret exclusion, ordinary polling, identical visible
results across distinct run IDs, and full-report changes after the 1200-character
display cutoff. The compact inbox stores a full-field digest internally and
returns `report_changed`, `run_id`, and the detail path only when an otherwise
invisible change occurs.
