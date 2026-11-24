Agent chats use a narrow, two-line sidebar: number and variant on the first
line, custom title on the second. Rename with `<leader>cR` or `r` in the sidebar; the name is saved as `name` in
the chat's state directory and survives restarts.

- `Esc` enters Normal mode in the terminal and leaves the chat open.
- `Ctrl-g` sends a literal Escape to the agent, in either Terminal or Normal mode.
- `i` resumes typing into the terminal.
- `Ctrl-h` in Normal mode focuses the sidebar in the popup layout; `Ctrl-l` returns to the chat.
- `j` / `k` select sidebar entries; Enter opens one; `n` creates a chat.
- `d` in the sidebar asks for confirmation, stops the chat's agent and any workers
  it started, and removes their saved records and transcripts. Project files,
  worktrees, branches and the backends' own conversation history stay.
- `Ctrl-,` toggles the chat workspace; `q` in Normal mode hides it.
- `<leader>c1` through `<leader>c9` open the corresponding chat.
- `<leader>c0` opens the next chat that needs you: waiting first, then unread.
- `<leader>cL` switches chats between the popup and a right-hand panel for this
  Neovim session. The panel has no sidebar and its winbar shows the name and
  status; `Ctrl-h` goes to the code window, LazyVim's `Ctrl-l` comes back, `q`
  hides it.

Status symbols: `●` working, `!` needs approval, `○` ready for input,
`×` exited, `?` unknown. `*` marks a response that finished while the chat
was not visible. Opening that chat clears it. Lualine
shows `!N *N` (waiting / unread) whenever either is non-zero, and nothing when both are zero. Status updates once per second.

Claude status comes from its session registry, matched by the session ID the
launcher's SessionStart hook records (so it survives `/clear`). The default,
personal, and inherited `CLAUDE_CONFIG_DIR` locations are checked. Codex status
comes from launch-scoped lifecycle hooks that record it in the chat's team
record. Hooks observe events without deciding approvals. Very brief state
transitions between polls can be missed.

Restart Neovim to load these changes. Existing agent processes aren't migrated.

Worker-report wakeups are enabled by default for newly launched Claude supervisors.
Open a fresh Claude chat without setting an environment variable; the
SessionStart hook registers that session's private socket in a mode-0600
sidecar. Existing running chats are not changed. Codex supervisors remain on
`team_status` polling. Set `NVIM_TEAM_DELIVERY=poll` before launching Neovim to
explicitly use polling for new Claude chats too. Team metadata reports
`delivery: events` only while the current Claude owner's registered endpoint
matches its current session; takeover to Codex or a stale/missing endpoint
reports polling instead.

The runner saves the complete worker result first, then sends a concise native
peer report only while execution is `authorized`. Pause, finish, deletion,
takeover, and session reset are serialized against delivery. Receipts distinguish
a complete socket write from unconfirmed transport acceptance and unconfirmed
model processing; delivery failure never changes completed worker work and is
shown in the worker summary. There is no background retry. Use
`team_status(full=true)` to recover any report after a failed or missing wakeup;
stable event IDs make ambiguous repeats recognizable.

An idle session receives a report as a new turn, within about ten seconds. A
session that is mid-turn does not: Claude Code absorbs the message into the
running turn as a system reminder (`absorbed_mid_turn`) rather than queueing a
new one, so a report that lands while the supervisor is working produces no
wakeup of its own. The supervisor's one nonwaiting `team_status` before it ends
a turn is what closes that window; the skill requires it for this reason.

The isolated real-client probes are runnable from the `nvim` directory and make
small real model calls. `claude-capture` is a hook helper, not a standalone
command: it requires Claude's SessionStart JSON on stdin and messaging variables
in the hook environment. In the first terminal, launch Claude with that hook
without changing the existing inbound controls:

    probe_dir="$(mktemp -d)"
    probe_script="$PWD/scripts/probe-event-delivery.py"
    probe_settings="$(python3 -c 'import json, shlex, sys; command = shlex.join(("python3", sys.argv[1], "claude-capture", "--out", sys.argv[2])); print(json.dumps({"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": command}]}]}}))' "$probe_script" "$probe_dir/endpoint.json")"
    printf 'Private probe directory for terminal 2: %s\n' "$probe_dir"
    claude --settings "$probe_settings"

