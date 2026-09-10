#!/usr/bin/env python3
"""Local team tools, durable worker jobs, and agent terminal attachment. Stdlib only."""

import argparse
import contextlib
import fcntl
import json
import os
from pathlib import Path
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
        return [backend, "--enable-auto-mode", "--mcp-config",
                json.dumps({"mcpServers": {"nvim_team": server}}),
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
        save(record)
        (directory(supervisor) / "brief.md").write_text(brief + "\n")
    return record


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
    record.update(status="starting", message="", run_id=str(uuid.uuid4()))
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


def worker_start(supervisor, name, task, backend="codex-bf", cwd=None):
    with locked(supervisor):
        if read(supervisor).get("deleting"):
            raise ValueError("Team is being deleted")
        return start_owned_worker(supervisor, name, task, backend, cwd)


def start_owned_worker(supervisor, name, task, backend, cwd):
    parent = read(supervisor)
    if parent["role"] != "supervisor":
        raise ValueError("Call team_start first")
    if backend not in BACKENDS or not task.strip() or not name.strip():
        raise ValueError("Provide a supported backend, name, and nonempty task")
    workspace = Path(cwd or parent["cwd"]).resolve(strict=True)
    if not workspace.is_dir():
        raise ValueError("Workspace must be an existing directory")
    agent_id = str(uuid.uuid4())
    record = {"id": agent_id, "parent": supervisor, "role": "worker", "name": name,
              "backend": backend, "cwd": str(workspace), "task": task, "created": time.time(),
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
        if record.get("status") in ("starting", "working", "stopping") and not alive(record.get("pid")):
            record["status"] = "interrupted"
            record["message"] = "Runner exited. Inspect its log before resuming."
    return rows


def manage_team(agent_id, action):
    record = read(agent_id)
    supervisor = record.get("parent") or record["id"]
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
    name = session_name(supervisor)
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
    shutil.rmtree(directory(supervisor))
    return {"id": supervisor, "deleted": True}


def team_status(supervisor, wait_seconds=0):
    timeout = min(30, max(0, wait_seconds))
    deadline = time.monotonic() + timeout
    initial = None
    while True:
        rows = [row for row in snapshot() if row.get("parent") == supervisor]
        fingerprint = [(row["id"], row["status"], row["updated"]) for row in rows]
        if initial is None:
            initial = fingerprint
        if fingerprint != initial or not any(row["status"] in ("working", "starting") for row in rows):
            break
        if time.monotonic() >= deadline:
            break
        time.sleep(0.2)
    return {"supervisor": read(supervisor), "workers": rows}


def worker_command(record, output):
    backend = record["backend"]
    session = record.get("session_id")
    if backend.startswith("codex"):
        args = [backend, "exec", "-c", 'sandbox_mode="workspace-write"',
                "-c", 'approval_policy="on-request"', "-c", 'approvals_reviewer="auto_review"']
        if session:
            args += ["resume", session]
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
    return ["zsh", "-c", shlex.join(args)]


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
        prompt = (
            "You are a worker reporting to a supervisor. Work only on the assigned task.\n"
            "For missing decisions, finish this turn with kind=question and your question. "
            "The supervisor will answer by resuming this same conversation. "
            "Permission failures are kind=blocked, never bypass permissions. "
            "Do not delegate additional agents. Return ONLY a JSON object at the end: "
            '{"kind":"result|question|blocked","message":"your report or question"}.\n\n'
            "PROJECT BRIEF\n" + parent["brief"] + "\n\nASSIGNMENT / FOLLOW-UP\n" +
            (folder / "prompt.txt").read_text()
        )
        output = folder / (run_id + "-result.json")
        env = os.environ.copy()
        env.pop("CLAUDECODE", None)
        if record.get("config_dir"):
            env["CLAUDE_CONFIG_DIR"] = record["config_dir"]
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
    tool("team_start", "Register or update THIS conversation as a supervisor. Codex: supply session_id from your shell's CODEX_THREAD_ID for exact-session reconnect. Preserve agreed decisions in brief.",
         {"name": STRING, "brief": STRING, "session_id": STRING}, ["name", "brief"]),
    tool("worker_start", "Start a durable worker. Use separate existing worktrees for concurrent writers.",
         {"name": STRING, "task": STRING, "backend": {"type": "string", "enum": list(BACKENDS)}, "cwd": STRING}, ["name", "task"]),
    tool("agent_send", "Answer or revise a worker by resuming its SAME session. Only between turns.",
         {"agent_id": STRING, "message": STRING}, ["agent_id", "message"]),
    tool("team_status", "Read worker questions/results. Wait up to 30 seconds for changes while work is running.",
         {"wait_seconds": {"type": "integer", "minimum": 0, "maximum": 30}}, []),
    tool("worker_stop", "Stop one of this supervisor's workers; preserve its conversation and files.",
         {"agent_id": STRING}, ["agent_id"]),
]


def mcp(supervisor):
    supervisor = str(uuid.UUID(supervisor))
    # The user's zsh wrapper may select a Claude config directory at launch.
    # Persist the actual inherited location for future workers and reconnects.
    if os.environ.get("CLAUDE_CONFIG_DIR"):
        with locked(supervisor):
            record = read(supervisor)
            record["config_dir"] = os.environ["CLAUDE_CONFIG_DIR"]
            save(record)
    functions = {function.__name__: function for function in (team_start, worker_start, agent_send, team_status, worker_stop)}
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
                    result = functions[params["name"]](supervisor, **params.get("arguments", {}))
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
    manage.add_argument("action", choices=("archive", "restore", "delete"))
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
        print(json.dumps(manage_team(args.agent, args.action)))
    else:
        print(json.dumps(snapshot()))


if __name__ == "__main__":
    main()
