#!/usr/bin/env python3
"""Exercise the staged DSH runtime over the same private socket RPC used by iOS."""
import json
from pathlib import Path
import shutil
import socket
import struct
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = ROOT / "ios" / "Sources" / "Resources" / "DSHRuntime"
ENTRY = RUNTIME / "ios-supervisor.mjs"


class Peer:
    def __init__(self, connection):
        self.connection = connection
        self.connection.settimeout(30)
        self.buffer = bytearray()
        self.next_id = 1
        self.credentials = []

    def send(self, message):
        payload = json.dumps(message, separators=(",", ":")).encode("utf-8")
        self.connection.sendall(struct.pack(">I", len(payload)) + payload)

    def receive(self):
        while len(self.buffer) < 4 or len(self.buffer) < 4 + struct.unpack(">I", self.buffer[:4])[0]:
            chunk = self.connection.recv(65_536)
            if not chunk:
                raise EOFError("Embedded Node process closed the IPC socket")
            self.buffer.extend(chunk)
        length = struct.unpack(">I", self.buffer[:4])[0]
        message = json.loads(bytes(self.buffer[4:4 + length]))
        del self.buffer[:4 + length]
        return message

    def answer_runtime(self, message):
        method = message.get("method")
        if method == "runtime.ready":
            self.send({"jsonrpc": "2.0", "id": message["id"], "result": {"accepted": True}})
        elif method == "credential.resolve":
            self.credentials.append(message.get("params", {}).get("apiBaseURL"))
            self.send({"jsonrpc": "2.0", "id": message["id"], "result": {"value": ""}})
        elif method == "credential.describe":
            self.send({"jsonrpc": "2.0", "id": message["id"], "result": {"configured": False}})
        elif method == "runtime.failed":
            raise RuntimeError(message.get("params", {}).get("message", "DSH runtime failed"))
        elif message.get("id") is not None:
            self.send({
                "jsonrpc": "2.0", "id": message["id"],
                "error": {"code": -32601, "message": f"Unexpected runtime request: {method}"},
            })

    def start(self):
        message = self.receive()
        if message.get("method") != "runtime.ready":
            raise RuntimeError(f"Expected runtime.ready, received {message}")
        self.answer_runtime(message)

    def request(self, method, params=None):
        request_id = self.next_id
        self.next_id += 1
        self.send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params or {}})
        while True:
            message = self.receive()
            if message.get("id") == request_id:
                if "error" in message:
                    raise RuntimeError(message["error"].get("message", "DSH RPC failed"))
                return message.get("result")
            self.answer_runtime(message)

    def wait_for_chat_done(self):
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            message = self.receive()
            if message.get("method") == "chat.done":
                return message.get("params", {})
            self.answer_runtime(message)
        raise TimeoutError("DSH did not settle the chat turn")