After Claude is idle, paste the printed private directory into a second terminal
in the same `nvim` checkout and send the harmless event:

    probe_dir='/paste/the/printed/private/path'
    python3 scripts/probe-event-delivery.py claude-send --endpoint "$probe_dir/endpoint.json" --message 'Harmless probe'

Exit the isolated Claude session and remove the private directory when finished.
The separate Codex probe is:

    python3 scripts/probe-event-delivery.py codex --model gpt-5.6-terra

It proves app-server multi-client tool-output delivery only; it does not enable
Codex supervisor wakeups because the current TUI is not attached to that engine.

## Supervisor teams

New Claude and Codex chats run inside a dedicated `nvim-agents` tmux
server. Hiding the chat or quitting Neovim detaches the view; the conversation
keeps running. Explicitly exiting the agent still ends its process. Team records,
worker transcripts, and resumable session IDs are stored under
`~/.local/state/nvim/agent-teams/` (override with `NVIM_TEAM_HOME`). A machine
restart stops active processes; saved conversations can be resumed.

After quitting Neovim, `<leader>cp` lists chats still running in `nvim-agents`
but not open here (`↺`, with `(open elsewhere)` if another Neovim is attached).
Choosing one reattaches to the running agent with its name and backend. Only live
sessions are listed.

Install the shared skill once for each client (both links use the same source):

    ln -s "$HOME/.config/nvim/skills/supervise" "$HOME/.claude/skills/supervise"
    ln -s "$HOME/.config/nvim/skills/supervise" "$HOME/.agents/skills/supervise"
    ln -s "$HOME/.config/nvim/skills/supervise-takeover" "$HOME/.claude/skills/supervise-takeover"
    ln -s "$HOME/.config/nvim/skills/supervise-takeover" "$HOME/.agents/skills/supervise-takeover"

Open a new chat with `<leader>cn`, brainstorm your project, then invoke
`/supervise project-name` in Claude or `$supervise project-name` in Codex.
The same conversation becomes the supervisor. Repeating
the command updates its brief rather than creating another team. Existing chats
launched before this integration need a new launch to receive its MCP tools.

Invoking the skill starts discussion. The supervisor coordinates and answers
worker questions; workers perform investigation, implementation, testing, and
detailed review. It starts work only within your explicit authorization.

Every project has a planning, execution, and review phase. The planner uses
plain `claude --model opus` with the normal account selected by your shell
wrapper. Inherited Anthropic gateway/API environment overrides are removed so
a Bifrost supervisor does not redirect the planner. Keep that Claude account
logged in; account limits and settings still apply. The planner researches,
asks the supervisor questions, and saves a detailed plan before implementation.

Each worker has a purpose, and the team's route for that purpose picks its
backend and model:

| Purpose | Kind | Default backend and model |
|---|---|---|
| `plan` | planner | `claude --model opus` |
| `research` | planner, read-only brief | `claude-bf --model opus` |
| `code` | executor | `claude --model opus` (`sonnet` when the plan spells out the edits) |
| `qa` | executor | `claude-bf --model sonnet` |
| `review` | reviewer | the user's choice |

`claude-bf` workers always get an explicit `--model`, because the wrapper forces
`ANTHROPIC_MODEL=claude-opus-4-8` otherwise. Through Bifrost, `opus` and
`sonnet` resolve to `claude-opus-5-5` and `claude-sonnet-5-5`. `codex-bf`
workers default to `gpt-5.6-terra` with medium reasoning. `team_checkpoint`
changes a route (`routes={"qa": {"backend": "codex-bf"}}`; `{}` resets it), and
`worker_start` accepts a one-off `backend` or `model`. Each worker keeps its
backend and model on resume.

`team_checkpoint(budget="bifrost")` is the budget switch: every route on
`claude` starts on `claude-bf` from the next worker, without a restart.
`budget="subscription"` switches back. No automatic billing fallback exists.

After execution, the supervisor asks whether review should use Bifrost GPT,
Bifrost Claude or Claude subscription, then starts a separate reviewer. Review findings go back
to executors for fixes and then back to the reviewer. All agents ask the
supervisor first; it answers from agreed decisions and escalates only unresolved
questions to you. The tools enforce phase/backend selection and require a
completed planner plus saved plan before execution. The skill requires review
findings to be resolved, beyond the tool's completed-review check.

