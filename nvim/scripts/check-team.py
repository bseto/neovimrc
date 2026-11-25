#!/usr/bin/env python3
"""Exercise durable worker question/resume/stop and MCP transport without model calls."""
import hashlib
import importlib.util
import json
import os
import shlex
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import tomllib
import uuid
from unittest.mock import patch

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
if "EXIT_TEST" in prompt:
    print("fatal: no credentials", file=sys.stderr)
    sys.exit(1)
resumed = "resume" in args or "--resume" in args
if resumed:
    print('{"type":"error","message":"Reconnecting... waiting for network"}', flush=True)
if resumed:
    assert args[args.index("resume" if "resume" in args else "--resume") + 1] == "test-session"
result = {"kind": "result" if resumed else "question", "message": "Done with blue" if resumed else "Which color?"}
print('{"type":"thread.started","thread_id":"test-session"}', flush=True)
print(json.dumps({"type":"item.completed","item":{"type":"agent_message","text":json.dumps(result)}}), flush=True)
if "-o" in args:
    Path(args[args.index("-o") + 1]).write_text(json.dumps(result) if "--output-schema" in args else "Done. " + json.dumps(result))
else:
    print(json.dumps({"type":"result", "structured_output":result}), flush=True)
''')
    fake.chmod(0o700)
    os.environ["PATH"] = str(root) + os.pathsep + os.environ["PATH"]
    supervisor = str(uuid.uuid4())
    team.save({"id": supervisor, "role": "chat", "backend": "claude", "cwd": str(root), "created": time.time()})
    team.team_start(supervisor, "Color", "Implement the agreed color. Ask if unspecified.")
    team.team_start(supervisor, "Color", "Keep scope to color.")
    assert len(team.records()) == 1
    worker = team.worker_start(supervisor, "Choose color", "Ask the supervisor which color.", "codex-bf")
    question = wait(worker["id"])
    assert question["status"] == "needs supervisor", question
    assert question["session_id"] == "test-session"
    assert team.team_status(supervisor)["workers"][0]["message"] == "Which color?"
    team.agent_send(supervisor, worker["id"], "Use blue.")
    result = wait(worker["id"])
    assert result["status"] == "done" and result["message"] == "Done with blue", result
    assert question.get("last_error") is None and result["last_error"] == "Reconnecting... waiting for network"
    transcript = (team.directory(worker["id"]) / "chat.md").read_text()
    assert "Which color?" in transcript and "Use blue." in transcript and "Done with blue" in transcript
    activity = [json.loads(line) for line in (team.directory(worker["id"]) / "activity.jsonl").read_text().splitlines()]
    assert any(event.get("assignment") == "Use blue." for event in activity)
    assert any(event.get("message") == "Which color?" for event in activity)
    assert any(event.get("message") == "Done with blue" for event in activity)
    inbox = {}
    first = team.team_status(supervisor, inbox=inbox)
    assert first["workers"][0]["assignment"] == "Use blue."
    assert first["workers"][0]["message"] == "Done with blue"
    assert team.team_status(supervisor, inbox=inbox) == {"workers": [], "active": 0}
    # Incidental record writes should not consume supervisor context.
    team.save(team.read(worker["id"]))
    assert team.team_status(supervisor, inbox=inbox)["workers"] == []
    # A distinct run remains visible even when its compact result is identical.
    repeated = team.read(worker["id"])
    repeated["run_id"] = str(uuid.uuid4())
    team.save(repeated)
    invisible = team.team_status(supervisor, inbox=inbox)["workers"][0]
    assert invisible["report_changed"] and invisible["run_id"] == repeated["run_id"]
    assert team.team_status(supervisor, inbox=inbox)["workers"] == []
    detailed = team.read(worker["id"])
    detailed["message"] = "Evidence " * 1000
    team.save(detailed)
    update = team.team_status(supervisor, inbox=inbox)
    assert len(update["workers"]) == 1 and "supervisor" not in update
    assert len(update["workers"][0]["message"]) < 1300
    assert detailed["message"] in Path(update["workers"][0]["details"]).read_text()
    assert team.team_status(supervisor, inbox=inbox)["workers"] == []
    # Full report changes beyond the display cutoff still advance the inbox.
    detailed = team.read(worker["id"])
    detailed["message"] = detailed["message"][:-1] + "X"
    team.save(detailed)
    cutoff = team.team_status(supervisor, inbox=inbox)["workers"][0]
    assert cutoff["report_changed"] and cutoff["run_id"] == detailed["run_id"]
    assert team.team_status(supervisor, inbox=inbox)["workers"] == []
    assert len(team.team_status(supervisor, full=True, inbox=inbox)["workers"]) == 1
    # A follow-up clears the live message but preserves the last result for takeover.
    detailed.update(status="starting", message="", assignment="Review evidence")
    team.save(detailed)
    assert team.read(worker["id"])["last_report"] == detailed["last_report"]
    detailed.update(status="working", pid=os.getpid())
    team.save(detailed)
    assert team.team_status(supervisor, wait_seconds=30, inbox=inbox)["active"] == 1
    started = time.monotonic()
    assert team.team_status(supervisor, wait_seconds=0.2, inbox=inbox) == {"workers": [], "active": 1}
    assert time.monotonic() - started >= 0.2
    assert time.monotonic() - started < 1, "team_status overran wait_seconds"
    def finish_during_poll():
        with team.locked(worker["id"]):
            finished = team.read(worker["id"])
            finished.update(status="done", message="Arrived during wait", pid=None)
            team.save(finished)
    update_timer = threading.Timer(0.1, finish_during_poll)
    update_timer.start()
    woke = team.team_status(supervisor, wait_seconds=5, inbox=inbox)
    update_timer.join()
    assert woke["workers"][0]["message"] == "Arrived during wait" and woke["active"] == 0
    # Repeat rows carry identity, status, and changed fields only; no assignment or path echoes.
    assert set(woke["workers"][0]) == {"id", "name", "status", "message"}, woke
    # Each connection has an independent first read; takeover resets its inbox.
    assert team.team_status(supervisor, inbox={})["workers"]
    team.save(result)
    # Opt-in Claude delivery uses the current owner/session, never changes work status,
    # and suppresses a repeat after a complete socket write.
    parent_before = team.read(supervisor)
    parent = dict(parent_before)
    parent.update(delivery="events", execution="authorized", owner=supervisor, session_id=supervisor)
    team.save(parent)
    endpoint = team.directory(supervisor) / "delivery-endpoint.json"
    endpoint.write_text(json.dumps({"session_id": supervisor, "socket": "fake", "token": "private-token"}))
    endpoint.chmod(0o600)
    assert team.team_status(supervisor)["supervisor"]["delivery"] == "events"
    sent = []
    real_sender = team.send_claude_event
    team.send_claude_event = lambda registered, message: sent.append((registered, message))
    delivered = team.read(worker["id"])
    delivered.update(run_id=str(uuid.uuid4()), status="done", message="Event result", pid=None)
    team.save(delivered)
    receipt = team.deliver_worker_report(worker["id"], delivered["run_id"])
    assert receipt["socket_write"] == "complete" and receipt["acceptance"] == "unconfirmed"
    assert receipt["event_id"] in sent[0][1] and sent[0][0]["token"] == "private-token"
    assert team.read(worker["id"])["status"] == "done"
    assert team.deliver_worker_report(worker["id"], delivered["run_id"])["socket_write"] == "complete"
    assert len(sent) == 1
    assert "private-token" not in json.dumps(team.snapshot())
    # A backend failure carries last_error; the saved message is only the log tail.
    delivered = team.read(worker["id"])
    delivered.update(run_id=str(uuid.uuid4()), status="error", message="Backend exited with code 1. unrelated OAuth warning",
                     last_error="could not auto resolve a provider for gpt-6-sol")
    team.save(delivered)
    failure = team.deliver_worker_report(worker["id"], delivered["run_id"])
    assert failure["event_id"].endswith(":failure:1") and failure["socket_write"] == "complete"
    # Worker-produced text never rides in the user-role notice; team_status carries it.
    assert "gpt-6-sol" not in sent[-1][1] and "OAuth" not in sent[-1][1] and "team_status" in sent[-1][1]
    assert "Event result" not in sent[0][1]
    delivered = team.read(worker["id"])
    delivered.update(status="done", last_error=None)
    team.save(delivered)
    # An ambiguous transport failure retains the same event identity for retry.
    delivered = team.read(worker["id"])
    delivered.update(run_id=str(uuid.uuid4()), status="done", message="Retry result")
    team.save(delivered)
    team.send_claude_event = lambda *_: (_ for _ in ()).throw(OSError("ambiguous local failure"))
    failed = team.deliver_worker_report(worker["id"], delivered["run_id"])
    retried = team.deliver_worker_report(worker["id"], delivered["run_id"])
    assert failed["socket_write"] == "failed" and failed["event_id"] == retried["event_id"]
    assert team.read(worker["id"])["status"] == "done"
    # Pausing prevents wakeup; takeover and reset route only to the new session endpoint.
    parent = team.read(supervisor)
    parent["execution"] = "paused"
    team.save(parent)
    delivered = team.read(worker["id"])
    delivered["run_id"] = str(uuid.uuid4())
    team.save(delivered)
    assert team.deliver_worker_report(worker["id"], delivered["run_id"])["status"] == "skipped"
    owner2, session2 = str(uuid.uuid4()), str(uuid.uuid4())
    team.save({"id": owner2, "role": "chat", "backend": "claude", "delivery": "events",
               "session_id": session2, "cwd": str(root), "created": time.time()})
    parent = team.read(supervisor)
    parent.update(execution="authorized", owner=owner2)
    team.save(parent)
    endpoint2 = team.directory(owner2) / "delivery-endpoint.json"
    endpoint2.write_text(json.dumps({"session_id": session2, "socket": "fake2"}))
    endpoint2.chmod(0o600)
    team.send_claude_event = lambda registered, message: sent.append((registered, message))
    delivered = team.read(worker["id"])
    delivered["run_id"] = str(uuid.uuid4())
    team.save(delivered)
    routed = team.deliver_worker_report(worker["id"], delivered["run_id"])
    assert routed["owner"] == owner2 and routed["session_id"] == session2 and sent[-1][0]["socket"] == "fake2"
    reset_session = str(uuid.uuid4())
    owner_record = team.read(owner2)
    owner_record["session_id"] = reset_session
    team.save(owner_record)
    assert team.team_status(supervisor)["supervisor"]["delivery"] == "poll"
    delivered = team.read(worker["id"])
    delivered["run_id"] = str(uuid.uuid4())
    team.save(delivered)
    assert "stale" in team.deliver_worker_report(worker["id"], delivered["run_id"])["error"]
    endpoint.unlink(missing_ok=True)
    team.send_claude_event = real_sender
    team.save(parent_before)
    for path in team.directory(owner2).iterdir():
        path.unlink()
    team.directory(owner2).rmdir()
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
    invalid = team.worker_start(supervisor, "Invalid", "INVALID_TEST", "codex-bf")
    assert wait(invalid["id"])["status"] == "error"
    exited = wait(team.worker_start(supervisor, "Exit", "EXIT_TEST", "codex-bf")["id"])
    assert exited["status"] == "error" and "no credentials" in exited["message"], exited
    stopping = team.worker_start(supervisor, "Stop", "STOP_TEST", "codex-bf")
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
        {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "team_status", "arguments": {}}},
    ]
    completed = subprocess.run([sys.executable, str(team.SCRIPT), "mcp", "--supervisor", supervisor],
                               input="\n".join(map(json.dumps, requests)) + "\n", text=True, capture_output=True, check=True)
    replies = list(map(json.loads, completed.stdout.splitlines()))
    assert len(replies) == 4 and len(replies[1]["result"]["tools"]) == 7
    assert not replies[2]["result"].get("isError")
    quiet = json.loads(replies[3]["result"]["content"][0]["text"])
    assert quiet == {"workers": [], "active": 0}
    # A new reader process sees the same team after all launch callers exit.
    restored = subprocess.run([sys.executable, str(team.SCRIPT), "snapshot"], text=True, capture_output=True, check=True)
    assert len(json.loads(restored.stdout)) == 5
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
    # Exercise ownership through the same dispatch boundary as MCP, including
    # a fresh chat and a context reset that keeps the same launcher identity.
    token = team.read(supervisor)["owner_token"]
    def rejected(caller, name, arguments):
        try:
            team.dispatch(caller, name, arguments)
        except ValueError:
            return
        raise AssertionError("Unauthorized operation accepted: " + name)
    rejected(supervisor, "worker_start", {"name": "Premature", "task": "Work", "owner_token": token})
    team.dispatch(supervisor, "team_checkpoint", {
        "handoff": "User approved color only. Worker has implemented blue; review next.",
        "execution": "authorized", "owner_token": token})
    checkpoint_at = team.read(supervisor)["checkpoint_at"]
    rejected(supervisor, "worker_start", {"kind": "executor", "name": "Too early", "task": "Work", "owner_token": token})
    rejected(supervisor, "worker_start", {"kind": "executor", "purpose": "research", "name": "Wrong kind", "task": "Plan", "owner_token": token})
    rejected(supervisor, "worker_start", {"purpose": "code", "name": "Wrong phase", "task": "Work", "owner_token": token})
    planner = team.dispatch(supervisor, "worker_start", {
        "kind": "planner", "name": "Plan color", "task": "Research color and ask about missing decisions.", "owner_token": token})
    assert planner["backend"] == "claude" and planner["model"] == "opus"
    assert "task" not in planner and "assignment" not in planner, "mutations must return summaries"
    # MCP configs run commands, so only files the user placed in MCP_DIR are accepted.
    team.MCP_DIR = root / "mcp"
    team.MCP_DIR.mkdir()
    (team.MCP_DIR / "grafana.json").write_text("{}")
    approved = team.approved_mcp_config("grafana")
    worker_args = shlex.split(team.worker_command({**planner, "mcp_config": approved}, root / "out.json")[2])
    assert worker_args[worker_args.index("--mcp-config") + 1] == approved
    for bad in ("{}", '{"mcpServers": {}}', "-x", "../grafana", "/etc/passwd", "missing"):
        try:
            team.approved_mcp_config(bad)
        except ValueError:
            continue
        raise AssertionError(f"accepted mcp_config {bad!r}")
    planner_args = shlex.split(team.worker_command(planner, root / "out.json")[2])
    assert planner_args[0] == "claude" and planner_args[planner_args.index("--model") + 1] == "opus"
    # Planning stays on the user's Claude subscription until they choose otherwise;
    # a recorded planner_backend then routes later planners to Codex, still kind="planner".
    rejected(supervisor, "team_checkpoint", {"execution": "authorized", "planner_backend": "gpt", "owner_token": token})
    team.dispatch(supervisor, "team_checkpoint", {"execution": "authorized", "planner_backend": "codex-bf", "owner_token": token})
    second_planner = team.dispatch(supervisor, "worker_start", {
        "kind": "planner", "name": "Plan color alternative", "task": "Plan an alternative.", "owner_token": token})
    assert second_planner["kind"] == "planner" and second_planner["backend"] == "codex-bf"
    assert second_planner["model"] == team.EXECUTION_MODEL
    assert team.team_status(supervisor)["supervisor"]["routes"]["plan"]["backend"] == "codex-bf"
    wait(second_planner["id"])
    team.worker_stop(supervisor, second_planner["id"])
    team.dispatch(supervisor, "team_checkpoint", {"execution": "authorized", "planner_backend": "claude", "owner_token": token})
    # Per-purpose routes: defaults, research as a read-only planner on Bifrost Claude,
    # the budget switch for the next worker, explicit overrides, and resets.
    routes = team.team_status(supervisor)["supervisor"]["routes"]
    assert routes == {"plan": {"backend": "claude", "model": "opus"}, "research": {"backend": "claude-bf", "model": "opus"},
                      "code": {"backend": "claude", "model": "opus"}, "qa": {"backend": "claude-bf", "model": "sonnet"}}
    assert team.team_status(supervisor)["supervisor"]["budget"] == "subscription"
    research = team.dispatch(supervisor, "worker_start", {"purpose": "research", "name": "Survey", "task": "Survey colors.", "owner_token": token})
    assert research["kind"] == "planner" and research["purpose"] == "research"
    assert (research["backend"], research["model"]) == ("claude-bf", "opus")
    research_args = shlex.split(team.worker_command(research, root / "out.json")[2])
    # The claude-bf wrapper forces ANTHROPIC_MODEL unless --model is passed.
    assert research_args[0] == "claude-bf" and research_args[research_args.index("--model") + 1] == "opus"
    wait(research["id"])
    team.worker_stop(supervisor, research["id"])
    rejected(supervisor, "team_checkpoint", {"execution": "authorized", "budget": "cheap", "owner_token": token})
    rejected(supervisor, "team_checkpoint", {"execution": "authorized", "routes": {"deploy": {"backend": "claude"}}, "owner_token": token})
    rejected(supervisor, "team_checkpoint", {"execution": "authorized", "routes": {"qa": {"backend": "gpt"}}, "owner_token": token})
    rejected(supervisor, "team_checkpoint", {"execution": "authorized", "routes": {"qa": {"model": "--yolo"}}, "owner_token": token})
    team.dispatch(supervisor, "team_checkpoint", {"execution": "authorized", "budget": "bifrost", "owner_token": token})
    routes = team.team_status(supervisor)["supervisor"]["routes"]
    assert {route["backend"] for route in routes.values()} == {"claude-bf"}
    budget_planner = team.dispatch(supervisor, "worker_start", {"kind": "planner", "name": "Budget plan", "task": "Plan.", "owner_token": token})
    assert (budget_planner["backend"], budget_planner["model"]) == ("claude-bf", "opus")
    explicit = team.dispatch(supervisor, "worker_start", {"kind": "planner", "backend": "claude", "model": "sonnet",
                                                          "name": "Explicit plan", "task": "Plan.", "owner_token": token})
    assert (explicit["backend"], explicit["model"]) == ("claude", "sonnet")
    for started in (budget_planner, explicit):
        wait(started["id"])
        team.worker_stop(supervisor, started["id"])
    team.dispatch(supervisor, "team_checkpoint", {"execution": "authorized", "budget": "subscription",
                                                  "routes": {"qa": {"backend": "codex-bf"}, "code": {"model": "sonnet"}}, "owner_token": token})
    routes = team.team_status(supervisor)["supervisor"]["routes"]
    assert routes["plan"]["backend"] == "claude" and routes["code"] == {"backend": "claude", "model": "sonnet"}
    assert routes["qa"] == {"backend": "codex-bf", "model": team.EXECUTION_MODEL}
    team.dispatch(supervisor, "team_checkpoint", {"execution": "authorized", "routes": {"qa": {}, "code": {}}, "owner_token": token})
    assert team.team_status(supervisor)["supervisor"]["routes"]["qa"] == {"backend": "claude-bf", "model": "sonnet"}
    assert "qa" not in team.read(supervisor)["routes"]
    # Pre-routes records keep their recorded choice and move it into routes on the next checkpoint.
    legacy = team.read(supervisor)
    legacy.pop("routes")
    legacy["planner_backend"] = "codex-bf"
    team.save(legacy)
    assert team.team_status(supervisor)["supervisor"]["routes"]["plan"]["backend"] == "codex-bf"
    team.dispatch(supervisor, "team_checkpoint", {"execution": "authorized", "owner_token": token})
    assert "planner_backend" not in team.read(supervisor) and team.read(supervisor)["routes"]["plan"] == {"backend": "codex-bf"}
    team.dispatch(supervisor, "team_checkpoint", {"execution": "authorized", "routes": {"plan": {}}, "owner_token": token})
    assert team.team_status(supervisor)["supervisor"]["routes"]["plan"]["backend"] == "claude"
    inherited = {"ANTHROPIC_AUTH_TOKEN": "fake", "ANTHROPIC_BASE_URL": "https://invalid.example",
                 "CLAUDE_CONFIG_DIR": "/fake/bifrost", "BIFROST_API_KEY": "fake", "CLAUDE_CODE_USE_BEDROCK": "1"}
    original_env = {key: os.environ.get(key) for key in inherited}
    os.environ.update(inherited)
    subscription_env = team.worker_environment(planner)
    assert all(key not in subscription_env for key in inherited)
    assert "PATH" in subscription_env
    for key, value in original_env.items():
        if value is None:
            os.environ.pop(key, None)
        else:
            os.environ[key] = value
    assert wait(planner["id"])["status"] == "needs supervisor"
    rejected(supervisor, "team_checkpoint", {"handoff": "Premature", "execution": "authorized", "phase": "execution", "owner_token": token})
    team.dispatch(supervisor, "agent_send", {"agent_id": planner["id"], "message": "Use blue, as agreed.", "owner_token": token})
    assert wait(planner["id"])["status"] == "done"
    plan = root / "plan.md"
    plan.write_text("Use blue. Implement color, test it, then independently review the diff.")
    team.dispatch(supervisor, "team_checkpoint", {"handoff": "User approved color only; review next.", "execution": "authorized",
        "phase": "execution", "plan_path": str(plan), "owner_token": token})
    checkpoint_at = team.read(supervisor)["checkpoint_at"]
    rejected(supervisor, "worker_start", {"kind": "executor", "backend": "codex-bf", "name": "Codex servers", "task": "Work", "mcp_config": "{}", "owner_token": token})
    rejected(supervisor, "worker_start", {"kind": "planner", "name": "Inline MCP", "task": "Work", "mcp_config": '{"mcpServers": {}}', "owner_token": token})
    coder = team.dispatch(supervisor, "worker_start", {"kind": "executor", "name": "Code color", "task": "Implement blue.", "owner_token": token})
    assert (coder["backend"], coder["model"], coder["purpose"]) == ("claude", "opus", "code")
    qa = team.dispatch(supervisor, "worker_start", {"purpose": "qa", "name": "QA color", "task": "Check blue.", "owner_token": token})
    assert (qa["kind"], qa["backend"], qa["model"]) == ("executor", "claude-bf", "sonnet")
    for started in (coder, qa):
        wait(started["id"])
        team.worker_stop(supervisor, started["id"])
    active_worker = team.dispatch(supervisor, "worker_start", {
        "kind": "executor", "backend": "codex-bf", "name": "Running during takeover", "task": "STOP_TEST", "owner_token": token})
    assert active_worker["backend"] == "codex-bf" and active_worker["model"] == team.EXECUTION_MODEL
    executor_args = shlex.split(team.worker_command(active_worker, root / "out.json")[2])
    assert executor_args[executor_args.index("--model") + 1] == team.EXECUTION_MODEL
    assert "--skip-git-repo-check" in executor_args
    assert 'model_provider="bifrost"' in executor_args
    resumed_args = shlex.split(team.worker_command({**active_worker, "session_id": "test-session"}, root / "out.json")[2])
    assert "--model" in resumed_args and "resume" in resumed_args and "--output-schema" in resumed_args
    time.sleep(0.3)
    successor, new_session = str(uuid.uuid4()), str(uuid.uuid4())
    team.save({"id": successor, "role": "chat", "backend": "codex-bf", "cwd": str(root), "created": time.time()})
    transfer = team.dispatch(successor, "team_takeover", {"team_id": supervisor, "session_id": new_session})
    assert transfer["brief"] == "Keep scope to color."
    assert transfer["supervisor"]["execution"] == "authorized"
    assert transfer["supervisor"]["phase"] == "execution" and transfer["supervisor"]["plan_path"] == str(plan)
    assert "review next" in transfer["handoff"]
    assert transfer["supervisor"]["checkpoint_at"] == checkpoint_at
    assert next(row for row in transfer["workers"] if row["id"] == active_worker["id"])["assignment"] == "STOP_TEST"
    assert transfer["workers"][0]["id"] == worker["id"]
    assert "brief" not in team.dispatch(successor, "team_status", {})["supervisor"]
    assert "owner_token" not in str(team.snapshot())
    rejected(supervisor, "worker_start", {"name": "Old", "task": "Work", "owner_token": token})
    rejected(supervisor, "worker_stop", {"agent_id": worker["id"], "owner_token": token})
    rejected(supervisor, "team_start", {"name": "Old", "brief": "Overwrite", "owner_token": token})
    successor_token = transfer["owner_token"]
    assert team.alive(team.read(active_worker["id"])["pid"])
    team.dispatch(successor, "worker_stop", {"agent_id": active_worker["id"], "owner_token": successor_token})
    assert wait(active_worker["id"])["status"] == "stopped"
    team.dispatch(successor, "agent_send", {"agent_id": worker["id"], "message": "Review blue.", "owner_token": successor_token})
    assert wait(worker["id"])["message"] == "Done with blue"
    assert team.read(worker["id"])["parent"] == supervisor
    assert team.read(worker["id"])["session_id"] == "test-session"
    reset_session = str(uuid.uuid4())
    reset_inbox = {}
    reset = team.dispatch(successor, "team_takeover", {"team_id": supervisor, "session_id": reset_session}, inbox=reset_inbox)
    assert reset["owner_token"] != successor_token
    assert team.read(successor)["session_id"] == reset_session
    # Takeover already returned every worker in full, so it seeds the inbox: the new
    # owner's next read is a diff, not a second copy of the assignments it just read.
    assert any("assignment" in row for row in reset["workers"])
    assert not any("assignment" in row for row in team.dispatch(successor, "team_status", {}, inbox=reset_inbox)["workers"])
    rejected(successor, "agent_send", {"agent_id": worker["id"], "message": "Stale", "owner_token": successor_token})
    team.dispatch(successor, "team_checkpoint", {"handoff": "Paused at user's request.", "execution": "paused", "owner_token": reset["owner_token"]})
    paused = team.dispatch(successor, "team_takeover", {"team_id": supervisor, "session_id": str(uuid.uuid4())})
    assert paused["supervisor"]["execution"] == "paused"
    rejected(successor, "agent_send", {"agent_id": worker["id"], "message": "Premature", "owner_token": paused["owner_token"]})
    assert (team.directory(supervisor) / "handoff.md").read_text().strip() == paused["handoff"]
    rejected(successor, "team_checkpoint", {"handoff": "Too long brief", "execution": "planning", "brief": "a\n\nb\n\nc\n\nd", "owner_token": paused["owner_token"]})
    # Resolve older deliberately failed fixture workers before entering review.
    for agent in (invalid, exited):
        team.worker_stop(supervisor, agent["id"])
    rejected(successor, "team_checkpoint", {"handoff": "Review", "execution": "authorized", "phase": "review", "owner_token": paused["owner_token"]})
    team.dispatch(successor, "team_checkpoint", {"handoff": "User chose Claude subscription review.", "execution": "authorized",
        "phase": "review", "reviewer_backend": "claude", "owner_token": paused["owner_token"]})
    rejected(successor, "worker_start", {"kind": "reviewer", "backend": "codex-bf", "name": "Wrong reviewer", "task": "Review", "owner_token": paused["owner_token"]})
    reviewer = team.dispatch(successor, "worker_start", {"kind": "reviewer", "backend": "claude", "name": "Review color", "task": "Review plan and diff; do not fix.", "owner_token": paused["owner_token"]})
    assert wait(reviewer["id"])["status"] == "needs supervisor"
    rejected(successor, "team_checkpoint", {"handoff": "Done", "execution": "finished", "phase": "finished", "owner_token": paused["owner_token"]})
    team.dispatch(successor, "agent_send", {"agent_id": reviewer["id"], "message": "The agreed color is blue.", "owner_token": paused["owner_token"]})
    assert wait(reviewer["id"])["status"] == "done"
    # Stopping finished workers keeps them done, so tidying cannot lock out completion.
    team.dispatch(successor, "worker_stop", {"agent_id": reviewer["id"], "owner_token": paused["owner_token"]})
    assert team.read(reviewer["id"])["status"] == "done"
    team.dispatch(successor, "team_checkpoint", {"execution": "finished", "phase": "finished", "owner_token": paused["owner_token"]})
    assert team.read(supervisor)["handoff"] == "User chose Claude subscription review."
    # A reset in the original terminal works without relinking worker parents.
    same_chat = team.dispatch(codex_id, "team_takeover", {"team_id": codex_id, "session_id": str(uuid.uuid4())})
    assert same_chat["supervisor"]["id"] == codex_id
    assert same_chat["supervisor"]["execution"] == "planning"
    # Claude SessionStart records the new ID used when takeover omits it.
    claude_session = str(uuid.uuid4())
    subprocess.run([sys.executable, str(team.SCRIPT), "hook", "--supervisor", supervisor,
                    "--root", str(team.ROOT), "--status", "idle"],
                   input=json.dumps({"session_id": claude_session}), text=True, check=True)
    claude_reset = team.dispatch(supervisor, "team_takeover", {"team_id": supervisor})
    assert team.read(supervisor)["session_id"] == claude_session
    assert claude_reset["supervisor"]["execution"] == "finished"
    assert claude_reset["supervisor"]["phase"] == "finished"
    original_tmux = team.tmux
    team.tmux = lambda *args, **kwargs: subprocess.CompletedProcess(args, 1)
    project_file = root / "keep.txt"
    project_file.write_text("Project files survive")
    running = team.worker_start(supervisor, "Delete running worker", "STOP_TEST", "codex-bf")
    time.sleep(0.3)
    team.manage_team(supervisor, "delete")
    assert not team.directory(supervisor).exists()
    assert not team.directory(running["id"]).exists()
    assert not team.directory(worker["id"]).exists()
    assert not team.directory(successor).exists()
    assert team.directory(codex_id).exists()
    assert project_file.read_text() == "Project files survive"
    team.tmux = original_tmux
    # Launch defaults follow the client, explicit polling wins, and reattach
    # preserves the mode of the already-running process. No real tmux/model calls.
    with patch.dict(os.environ):
        os.environ.pop("NVIM_TEAM_DELIVERY", None)
        with patch.object(team, "tmux", return_value=subprocess.CompletedProcess([], 1, stdout="")) as launch_tmux, \
                patch.object(team.os, "execvp"), patch.object(team, "ensure_mcp_login") as login:
            for backend, expected in (("claude", "events"), ("claude-bf", "events"), ("codex-bf", "poll")):
                chat_id = str(uuid.uuid4())
                team.launch(backend, chat_id)
                assert team.read(chat_id)["delivery"] == expected
                assert [call.args[0] for call in login.call_args_list] == (list(team.CODEX_OAUTH_PLUGINS) if backend == "codex-bf" else [])
                launch_tmux.assert_any_call("set-option", "-t", team.session_name(chat_id), "mouse", "on", check=True)
            os.environ["NVIM_TEAM_DELIVERY"] = "poll"
            chat_id = str(uuid.uuid4())
            team.launch("claude", chat_id)
            assert team.read(chat_id)["delivery"] == "poll"
        os.environ.pop("NVIM_TEAM_DELIVERY")
        with patch.object(team, "tmux", return_value=subprocess.CompletedProcess([], 0, stdout="")) as launch_tmux, \
                patch.object(team.os, "execvp"):
            team.launch("claude", chat_id)
            assert team.read(chat_id)["delivery"] == "poll"
            launch_tmux.assert_any_call("set-option", "-t", team.session_name(chat_id), "mouse", "on", check=True)
            assert "new-session" not in [call.args[0] for call in launch_tmux.call_args_list]
    with patch.object(team.shutil, "which", return_value="codex"), \
            patch.object(team.subprocess, "run") as run:
        team.ensure_mcp_login("atlassian-rovo")
        run.assert_called_once_with(["codex", "mcp", "login", "atlassian-rovo"], check=True)

    with patch.object(team, "tmux", return_value=subprocess.CompletedProcess([], 1)) as launch_tmux, \
            patch.object(team.os, "execvp") as attach, \
            patch.object(team.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "codex")):
        chat_id = str(uuid.uuid4())
        try:
            team.launch("codex-bf", chat_id)
        except subprocess.CalledProcessError:
            pass
        else:
            raise AssertionError("Failed login must stop launch")
        assert not (team.directory(chat_id) / "agent.json").exists()
        assert [call.args[0] for call in launch_tmux.call_args_list] == ["has-session"]
        attach.assert_not_called()

    with patch.object(team, "tmux", return_value=subprocess.CompletedProcess([], 0, stdout="")), \
            patch.object(team.os, "execvp"), patch.object(team, "ensure_mcp_login") as login:
        team.launch("codex-bf", codex_id)
        login.assert_not_called()
    with patch.object(team, "tmux", return_value=subprocess.CompletedProcess(
            [], 0, stdout=f"{team.session_name(codex_id)} 1\nunrelated 0\n")):
        rows = team.running()
        assert [row["id"] for row in rows] == [codex_id] and rows[0]["attached"] == 1
        assert set(rows[0]) == {"id", "backend", "name", "role", "cwd", "created", "attached"}
    with patch.object(team, "tmux", return_value=subprocess.CompletedProcess([], 1, stdout="")):
        assert team.running() == []
    # Commander chat: fixtures only, no real tmux or model. The chat_* tools unlock from the MCP
    # launch flag, never from agent.json.
    team.CLAUDE_DIR, team.CODEX_DIR = root / "claude", root / "codex"
    (team.CLAUDE_DIR / "sessions").mkdir(parents=True)
    (team.CLAUDE_DIR / "projects/p").mkdir(parents=True)
    (team.CODEX_DIR / "sessions/2026/11/23").mkdir(parents=True)
    ids = {key: str(uuid.uuid4()) for key in "CABPWXN"}
    sa, sx = str(uuid.uuid4()), str(uuid.uuid4())
    for key, extra in {"C": {"role": "commander", "delivery": "events"}, "A": {"session_id": sa, "name": "alpha"},
                       "B": {}, "P": {"config_dir": str(root / "personal")}, "W": {"role": "worker"},
                       "X": {"backend": "codex-bf", "chat_status": "idle", "session_id": sx},
                       "N": {"backend": "codex-bf", "session_id": None}}.items():
        team.save({"id": ids[key], "parent": None, "role": "chat", "name": key, "backend": "claude", "cwd": str(root),
                   "created": time.time(), "session_id": ids[key], "config_dir": "", **extra})
    (team.directory(ids["X"]) / "name").write_text("xray\n")
    (team.directory(ids["A"]) / "name").write_text("alpha\n")
    now_ms = lambda ago: int((time.time() - ago) * 1000)
    rows = {}

    def registry(key, session, status="idle", ago=10, name=None, pid=None):
        rows[key] = {"pid": pid or os.getpid(), "sessionId": session, "kind": "interactive", "name": name or key,
                     "tmux": f"team-{ids.get(key, key)}:@1.%1", "status": status, "statusUpdatedAt": now_ms(ago)}
        (team.CLAUDE_DIR / "sessions" / f"{key}.json").write_text(json.dumps(rows[key]))

    registry("A", sa)
    registry("B", ids["B"], "busy")
    registry("D", str(uuid.uuid4()), pid=999999)
    registry("C", ids["C"])
    ledger = json.dumps({"type": "artifact-autoreact-ledger", "pad": "x" * 1000})
    transcript = team.CLAUDE_DIR / "projects/p" / f"{sa}.jsonl"
    text = lambda role, content, **kw: json.dumps({"type": role, "timestamp": "2026-11-23T00:00:00Z",
                                                   "message": {"content": content}, **kw})
    transcript.write_text("\n".join([
        text("user", "fix the thing"), text("assistant", [{"type": "text", "text": "done, ok?"}]),
        text("assistant", [{"type": "tool_use", "name": "Bash", "input": {"command": "ls"}}]),
        text("user", "meta text", isMeta=True), text("user", "<system-reminder>x</system-reminder>"),
        json.dumps({"type": "queue-operation", "operation": "enqueue", "content": "<task-notification>x"}),
        json.dumps({"type": "queue-operation", "operation": "enqueue", "content": "plain"}),
        json.dumps({"type": "queue-operation", "operation": "dequeue", "content": "plain"}),
        *[ledger] * 3000]) + "\n")
    rollout = team.CODEX_DIR / "sessions/2026/11/23" / f"rollout-2026-11-23T00-00-00-{sx}.jsonl"
    message = lambda role, kind, body: json.dumps({"type": "response_item", "timestamp": "t", "payload": {
        "type": "message", "role": role, "content": [{"type": kind, "text": body}]}})
    rollout.write_text("\n".join([
        message("user", "input_text", "# AGENTS.md instructions for x"), message("user", "input_text", "real question"),
        message("developer", "input_text", "dev text"),
        json.dumps({"type": "response_item", "payload": {"type": "function_call", "name": "shell"}}),
        message("assistant", "output_text", "final answer")]) + "\n")

    rule = "─" * 80
    footer = "  work │ Opus 5.5\n  ⏵⏵ auto mode on (shift+tab to cycle)\n"
    idle_screen = f'out\n{rule}\n❯\xa0\x1b[2mTry "fix lint"\x1b[0m\n{rule}\n{footer}'
    typed = lambda body: f"out\n{rule}\n❯ {body}\n{rule}\n{footer}"
    dialog_screen = f"Do you want to proceed?\n ❯ 1. Yes\n   2. No\n Esc to cancel\n"
    assert team.input_text(idle_screen) == "" and team.input_text(typed("half typed")) == "half typed"
    assert team.input_text(dialog_screen) is None and team.DIALOG.search(dialog_screen)
    assert not team.DIALOG.search(team.SGR.sub("", idle_screen))
    # SGR: only attribute 2 is dim; 38/48 colour arguments (truecolor, 256, colon form) are not
    for params, start, dim in (("2", False, True), ("38;2;1;2;3", False, False), ("38;5;2", False, False), ("48;2;9;2;9", False, False),
                               ("38:2::1:2:3", False, False), ("1;2", False, True), ("38;2;1;2;3;2", False, True),
                               ("2;38;2;1;2;3", False, True), ("38;2;1;2;3", True, True), ("39", True, True),
                               ("22", True, False), ("0", True, False), ("", True, False)):
        assert team.sgr_dim(params, start) is dim, params
    assert team.input_text(f"out\n{rule}\n❯ \x1b[38;2;10;20;30mhalf typed\x1b[39m\n{rule}\n{footer}") == "half typed"
    assert team.input_text(f"out\n{rule}\n\x1b[38;2;1;2;3m❯\x1b[39m typed text\n{rule}\n{footer}") == "typed text"
    assert team.input_text(f"out\n{rule}\n❯ \x1b[38;5;2mhalf\x1b[0m\n{rule}\n{footer}") == "half"
    assert team.input_text(f"out\n{rule}\n❯ \x1b[2;38;2;1;2;3mTry x\x1b[0m\n{rule}\n{footer}") == ""
    plain_lines = lambda body: team.SGR.sub("", body).rstrip("\n").splitlines()
    survey = f"1: Bad  2: Fine  3: Good  0: Dismiss\nHow is Claude doing this session? (optional)\n{rule}\n❯ \n{rule}\n{footer}"
    assert not team.idle_layout(plain_lines(survey)) and team.idle_layout(plain_lines(idle_screen))
    assert not team.idle_layout(plain_lines(f"out\n{rule}\n❯ \n{rule}\n  work │ Opus 5.5\n"))
    assert not team.idle_layout(plain_lines(f"out\n{rule}\n❯ \n{rule}\n  Can Anthropic look at your session transcript to help us improve Claude Code?\n{footer}"))
    assert not team.idle_layout(plain_lines(f"out\n{rule}\n❯ \n{rule}\n" + "  x\n" * 6 + footer))
    asked = f"Would you like to merge it now?\n{rule}\n❯ \n{rule}\n{footer}"
    assert not team.DIALOG.search("\n".join(team.bottom(plain_lines(asked)))) and team.idle_layout(plain_lines(asked))
    assert team.DIALOG.search("\n".join(team.bottom(plain_lines(dialog_screen))))
    screens, calls, listed = {}, [], {"v": {"team-" + ids[k] for k in "CABPWXN"}}

    def fake(*args, **kwargs):
        calls.append(args)
        out = ""
        if args[0] == "list-sessions":
            out = "\n".join(sorted(listed["v"]))
        elif args[0] == "list-panes":
            out = "%" + args[2][len("=team-"):-1] + "\n"
        elif args[0] == "capture-pane":
            out = screens.get(args[-1][1:], idle_screen)
        elif args[0] == "display-message":
            out = screens.get("mode", "0")
        elif args[0] == "paste-buffer":
            target = args[-1][1:]
            screens[target] = typed(screens["paste"])
        elif args[0] == "load-buffer":
            screens["paste"] = kwargs["input"]
        elif args[0] == "send-keys" and (args[-1] == "Enter" or args[-1].isdigit()):
            rows["A"]["status"] = "busy"
            (team.CLAUDE_DIR / "sessions/A.json").write_text(json.dumps(rows["A"]))
            if args[-1].isdigit():
                screens[ids["A"]] = idle_screen
        return subprocess.CompletedProcess(args, 0, stdout=out)

    def refused(items, reason, **kw):
        calls.clear()
        result = team.chat_send(ids["C"], items)["results"][0]
        assert result["result"] == "refused" and reason in result["reason"], result
        assert not any(c[0] == "paste-buffer" for c in calls)
        return result

    send = lambda key, body, name=None: [{"chat_id": ids[key], "chat_name": name or {"A": "alpha"}.get(key, key), "text": body}]
    with patch.object(team, "tmux", fake), patch.object(team.time, "sleep"):
        listing = team.chat_list(ids["C"], inbox=(box := {}))
        by = {c["id"]: c for c in listing["chats"]}
        assert set(by) == {ids[k] for k in "ABXN"}, set(by)
        assert by[ids["A"]]["state"] == "idle" and by[ids["B"]]["state"] == "working" and by[ids["X"]]["state"] == "idle"
        assert "transcript" not in by[ids["N"]] and by[ids["A"]]["last_prompt"] == "fix the thing"
        assert by[ids["X"]]["last_reply"] == "final answer" and by[ids["X"]]["last_prompt"] == "real question"
        assert team.chat_list(ids["C"], inbox=box)["chats"] == []
        with transcript.open("a") as file:
            file.write(ledger + "\n")
        assert team.chat_list(ids["C"], inbox=box)["chats"] == []
        with transcript.open("a") as file:
            file.write(text("assistant", [{"type": "text", "text": "new reply"}], timestamp="2026-11-23T00:00:09Z") + "\n")
        assert [c["id"] for c in team.chat_list(ids["C"], inbox=box)["chats"]] == [ids["A"]]
        assert len(team.chat_list(ids["C"], full=True, inbox=box)["chats"]) == 4
        listed["v"].discard("team-" + ids["B"])
        assert team.chat_list(ids["C"], inbox=box)["removed"] == [ids["B"]]
        listed["v"].add("team-" + ids["B"])
        read_items = team.chat_read(ids["C"], ids["A"][:8])["items"]
        assert [i["role"] for i in read_items] == ["user", "assistant", "tool", "assistant"], read_items
        for bad, word in (("nope", "No live chat"),):
            try:
                team.chat_read(ids["C"], bad)
            except ValueError as error:
                assert word in str(error)
            else:
                raise AssertionError(bad)
        screens[ids["A"]] = idle_screen
        assert team.chat_read(ids["C"], ids["A"], source="screen")["screen"][0] == "out"

        # chat_send guards: every refusal happens before any paste
        refused(send("B", "hello there"), "Chat is working")
        refused(send("X", "hello there", "xray"), "Codex")
        refused(send("A", "hello", "wrong"), "chat_name does not match")
        refused([{"chat_id": ids["A"][:8], "chat_name": "alpha", "text": "hello"}], "No live chat")
        for body, why in (("/clear", "ASCII letter"), ("!ls", "ASCII letter"), ("1", "ASCII letter"), (" 2 yes", "ASCII letter"),
                          ("a\x1b[201~b", "control"), ("a\nb", "control"), ("a‮b", "control"), ("a​b", "control"),
                          ("x" * 501, "1-500"), ("see @", "end with a word"), ("look in /tmp", "end with a word")):
            refused(send("A", body), why)
        try:
            team.chat_send(ids["C"], send("A", "a") * 4)
        except ValueError as error:
            assert "1-3" in str(error)
        else:
            raise AssertionError("4 items")
        try:
            team.chat_send(ids["C"], send("A", "a" * 450) * 3)
        except ValueError as error:
            assert "1200" in str(error)
        else:
            raise AssertionError("batch size")
        screens[ids["A"]] = dialog_screen
        refused(send("A", "hello"), "dialog")
        screens[ids["A"]] = typed("half typed")
        refused(send("A", "hello"), "not empty")
        screens[ids["A"]] = "no prompt here\n"
        refused(send("A", "hello"), "plain idle layout")
        screens[ids["A"]] = idle_screen
        screens["mode"] = "1"
        refused(send("A", "hello"), "copy mode")
        screens["mode"] = "0"
        registry("A", sa, ago=0.5)
        refused(send("A", "hello"), "just changed state")
        registry("A", sa)
        registry("A2", sa)
        assert [c["state"] for c in team.live_chats(ids["C"]) if c["id"] == ids["A"]] == ["unknown"]
        refused(send("A", "hello"), "only chats whose turn is done")
        (team.CLAUDE_DIR / "sessions/A2.json").unlink()
        registry("A", sa)
        seen = team.seen_text[:]
        team.seen_text.append("The quick brown fox jumps over the lazy dog, again and again.")
        refused(send("A", "Write: The quick brown fox jumps over the lazy dog, again and again."), "copies")
        team.seen_text[:] = seen
        screens[ids["A"]] = idle_screen
        calls.clear()

        # success: one bracketed paste, then Enter; never send-keys -l
        result = team.chat_send(ids["C"], send("A", "Please continue"))["results"][0]
        assert result["result"] == "sent" and result["confirmed"], result
        names = [c[0] for c in calls if c[0] in ("load-buffer", "paste-buffer", "send-keys")]
        assert names == ["load-buffer", "paste-buffer", "send-keys"] and calls[-2][-1] != "-l"
        assert all("-l" not in c for c in calls if c[0] == "send-keys")
        assert screens["paste"] == "[commander] Please continue"
        assert ["-t", "=team-" + ids["A"] + ":"] == list(next(c for c in calls if c[0] == "list-panes")[1:3])
        log_rows = [json.loads(line) for line in (team.directory(ids["C"]) / "commander.log").read_text().splitlines()]
        assert log_rows[-1]["result"] == "sent" and log_rows[-1]["text"] == "[commander] Please continue" and log_rows[-1]["sha256"]
        for earlier, later in zip(log_rows, log_rows[1:]):
            assert later["prev"] == hashlib.sha256(json.dumps(earlier).encode()).hexdigest()
        assert oct((team.directory(ids["C"]) / "commander.log").stat().st_mode & 0o777) == "0o600"
        refused(send("A", "again please"), "1 send per chat per 30 s")
        # re-check failure: a dialog appears after the paste, no Enter is sent
        registry("A", sa)
        screens[ids["A"]] = idle_screen
        (team.directory(ids["C"]) / "commander.log").write_text("")
        calls.clear()
        original_fake = fake

        def late_dialog(*args, **kwargs):
            result = original_fake(*args, **kwargs)
            if args[0] == "paste-buffer":
                screens[ids["A"]] = dialog_screen
            return result
        with patch.object(team, "tmux", late_dialog):
            result = team.chat_send(ids["C"], send("A", "Please continue"))["results"][0]
        assert result["result"] == "refused" and result.get("text_left_in_input"), result
        assert not any(c[0] == "send-keys" for c in calls)
        screens[ids["A"]] = idle_screen
        # the box shows something other than our text: no Enter
        calls.clear()

        def other_text(*args, **kwargs):
            result = original_fake(*args, **kwargs)
            if args[0] == "paste-buffer":
                screens[ids["A"]] = typed("someone typed here too")
            return result
        with patch.object(team, "tmux", other_text):
            result = team.chat_send(ids["C"], send("A", "Please continue"))["results"][0]
        assert result["result"] == "refused" and "exactly" in result["reason"]
        assert not any(c[0] == "send-keys" for c in calls)
        screens[ids["A"]] = idle_screen
        log = team.directory(ids["C"]) / "commander.log"
        # a survey above an empty box, or a missing footer, is refused before any paste
        log.write_text("")
        for bad in (survey, f"out\n{rule}\n❯ \n{rule}\n  work │ Opus 5.5\n"):
            screens[ids["A"]] = bad
            refused(send("A", "hello"), "plain idle layout")
        # a reply that asks "Would you like to" does not block a send
        screens[ids["A"]] = f"Would you like to merge it now?\n{rule}\n❯\xa0\x1b[2mTry x\x1b[0m\n{rule}\n{footer}"
        assert team.chat_send(ids["C"], send("A", "Yes merge it"))["results"][0]["result"] == "sent"
        # bypass-permissions chats are refused by their footer; manual-mode chats are allowed
        log.write_text("")
        registry("A", sa)
        screens[ids["A"]] = idle_screen.replace("⏵⏵ auto mode on", "⏵⏵ bypass permissions on")
        refused(send("A", "hello"), "plain idle layout")
        screens[ids["A"]] = idle_screen.replace("⏵⏵ auto mode on (shift+tab to cycle)", "⏸ manual mode on")
        assert team.chat_send(ids["C"], send("A", "Manual mode is fine"))["results"][0]["result"] == "sent"
        # shell (turn done, a background shell or agent still runs) is accepted, with agent rows under the footer;
        # a running turn is still refused
        log.write_text("")
        registry("A", sa, "shell")
        rows_below = "  ⏺ main\n" + "".join(f"  ◯ general-purpose  waiting on 1 shell · task {n}\n" for n in range(6))
        screens[ids["A"]] = idle_screen + rows_below
        result = team.chat_send(ids["C"], send("A", "Background work is fine"))["results"][0]
        assert result["result"] == "sent" and result["confirmed"] is True, result
        log.write_text("")
        registry("A", sa, "busy")
        refused(send("A", "hello"), "working")
        # chat_answer: a one-time option on a waiting chat; refuses standing options, a Yes to hard stops, idle chats
        perm = ("out\n Bash command\n   printf 'format=B' > notes.txt\n Do you want to proceed?\n ❯ 1. Yes\n"
                "   2. Yes, and don't ask again for printf commands in /work\n"
                "   3. No, and tell Claude what to do differently (esc)\n Esc to cancel\n")
        assert team.dialog_options(perm)[1] == {1: "Yes", 2: "Yes, and don't ask again for printf commands in /work",
                                               3: "No, and tell Claude what to do differently (esc)"}
        answer = lambda option: team.chat_answer(ids["C"], ids["A"], "alpha", option)

        def pending(command):
            call = str(uuid.uuid4())
            with transcript.open("a") as file:
                file.write(text("assistant", [{"type": "tool_use", "id": call, "name": "Bash", "input": {"command": command}}]) + "\n")
            return call

        def finish(call):
            with transcript.open("a") as file:
                file.write(text("user", [{"type": "tool_result", "tool_use_id": call, "content": ""}]) + "\n")

        log.write_text("")
        registry("A", sa, "waiting")
        screens[ids["A"]] = perm
        assert "one-time Yes" in answer(2)["reason"]
        assert "No option 5" in answer(5)["reason"]
        assert "pending tool call" in answer(1)["reason"]  # no pending call in the transcript: refuse
        push = pending("git push origin main && printf 'format=B' > notes.txt")
        assert "push to main" in answer(1)["reason"]  # the screen shows only the tail; the transcript has the push
        finish(push)
        # git push: allowed to a branch with an open PR; never main/master, forced, deleting or hidden
        prs = {"feature-x": '[{"number": 7}]', "no-pr": "[]"}

        def run_in(cwd, *command):
            out = "feature-x" if command[:2] == ("git", "rev-parse") else prs.get(command[4], "[]")
            return subprocess.CompletedProcess(command, 0, stdout=out)

        with patch.object(team, "run_in", run_in):
            def approve(command, screen_text=None):
                log.write_text("")
                registry("A", sa, "waiting")
                screens[ids["A"]] = perm.replace("printf 'format=B' > notes.txt", screen_text or command[:60])
                call = pending(command)
                result = answer(1)
                finish(call)
                return result

            for allowed in ("git push origin feature-x", "git push -u origin HEAD",
                            "git push origin feature-x:feature-x", 'gh pr comment 12 --body "terrateam plan"',
                            "gh pr comment 12 -b 'terrateam plan dir:terraform/x workspace:default'",
                            'git commit -m "fix consumer" && git push origin feature-x',
                            "gh pr create --draft --title x", "gh api repos/x/y/pulls",
                            "gh api --paginate --jq .[].number repos/x/y/pulls", "gh pr create -t '-d' --draft"):
                assert approve(allowed)["result"] == "answered", (allowed, approve(allowed))
            for refused_command, why in (
                    ("git push origin no-pr", "no open PR"), ("git push origin main", "push to main"),
                    ("git push origin HEAD:master", "push to master"), ("git push -f origin feature-x", "options"),
                    ("git push --force-with-lease", "options"), ("git push origin +feature-x", "force push"),
                    ("git push origin :feature-x", "deleting"), ("git push --delete origin feature-x", "options"),
                    ("git push upstream feature-x", "other than origin"), ("git -c a=b push origin feature-x", "options before"),
                    ("/usr/bin/git push origin main", "plain"), ("xargs git push origin feature-x", "another command"),
                    ("echo $(git push origin feature-x)", "cannot be checked"), ("cd /tmp && git push origin feature-x", "shares its command"),
                    ("git\tpush origin main", "push to main"), ("printf x; git\x0bpush", "one shell word"),
                    ('gh pr comment 12 --body "terrateam apply"', "terrateam plan"),
                    ('gh pr comment 12 --body "terrateam plan; terrateam apply"', "terrateam plan"),
                    ('gh pr comment 12 --body "lgtm"', "terrateam plan"), ("gh pr comment 12 --body-file x", "option"),
                    ("gh pr ready 12", "hard stop"), ("gh pr merge 12", "hard stop"), ("terraform plan", "hard stop"),
                    ("tofu apply", "hard stop"), ("printf x#; git push origin main", "push to main"),
                    ("G=git; $G push origin main", "built at run time"), ("git push", "name the branch"),
                    ("git push origin", "name the branch"), ('git commit -m "fix push"', "cannot place"),
                    ("git remote set-url origin x && git push origin feature-x", "shares its command"),
                    ("X=push; git $X origin main", "built at run time"),
                    ('git -c alias.p=pu""sh p origin main', "options before"), ("git p origin main", "allow-list"),
                    ("git push origin feature-x && echo done", "shares its command"),
                    ("git push origin feature-x > out.txt", "unexpected"), ("git add . > log.txt && git push origin feature-x", "shares its command"), ("git branch -d old", "hard stop"),
                    ("gh pr create --title x", "without --draft"), ("gh api -X POST repos/x/y/issues", "read options"), ("gh api -XPOST repos/x/y/issues", "read options"),
                    ("gh api -fbody=x repos/x/y/issues", "read options"), ("gh api --method=POST repos/x", "read options"),
                    ("gh api -H 'X-HTTP-Method-Override: POST' repos/x", "read options"),
                    ("gh pr create --title -d", "without --draft"), ("gh pr create -t '--draft' -b x", "without --draft"),
                    ("gh pr create --draft=false", "unknown option"), ("gh pr create -dw", "unknown option"),
                    ("gh pr close 12", "allow-list"), ("gh co 12", "allow-list")):
                result = approve(refused_command)
                assert result["result"] == "refused" and why in result["reason"], (refused_command, result)
            # the screen shows a push the transcript does not explain
            assert "does not explain" in approve("printf ok > notes.txt", "git push origin main")["reason"]
        pending("printf 'format=B' > notes.txt")
        pending("printf 'format=B' > notes.txt")
        screens[ids["A"]] = perm.replace("1. Yes", "1. Yes, and auto-accept edits")
        assert "one-time Yes" in answer(1)["reason"]
        screens[ids["A"]] = perm.replace("printf 'format=B' > notes.txt", "gh pr merge 12")
        assert "hard stop" in answer(1)["reason"]
        assert answer(3)["result"] == "answered"  # declining a hard stop is fine
        log.write_text("")
        registry("A", sa, "waiting")
        screens[ids["A"]] = perm
        calls.clear()
        result = answer(1)
        assert result["result"] == "answered" and result["confirmed"] and result["label"] == "Yes", result
        assert ("send-keys", "-t", "%" + ids["A"], "1") in calls
        assert json.loads(log.read_text().splitlines()[-1])["tool"] == "chat_answer"
        # a status icon that changes between the two reads is not a changed prompt
        assert team.dialog_key(*team.dialog_options("⏺ Bash\n" + perm)) == team.dialog_key(*team.dialog_options("✻ Bash\n" + perm))
        assert team.dialog_key(*team.dialog_options(perm)) != team.dialog_key(*team.dialog_options(perm.replace("notes", "other")))
        # answers skip the per-chat 30 s rule and do not count toward it: answer twice, then send, all at once
        registry("A", sa, "waiting")
        screens[ids["A"]] = perm
        assert answer(1)["result"] == "answered"
        registry("A", sa)
        assert team.chat_send(ids["C"], send("A", "Thanks, carry on"))["results"][0]["result"] == "sent"
        registry("A", sa)
        assert "only a chat waiting" in answer(1)["reason"]
        # AskUserQuestion: chat_read returns the full input; chat_answer answers each tab, checks the review page, submits
        ask = [{"header": "Color", "question": "Which color?", "multiSelect": False,
                "options": [{"label": "Red", "description": "warm"}, {"label": "Blue", "description": "cool"}]},
               {"header": "Pets", "question": "Which pets?", "multiSelect": True, "options": [
                   {"label": "Cat", "description": "c"}, {"label": "Dog", "description": "d"}, {"label": "Fish", "description": "f"}]},
               {"header": "Size", "question": "Which size?", "multiSelect": False,
                "options": [{"label": "Small", "description": "s"}, {"label": "Large", "description": "l"}]}]

        def asking(questions):
            call = "toolu_" + uuid.uuid4().hex
            with transcript.open("a") as file:
                file.write(text("assistant", [{"type": "tool_use", "id": call, "name": "AskUserQuestion",
                                               "input": {"questions": questions}}]) + "\n")
            return call

        review = ("Review your answers\n ● Which color?\n   → Blue\n ● Which pets?\n   → Cat, Fish\n"
                  " ● Which size?\n   → Medium please\n\n❯ 1. Submit answers\n  2. Cancel\n")
        tabs = "←  ☐ Color  ☐ Pets  ☐ Size  ✔ Submit  →\nWhich color?\nWhich pets?\nWhich size?\n"
        dialog = {"keys": [], "review": review, "row": "❯    Submit"}

        def question_tmux(*args, **kwargs):
            calls.append(args)
            if args[0] == "capture-pane":
                keys = dialog["keys"]
                if keys[-2:] == ["Medium please", "Enter"]:
                    return subprocess.CompletedProcess(args, 0, stdout=dialog["review"])
                return subprocess.CompletedProcess(args, 0, stdout=tabs + (dialog["row"] if keys[-1:] == ["Down"] else "❯ 1. Red") + "\n")
            if args[0] == "send-keys":
                if dialog["keys"][-2:] == ["Medium please", "Enter"] and args[-1] == "1":
                    registry("A", sa, "busy")
                dialog["keys"].append(args[-1])
                return subprocess.CompletedProcess(args, 0, stdout="")
            return original_fake(*args, **kwargs)

        good = [{"option": 2}, {"options": [3, 1]}, {"text": "Medium please"}]
        ask_answer = lambda qid, answers, **kw: team.chat_answer(ids["C"], ids["A"], "alpha", question_id=qid, answers=answers, **kw)
        with patch.object(team, "tmux", question_tmux):
            def run(qid, answers, **kw):
                log.write_text("")
                registry("A", sa, "waiting")
                dialog["keys"] = []
                return ask_answer(qid, answers, **kw)

            for call in team.pending_tools(team.resolve_chat(ids["C"], ids["A"])):
                finish(call["id"])
            qid = asking(ask)
            registry("A", sa)
            assert "question" not in team.chat_read(ids["C"], ids["A"])  # only a waiting chat shows its question
            registry("A", sa, "waiting")
            read_back = team.chat_read(ids["C"], ids["A"], source="screen")
            assert read_back["question"] == {"id": qid, "questions": ask}, read_back
            assert "question" in team.chat_read(ids["C"], ids["A"]) and "cool" in "\n".join(team.seen_text)
            result = run(qid, good)
            assert result["result"] == "answered" and result["confirmed"], result
            assert result["answers"] == ["Blue", "Cat, Fish", "Medium please"]
            assert dialog["keys"] == ["2", "1", "3", "Down", "Down", "Down", "Down", "Enter", "3", "Medium please", "Enter", "1"], dialog["keys"]
            assert ("send-keys", "-t", "%" + ids["A"], "-l", "--", "Medium please") in calls
            assert json.loads(log.read_text().splitlines()[-1])["answers"] == result["answers"]
            finish(qid)
            # refusals before any key
            standing = [dict(ask[0], options=[{"label": "Yes, and don't ask again", "description": ""}, ask[0]["options"][1]])]
            for qs, qid_of, answers, why in (
                    (ask, "toolu_old", good, "changed or is gone"), (ask, None, good[:2], "one answer per question"),
                    (ask, None, [{"option": 3}, *good[1:]], "options 1-2"), (ask, None, [good[0], {"option": 1}, good[2]], "takes options"),
                    (ask, None, [good[0], {"text": "Cat please"}, good[2]], "multiSelect"),
                    (ask, None, [good[0], {"options": [1, 1]}, good[2]], "options 1-3"),
                    (ask, None, [{"option": True}, *good[1:]], "options 1-2"),
                    (ask, None, [good[0], good[1], {"text": "/clear"}], "ASCII letter"),
                    (ask, None, [good[0], good[1], {"text": "Always allow this from now on"}], "standing"),
                    (ask, None, [good[0], good[1], {"text": "Go ahead and merge it"}], "hard stop"),
                    (ask, None, [good[0], good[1], {"option": 1, "text": "x"}], "Each answer"),
                    (standing, None, [{"option": 1}], "standing permission"),
                    ([dict(ask[0], question="Merge the PR now?")], None, [{"option": 2}], "hard stop"),
                    ([dict(ask[0], options=[{"label": "Push to main", "description": ""}, ask[0]["options"][1]])], None, [{"option": 1}], "hard stop"),
                    ([dict(ask[0], options=[ask[0]["options"][0], {"label": "Run terraform apply", "description": ""}])], None, [{"option": 2}], "hard stop")):
                call = asking(qs)
                result = run(qid_of or call, answers)
                assert result["result"] == "refused" and why in result["reason"], (answers, result)
                assert dialog["keys"] == [], (answers, dialog["keys"])
                finish(call)
            qid = asking(ask)
            for extra, why in (({"option": 1}, "not both"), ({}, None)):
                result = team.chat_answer(ids["C"], ids["A"], "alpha", question_id=qid, answers=good if extra else None, **extra)
                assert result["result"] == "refused" and "not both" in result["reason"], result
            # the review page shows something else: no Submit, the dialog stays open
            dialog["review"] = review.replace("Medium please", "Large")
            result = run(qid, good)
            assert result["result"] == "partial" and "review page" in result["reason"] and dialog["keys"][-1] == "Enter", result
            dialog["review"] = review
            # the cursor did not reach the multiSelect Submit row
            dialog["row"] = "❯ 4. [ ] Type something"
            result = run(qid, good)
            assert result["result"] == "partial" and "Submit row" in result["reason"], result
            dialog["row"] = "❯    Submit"
            # the question is not on screen
            tabs_saved, tabs = tabs, "something else\n"
            result = run(qid, good)
            assert result["result"] == "refused" and "not on screen" in result["reason"] and not dialog["keys"], result
            tabs = tabs_saved
            # a digit must never land on a permission dialog: another pending call, or a dialog on screen, refuses
            bash = pending("printf x > notes.txt")
            result = run(qid, good)
            assert result["result"] == "refused" and "Another tool call" in result["reason"] and not dialog["keys"], result
            finish(bash)
            tabs_saved, tabs = tabs, tabs + "Do you want to proceed?\n❯ 1. Yes\n  2. Yes, and don't ask again\n"
            result = run(qid, good)
            assert result["result"] == "refused" and "permission dialog" in result["reason"] and not dialog["keys"], result
            tabs = tabs_saved
            finish(qid)
        # chat_open: starts a detached plain-claude chat named in cwd; refuses bad names, folders and duplicates
        log.write_text("")
        opened = []
        with patch.object(team, "WORKSPACE", team.ROOT.parent), patch.object(team, "launch", lambda *a, **kw: (opened.append((a, kw)), team.save(
                {"id": a[1], "name": "claude chat", "backend": "claude", "role": "chat", "created": time.time()}))):
            result = team.chat_open(ids["C"], "db fix", str(team.ROOT))
            assert result["result"] == "opened" and opened[-1][0][0] == "claude", result
            assert opened[-1][1] == {"cwd": str(team.ROOT.resolve()), "attach": False, "clean_env": True}
            assert (team.directory(result["chat_id"]) / "name").read_text() == "db fix\n"
            for name, cwd, why in (("alpha", str(team.ROOT), "already has that name"), ("-x", str(team.ROOT), "name is"),
                                   ("a" * 61, str(team.ROOT), "name is"), ("ok", str(team.ROOT / "missing"), "not a directory"),
                                   ("ok\nx", str(team.ROOT), "name is"), ("ok", "/", "must be under")):
                result = team.chat_open(ids["C"], name, cwd)
                assert result["result"] == "refused" and why in result["reason"], (name, result)
            assert len(opened) == 1 and json.loads(log.read_text().splitlines()[-1])["tool"] == "chat_open"
            result = team.chat_open(ids["C"], "bf chat", str(team.ROOT), "claude-bf")
            assert result["result"] == "opened" and opened[-1][0][0] == "claude-bf" and not opened[-1][1]["clean_env"], result
            for bad in ("codex-bf", "", None, "claude --x"):
                result = team.chat_open(ids["C"], "bad backend", str(team.ROOT), bad)
                assert result["result"] == "refused" and "backend must be" in result["reason"], (bad, result)
            assert len(opened) == 2
        # a plain claude chat from chat_open never inherits Bifrost env; claude-bf keeps it
        with patch.dict(os.environ, {"ANTHROPIC_BASE_URL": "https://x", "ANTHROPIC_AUTH_TOKEN": "t", "ANTHROPIC_MODEL": "m"}), \
                patch.object(team, "tmux", return_value=subprocess.CompletedProcess([], 1, stdout="")) as launch_tmux, \
                patch.object(team.os, "execvp"):
            for backend, clean in (("claude", True), ("claude-bf", False)):
                team.launch(backend, str(uuid.uuid4()), attach=False, clean_env=clean)
                call = next(c for c in launch_tmux.call_args_list if c.args[0] == "new-session")
                assert any(k.startswith("ANTHROPIC_") for k in call.kwargs["env"]) != clean, backend
                pane = shlex.split(call.args[-1])[-1]
                assert ("unset -m 'ANTHROPIC_*' 'CLAUDE_CODE_USE_*'" in pane) == clean, backend
                assert ("unset CLAUDE_CONFIG_DIR BIFROST_API_KEY CLAUDE_CODE_API_KEY_HELPER" in pane) == clean
                launch_tmux.reset_mock()
        # goals survive in a file under the team home
        assert team.goal_load(ids["C"]) == {"goals": []}
        team.goal_save(ids["C"], [{"title": "Ship X", "owner": "alpha", "next": "review"}])
        assert team.goal_load(ids["C"])["goals"][0]["owner"] == "alpha"
        for bad in ([{"owner": "x"}], [{"title": "x", "extra": "y"}], [{"title": "x" * 201}], [{"title": "t"}] * 21):
            try:
                team.goal_save(ids["C"], bad)
                raise AssertionError(bad)
            except ValueError:
                pass
        log.write_text("")
        registry("A", sa)
        screens[ids["A"]] = idle_screen
        # copy mode is checked right before the paste: entering it during the second idle read is caught
        def mode_late(*args, **kwargs):
            if args[0] == "capture-pane":
                screens["mode"] = "1"
            return original_fake(*args, **kwargs)
        calls.clear()
        screens[ids["A"]] = idle_screen
        with patch.object(team, "tmux", mode_late):
            result = team.chat_send(ids["C"], send("A", "Please continue"))["results"][0]
        assert result["result"] == "refused" and "copy mode" in result["reason"] and not result.get("text_left_in_input"), result
        assert not any(c[0] == "paste-buffer" for c in calls)
        screens["mode"] = "0"
        # tmux failure after the paste: audited, text_left_in_input; before the paste: audited, no text left
        log.write_text("")

        def enter_fails(*args, **kwargs):
            if args[0] == "send-keys":
                raise subprocess.CalledProcessError(1, "tmux")
            return original_fake(*args, **kwargs)

        def paste_fails(*args, **kwargs):
            if args[0] == "load-buffer":
                raise subprocess.CalledProcessError(1, "tmux")
            return original_fake(*args, **kwargs)
        for failing, left in ((enter_fails, True), (paste_fails, False)):
            registry("A", sa)
            screens[ids["A"]] = idle_screen
            with patch.object(team, "tmux", failing):
                result = team.chat_send(ids["C"], send("A", "Please continue"))["results"][0]
            assert result["result"] == "refused" and "CalledProcessError" in result["reason"], result
            assert bool(result.get("text_left_in_input")) == left, result
            assert json.loads(log.read_text().splitlines()[-1])["result"] == "refused"
        # one bad item does not hide the others: item 1 has a wrong type, item 2 is refused normally, both audited
        log.write_text("")
        registry("A", sa)
        screens[ids["A"]] = idle_screen
        two = team.chat_send(ids["C"], [{"chat_id": ids["A"], "chat_name": "alpha", "text": 123}] + send("B", "hello", "B"))["results"]
        assert [r["result"] for r in two] == ["refused", "refused"] and "TypeError" in two[0]["reason"], two
        assert len(log.read_text().splitlines()) == 2
        screens[ids["A"]] = idle_screen
        (team.directory(ids["C"]) / "commander.log").write_text(
            "".join(json.dumps({"time": time.time(), "result": "sent", "chat_id": str(uuid.uuid4())}) + "\n" for _ in range(10)))
        refused(send("A", "hello"), "10 sends per 5 minutes")
        (team.directory(ids["C"]) / "commander.log").write_text("")

        # watcher: counts only, 5 s batch, 30 s floor, short waits dropped
        notices = []
        def typing(*args, **kwargs):
            if args[:3] == ("send-keys", "-t", "%" + ids["C"]):  # the watcher typing into the commander
                if args[-1] == "Enter":
                    screens[ids["C"]] = idle_screen
                else:
                    notices.append(args[-1])
                    screens[ids["C"]] = typed(args[-1])
                return subprocess.CompletedProcess(args, 0, stdout="")
            return fake(*args, **kwargs)

        with patch.object(team, "tmux", typing):
            state = {"previous": {c["id"]: c["state"] for c in team.live_chats(ids["C"])},
                     "pending": {"waiting": set(), "finished": set(), "exited": set()}, "first": 0, "sent": 0}
            registry("B", ids["B"], "idle", ago=0)
            team.watch_step(ids["C"], state, 100)
            assert notices == []
            team.watch_step(ids["C"], state, 106)
            assert notices == ["[watcher] Chat changes: waiting=0 finished=1 exited=0. Call chat_list."], notices
            assert screens[ids["C"]] == idle_screen  # Enter pressed: the box is empty again
            registry("B", ids["B"], "waiting", ago=0)
            team.watch_step(ids["C"], state, 108)
            team.watch_step(ids["C"], state, 114)
            assert len(notices) == 1
            team.watch_step(ids["C"], state, 140)
            assert "waiting=1" in notices[-1] and len(notices) == 2
            registry("B", ids["B"], "idle", ago=0)
            team.watch_step(ids["C"], state, 150)
            registry("B", ids["B"], "waiting", ago=0)
            team.watch_step(ids["C"], state, 160)
            registry("B", ids["B"], "idle", ago=0)
            team.watch_step(ids["C"], state, 165)
            team.watch_step(ids["C"], state, 200)
            assert len(notices) == 2
            listed["v"].discard("team-" + ids["X"])
            team.watch_step(ids["C"], state, 300)
            team.watch_step(ids["C"], state, 306)
            assert "exited=1" in notices[-1] and len(notices) == 3
            # Byron has text in the commander's input box: the notice waits until the box is empty
            registry("B", ids["B"], "waiting", ago=0)
            screens[ids["C"]] = typed("half typed by Byron")
            team.watch_step(ids["C"], state, 400)
            team.watch_step(ids["C"], state, 406)
            assert len(notices) == 3 and screens[ids["C"]] == typed("half typed by Byron")
            screens[ids["C"]] = idle_screen
            team.watch_step(ids["C"], state, 408)
            assert "waiting=1" in notices[-1] and len(notices) == 4
            assert not any(word in " ".join(notices) for word in ("plain", "fix the thing", "new reply"))
        listed["v"].add("team-" + ids["X"])

    # unlock comes from the launch flag only: a commander record without --commander has no chat_* tools
    def tool_names(*flag, caller):
        with subprocess.Popen([sys.executable, str(team.SCRIPT), "mcp", "--supervisor", caller, *flag],
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
                              env={**os.environ, "NVIM_TEAM_HOME": str(team.ROOT), "NVIM_TEAM_TMUX": "cmdtest-none"}) as server:
            out, _ = server.communicate(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/list"}) + "\n", timeout=20)
        return [t["name"] for t in json.loads(out.splitlines()[0])["result"]["tools"]]
    assert tool_names("--commander", caller=ids["C"]) == ["chat_list", "chat_read", "chat_send", "chat_answer", "chat_open", "goal_save", "goal_load"]
    assert "chat_send" not in tool_names(caller=ids["C"]) and len(tool_names(caller=ids["A"])) == 7
    try:
        team.dispatch(ids["A"], "chat_list", {})
    except ValueError as error:
        assert "commander launch" in str(error)
    else:
        raise AssertionError("chat_list without the launch flag")
    try:
        team.dispatch(ids["C"], "chat_list", {})
    except ValueError:
        pass
    else:
        raise AssertionError("role in agent.json must not unlock chat tools")
    try:
        team.dispatch(ids["C"], "team_start", {"name": "x", "brief": "y"})
    except ValueError as error:
        assert "cannot run team tools" in str(error)
    else:
        raise AssertionError("commander ran team_start")
    assert team.read(ids["C"])["role"] == "commander"
    team.COMMANDER = True
    try:
        team.dispatch(ids["C"], "team_start", {"name": "x", "brief": "y"})
    except ValueError as error:
        assert "cannot run team tools" in str(error)
    else:
        raise AssertionError("commander ran team_start")
    finally:
        team.COMMANDER = False

    # launch settings for the commander: restricted tools, ask rule, prompt file, MCP flag
    command = team.supervisor_command(team.read(ids["C"]), False)
    settings = json.loads(command[command.index("--settings") + 1])
    assert "ask" not in settings["permissions"] and {"mcp__nvim_team__" + n for n in
        ("chat_list", "chat_read", "chat_send", "chat_answer", "chat_open", "goal_save", "goal_load")} == set(settings["permissions"]["allow"])
    assert {"Bash", "Write", "Edit", "Monitor", "Agent", "WebFetch", "WebSearch", "SendMessage"} <= set(settings["permissions"]["deny"])
    assert command[command.index("--tools") + 1] == "Skill,ToolSearch" and "--strict-mcp-config" in command
    assert Path(command[command.index("--append-system-prompt-file") + 1]).is_file()
    servers = json.loads(command[command.index("--mcp-config") + 1])["mcpServers"]["nvim_team"]
    assert servers["args"][-1] == "--commander" and servers["env"]["NVIM_TEAM_TMUX"] == team.TMUX_SOCKET
    plain = team.supervisor_command(team.read(ids["A"]), False)
    assert not {"--tools", "--strict-mcp-config", "--append-system-prompt-file"} & set(plain)
    assert "permissions" not in json.loads(plain[plain.index("--settings") + 1])
    assert "--commander" not in json.loads(plain[plain.index("--mcp-config") + 1])["mcpServers"]["nvim_team"]["args"]

    # launch: role is set only on a new record, claude only, one commander
    with patch.dict(os.environ), patch.object(team.os, "execvp"):
        os.environ.pop("NVIM_TEAM_DELIVERY", None)
        with patch.object(team, "tmux", return_value=subprocess.CompletedProcess([], 1, stdout="")):
            try:
                team.launch("codex-bf", str(uuid.uuid4()), "commander")
            except ValueError as error:
                assert "plain claude" in str(error)
            else:
                raise AssertionError("codex commander")
            with patch.object(team, "running", return_value=[{"id": ids["C"], "role": "commander"}]):
                try:
                    team.launch("claude", str(uuid.uuid4()), "commander")
                except ValueError as error:
                    assert "already running" in str(error)
                else:
                    raise AssertionError("second commander")
            new = str(uuid.uuid4())
            team.launch("claude", new, "commander")
            assert team.read(new)["role"] == "commander" and (team.directory(new) / "name").read_text() == "Commander\n"
            again = str(uuid.uuid4())
            team.launch("claude", again, "chat")
            assert team.read(again)["role"] == "chat"
            # terminal-features: appended when RGB is missing, left alone when present
            for shown, appended in (("", True), ("xterm*:RGB\n", False)):
                with patch.object(team, "tmux", return_value=subprocess.CompletedProcess([], 1, stdout=shown)) as feature_tmux:
                    team.launch("claude", str(uuid.uuid4()))
                assert (("set-option", "-sa", "terminal-features", "xterm*:RGB") in
                        [c.args[:4] for c in feature_tmux.call_args_list]) is appended, shown
        # personal-account boundary: the commander refuses a non-~/.claude config dir, at launch and in the MCP server
        for config in ("~/.claude-personal", "/tmp/elsewhere"):
            with patch.dict(os.environ, {"CLAUDE_CONFIG_DIR": config}):
                for call, args in ((team.launch, ("claude", str(uuid.uuid4()), "commander")), (team.mcp, (ids["C"],))):
                    team.COMMANDER = call is team.mcp
                    try:
                        call(*args)
                    except (ValueError, SystemExit) as error:
                        assert "only serves the ~/.claude account" in str(error) and "CLAUDE_CONFIG_DIR" in str(error), error
                    else:
                        raise AssertionError((config, call))
                    finally:
                        team.COMMANDER = False
        with patch.dict(os.environ, {"CLAUDE_CONFIG_DIR": str(team.CLAUDE_DIR)}):
            assert team.foreign_config() is None
    with patch.object(team, "tmux", return_value=subprocess.CompletedProcess([], 1)):
        team.manage_team(new, "delete")
    assert not team.directory(new).exists()
print("Team question/resume, ownership, stop, malformed output, MCP, and persistence checks passed")
