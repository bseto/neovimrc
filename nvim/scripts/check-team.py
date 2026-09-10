#!/usr/bin/env python3
"""Exercise durable worker question/resume/stop and MCP transport without model calls."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import tomllib
import uuid

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("team", Path(__file__).with_name("agent-team.py"))
team = importlib.util.module_from_spec(spec)
spec.loader.exec_module(team)


def wait(agent_id):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        record = team.read(agent_id)
        if record["status"] not in ("starting", "working", "stopping"):
            return record
        time.sleep(0.05)
    raise AssertionError(team.read(agent_id))


with tempfile.TemporaryDirectory(prefix="nvim-team-check-") as temporary:
    root = Path(temporary)
    team.ROOT = root / "state"
    os.environ["NVIM_TEAM_HOME"] = str(team.ROOT)
    # Fake only the backend executable; use real detached runners, locks, files,
    # JSON event parsing, process signals, and resume arguments.
    fake = root / "zsh"
    fake.write_text("#!" + sys.executable + "\n" + '''
import json, shlex, sys, time
from pathlib import Path
args = shlex.split(sys.argv[2])
prompt = sys.stdin.read()
if "STOP_TEST" in prompt:
    time.sleep(60)
if "INVALID_TEST" in prompt:
    print('{"type":"thread.started","thread_id":"test-session"}', flush=True)
    sys.exit(0)
resumed = "resume" in args
if resumed:
    assert args[args.index("resume") + 1] == "test-session"
result = {"kind": "result" if resumed else "question", "message": "Done with blue" if resumed else "Which color?"}
print('{"type":"thread.started","thread_id":"test-session"}', flush=True)
print(json.dumps({"type":"item.completed","item":{"type":"agent_message","text":json.dumps(result)}}), flush=True)
Path(args[args.index("-o") + 1]).write_text(json.dumps(result))
''')
    fake.chmod(0o700)
    os.environ["PATH"] = str(root) + os.pathsep + os.environ["PATH"]
    supervisor = str(uuid.uuid4())
    team.save({"id": supervisor, "role": "chat", "backend": "claude", "cwd": str(root), "created": time.time()})
    team.team_start(supervisor, "Color", "Implement the agreed color. Ask if unspecified.")
    team.team_start(supervisor, "Color", "Keep scope to color.")
    assert len(team.records()) == 1
    worker = team.worker_start(supervisor, "Choose color", "Ask the supervisor which color.", "codex")
    question = wait(worker["id"])
    assert question["status"] == "needs supervisor", question
    assert question["session_id"] == "test-session"
    assert team.team_status(supervisor)["workers"][0]["message"] == "Which color?"
    team.agent_send(supervisor, worker["id"], "Use blue.")
    result = wait(worker["id"])
    assert result["status"] == "done" and result["message"] == "Done with blue", result
    transcript = (team.directory(worker["id"]) / "chat.md").read_text()
    assert "Which color?" in transcript and "Use blue." in transcript and "Done with blue" in transcript
    try:
        team.agent_send(str(uuid.uuid4()), worker["id"], "Unauthorized")
        raise AssertionError("Foreign supervisor accepted")
    except ValueError:
        pass
    try:
        team.read("../../outside")
        raise AssertionError("Invalid ID accepted")
    except ValueError:
        pass
    invalid = team.worker_start(supervisor, "Invalid", "INVALID_TEST", "codex")
    assert wait(invalid["id"])["status"] == "error"
    stopping = team.worker_start(supervisor, "Stop", "STOP_TEST", "codex")
    time.sleep(0.3)
    try:
        team.agent_send(supervisor, stopping["id"], "Second turn")
        raise AssertionError("Concurrent turn accepted")
    except ValueError:
        pass
    team.worker_stop(supervisor, stopping["id"])
    assert wait(stopping["id"])["status"] == "stopped"
    requests = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2024-11-05"}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
        {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "team_status", "arguments": {}}},
    ]
    completed = subprocess.run([sys.executable, str(team.SCRIPT), "mcp", "--supervisor", supervisor],
                               input="\n".join(map(json.dumps, requests)) + "\n", text=True, capture_output=True, check=True)
    replies = list(map(json.loads, completed.stdout.splitlines()))
    assert len(replies) == 3 and len(replies[1]["result"]["tools"]) == 5
    assert not replies[2]["result"].get("isError")
    # A new reader process sees the same team after all launch callers exit.
    restored = subprocess.run([sys.executable, str(team.SCRIPT), "snapshot"], text=True, capture_output=True, check=True)
    assert len(json.loads(restored.stdout)) == 4
    codex_id, session_id = str(uuid.uuid4()), str(uuid.uuid4())
    codex = {"id": codex_id, "role": "chat", "backend": "codex-bf", "cwd": str(root), "created": time.time()}
    team.save(codex)
    command = team.supervisor_command(codex, False)
    config = {}
    for index, argument in enumerate(command):
        if argument == "-c":
            parsed = tomllib.loads(command[index + 1])
            config.update(parsed.get("mcp_servers", {}).get("nvim_team", {}))
    assert config["command"] == sys.executable
    assert "resume" not in command
    subprocess.run([sys.executable, str(team.SCRIPT), "hook", "--supervisor", codex_id,
                    "--root", str(team.ROOT), "--status", "busy"],
                   input=json.dumps({"session_id": session_id}), text=True, check=True)
    codex = team.read(codex_id)
    assert codex["session_id"] == session_id and codex["chat_status"] == "busy"
    resumed = team.supervisor_command(codex, True)
    assert resumed[1:3] == ["resume", session_id]
    team.team_start(codex_id, "Codex supervisor", "Same team protocol", session_id=session_id)
    try:
        team.team_start(codex_id, "Wrong session", "Must reject", session_id=str(uuid.uuid4()))
        raise AssertionError("Different supervisor session accepted")
    except ValueError:
        pass
    assert team.team_status(codex_id)["supervisor"]["backend"] == "codex-bf"
    assert team.team_status(codex_id)["workers"] == []
    no_hooks = str(uuid.uuid4())
    team.save({"id": no_hooks, "role": "chat", "backend": "codex-bf", "cwd": str(root), "created": time.time()})
    team.team_start(no_hooks, "No hooks", "Register directly", session_id=session_id)
    assert team.supervisor_command(team.read(no_hooks), True)[1:3] == ["resume", session_id]
    plain_chat = str(uuid.uuid4())
    team.save({"id": plain_chat, "role": "chat", "backend": "claude", "cwd": str(root), "created": time.time()})
    team.manage_team(plain_chat, "archive")
    assert team.read(plain_chat)["archived"]
    team.manage_team(plain_chat, "restore")
    assert not team.read(plain_chat)["archived"]
    team.manage_team(worker["id"], "archive")
    assert team.read(supervisor)["archived"]
    assert team.read(worker["id"])["session_id"] == "test-session"
    team.manage_team(supervisor, "restore")
    assert not team.read(supervisor)["archived"]
    original_tmux = team.tmux
    team.tmux = lambda *args, **kwargs: subprocess.CompletedProcess(args, 1)
    project_file = root / "keep.txt"
    project_file.write_text("Project files survive")
    running = team.worker_start(supervisor, "Delete running worker", "STOP_TEST", "codex")
    time.sleep(0.3)
    team.manage_team(supervisor, "delete")
    assert not team.directory(supervisor).exists()
    assert not team.directory(running["id"]).exists()
    assert not team.directory(worker["id"]).exists()
    assert team.directory(codex_id).exists()
    assert project_file.read_text() == "Project files survive"
    team.tmux = original_tmux
print("Team question/resume, ownership, stop, malformed output, MCP, and persistence checks passed")
