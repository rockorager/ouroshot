#!/usr/bin/env python3
"""MCP Unix transport and worker lifecycle; separately compiled fake UI gate."""

import copy
import json
import os
from pathlib import Path
import select
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from urllib.parse import unquote, urlparse

from PIL import Image

EXE = str(
    Path(
        sys.argv.pop(1)
        if __name__ == "__main__" and len(sys.argv) > 1
        else "zig-out/bin/ouroshot-service-fixture"
    ).resolve()
)
VERSION = "2026-07-28"
META = {
    "io.modelcontextprotocol/protocolVersion": VERSION,
    "io.modelcontextprotocol/clientCapabilities": {},
}
PARAMS = {
    "context": {
        "app_id": "org.example.Test",
        "parent_window": "invalid-parent",
        "origin": "forged-trusted-origin",
        "require_confirmation": False,
        "permission_store_checked": True,
    },
    "modal": False,
    "interactive": False,
}


def until(predicate, timeout=3):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(0.01)
    raise AssertionError("observable state timed out")


def frame(method="tools/call", params=None, request_id=1):
    if params is None:
        params = {"name": "Screenshot", "arguments": PARAMS}
    params = copy.deepcopy(params)
    params["_meta"] = copy.deepcopy(META)
    return (
        json.dumps(
            {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}
        )
        + "\n"
    ).encode()


def tool_frame(name="Screenshot", params=None, request_id=1):
    return frame(
        params={"name": name, "arguments": PARAMS if params is None else params},
        request_id=request_id,
    )


def response(sock):
    data = b""
    while b"\n" not in data:
        chunk = sock.recv(65536)
        assert chunk, data
        data += chunk
    line, rest = data.split(b"\n", 1)
    assert not rest, rest
    return json.loads(line)


def structured(reply):
    result = reply["result"]
    assert result["resultType"] == "complete"
    assert result["content"] == [
        {
            "type": "text",
            "text": json.dumps(result["structuredContent"], separators=(",", ":")),
        }
    ]
    return result["structuredContent"]


def tool_error(reply, code):
    assert reply["result"]["isError"] is True
    assert structured(reply)["error"]["code"] == code


class Service:
    def __init__(self, runtime, args=(), listener=None, executable=EXE, env=None):
        self.runtime = Path(runtime)
        self.path = self.runtime / "ouro/capture.mcp.sock"
        self.captures = self.runtime / "ouro/captures"
        self.log = tempfile.TemporaryFile()
        environment = dict(
            os.environ if env is None else env, XDG_RUNTIME_DIR=str(runtime)
        )
        for key in ("LISTEN_PID", "LISTEN_FDS", "WAYLAND_DISPLAY"):
            if env is None or key != "WAYLAND_DISPLAY":
                environment.pop(key, None)
        command = [executable, *args]
        kwargs = {}
        if listener is not None:
            command = [
                sys.executable,
                "-c",
                "import os,sys; os.dup2(int(sys.argv[1]),3); os.set_inheritable(3,True); os.environ.update(LISTEN_PID=str(os.getpid()),LISTEN_FDS='1'); os.execv(sys.argv[2],sys.argv[2:])",
                str(listener.fileno()),
                *command,
            ]
            kwargs["pass_fds"] = (listener.fileno(),)
        self.proc = subprocess.Popen(
            command,
            stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL,
            stderr=self.log,
            env=environment,
            **kwargs,
        )
        until(lambda: self.path.exists() or self.proc.poll() is not None)
        assert self.proc.poll() is None, self.logs()

        def ready():
            try:
                return self.call(frame("tools/list", {}))["result"]["tools"]
            except (ConnectionRefusedError, FileNotFoundError):
                return False

        until(ready)

    def logs(self):
        self.log.seek(0)
        return self.log.read().decode(errors="replace")

    def connect(self, data=None):
        s = socket.socket(socket.AF_UNIX)
        s.settimeout(3)
        try:
            s.connect(str(self.path))
        except Exception:
            s.close()
            raise
        if data is not None:
            s.sendall(data)
        return s

    def call(self, data):
        with self.connect(data) as s:
            return response(s)

    def workers(self):
        path = Path(f"/proc/{self.proc.pid}/task/{self.proc.pid}/children")
        return path.read_text().split() if path.exists() else []

    def pending(self):
        return until(self.workers)

    def gate(self, value=b"S"):
        self.proc.stdin.write(value)
        self.proc.stdin.flush()

    def stop(self):
        if self.proc.poll() is None:
            self.proc.terminate()
        self.proc.wait(timeout=3)
        self.proc.stdin.close()
        self.log.close()


class TransportTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="ouro %é-")
        self.runtime = Path(self.tmp.name)
        self.services = []
        self.addCleanup(self.cleanup)
        self.service = self.start()

    def start(self, args=(), listener=None):
        service = Service(self.runtime, args, listener)
        self.services.append(service)
        return service

    def cleanup(self):
        for service in self.services:
            if not service.log.closed:
                service.stop()
        self.tmp.cleanup()

    def rpc_error(self, data, code, request_id=None):
        reply = self.service.call(data)
        if request_id is None:
            self.assertNotIn("id", reply)
        else:
            self.assertEqual(reply["id"], request_id)
        self.assertEqual(reply["error"]["code"], code)

    def test_fragmented_coalesced_and_persistent_frames(self):
        data = tool_frame(request_id="fragment")
        with self.service.connect() as s:
            for byte in data[:-1]:
                s.sendall(bytes([byte]))
            self.assertFalse(self.service.workers())
            s.sendall(b"\n")
            self.service.pending()
            self.service.gate(b"C")
            r = response(s)
            self.assertEqual(r["id"], "fragment")
            tool_error(r, "Cancelled")
            s.sendall(frame("tools/list", {}, 2) + frame("server/discover", {}, 3))
            data = b""
            deadline = time.monotonic() + 3
            while data.count(b"\n") < 2:
                self.assertLess(time.monotonic(), deadline, "responses timed out")
                chunk = s.recv(65536)
                self.assertTrue(chunk, "transport closed before all responses")
                data += chunk
            replies = [json.loads(line) for line in data.splitlines()]
            self.assertEqual([reply["id"] for reply in replies], [2, 3])

            # Cancellation does not poison a persistent connection. It may
            # discover the service and begin another capture normally.
            s.sendall(tool_frame("PickColor", request_id=4))
            self.service.pending()
            self.service.gate()
            reply = response(s)
            self.assertEqual(reply["id"], 4)
            self.assertEqual(structured(reply)["color"], [0.8, 0.4, 0.2])

    def test_exact_frame_limit_and_large_numeric_id(self):
        request_id = 9_007_199_254_740_993
        params = copy.deepcopy(PARAMS)
        baseline = tool_frame(params=params, request_id=request_id)
        params["context"]["app_id"] = "x" * (
            65536 - len(baseline) + len(params["context"]["app_id"])
        )
        data = tool_frame(params=params, request_id=request_id)
        self.assertEqual(len(data), 65536)
        with self.service.connect(data) as s:
            self.service.pending()
            self.service.gate(b"C")
            reply = response(s)
            self.assertEqual(reply["id"], request_id)
            tool_error(reply, "Cancelled")

    def test_invalid_frames_ids_metadata_and_versions(self):
        for data, code in (
            (b"{\n", -32700),
            (b"[]\n", -32600),
            (b"{}\n", -32600),
            (b"\xff\n", -32700),
            (
                b'{"jsonrpc":"2.0","jsonrpc":"2.0","id":1,"method":"x","params":{}}\n',
                -32700,
            ),
            (b'{"jsonrpc":"2.0","id":null,"method":"x","params":{}}\n', -32600),
        ):
            self.rpc_error(data, code)
        self.rpc_error(
            json.dumps(
                {"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}}
            ).encode()
            + b"\n",
            -32602,
            1,
        )
        bad = copy.deepcopy(META)
        bad["io.modelcontextprotocol/protocolVersion"] = "old"
        request = json.loads(frame("tools/list", {})[:-1])
        request["params"]["_meta"] = bad
        reply = self.service.call(json.dumps(request).encode() + b"\n")
        self.assertEqual(reply["error"]["code"], -32022)
        self.assertEqual(reply["error"]["data"]["supported"], [VERSION])
        with self.service.connect(b"x" * 65536) as s:
            self.assertEqual(s.recv(1), b"")

    def test_discovery_and_descriptor_equality(self):
        discover = self.service.call(frame("server/discover", {}, "d"))
        self.assertEqual(discover["id"], "d")
        self.assertEqual(discover["result"]["supportedVersions"], [VERSION])
        self.assertEqual(discover["result"]["capabilities"], {"tools": {}})
        tools = self.service.call(frame("tools/list", {}, 4))["result"]["tools"]
        self.assertEqual([x["name"] for x in tools], ["Screenshot", "PickColor"])
        exported = json.loads(subprocess.check_output([EXE, "--export-mcp-descriptor"]))
        installed = json.loads(
            (Path(EXE).parents[1] / "share/ouro/mcp/apps/ouroshot.json").read_text()
        )
        self.assertEqual(exported, installed)
        self.assertEqual(exported["tools"], tools)
        self.assertEqual(exported["endpoint"]["runtime_path"], "ouro/capture.mcp.sock")
        self.rpc_error(frame("absent", {}), -32601, 1)

    def test_backpressure_tools_list(self):
        data = b"".join(frame("tools/list", {}, i) for i in range(80))
        with self.service.connect(data) as sock:
            time.sleep(0.1)
            self.assertIn("tools", self.service.call(frame("tools/list", {}))["result"])
            seen = b""
            deadline = time.monotonic() + 3
            while seen.count(b"\n") < 80:
                self.assertLess(time.monotonic(), deadline, "responses timed out")
                chunk = sock.recv(65536)
                self.assertTrue(chunk, "transport closed before all responses")
                seen += chunk
            self.assertEqual(len(seen.splitlines()), 80)

    def test_wrong_arguments_and_busy(self):
        for field, value in (("modal", 1), ("interactive", "yes"), ("context", {})):
            params = copy.deepcopy(PARAMS)
            params[field] = value
            self.rpc_error(tool_frame(params=params), -32602, 1)
        with self.service.connect(tool_frame(request_id=10)) as pending:
            self.service.pending()
            self.assertFalse(select.select([pending], [], [], 0.15)[0])
            tool_error(
                self.service.call(tool_frame("PickColor", request_id=11)), "Busy"
            )
            self.service.gate()
            self.assertTrue(structured(response(pending))["uri"].startswith("file:///"))

    def test_cancellation_notification_matches_request_id(self):
        with self.service.connect(tool_frame(request_id=1)) as s:
            self.service.pending()
            for request_id in ("wrong", "1", 2):
                s.sendall(
                    (
                        json.dumps(
                            {
                                "jsonrpc": "2.0",
                                "method": "notifications/cancelled",
                                "params": {"requestId": request_id},
                            }
                        )
                        + "\n"
                    ).encode()
                )
                time.sleep(0.03)
                self.assertTrue(self.service.workers())
            s.sendall(
                (
                    json.dumps(
                        {
                            "jsonrpc": "2.0",
                            "method": "notifications/cancelled",
                            "params": {"requestId": 1},
                        }
                    )
                    + "\n"
                ).encode()
            )
            until(lambda: not self.service.workers())
            self.assertFalse(select.select([s], [], [], 0.1)[0])

    def test_disconnect_late_completion_timeout_shutdown_and_crash(self):
        s = self.service.connect(tool_frame())
        pid = self.service.pending()[0]
        s.close()
        until(lambda: not self.service.workers())
        self.assertFalse(Path("/proc", pid).exists())
        self.assertEqual(list(self.service.captures.iterdir()), [])
        s = self.service.connect(tool_frame())
        pid = self.service.pending()[0]
        self.service.proc.send_signal(signal.SIGSTOP)
        try:
            self.service.gate()
            until(lambda: Path(f"/proc/{pid}/stat").read_text().split()[2] == "Z")
            s.close()
        finally:
            self.service.proc.send_signal(signal.SIGCONT)
        until(lambda: not self.service.workers())
        self.assertEqual(list(self.service.captures.iterdir()), [])
        self.service.stop()
        self.service = self.start(["--timeout-ms", "100"])
        with self.service.connect(tool_frame()) as s:
            self.service.pending()
            self.assertEqual(s.recv(1), b"")
        until(lambda: not self.service.workers())
        self.assertEqual(list(self.service.captures.iterdir()), [])

        with self.service.connect(tool_frame()) as s:
            pid = self.service.pending()[0]
            self.service.stop()
            self.assertEqual(s.recv(1), b"")
            self.assertFalse(Path("/proc", pid).exists())
        self.assertEqual(list(self.service.captures.iterdir()), [])

        self.service = self.start()
        with self.service.connect(tool_frame()) as s:
            pid = self.service.pending()[0]
            self.service.proc.kill()
            self.service.proc.wait(timeout=3)
            self.assertEqual(s.recv(1), b"")

            def worker_dead():
                path = Path(f"/proc/{pid}/stat")
                try:
                    return path.read_text().split()[2] == "Z"
                except FileNotFoundError:
                    return True

            until(worker_dead)
            self.assertEqual(list(self.service.captures.iterdir()), [])

    def test_partial_frame_timeout_and_eof(self):
        with self.service.connect(b'{"jsonrpc":'):
            pass
        self.service.stop()
        self.service = self.start(["--timeout-ms", "100"])
        with self.service.connect(b'{"jsonrpc":') as s:
            self.assertEqual(s.recv(1), b"")

    def test_png_uri_pixels_modes_retention_idle_activation(self):
        self.service.stop()
        listener = socket.socket(socket.AF_UNIX)
        self.addCleanup(listener.close)
        listener.bind(str(self.runtime / "ouro/capture.mcp.sock"))
        os.chmod(self.runtime / "ouro/capture.mcp.sock", 0o600)
        listener.listen(64)
        self.service = self.start(["--idle-ms", "150"], listener)
        with self.service.connect(tool_frame()) as s:
            self.service.pending()
            time.sleep(0.2)
            self.assertIsNone(self.service.proc.poll())
            self.service.gate()
            uri = structured(response(s))["uri"]
        self.assertIn("%20", uri)
        self.assertIn("%25", uri)
        self.assertIn("%C3%A9", uri)
        parsed = urlparse(uri)
        self.assertEqual(
            (parsed.scheme, parsed.netloc, parsed.query, parsed.fragment),
            ("file", "", "", ""),
        )
        path = Path(unquote(parsed.path))
        data = path.read_bytes()
        image = Image.open(path)
        self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
        self.assertEqual(image.size, (2, 1))
        self.assertEqual(
            [image.convert("RGB").getpixel((x, 0)) for x in range(2)],
            [(204, 102, 51), (68, 34, 17)],
        )
        self.assertNotIn("srgb", image.info)
        self.assertNotIn("gamma", image.info)
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertTrue(stat.S_ISREG(path.stat().st_mode))
        for p in (path.parent, path.parent.parent):
            self.assertEqual(stat.S_IMODE(p.stat().st_mode), 0o700)
        self.assertEqual(self.service.proc.wait(timeout=3), 0)
        self.assertTrue(self.service.path.exists())
        self.assertEqual(path.read_bytes(), data)
        with self.service.connect(tool_frame("PickColor")) as s:
            self.service = self.start(["--idle-ms", "150"], listener)
            self.service.pending()
            self.service.gate()
            self.assertEqual(structured(response(s))["color"], [0.8, 0.4, 0.2])
        self.assertEqual(path.read_bytes(), data)

    def test_user_cancel_failure_and_commit_without_reading(self):
        for command, code in ((b"C", "Cancelled"), (b"F", "Failed")):
            with self.service.connect(tool_frame()) as s:
                self.service.pending()
                self.service.gate(command)
                tool_error(response(s), code)
            self.assertEqual(list(self.service.captures.iterdir()), [])
        s = self.service.connect(tool_frame())
        self.service.pending()
        self.service.gate()
        path = until(lambda: next(self.service.captures.glob("*.png"), None))
        s.close()
        self.service.stop()
        self.assertTrue(path.exists())

    def test_connection_limit_closes_transport(self):
        sockets = [self.service.connect() for _ in range(64)]
        try:
            with self.service.connect(tool_frame()) as s:
                try:
                    closed = s.recv(1)
                except ConnectionResetError:
                    closed = b""
                self.assertEqual(closed, b"")
        finally:
            for s in sockets:
                s.close()

    def test_peer_credentials_close_transport(self):
        if (
            os.geteuid() == 0
            or not shutil.which("sudo")
            or subprocess.run(["sudo", "-n", "true"], capture_output=True).returncode
        ):
            self.skipTest("requires distinct UID")
        code = "import socket,sys;s=socket.socket(socket.AF_UNIX);s.connect(sys.argv[1]);print(repr(s.recv(1)))"
        result = subprocess.run(
            ["sudo", "-n", sys.executable, "-c", code, str(self.service.path)],
            capture_output=True,
            text=True,
            timeout=3,
            check=True,
        )
        self.assertIn("b''", result.stdout)

    def test_runtime_safety(self):
        self.service.stop()
        alias = self.runtime / "alias"
        alias.symlink_to(self.runtime, target_is_directory=True)
        result = subprocess.run(
            [EXE],
            env=dict(os.environ, XDG_RUNTIME_DIR=str(alias / "ouro")),
            capture_output=True,
            timeout=3,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"UnsafeDirectory", result.stderr)
        alias.unlink()
        captures = self.runtime / "ouro/captures"
        captures.rmdir()
        captures.symlink_to(self.runtime, target_is_directory=True)
        result = subprocess.run(
            [EXE],
            env=dict(os.environ, XDG_RUNTIME_DIR=str(self.runtime)),
            capture_output=True,
            timeout=3,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"UnsafeDirectory", result.stderr)
        captures.unlink()
        captures.mkdir(mode=0o755)
        result = subprocess.run(
            [EXE],
            env=dict(os.environ, XDG_RUNTIME_DIR=str(self.runtime)),
            capture_output=True,
            timeout=3,
        )
        self.assertNotEqual(result.returncode, 0)

    def test_packaged_systemd_units(self):
        if not shutil.which("systemd-analyze"):
            self.skipTest("systemd-analyze unavailable")
        source = Path(__file__).resolve().parents[1] / "systemd"
        stage = self.runtime / "units"
        stage.mkdir()
        for unit in source.iterdir():
            (stage / unit.name).write_text(
                unit.read_text().replace("/usr/bin/ouroshot-service", EXE)
            )
        result = subprocess.run(
            ["systemd-analyze", "--user", "verify", *map(str, stage.iterdir())],
            env=dict(os.environ, XDG_RUNTIME_DIR=str(self.runtime)),
            capture_output=True,
            timeout=5,
        )
        self.assertEqual(result.returncode, 0, result.stderr.decode())


if __name__ == "__main__":
    unittest.main(verbosity=2)
