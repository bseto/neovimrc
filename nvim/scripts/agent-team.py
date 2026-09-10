#!/usr/bin/env python3
"""Local team tools, durable worker jobs, and agent terminal attachment. Stdlib only."""

import argparse
import contextlib
import fcntl
import json
import os
from pathlib import Path
import re
import shlex
import signal
import shutil
import subprocess
import sys
import threading
import time
import uuid

SCRIPT = Path(__file__).resolve()
BACKENDS = ("claude", "claude-bf", "codex", "codex-bf")
EXECUTION_MODEL = "gpt-5.6-terra"
SCHEMA = json.loads(SCRIPT.with_name("team-result.schema.json").read_text())
ROOT = Path(os.environ.get("NVIM_TEAM_HOME", Path.home() / ".local/state/nvim/agent-teams"))


def directory(agent_id):
    # IDs come from tools and persisted records, never allow path traversal.
    return ROOT / str(uuid.UUID(agent_id))


def read(agent_id):
    return json.loads((directory(agent_id) / "agent.json").read_text())


def save(record):
    folder = directory(record["id"])
    folder.mkdir(parents=True, exist_ok=True, mode=0o700)
    record["updated"] = time.time()
    if record.get("role") == "worker":
        previous = read(record["id"]) if (folder / "agent.json").exists() else {}
        fields = ("run_id", "assignment", "status", "message")
        if any(previous.get(key) != record.get(key) for key in fields):
            record["activity_at"] = record["updated"]
            if record.get("message") and record.get("status") not in ("starting", "working", "stopping"):
                record["last_report"] = record["message"]
            event = {key: record[key] for key in (*fields, "updated") if key in record}
            with (folder / "activity.jsonl").open("a") as activity:
                activity.write(json.dumps(event) + "\n")
    temporary = folder / ("record-" + str(uuid.uuid4()))
    temporary.write_text(json.dumps(record, indent=2) + "\n")
    temporary.replace(folder / "agent.json")


@contextlib.contextmanager
def locked(agent_id):
    folder = directory(agent_id)
    folder.mkdir(parents=True, exist_ok=True, mode=0o700)
    with (folder / "lock").open("a") as file:
        fcntl.flock(file, fcntl.LOCK_EX)
        yield


def records():
    result = []
    for path in ROOT.glob("*/agent.json"):
        try:
            result.append(json.loads(path.read_text()))
        except (OSError, ValueError):
            continue
    return sorted(result, key=lambda item: item.get("created", 0))


def log(agent_id, speaker, message):
    with (directory(agent_id) / "chat.md").open("a") as file:
        file.write(f"\n## {speaker}\n\n{message}\n")


def tmux(*args, **kwargs):
    return subprocess.run(["tmux", "-L", "nvim-agents", "-f", "/dev/null", *args], **kwargs)


def session_name(agent_id):
    return "team-" + str(uuid.UUID(agent_id))


def supervisor_command(record, exists):
    backend, agent_id = record["backend"], record["id"]
    server = {"command": sys.executable,
              "args": [str(SCRIPT), "mcp", "--supervisor", agent_id],
              "env": {"NVIM_TEAM_HOME": str(ROOT)}}
    if backend.startswith("claude"):
        hook = shlex.join([sys.executable, str(SCRIPT), "hook", "--supervisor", agent_id,
                           "--root", str(ROOT), "--status", "idle"])
        return [backend, "--enable-auto-mode", "--mcp-config",
                json.dumps({"mcpServers": {"nvim_team": server}}),
                "--settings", json.dumps({"hooks": {"SessionStart": [{"hooks": [
                    {"type": "command", "command": hook}]}]}}),
                "--resume" if exists else "--session-id", record["session_id"]]
    command = [backend]
    if exists:
        if not record.get("session_id"):
            raise ValueError("Codex session ID was not recorded. Run $supervise in the live chat before restarting it.")
        command += ["resume", record["session_id"]]
    command += ["--approve-for-me"]
    for key in ("command", "args"):
        command += ["-c", "mcp_servers.nvim_team." + key + "=" + json.dumps(server[key])]
    command += ["-c", "mcp_servers.nvim_team.env.NVIM_TEAM_HOME=" + json.dumps(str(ROOT))]
    for event, status in {"SessionStart": "idle", "UserPromptSubmit": "busy",
                          "PermissionRequest": "waiting", "PostToolUse": "busy",
                          "Stop": "idle", "Interrupt": "idle", "SessionEnd": "exited"}.items():
        hook = shlex.join([sys.executable, str(SCRIPT), "hook", "--supervisor", agent_id,
                           "--root", str(ROOT), "--status", status])
        command += ["-c", f'hooks.{event}=[{{hooks=[{{type="command",command={json.dumps(hook)}}}]}}]']
    return command


