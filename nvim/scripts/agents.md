Agent chats use a narrow, two-line sidebar: number and variant on the first
line, custom title on the second. Rename with `<leader>cR` or `r` in the sidebar.

- `Esc` enters Normal mode in the terminal and leaves the chat open.
- `Ctrl-g` sends a literal Escape to the agent, in either Terminal or Normal mode.
- `i` resumes typing into the terminal.
- `Ctrl-h` in Normal mode focuses the sidebar; `Ctrl-l` returns to the chat.
- `j` / `k` select sidebar entries; Enter opens one; `n` creates a chat.
- `Ctrl-,` toggles the chat workspace; `q` in Normal mode hides it.
- `<leader>c1` through `<leader>c9` open the corresponding chat.

Status symbols: `●` working, `!` needs approval, `○` ready for input,
`×` exited, `?` unknown. `*` marks a response that finished while another
buffer was focused. Opening that chat clears it. Status updates once per second.

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

Executors use `codex-bf --model gpt-5.6-terra` with medium reasoning, explicitly
selecting the Bifrost provider. This balanced default can be overridden per
worker; availability depends on the gateway key. No automatic model or billing
fallback is configured. The planner defaults to Opus; a supported Fable model
can be passed explicitly. Each worker keeps its role and model on resume.

After execution, the supervisor asks whether review should use Bifrost GPT or
Claude subscription, then starts a separate reviewer. Review findings go back
to executors for fixes and then back to the reviewer. All agents ask the
supervisor first; it answers from agreed decisions and escalates only unresolved
questions to you. The tools enforce phase/backend selection and require a
completed planner plus saved plan before execution. The skill requires review
findings to be resolved, beyond the tool's completed-review check.

`team_checkpoint` saves `phase`, the absolute `plan_path`, and the chosen
`reviewer_backend`; `handoff` may be omitted to keep the saved one. Stopping a
`done` worker keeps it `done`, and the finish gate compares reviewer and executor
completion times, so later stops never make a review look stale. Authorization remains separate: planning permission alone
does not authorize implementation. These fields and worker roles/models survive
takeover and appear in team summaries. Team rows show planner/executor/reviewer.

The supervisor saves a 1–3 paragraph goal in `brief.md` and a short current
handoff in `handoff.md`, beside the authoritative `agent.json` in the team's
state directory. It checkpoints decisions, next steps, and authorization scope
throughout the conversation. Worker records
remain live independently, so takeover can see updates since the last checkpoint.
Assignments, follow-ups, state changes, and full results are also recorded
automatically in each worker's `activity.jsonl`. The worker record retains its
current assignment and last report. The supervisor only needs to checkpoint
decisions, authorization, and next steps, rather than duplicate worker bookkeeping.
The detail page shows the age of that explicit checkpoint; hooks and takeover
do not reset its timestamp. An absent timestamp displays as "never".

For a fresh supervisor context, clear the conversation using your client's
reset command (for example `/clear` in Claude), then invoke
`/supervise-takeover <team-id>` in Claude or `$supervise-takeover <team-id>` in
Codex. You can also open a fresh Neovim agent chat and run that command there.
The team detail page displays both commands with the stable team ID. Takeover
commands can be copied with `y` from a team or worker row or detail page. The
command uses the current supervisor's client syntax and goes to the unnamed
register and, when available, the system clipboard. Both client variants remain
visible in the detail page if you want to switch clients.
Takeover preserves workers, transcripts, and planning/authorized/paused state; `i` opens
the current supervisor. It returns a fresh ownership token and rejects mutations
using the old token. This protects team-tool calls, not arbitrary shell activity.
An already-running worker finishes its current turn normally.

After installing this update, restart Neovim for the view changes and launch a
fresh agent chat for the new MCP tools and Claude SessionStart hook. Exit old
supervisor processes before the first takeover: MCP servers already running the
previous code cannot enforce ownership tokens. Subsequent takeovers work with
the updated tools after a reset or from a new chat. The SessionStart hook records
Claude's new session ID after `/clear`; Codex supplies `CODEX_THREAD_ID` explicitly.

`<leader>ct` opens the team view. `j/k` select rows, `l` or Enter inspect an
agent, `h` returns to its parent, `i` opens the supervisor's live chat, and `q`
closes the view. Worker pages show their transcript and backend errors. Send
worker instructions through the supervisor, which owns their context. New
Neovim instances discover saved teams and reattach their supervisor on `i`.

`a` archives the selected team (or restores it from the archive list). Archive
hides the team without stopping agents or removing history. `A` switches between
active and archived teams. `d` asks for confirmation, stops the team's supervisor
and workers, and removes its local team records and transcripts. These actions
target the whole team even from a worker row. Project files, worktrees, branches,
and the backends' own conversation history remain intact. If workers cannot be
stopped, deletion reports an error and retains the team for a retry.

The Agents sidebar has the same `a` (archive) and `d` (delete) keys for its
selected chat. `A` opens the archived chats/teams list; press `a` there to restore
an entry or `i` to reopen it. Ordinary chats can also be archived, even before
they become supervisors. `?` in the sidebar lists all its actions. Archive is a
way to hide something you might return to; it does not pause or cancel work.

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
30 seconds. The inbox does not alter the durable records or Neovim's full view.
If only a run ID or report text beyond the display cutoff changed, the compact
update carries `report_changed`, the new `run_id`, and the detail path.
Summaries carry `last_error` while a worker is retrying a failed connection or
API call, and backend exit errors include the last lines of `backend.log`. Every
tool call's duration is appended to the team's `mcp.log`; Claude Code itself
backgrounds any tool call past two minutes and delivers it as a notification.

Planners run on `claude`, executors on `codex-bf`, reviewers on the chosen one. They report a structured result, question,
or permission blocker at the end of a turn. A turn ends when the model stops
calling tools, so an interim message becomes that turn's report. Answering a
question resumes the same backend session. In polling mode, the supervisor uses
a 30-second inbox wait while workers are active and must stay in that loop to
receive updates autonomously. In event mode, the verified Claude peer message
wakes the idle session; if it does not arrive, tell the supervisor to check its
team. Opening the UI alone does not send prompts or wake a paused supervisor.

Codex workers use workspace-write with automatic approval review; Claude
workers use auto mode and deny requests that would require an interactive
permission prompt. No approval is converted into a conversational question or
bypassed. Codex workers pass `--skip-git-repo-check`, so any existing directory
works as `cwd`; if a Codex plugin's OAuth has expired they report `blocked`, and
`codex mcp login <server>` followed by `agent_send` resumes them. Claude workers
accept `mcp_config` (file path or JSON) for extra MCP servers; claude.ai
connectors are unavailable in headless mode. Workers share the supervisor's directory by default. For concurrent
writers, the supervisor must supply separate existing worktree directories;
this version does not create or merge worktrees automatically.

The view shows registered supervisors and their direct workers, not arbitrary
native subagents launched outside the team tools. Worker output updates as
backend events arrive. The supervisor's full conversation remains in its
attached terminal; its team page shows its brief and workers. The Codex skill
registers `CODEX_THREAD_ID` for reconnect after process exit. Lifecycle hooks also
record session IDs and status when enabled/trusted; otherwise sidebar status may
be unknown. If its ID is missing after a process exits, the launcher reports the
problem instead of resuming an unrelated conversation.

Additional isolated checks (no model calls):

    python3 scripts/check-team.py
    nvim --headless -u NONE -l scripts/check-team-ui.lua

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
