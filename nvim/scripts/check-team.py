#!/usr/bin/env python3
"""Exercise durable worker question/resume/stop and MCP transport without model calls."""
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
    plain_chat = str(uuid.uuid4())
    team.save({"id": plain_chat, "role": "chat", "backend": "claude", "cwd": str(root), "created": time.time()})
    team.manage_team(plain_chat, "archive")
    assert team.read(plain_chat)["archived"]
    team.manage_team(plain_chat, "restore")
    assert not team.read(plain_chat)["archived"]
    # Exercise the CLI used by Neovim, including its subcommand dispatch.
    archived = subprocess.run([sys.executable, str(team.SCRIPT), "manage", "archive", "--agent", worker["id"]],
                              text=True, capture_output=True, check=True)
    assert json.loads(archived.stdout)["archived"]
    assert team.read(supervisor)["archived"]
    assert team.read(worker["id"])["session_id"] == "test-session"
    restored = subprocess.run([sys.executable, str(team.SCRIPT), "manage", "restore", "--agent", supervisor],
                              text=True, capture_output=True, check=True)
    assert not json.loads(restored.stdout)["archived"]
    assert not team.read(supervisor)["archived"]
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
    rejected(supervisor, "worker_start", {"kind": "planner", "backend": "claude-bf", "name": "Wrong route", "task": "Plan", "owner_token": token})
    planner = team.dispatch(supervisor, "worker_start", {
        "kind": "planner", "name": "Plan color", "task": "Research color and ask about missing decisions.", "owner_token": token})
    assert planner["backend"] == "claude" and planner["model"] == "opus"
    assert "task" not in planner and "assignment" not in planner, "mutations must return summaries"
    assert "--mcp-config" in shlex.split(team.worker_command({**planner, "mcp_config": "{}"}, root / "out.json")[2])
    planner_args = shlex.split(team.worker_command(planner, root / "out.json")[2])
    assert planner_args[0] == "claude" and planner_args[planner_args.index("--model") + 1] == "opus"
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
    rejected(supervisor, "worker_start", {"kind": "executor", "backend": "claude", "name": "Wrong executor", "task": "Work", "owner_token": token})
    rejected(supervisor, "worker_start", {"kind": "executor", "name": "Codex servers", "task": "Work", "mcp_config": "{}", "owner_token": token})
    active_worker = team.dispatch(supervisor, "worker_start", {
        "kind": "executor", "name": "Running during takeover", "task": "STOP_TEST", "owner_token": token})
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
    reset = team.dispatch(successor, "team_takeover", {"team_id": supervisor, "session_id": reset_session})
    assert reset["owner_token"] != successor_token
    assert team.read(successor)["session_id"] == reset_session
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
        with patch.object(team, "tmux", return_value=subprocess.CompletedProcess([], 1)), \
                patch.object(team.os, "execvp"):
            for backend, expected in (("claude", "events"), ("claude-bf", "events"), ("codex-bf", "poll")):
                chat_id = str(uuid.uuid4())
                team.launch(backend, chat_id)
                assert team.read(chat_id)["delivery"] == expected
            os.environ["NVIM_TEAM_DELIVERY"] = "poll"
            chat_id = str(uuid.uuid4())
            team.launch("claude", chat_id)
            assert team.read(chat_id)["delivery"] == "poll"
        os.environ.pop("NVIM_TEAM_DELIVERY")
        with patch.object(team, "tmux", return_value=subprocess.CompletedProcess([], 0)), \
                patch.object(team.os, "execvp"):
            team.launch("claude", chat_id)
            assert team.read(chat_id)["delivery"] == "poll"
print("Team question/resume, ownership, stop, malformed output, MCP, and persistence checks passed")
