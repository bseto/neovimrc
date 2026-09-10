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

Claude status comes from its session files, matched by process ancestry.
The default, personal, and inherited `CLAUDE_CONFIG_DIR` locations are checked.
New Codex chats receive launch-scoped lifecycle hooks that write status into
temporary files. They observe events without deciding approvals. Unknown or
unsupported events remain unknown; arbitrary conversational questions aren't
separately classified. Very brief state transitions between polls can be missed.

Restart Neovim to load these changes. Existing agent processes aren't migrated.

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

Open a new chat with `<leader>cn`, brainstorm your project, then invoke
`/supervise project-name` in Claude or `$supervise project-name` in Codex.
The same conversation becomes the supervisor. Repeating
the command updates its brief rather than creating another team. Existing chats
launched before this integration need a new launch to receive its MCP tools.

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

The supervisor gets five session-scoped MCP tools: `team_start`, `worker_start`,
`team_status`, `agent_send`, and `worker_stop`. Workers can use `codex-bf`,
`codex`, `claude`, or `claude-bf`. They report a structured result, question,
or permission blocker at the end of a turn. Answering a question resumes the
same backend session. The supervisor uses a 30-second inbox wait while workers
are active; it must stay in that loop to receive updates autonomously. If it
ends its turn, tell it to check its team. Opening the UI alone does not send
prompts or wake a paused supervisor.

Codex workers use workspace-write with automatic approval review; Claude
workers use auto mode and deny requests that would require an interactive
permission prompt. No approval is converted into a conversational question or
bypassed. Workers share the supervisor's directory by default. For concurrent
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