def supervisor_hook(agent_id, status):
    payload = json.load(sys.stdin)
    with locked(agent_id):
        record = read(agent_id)
        session = payload.get("session_id")
        if session:
            record["session_id"] = str(uuid.UUID(session))
        record["chat_status"] = status
        save(record)


def launch(backend, agent_id):
    if backend not in BACKENDS:
        raise ValueError("Unsupported supervisor backend")
    agent_id = str(uuid.UUID(agent_id))
    with locked(agent_id):
        exists = (directory(agent_id) / "agent.json").exists()
        record = read(agent_id) if exists else {
            "id": agent_id, "parent": None, "role": "chat", "name": backend + " chat",
            "backend": backend, "cwd": os.getcwd(), "created": time.time(),
            "status": "ready", "session_id": agent_id if backend.startswith("claude") else None,
            "config_dir": os.environ.get("CLAUDE_CONFIG_DIR", ""),
        }
        if record.get("deleting"):
            raise ValueError("Team is being deleted")
        save(record)
        name = session_name(agent_id)
        if tmux("has-session", "-t", name, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
            command = supervisor_command(record, exists)
            # zsh resolves the user's existing claude/claude-bf functions.
            env = os.environ.copy()
            env.pop("CLAUDECODE", None)
            env.pop("TMUX", None)
            env["NVIM_TEAM_HOME"] = str(ROOT)
            if record.get("config_dir"):
                env["CLAUDE_CONFIG_DIR"] = record["config_dir"]
            launch_env = ["-e", "NVIM_TEAM_HOME=" + str(ROOT)]
            if record.get("config_dir"):
                launch_env += ["-e", "CLAUDE_CONFIG_DIR=" + record["config_dir"]]
            tmux("new-session", "-d", "-s", name, "-c", record["cwd"], *launch_env,
                 shlex.join(["zsh", "-c", shlex.join(command)]), env=env, check=True)
            tmux("set-option", "-t", name, "status", "off", check=True)
            tmux("set-option", "-t", name, "history-limit", "50000", check=True)
    os.environ.pop("TMUX", None)
    os.execvp("tmux", ["tmux", "-L", "nvim-agents", "attach-session", "-t", name])


def team_start(supervisor, name, brief, session_id=None):
    if not name.strip() or not brief.strip():
        raise ValueError("Provide a project name and brief")
    validate_brief(brief)
    with locked(supervisor):
        record = read(supervisor)
        if record.get("deleting"):
            raise ValueError("Team is being deleted")
        if session_id is not None:
            session_id = str(uuid.UUID(session_id))
            if record.get("session_id") and record["session_id"] != session_id:
                raise ValueError("Session ID does not match the registered supervisor")
            record["session_id"] = session_id
        record.update(role="supervisor", name=name, brief=brief, status="supervising")
        record.setdefault("owner", supervisor)
        record.setdefault("owner_token", str(uuid.uuid4()))
        record.setdefault("execution", "planning")
        record.setdefault("phase", "planning")
        record.setdefault("handoff", "Planning; execution has not been authorized.")
        save(record)
        write_handoff(record)
    return record


def validate_brief(brief):
    if not brief.strip() or len(brief) > 6000 or len(re.split(r"\n\s*\n", brief.strip())) > 3:
        raise ValueError("Keep the goal brief to 1–3 short paragraphs (at most 6000 characters)")


def write_handoff(record):
    # agent.json is authoritative; these small files are for human inspection.
    for name, content in (("brief", record["brief"]), ("handoff", record["handoff"])):
        path = directory(record["id"]) / (name + ".md")
        temporary = path.with_suffix(".tmp")
        temporary.write_text(content + "\n")
        temporary.replace(path)


def team_checkpoint(supervisor, handoff, execution, brief=None, phase=None, plan_path=None, reviewer_backend=None):
    if execution not in ("planning", "authorized", "paused", "finished"):
        raise ValueError("Invalid execution state")
    if not handoff.strip() or len(handoff) > 6000:
        raise ValueError("Provide a concise handoff (at most 6000 characters)")
    if brief is not None:
        validate_brief(brief)
    with locked(supervisor):
        record = read(supervisor)
        if record.get("role") != "supervisor" or record.get("deleting"):
            raise ValueError("Select an available team")
        next_phase = phase or record.get("phase", "planning")
        if next_phase not in ("planning", "execution", "review", "finished"):
            raise ValueError("Invalid workflow phase")
        if reviewer_backend is not None and reviewer_backend not in ("claude", "codex-bf"):
            raise ValueError("Choose Claude subscription or Bifrost GPT for review")
        if plan_path is not None:
            path = Path(plan_path)
            if not path.is_absolute() or not path.is_file():
                raise ValueError("Provide the absolute path to the planner's saved plan")
            record["plan_path"] = str(path)
        workers = [row for row in records() if row.get("parent") == supervisor]
        if next_phase != "planning":
            if not record.get("plan_path") or not Path(record["plan_path"]).is_file():
                raise ValueError("Save a plan before leaving the planning phase")
            if not any(row.get("kind") == "planner" and row.get("status") == "done" for row in workers):
                raise ValueError("The planner must finish before execution")
        if next_phase in ("review", "finished"):
            if any(row.get("kind") == "executor" and row.get("status") in
                   ("starting", "working", "stopping", "needs supervisor", "blocked", "error", "interrupted") for row in workers):
                raise ValueError("Resolve executor work before review")
        if next_phase == "review" and not (reviewer_backend or record.get("reviewer_backend")):
            raise ValueError("Ask the user to choose the review backend before starting review")
        if next_phase == "finished" and not any(row.get("kind") == "reviewer" and row.get("status") == "done" for row in workers):
            raise ValueError("A reviewer must finish before declaring completion")
        latest_execution = max((row.get("activity_at", row.get("updated", 0)) for row in workers
                                if row.get("kind") == "executor"), default=0)
        if next_phase == "finished" and not any(row.get("kind") == "reviewer" and row.get("status") == "done"
                                                and row.get("activity_at", 0) >= latest_execution for row in workers):
            raise ValueError("Review the latest executor changes before declaring completion")
        if execution == "finished" and next_phase != "finished":
            raise ValueError("Finish the review phase before marking execution finished")
        if brief is not None:
            record["brief"] = brief
        record.update(handoff=handoff, execution=execution, phase=next_phase, checkpoint_at=time.time())
        if reviewer_backend is not None:
            record["reviewer_backend"] = reviewer_backend
        save(record)
        write_handoff(record)
    return {"team_id": supervisor, "execution": execution, "phase": next_phase, "saved": True}


def team_takeover(caller, team_id, session_id=None):
    team_id = str(uuid.UUID(team_id))
    with locked(team_id):
        record = read(team_id)
        chat = read(caller)
        if session_id is None:
            if not chat["backend"].startswith("claude"):
                raise ValueError("Codex takeover requires session_id from CODEX_THREAD_ID")
            session_id = chat.get("session_id")
        session_id = str(uuid.UUID(session_id))
        if record.get("role") != "supervisor" or record.get("deleting"):
            raise ValueError("Select an available team")
        if caller != team_id and (chat.get("role") != "chat" or chat.get("team_id") not in (None, team_id)):
            raise ValueError("Use a fresh chat or this team's existing supervisor chat")
        if caller != team_id:
            with locked(caller):
                chat = read(caller)
                chat.update(team_id=team_id, session_id=session_id)
                save(chat)
        else:
            record["session_id"] = session_id
        record.update(owner=caller, owner_token=str(uuid.uuid4()))
        record.setdefault("execution", "planning")
        record.setdefault("handoff", "Legacy team: verify progress and execution authorization with the user.")
        save(record)
        write_handoff(record)
    result = team_status(team_id)
    result.update(brief=record["brief"], handoff=record["handoff"], owner_token=record["owner_token"])
    return result


def owned(supervisor, agent_id):
    record = read(agent_id)
    if record.get("parent") != supervisor:
        raise ValueError("This worker does not belong to this supervisor")
    return record


def alive(pid):
    if not pid:
        return False
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def launch_worker(record, message):
    """Caller owns the per-worker lock; runner takes it before starting."""
    folder = directory(record["id"])
    record.update(status="starting", message="", assignment=message, run_id=str(uuid.uuid4()))
    (folder / "prompt.txt").write_text(message)
    save(record)
    log(record["id"], "Supervisor", message)
    with (folder / "runner.log").open("a") as errors:
        env = os.environ.copy()
        env["NVIM_TEAM_HOME"] = str(ROOT)
        env.pop("CLAUDECODE", None)
        env.pop("TMUX", None)
        process = subprocess.Popen(
            [sys.executable, str(SCRIPT), "run", "--agent", record["id"], "--run", record["run_id"]],
            stdin=subprocess.DEVNULL, stdout=errors, stderr=errors,
            start_new_session=True, env=env,
        )
    record["pid"] = process.pid
    save(record)
    return record


def worker_start(supervisor, name, task, backend=None, cwd=None, kind="executor", model=None):
    with locked(supervisor):
        if read(supervisor).get("deleting"):
            raise ValueError("Team is being deleted")
        return start_owned_worker(supervisor, name, task, backend, cwd, kind, model)


def start_owned_worker(supervisor, name, task, backend, cwd, kind, model):
    parent = read(supervisor)
    if parent["role"] != "supervisor":
        raise ValueError("Call team_start first")
    if kind not in ("planner", "executor", "reviewer"):
        raise ValueError("Choose planner, executor, or reviewer")
    backend = backend or ("claude" if kind == "planner" else
                          parent.get("reviewer_backend", "codex-bf") if kind == "reviewer" else "codex-bf")
    model = model or ("opus" if backend.startswith("claude") else EXECUTION_MODEL)
    if not model.strip() or model.startswith("-"):
        raise ValueError("Provide a model name")
    if backend not in BACKENDS or not task.strip() or not name.strip():
        raise ValueError("Provide a supported backend, name, and nonempty task")
    workspace = Path(cwd or parent["cwd"]).resolve(strict=True)
    if not workspace.is_dir():
        raise ValueError("Workspace must be an existing directory")
    agent_id = str(uuid.uuid4())
    record = {"id": agent_id, "parent": supervisor, "role": "worker", "name": name,
              "backend": backend, "kind": kind, "model": model,
              "cwd": str(workspace), "task": task, "created": time.time(),
              "config_dir": parent.get("config_dir", "")}
    with locked(agent_id):
        return launch_worker(record, task)


def agent_send(supervisor, agent_id, message):
    owned(supervisor, agent_id)
    with locked(supervisor):
        if read(supervisor).get("deleting"):
            raise ValueError("Team is being deleted")
        return send_owned_worker(supervisor, agent_id, message)


def send_owned_worker(supervisor, agent_id, message):
    if not message.strip():
        raise ValueError("Message must not be empty")
    with locked(agent_id):
        record = owned(supervisor, agent_id)
        if record["status"] in ("starting", "working", "stopping") and alive(record.get("pid")):
            raise ValueError("Worker is running; wait for its turn to finish or stop it first")
        if not record.get("session_id"):
            raise ValueError("Worker has no resumable session; inspect the error and start a new worker")
        return launch_worker(record, message)


def worker_stop(supervisor, agent_id):
    with locked(agent_id):
        record = owned(supervisor, agent_id)
        if record["status"] in ("starting", "working", "stopping") and alive(record.get("pid")):
            # PID is held by our detached runner, which also reaps its backend child.
            os.kill(record["pid"], signal.SIGTERM)
            record["status"] = "stopping"
        else:
            record["status"] = "stopped"
        save(record)
        return record


def snapshot():
    rows = records()
    for record in rows:
        record.pop("owner_token", None)
        if record.get("status") in ("starting", "working", "stopping") and not alive(record.get("pid")):
            record["status"] = "interrupted"
            record["message"] = "Runner exited. Inspect its log before resuming."
    return rows


def manage_team(agent_id, action):
    record = read(agent_id)
    supervisor = record.get("team_id") or record.get("parent") or record["id"]
    with locked(supervisor):
        parent = read(supervisor)
        if parent.get("role") not in ("supervisor", "chat"):
            raise ValueError("Select a team or chat")
        if action in ("archive", "restore"):
            if parent.get("deleting"):
                raise ValueError("Team is being deleted")
            parent["archived"] = action == "archive"
            save(parent)
            return parent
        if action != "delete":
            raise ValueError("Unknown team action")
        parent["deleting"] = True
        save(parent)
    # Block new worker turns before stopping the supervisor and its workers.
    chats = [row for row in records() if row.get("team_id") == supervisor]
    for chat_id in [supervisor, *(row["id"] for row in chats)]:
        name = session_name(chat_id)
        check = tmux("has-session", "-t", name, capture_output=True)
        if check.returncode == 0:
            tmux("kill-session", "-t", name, check=True, capture_output=True)
        elif check.returncode != 1:
            raise RuntimeError("Could not inspect supervisor terminal; team retained")
    children = [row for row in records() if row.get("parent") == supervisor]
    for child in children:
        worker_stop(supervisor, child["id"])
    deadline = time.monotonic() + 12
    while any(read(child["id"]).get("status") == "stopping" and alive(read(child["id"]).get("pid"))
              for child in children):
        if time.monotonic() >= deadline:
            raise RuntimeError("Workers have not stopped; team retained. Retry delete after checking them.")
        time.sleep(0.1)
    for child in children:
        shutil.rmtree(directory(child["id"]))
    for chat in chats:
        shutil.rmtree(directory(chat["id"]))
    shutil.rmtree(directory(supervisor))
    return {"id": supervisor, "deleted": True, "chat_ids": [supervisor, *(row["id"] for row in chats)]}


def worker_summary(row):
    result = {key: row[key] for key in ("id", "name", "backend", "kind", "model", "cwd", "status", "run_id", "activity_at") if key in row}
    for key in ("assignment", "message", "last_report"):
        value = row.get(key, row.get("task", "") if key == "assignment" else "")
        if value:
            result[key] = value[:1200] + ("… [see details]" if len(value) > 1200 else "")
    if result.get("last_report") == result.get("message"):
        result.pop("last_report", None)
    result["details"] = str(directory(row["id"]) / "activity.jsonl")
    result["transcript"] = str(directory(row["id"]) / "chat.md")
    return result


def team_status(supervisor, wait_seconds=0, full=False, inbox=None):
    timeout = min(30, max(0, wait_seconds))
    deadline = time.monotonic() + timeout
    while True:
        rows = [worker_summary(row) for row in snapshot() if row.get("parent") == supervisor]
        parent = read(supervisor)
        summary = {key: parent[key] for key in
                   ("id", "name", "backend", "status", "owner", "execution", "phase", "plan_path", "reviewer_backend", "checkpoint_at") if key in parent}
        current = {"supervisor": summary, "workers": {row["id"]: row for row in rows}}
        previous = inbox.get(supervisor) if inbox is not None and not full else None
        if current != previous or not any(row["status"] in ("working", "starting", "stopping") for row in rows):
            break
        if time.monotonic() >= deadline:
            break
        time.sleep(0.2)
    if inbox is not None:
        inbox[supervisor] = current
    result = {"workers": [row for row in rows if previous is None or previous["workers"].get(row["id"]) != row],
              "active": sum(row["status"] in ("starting", "working", "stopping") for row in rows)}
    if previous is None or previous["supervisor"] != summary:
        result["supervisor"] = summary
    if previous is not None:
        removed = sorted(previous["workers"].keys() - current["workers"].keys())
        if removed:
            result["removed"] = removed
    return result


def worker_command(record, output):
    backend = record["backend"]
    session = record.get("session_id")
    if backend.startswith("codex"):
        args = [backend, "exec", "-c", 'sandbox_mode="workspace-write"',
                "-c", 'approval_policy="on-request"', "-c", 'approvals_reviewer="auto_review"']
        if session:
            args += ["resume", session]
        if record.get("model"):
            args += ["--model", record["model"]]
        if backend == "codex-bf":
            args += ["-c", 'model_provider="bifrost"', "-c", 'model_reasoning_effort="medium"']
        args += ["--json", "-o", str(output)]
        if not session:
            args += ["--output-schema", str(SCRIPT.with_name("team-result.schema.json"))]
        args += ["-"]
    else:
        args = [backend, "-p", "--verbose", "--output-format", "stream-json",
                "--permission-mode", "auto", "--permission-prompts", "none",
                "--json-schema", json.dumps(SCHEMA)]
        if session:
            args += ["--resume", session]
        if record.get("model"):
            args += ["--model", record["model"]]
    return ["zsh", "-c", shlex.join(args)]


def worker_environment(record):
    env = os.environ.copy()
    env.pop("CLAUDECODE", None)
    if record["backend"] == "claude":
        # Plain Claude uses the normal account selected by the user's wrapper,
        # even when its supervisor was launched through the Bifrost wrapper.
        for key in list(env):
            if key.startswith("ANTHROPIC_") or key.startswith("CLAUDE_CODE_USE_") or key in (
                "CLAUDE_CONFIG_DIR", "BIFROST_API_KEY", "CLAUDE_CODE_API_KEY_HELPER"):
                env.pop(key)
    elif record.get("config_dir"):
        env["CLAUDE_CONFIG_DIR"] = record["config_dir"]
    return env


def run_worker(agent_id, run_id):
    folder = directory(agent_id)
    process = None
    stopped = False

    def stop(_signum, _frame):
        nonlocal stopped
        stopped = True
        if process and process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            def force_stop():
                if process.poll() is None:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
            watchdog = threading.Timer(5, force_stop)
            watchdog.daemon = True
            watchdog.start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        with locked(agent_id):
            record = read(agent_id)
            if record["run_id"] != run_id:
                return
            if stopped or record["status"] == "stopping":
                record["status"] = "stopped"
                save(record)
                return
            record["status"] = "working"
            save(record)
        parent = read(record["parent"])
        duties = {
            "planner": "Research and plan only; do not implement project changes. Save a detailed plan in the workspace, "
                       "including findings, file/worktree scope, steps, dependencies, risks, and acceptance tests. "
                       "Return its absolute path and a short summary. Ask the supervisor about missing decisions.",
            "executor": "Implement only your assigned part of the saved plan and run its relevant checks. "
                        "Ask the supervisor before resolving an unplanned scope or design decision.",
            "reviewer": "Independently review the changes against the saved plan and validation evidence. "
                        "Do not implement fixes. Report actionable findings with file paths and severity, or an explicit clean result.",
        }
        prompt = (
            "You are a worker reporting to a supervisor. Work only on the assigned task.\n"
            + duties.get(record.get("kind"), duties["executor"]) + "\n"
            "For missing decisions, finish this turn with kind=question and your question. "
            "The supervisor will answer by resuming this same conversation. "
            "Permission failures are kind=blocked, never bypass permissions. "
            "Do not delegate additional agents. Return ONLY a JSON object at the end: "
            '{"kind":"result|question|blocked","message":"your report or question"}.\n\n'
            "Keep the report concise: outcome, changed file paths, validation, blockers, next action. "
            "Save detailed findings in the workspace and return their paths instead of long logs or diffs.\n\n"
            "PROJECT BRIEF\n" + parent["brief"] + "\nSAVED PLAN: " + parent.get("plan_path", "Not yet written") + "\n\nASSIGNMENT / FOLLOW-UP\n" +
            (folder / "prompt.txt").read_text()
        )
        output = folder / (run_id + "-result.json")
        env = worker_environment(record)
        with (folder / "backend.log").open("a") as errors:
            process = subprocess.Popen(worker_command(record, output), cwd=record["cwd"],
                                       env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                       stderr=errors, text=True, start_new_session=True)
            if stopped:
                stop(None, None)
            process.stdin.write(prompt)
            process.stdin.close()
            final = None
            with (folder / "events.jsonl").open("a") as events:
                for line in process.stdout:
                    events.write(line)
                    events.flush()
                    try:
                        event = json.loads(line)
                    except ValueError:
                        continue
                    session = event.get("thread_id") or event.get("session_id")
                    if session:
                        with locked(agent_id):
                            current = read(agent_id)
                            current["session_id"] = session
                            save(current)
                    item = event.get("item", {})
                    if event.get("type") == "item.completed":
                        if item.get("type") == "agent_message":
                            log(agent_id, "Worker", item.get("text", ""))
                        elif item.get("type") == "command_execution":
                            log(agent_id, "Command", item.get("command", "") + "\n\n" + item.get("aggregated_output", ""))
                    if event.get("type") == "assistant":
                        for block in event.get("message", {}).get("content", []):
                            if block.get("type") == "text":
                                log(agent_id, "Worker", block["text"])
                            elif block.get("type") == "tool_use":
                                log(agent_id, "Tool", block["name"] + "\n" + json.dumps(block.get("input", {})))
                    if event.get("type") == "result":
                        final = event.get("structured_output") or event.get("result")
            code = process.wait()
        if stopped:
            state, message = "stopped", "Stopped by supervisor"
        elif code:
            state, message = "error", f"Backend exited with code {code}. See backend.log."
        else:
            if output.exists():
                final = json.loads(output.read_text())
            if isinstance(final, str):
                final = json.loads(final)
            if not isinstance(final, dict) or final.get("kind") not in ("result", "question", "blocked") or not isinstance(final.get("message"), str):
                raise ValueError("Worker returned no valid result/question object; inspect events.jsonl")
            state = {"result": "done", "question": "needs supervisor", "blocked": "blocked"}[final["kind"]]
            message = final["message"]
        log(agent_id, state, message)
        with locked(agent_id):
            current = read(agent_id)
            current.update(status=state, message=message, pid=None)
            save(current)
    except Exception as error:
        if process and process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
        with locked(agent_id):
            current = read(agent_id)
            current.update(status="stopped" if stopped else "error", message=str(error), pid=None)
            save(current)
        log(agent_id, "Runner", str(error))


def tool(name, description, properties, required):
    return {"name": name, "description": description, "inputSchema": {
        "type": "object", "properties": properties, "required": required, "additionalProperties": False}}


STRING = {"type": "string"}
TOOLS = [
    tool("team_start", "Register or update a supervisor with a 1–3 paragraph goal brief. Supply the actual session_id. Save the returned owner_token for subsequent mutations; existing teams require it.",
         {"name": STRING, "brief": STRING, "session_id": STRING, "owner_token": STRING}, ["name", "brief"]),
    tool("team_takeover", "Explicitly transfer a stable team to THIS conversation after a reset or in a new chat. Preserves workers and execution state. Returns goal, handoff, worker summaries and a new owner_token; invalidates the old token.",
         {"team_id": STRING, "session_id": STRING}, ["team_id"]),
    tool("team_checkpoint", "Save a concise current handoff and execution authorization state. Update after decisions, assignments, results and blockers, and before ending a turn. Optional brief replaces the 1–3 paragraph goal.",
         {"handoff": STRING, "execution": {"type": "string", "enum": ["planning", "authorized", "paused", "finished"]},
          "brief": STRING, "phase": {"type": "string", "enum": ["planning", "execution", "review", "finished"]},
          "plan_path": STRING, "reviewer_backend": {"type": "string", "enum": ["claude", "codex-bf"]},
          "owner_token": STRING}, ["handoff", "execution", "owner_token"]),
    tool("worker_start", "Start a planner (Claude subscription/Opus), executor (Bifrost GPT/" + EXECUTION_MODEL + "), or reviewer (user-chosen backend). Match the saved phase. Use separate existing worktrees for concurrent writers. Optional model overrides the role default.",
         {"name": STRING, "task": STRING, "backend": {"type": "string", "enum": list(BACKENDS)},
          "kind": {"type": "string", "enum": ["planner", "executor", "reviewer"]}, "model": STRING,
          "cwd": STRING, "owner_token": STRING}, ["name", "task", "kind", "owner_token"]),
    tool("agent_send", "Answer or revise a worker by resuming its SAME session. Only between turns.",
         {"agent_id": STRING, "message": STRING, "owner_token": STRING}, ["agent_id", "message", "owner_token"]),
    tool("team_status", "Inbox: first read returns all workers, later reads only changed summaries. Empty workers means no changes, not no workers; active counts running workers. Wait up to 30 seconds. Use full=true to recover all summaries. Detailed reports remain at the returned paths.",
         {"wait_seconds": {"type": "integer", "minimum": 0, "maximum": 30}, "full": {"type": "boolean"}}, []),
    tool("worker_stop", "Stop one of this supervisor's workers; preserve its conversation and files.",
         {"agent_id": STRING, "owner_token": STRING}, ["agent_id", "owner_token"]),
]


def dispatch(caller, name, arguments, inbox=None):
    functions = {function.__name__: function for function in
                 (team_start, team_checkpoint, worker_start, agent_send, team_status, worker_stop)}
    # Serialize control changes across chats; never hold this during an inbox wait.
    # Worker runners use their existing per-record locks independently.
    ROOT.mkdir(parents=True, exist_ok=True)
    with (ROOT / "control.lock").open("a") as control:
        fcntl.flock(control, fcntl.LOCK_EX)
        if name == "team_takeover":
            result = team_takeover(caller, **arguments)
            if inbox is not None:
                inbox.pop(result["supervisor"]["id"], None)
            return result
        chat = read(caller)
        team_id = chat.get("team_id", caller)
        parent = read(team_id)
        args = dict(arguments)
        token = args.pop("owner_token", None)
        if parent.get("owner", caller) != caller:
            raise ValueError("Supervisor replaced. Stop issuing instructions; explicit takeover is required.")
        if name != "team_status" and parent.get("role") == "supervisor":
            if not token or token != parent.get("owner_token"):
                raise ValueError("Missing or stale owner_token. Use explicit team_takeover to claim this team.")
        if parent.get("deleting"):
            raise ValueError("Team is being deleted")
        if name in ("worker_start", "agent_send") and parent.get("execution") != "authorized":
            raise ValueError("Execution is not authorized. Discuss with the user, then save authorization with team_checkpoint.")
        if name in ("worker_start", "agent_send"):
            worker = args if name == "worker_start" else owned(team_id, args["agent_id"])
            kind = worker.get("kind", "executor")
            required_phase = {"planner": "planning", "executor": "execution", "reviewer": "review"}.get(kind)
            if parent.get("phase", "planning") != required_phase:
                raise ValueError("Worker role must match the saved workflow phase: planning, execution, then review")
            required_backend = {"planner": "claude", "executor": "codex-bf",
                                "reviewer": parent.get("reviewer_backend")}[kind]
            backend = worker.get("backend") or required_backend
            if backend != required_backend:
                raise ValueError("This role requires backend " + str(required_backend))
        if name == "team_start" and team_id != caller:
            session = args.pop("session_id", None)
            if session is not None and session != chat.get("session_id"):
                raise ValueError("Session changed; use explicit team_takeover")
        if name != "team_status":
            return functions[name](team_id, **args)
    return team_status(team_id, inbox=inbox, **args)


def mcp(supervisor):
    supervisor = str(uuid.UUID(supervisor))
    inbox = {}
    # The user's zsh wrapper may select a Claude config directory at launch.
    # Persist the actual inherited location for future workers and reconnects.
    if os.environ.get("CLAUDE_CONFIG_DIR"):
        with locked(supervisor):
            record = read(supervisor)
            record["config_dir"] = os.environ["CLAUDE_CONFIG_DIR"]
            save(record)
    for line in sys.stdin:
        request = None
        try:
            request = json.loads(line)
            if "id" not in request:
                continue
            method = request.get("method")
            if method == "initialize":
                result = {"protocolVersion": request["params"]["protocolVersion"],
                          "capabilities": {"tools": {}}, "serverInfo": {"name": "nvim_team", "version": "1.0.0"}}
            elif method == "ping":
                result = {}
            elif method == "tools/list":
                result = {"tools": TOOLS}
            elif method == "tools/call":
                try:
                    params = request["params"]
                    result = dispatch(supervisor, params["name"], params.get("arguments", {}), inbox=inbox)
                    result = {"content": [{"type": "text", "text": json.dumps(result)}]}
                except Exception as error:
                    result = {"isError": True, "content": [{"type": "text", "text": str(error)}]}
            else:
                print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "error": {"code": -32601, "message": "Method not found"}}), flush=True)
                continue
            print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)
        except Exception as error:
            print(json.dumps({"jsonrpc": "2.0", "id": request.get("id") if isinstance(request, dict) else None,
                              "error": {"code": -32603, "message": str(error)}}), flush=True)