`team_checkpoint` saves `phase`, the absolute `plan_path`, `routes`, `budget`,
and the chosen `reviewer_backend`; `handoff` may be omitted to keep the saved one. Stopping a
`done` worker keeps it `done`, and the finish gate compares reviewer and executor
completion times, so later stops never make a review look stale. Authorization remains separate: planning permission alone
does not authorize implementation. These fields and worker roles/models survive
takeover and appear in team summaries.

The supervisor saves a 1–3 paragraph goal in `brief.md` and a short current
handoff in `handoff.md`, beside the authoritative `agent.json` in the team's
state directory. It checkpoints decisions, next steps, and authorization scope
throughout the conversation. Worker records
remain live independently, so takeover can see updates since the last checkpoint.
Assignments, follow-ups, state changes, and full results are also recorded
automatically in each worker's `activity.jsonl`. The worker record retains its
current assignment and last report. The supervisor only needs to checkpoint
decisions, authorization, and next steps, rather than duplicate worker bookkeeping.

For a fresh supervisor context, clear the conversation using your client's
reset command (for example `/clear` in Claude), then invoke
`/supervise-takeover <team-id>` in Claude or `$supervise-takeover <team-id>` in
Codex. You can also open a fresh Neovim agent chat and run that command there.
The supervisor shows both commands with the stable team ID.
Takeover preserves workers, transcripts, and planning/authorized/paused state. It returns a fresh ownership token and rejects mutations
using the old token. This protects team-tool calls, not arbitrary shell activity.
An already-running worker finishes its current turn normally.

After installing this update, launch a
fresh agent chat for the new MCP tools and Claude SessionStart hook. Exit old
supervisor processes before the first takeover: MCP servers already running the
previous code cannot enforce ownership tokens. Subsequent takeovers work with
the updated tools after a reset or from a new chat. The SessionStart hook records
Claude's new session ID after `/clear`; Codex supplies `CODEX_THREAD_ID` explicitly.

The supervisor gets seven session-scoped MCP tools: `team_start`, `team_takeover`,
`team_checkpoint`, `worker_start`, `team_status`, `agent_send`, and `worker_stop`.
Mutating calls carry an ownership token; worker starts and follow-ups require
saved execution authorization. Inbox reads return short summaries rather than
repeating the entire brief and assignments.
`team_status` returns all worker summaries on its first call, then only changes
within that MCP connection: a worker already reported comes back with its id, name,
status, and the fields that changed, so assignments and paths are not echoed again. `workers: []` means no updates, while `active` counts
running workers. `full=true` recovers the full overview; a server reconnect or
takeover resets the inbox. Reports and assignments are capped at 1200 characters
per field with paths to full activity and transcripts. Updates that arrive
between polls are returned immediately; unchanged running teams wait up to
30 seconds. The inbox does not alter the durable records.
If only a run ID or report text beyond the display cutoff changed, the compact
update carries `report_changed`, the new `run_id`, and the detail path.
Summaries carry `last_error` while a worker is retrying a failed connection or
API call, and backend exit errors include the last lines of `backend.log`. Every
tool call's duration is appended to the team's `mcp.log`; Claude Code itself
backgrounds any tool call past two minutes and delivers it as a notification.

Workers run on their purpose's route; `team_status` shows the effective
`routes` and `budget`. `planner_backend` and `reviewer_backend` are shorthands
for the `plan` and `review` route backends. A reviewer must use the review
backend the user chose. Several workers of the phase's role may run at once. They report a structured result, question,
or permission blocker at the end of a turn. A turn ends when the model stops
calling tools, so an interim message becomes that turn's report. Answering a
question resumes the same backend session. In polling mode, the supervisor uses
a 30-second inbox wait while workers are active and must stay in that loop to
receive updates autonomously. In event mode, the verified Claude peer message
wakes the idle session; if it does not arrive, tell the supervisor to check its
team.

Codex workers use workspace-write with automatic approval review; Claude
workers use auto mode and deny requests that would require an interactive
permission prompt. No approval is converted into a conversational question or
bypassed. Codex workers pass `--skip-git-repo-check`, so any existing directory
works as `cwd`; if a Codex plugin's OAuth has expired they report `blocked`, and
`codex mcp login <server>` followed by `agent_send` resumes them (the Codex chat
launcher logs into Atlassian before each new or resumed Codex process
and stops if login fails; attaching to a running process skips login). The
`codex mcp list --json` auth status is `unknown`, so it cannot reliably skip
login for already-authenticated servers. Claude
workers accept `mcp_config` (the name of a user-approved config in `~/.config/nvim-agents/mcp/<name>.json`) for extra MCP servers; claude.ai
connectors are unavailable in headless mode. Workers share the supervisor's directory by default. For concurrent
writers, the supervisor must supply separate existing worktree directories;
this version does not create or merge worktrees automatically.

