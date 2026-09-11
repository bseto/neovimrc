#!/usr/bin/env python3
"""Isolated probes for Claude inbox and Codex app-server report delivery."""

import argparse
import json
import os
from pathlib import Path
import shlex
import signal
import socket
import subprocess
import tempfile
import time
import uuid
import urllib.request


def capture(path):
    payload = json.load(__import__("sys").stdin)
    endpoint = os.environ.get("CLAUDE_CODE_MESSAGING_SOCKET")
    token = os.environ.get("CLAUDE_CODE_MESSAGING_TOKEN")
    if not endpoint:
        raise RuntimeError("Claude did not export a messaging socket")
    value = {"session_id": payload.get("session_id"), "socket": endpoint, "token": token}
    temporary = path.with_name(path.name + "." + str(uuid.uuid4()))
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as file:
        json.dump(value, file)
        file.write("\n")
    temporary.replace(path)


def claude_send(path, message):
    endpoint = json.loads(path.read_text())
    address = endpoint["socket"].removeprefix("uds:")
    lines = []
    if endpoint.get("token"):
        lines.append({"type": "auth", "token": endpoint["token"]})
    lines.append({"type": "user", "message": {"role": "user", "content": message}})
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(3)
        connection.connect(address)
        connection.sendall(b"".join(json.dumps(line).encode() + b"\n" for line in lines))
    print(json.dumps({"socket_write": "complete", "session_id": endpoint.get("session_id"),
                      "acceptance": "unconfirmed", "model_processed": "unconfirmed"}))


def codex_probe(model):
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    url = "ws://127.0.0.1:" + str(port)
    javascript = r'''
const url = process.env.NVIM_PROBE_URL;
const cwd = process.env.NVIM_PROBE_CWD;
const model = process.env.NVIM_PROBE_MODEL;
async function client(name) {
  const ws = new WebSocket(url), pending = new Map(), events = [];
  let next = 1;
  await new Promise((resolve, reject) => { ws.onopen = resolve; ws.onerror = reject; });
  ws.onmessage = ({data}) => {
    const value = JSON.parse(data);
    if (value.id && pending.has(value.id)) {
      const [resolve, reject] = pending.get(value.id); pending.delete(value.id);
      value.error ? reject(Error(JSON.stringify(value.error))) : resolve(value.result);
    } else events.push(value);
  };
  const request = (method, params) => new Promise((resolve, reject) => {
    const id = next++; pending.set(id, [resolve, reject]);
    ws.send(JSON.stringify({method, id, params}));
  });
  await request("initialize", {clientInfo:{name, title:name, version:"0.1"}});
  ws.send(JSON.stringify({method:"initialized", params:{}}));
  return {ws, request, events};
}
const waitFor = (client, match, timeout=120000) => new Promise((resolve, reject) => {
  const started = Date.now();
  const timer = setInterval(() => {
    const value = client.events.find(match);
    if (value) { clearInterval(timer); resolve(value); }
    else if (Date.now() - started >= timeout) { clearInterval(timer); reject(Error("notification timeout")); }
  }, 20);
});
const observer = await client("nvim_delivery_observer");
const started = await observer.request("thread/start", {cwd, model, modelProvider:"bifrost", ephemeral:false});
const threadId = started.thread.id;
const seeded = await observer.request("turn/start", {threadId, input:[{
  type:"text", text:"Harmless isolated delivery probe setup. Reply READY."
}]});
await waitFor(observer, v => v.method === "turn/completed" && v.params.turn.id === seeded.turn.id);
const sender = await client("nvim_delivery_sender");
const resumed = await sender.request("thread/resume", {threadId});
const eventId = "probe:" + crypto.randomUUID();
const accepted = await sender.request("turn/start", {threadId, input:[], toolOutput:{
  name:"worker_report", namespace:"nvim_team", output:JSON.stringify({
    event_id:eventId, kind:"result", message:"Harmless isolated delivery probe. Reply PROBE_OK."
  })
}});
const turnId = accepted.turn.id;
const completed = await waitFor(sender, v => v.method === "turn/completed" && v.params.turn.id === turnId);
const observerCompleted = await waitFor(observer, v => v.method === "turn/completed" && v.params.turn.id === turnId, 5000).then(() => true, () => false);
const readback = await sender.request("thread/read", {threadId, includeTurns:true});
const result = {thread_id:threadId, same_thread:resumed.thread.id === threadId,
  turn_accepted:turnId, turn_status:completed.params.turn.status,
  observer_saw_completed_turn:observerCompleted,
  event_id_in_readback:JSON.stringify(readback).includes(eventId)};
if (!result.same_thread || result.turn_status !== "completed" ||
    !result.observer_saw_completed_turn || !result.event_id_in_readback) throw Error(JSON.stringify(result));
console.log(JSON.stringify(result, null, 2));
observer.ws.close(); sender.ws.close();
'''
    with tempfile.TemporaryDirectory(prefix="codex-delivery-probe-") as temporary:
        probe_workspace = Path(temporary) / "workspace"
        probe_workspace.mkdir()
        server_log_path = Path(temporary) / "server.log"
        args = ["codex-bf", "app-server", "--listen", url,
                "-c", 'model_provider="bifrost"', "-c", "model=" + json.dumps(model),
                "-c", 'sandbox_mode="workspace-write"', "-c", 'approval_policy="on-request"',
                "-c", 'approvals_reviewer="auto_review"']
        server = None
        with server_log_path.open("w+") as server_log:
            try:
                server = subprocess.Popen(["zsh", "-lic", shlex.join(args)], stdout=subprocess.DEVNULL,
                                          stderr=server_log, text=True, start_new_session=True)
                deadline = time.monotonic() + 15
                while server.poll() is None and time.monotonic() < deadline:
                    try:
                        if urllib.request.urlopen("http://127.0.0.1:" + str(port) + "/readyz", timeout=.2).status == 200:
                            break
                    except Exception:
                        time.sleep(.05)
                else:
                    raise RuntimeError("Codex app-server did not become ready")
                environment = os.environ.copy()
                environment.update(NVIM_PROBE_URL=url, NVIM_PROBE_CWD=str(probe_workspace), NVIM_PROBE_MODEL=model)
                completed = subprocess.run(["node", "--input-type=module", "-e", javascript],
                                           env=environment, text=True, capture_output=True, timeout=180)
                if completed.returncode:
                    raise RuntimeError(completed.stderr or completed.stdout)
                print(completed.stdout, end="")
            except Exception as error:
                server_log.flush()
                server_log.seek(0)
                raise RuntimeError(str(error) + "\napp-server: " + server_log.read()[-2000:]) from error
            finally:
                if server and server.poll() is None:
                    os.killpg(server.pid, signal.SIGTERM)
                    try:
                        server.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        os.killpg(server.pid, signal.SIGKILL)
                        server.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    capture_parser = commands.add_parser("claude-capture")
    capture_parser.add_argument("--out", type=Path, required=True)
    send_parser = commands.add_parser("claude-send")
    send_parser.add_argument("--endpoint", type=Path, required=True)
    send_parser.add_argument("--message", required=True)
    codex_parser = commands.add_parser("codex")
    codex_parser.add_argument("--model", default="gpt-5.6-terra")
    args = parser.parse_args()
    if args.command == "claude-capture":
        capture(args.out)
    elif args.command == "claude-send":
        claude_send(args.endpoint, args.message)
    else:
        codex_probe(args.model)


if __name__ == "__main__":
    main()