def start_runtime(node, workspace, database):
    parent, child = socket.socketpair()
    command = [
        node, "--no-warnings", "--expose-internals", str(ENTRY), f"--ipc-fd={child.fileno()}",
        f"--workspace={workspace}", f"--database={database}",
        "--api-base=https://api.deepseek.com",
    ]
    process = subprocess.Popen(
        command, cwd=RUNTIME, pass_fds=(child.fileno(),), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    child.close()
    return Peer(parent), process


def stop_runtime(peer, process):
    peer.connection.close()
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
    if process.returncode not in (0, -15):
        error = process.stderr.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Embedded Node exited with {process.returncode}: {error[-4_000:]}")


def plugin_fixture(workspace, name, module):
    path = workspace / "plugin-imports" / name
    path.mkdir(parents=True)
    (path / "package.json").write_text(json.dumps({
        "name": name, "version": "1.0.0", "type": "module",
        "dsh": {"bundle": {"patch": "./cordis.patch.yml", "platforms": ["ios"]}},
    }))
    (path / "cordis.patch.yml").write_text(
        f"- insert:\n    - id: {name}\n      name: ./{name}.mjs\n"
    )
    (path / f"{name}.mjs").write_text(module)
    return {"path": str(path)}


def check_plugin_restart(peer, workspace):
    good = "dsbot-smoke-good"
    bad = "dsbot-smoke-bad"
    for name, module, rollback in (
        (good, "export default { apply() {} }", False),
        (bad, "export default { apply() { throw new Error('fixture failure') } }", True),
    ):
        staged = peer.request("plugins.install.local", plugin_fixture(workspace, name, module))
        if not staged.get("restartRequired"):
            raise AssertionError(f"Plugin was not staged: {staged}")
        restarted = peer.request("runtime.restart")
        if restarted.get("rolledBack") != rollback or restarted.get("safeMode"):
            raise AssertionError(f"Unexpected plugin restart result: {restarted}")
        bundles = peer.request("agent.info")["profile"]["bundles"]
        if good not in bundles or bad in bundles:
            raise AssertionError(f"Incorrect effective profile: {bundles}")
    peer.request("plugins.remove", {"name": good})
    peer.request("runtime.restart")
    if good in peer.request("agent.info")["profile"]["bundles"]:
        raise AssertionError("Removed plugin is still active")


def check_preparation_abort(peer, workspace):
    name = "dsbot-pending-turn-fixture"
    plugin = """
import { access, writeFile } from 'node:fs/promises'
import { setTimeout as delay } from 'node:timers/promises'
export default {
  inject: ['sessionPersistence'],
  apply(ctx) {
    const store = ctx.sessionPersistence
    const original = store.stat.bind(store)
    store.stat = async (id) => {
      if (id === 'ios:preparation') {
        await writeFile('preparation-entered', '')
        for (let retry = 0; retry < 500; retry++) {
          if (await access('preparation-release').then(() => true, () => false)) break
          await delay(10)
        }
      }
      return original(id)
    }
  }
}
"""
    peer.request("plugins.install.local", plugin_fixture(workspace, name, plugin))
    peer.request("runtime.restart")
    request_id = peer.next_id
    peer.next_id += 1
    peer.send({"jsonrpc": "2.0", "id": request_id, "method": "chat.send", "params": {
        "sessionId": "preparation", "turnId": "preparing-turn", "model": "deepseek-flash",
        "apiBaseURL": "https://api.deepseek.com", "text": "must never be sent",
    }})
    deadline = time.monotonic() + 5
    while not (workspace / "preparation-entered").exists():
        if time.monotonic() > deadline:
            raise AssertionError("The agent never entered the delayed preparation phase")
        time.sleep(0.01)
    try:
        result = peer.request("chat.abort", {"turnId": "preparing-turn"})
        assert result.get("aborted") is True, result
    finally:
        (workspace / "preparation-release").touch()
    event = peer.wait_for_chat_done()
    assert event["turnId"] == "preparing-turn" and event["status"] == "aborted", event
    state = peer.request("session.history", {"sessionId": "preparation"})
    assert not state.get("messages"), state
    peer.request("plugins.remove", {"name": name})
    peer.request("runtime.restart")


def main():
    node = shutil.which("node")
    if not node or not ENTRY.is_file():
        raise SystemExit("Stage DSHRuntime and install Node.js before running the runtime smoke probe")
    node_version = subprocess.check_output([node, "--version"], text=True).strip()
    if node_version != "v24.22.1":
        raise SystemExit(f"Expected host Node v24.22.1 for the pinned smoke environment; found {node_version}")

    with tempfile.TemporaryDirectory(prefix="dsbot-dsh-smoke-") as temporary:
        workspace = Path(temporary) / "dsh-home"
        workspace.mkdir()
        database = workspace / "sessions.sqlite"
        peer, process = start_runtime(node, workspace, database)
        try:
            peer.start()
            info = peer.request("agent.info")
            if (info.get("engine"), info.get("dshVersion"), info.get("nodeVersion")) != (
                "node+dsh", "0.2.2-rc.5", "24.22.1",
            ):
                raise AssertionError(f"Unexpected runtime identity: {info}")
            plugins = set(info.get("plugins", []))
            if not {"dsh-agent", "dsh-agent-loop", "dsh-session", "dsh-llm",
                    "dsbot-ios-sqlite-session-persistence"}.issubset(plugins):
                raise AssertionError(f"The runtime did not mount the required DSH core: {sorted(plugins)}")

            for index, api_base in enumerate(("https://api.deepseek.com", "https://gateway.example/v1")):
                turn_id = f"smoke-{index}"
                result = peer.request("chat.send", {
                    "sessionId": "smoke", "turnId": turn_id,
                    "model": "deepseek-flash" if index == 0 else "deepseek-flash-thinking",
                    "apiBaseURL": api_base, "systemPrompt": "", "text": f"Durable DSH turn {index}",
                    "legacyHistory": [], "customTools": False, "isGroup": False,
                })
                if result.get("engine") != "node+dsh" or result.get("status") != "accepted":
                    raise AssertionError(f"DSH rejected the smoke turn: {result}")
                done = peer.wait_for_chat_done()
                if done.get("status") != "error" or "no API key" not in done.get("error", ""):
                    raise AssertionError(f"Expected a surfaced missing-key error, got {done}")

            if "https://api.deepseek.com" not in peer.credentials or "https://gateway.example/v1" not in peer.credentials:
                raise AssertionError(f"Keychain bridge did not follow the selected endpoint: {peer.credentials}")
            check_plugin_restart(peer, workspace)
            check_preparation_abort(peer, workspace)
            peer.request("agent.suspend")
            before = peer.request("session.history", {"sessionId": "smoke"})
            contents = [item["content"] for item in before.get("messages", [])]
            if contents != ["Durable DSH turn 0", "Durable DSH turn 1"]:
                raise AssertionError(f"Unexpected SQLite session history: {contents}")
        finally:
            stop_runtime(peer, process)

        # A second Node process must reconstruct the same upstream DSH session.
        peer, process = start_runtime(node, workspace, database)
        try:
            peer.start()
            recovered = peer.request("session.history", {"sessionId": "smoke"})
            contents = [item["content"] for item in recovered.get("messages", [])]
            if contents != ["Durable DSH turn 0", "Durable DSH turn 1"]:
                raise AssertionError(f"DSH session did not survive runtime restart: {contents}")
            print("DSH 0.2.2-rc.5 runtime, IPC, credential bridge, endpoint update, plugin restart, rollback, preparation abort, and SQLite recovery passed")
        finally:
            stop_runtime(peer, process)


if __name__ == "__main__":
    main()