The Codex skill
registers `CODEX_THREAD_ID` for reconnect after process exit. Lifecycle hooks also
record session IDs and status when enabled/trusted; otherwise sidebar status may
be unknown. If its ID is missing after a process exits, the launcher reports the
problem instead of resuming an unrelated conversation.

Additional isolated checks (no model calls):

    python3 scripts/check-team.py

## Bifrost budget

Codex Bifrost chats show the key's remaining budget in the Neovim chat footer
and lualine. The lookup runs asynchronously, at most once per minute while
the chat is visible. Failed refreshes keep the previous amount marked `[stale]`;
no successful lookup shows `unavailable`. This is the key's reported quota,
not a guarantee that every shared team or provider budget has capacity.

The same helper is usable from other statuslines or scripts:

    python3 ~/.config/nvim/scripts/bifrost-budget.py
    python3 ~/.config/nvim/scripts/bifrost-budget.py --json
    python3 ~/.config/nvim/scripts/bifrost-budget.py --refresh

It reads `BIFROST_API_KEY` or the existing `bifrost_api_key` Keychain entry,
and caches normalized budget data under `~/.cache/nvim/bifrost-budget/`.
Credentials are never stored in the cache. JSON includes each budget window's
limit, used amount, remaining amount, last reset, and fetch/stale metadata.
Codex's own built-in TUI statusline has fixed fields and cannot run this custom
command; the display is provided by Neovim around the Codex terminal.

    python3 scripts/check-bifrost-budget.py

Run the isolated UI check from the nvim directory:

    nvim --headless -u NONE -l scripts/check-agents.lua

The check launches local `cat` terminals instead of AI agents.

## Commander chat

`<leader>ck` opens the one commander chat (plain `claude`). It starts one if none runs and reopens the live one. A second one is refused. Sidebar `d` deletes it like any chat.

- It reads live chats on the agent tmux server that run under `~/.claude`, and Codex chats read-only. It does not see `~/.claude-personal` chats, workers or itself.
- Tools: `chat_list` (first call all chats, later calls only changes), `chat_read` (transcript or screen), `chat_send`. The rules are in `scripts/commander.md`, passed with `--append-system-prompt-file`, so they survive `/clear`.
- The commander launches with `--tools Skill,ToolSearch` (no Read, so it cannot read raw transcripts past the copy check), `--strict-mcp-config`, deny rules for Bash, Write, Edit, Monitor, Agent, web tools and `SendMessage`, and an MCP server started with `--commander`. The chat tools unlock from that flag only, never from `role` in `agent.json`. A commander cannot call team tools.
- `chat_send` runs without a permission prompt: the launch `--settings` allow it. The commander sends only when Byron's own message asks for it, and the send guards (idle screen, text limits, rate limit, audit log) still apply.
- Send path: one line, at most 500 characters, 3 items and 1200 characters per call, starts with an ASCII letter, no control or format characters, tagged `[commander] `. Each item needs the full chat id and the current name. Refused: Codex chats, chats that are not `idle` (`shell` means a background shell task runs), a dialog, a non-empty input box, tmux copy mode, duplicate names, text copying 40+ characters of text it just read, and rate limits (1 per chat per 30 s, 10 per 5 min).
- Before typing it reads the screen twice, at least 2 s apart, and needs the plain idle layout. The text goes in as one bracketed paste. After 0.3 s the input box must hold exactly that text, with no dialog and no copy mode. Only then it sends `Enter`. Otherwise the text stays in the box and the result says so.
- Residual risk: a dialog that opens in the milliseconds before `Enter` gets `Enter`. Your approval is the gate. Your own grid reply into the same chat can mix with a send. Any chat runs as your user and can still reach every file and socket the commander reads.
- Watcher notices: into waiting, a finished turn (`working` to `idle` or `shell`), exited. At most one per 30 s. Counts only, no chat text.
- Audit: `<NVIM_TEAM_HOME>/<commander id>/commander.log`, JSON lines with the full text, its sha256 and the hash of the previous line.
- `NVIM_TEAM_TMUX=<name>` points the scripts and the grid at another tmux server (default `nvim-agents`). Tests use it.