def main():
    global ROOT
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    launch_parser = sub.add_parser("launch")
    launch_parser.add_argument("--backend", choices=BACKENDS, required=True)
    launch_parser.add_argument("--session", default=os.environ.get("NVIM_TEAM_SESSION"))
    server = sub.add_parser("mcp")
    server.add_argument("--supervisor", required=True)
    hook = sub.add_parser("hook")
    hook.add_argument("--supervisor", required=True)
    hook.add_argument("--root", required=True)
    hook.add_argument("--status", choices=("idle", "busy", "waiting", "exited"), required=True)
    runner = sub.add_parser("run")
    runner.add_argument("--agent", required=True)
    runner.add_argument("--run", required=True)
    sub.add_parser("snapshot")
    manage = sub.add_parser("manage")
    manage.add_argument("operation", choices=("archive", "restore", "delete"))
    manage.add_argument("--agent", required=True)
    args = parser.parse_args()
    if args.action == "launch":
        launch(args.backend, args.session or str(uuid.uuid4()))
    elif args.action == "mcp":
        mcp(args.supervisor)
    elif args.action == "run":
        run_worker(args.agent, args.run)
    elif args.action == "hook":
        ROOT = Path(args.root)
        supervisor_hook(args.supervisor, args.status)
    elif args.action == "manage":
        print(json.dumps(manage_team(args.agent, args.operation)))
    else:
        print(json.dumps(snapshot()))


if __name__ == "__main__":
    main()
