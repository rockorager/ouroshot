#!/usr/bin/env python3
"""Real Unix transport and worker lifecycle; separately compiled fake UI gate.

zig build -Dservice-test-fixture=true
python3 test/service.py [zig-out/bin/ouroshot-service-fixture]
No compositor or desktop session is used by these deterministic tests.
"""
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

EXE = str(Path(sys.argv.pop(1) if __name__ == "__main__" and len(sys.argv) > 1 else "zig-out/bin/ouroshot-service-fixture").resolve())
IFACE = "dev.rockorager.ouro.Capture"
PARAMS = {"context": {"app_id": "org.example.Test", "parent_window": "invalid-parent", "origin": "forged-trusted-origin", "require_confirmation": False, "permission_store_checked": True}, "modal": False, "interactive": False}


def until(predicate, timeout=3):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(.01)
    raise AssertionError("observable state timed out")


def frame(method="Screenshot", params=None):
    return json.dumps({"method": IFACE + "." + method, "parameters": PARAMS if params is None else params}).encode() + b"\0"


def response(sock):
    data = b""
    while b"\0" not in data:
        chunk = sock.recv(65536)
        assert chunk, data
        data += chunk
    assert data.endswith(b"\0") and data.count(b"\0") == 1, data
    return json.loads(data[:-1])


class Service:
    def __init__(self, runtime, args=(), listener=None, executable=EXE, env=None):
        self.runtime = Path(runtime)
        self.path = self.runtime / "ouro/capture.sock"
        self.captures = self.runtime / "ouro/captures"
        self.log = tempfile.TemporaryFile()
        environment = dict(os.environ if env is None else env, XDG_RUNTIME_DIR=str(runtime))
        for key in ("LISTEN_PID", "LISTEN_FDS", "WAYLAND_DISPLAY"):
            if env is None or key != "WAYLAND_DISPLAY":
                environment.pop(key, None)
        command = [executable, *args]
        kwargs = {}
        if listener is not None:
            # Like systemd: preserve the listening fd across exec with this PID.
            command = [sys.executable, "-c", "import os,sys; os.dup2(int(sys.argv[1]),3); os.set_inheritable(3,True); os.environ.update(LISTEN_PID=str(os.getpid()),LISTEN_FDS='1'); os.execv(sys.argv[2],sys.argv[2:])", str(listener.fileno()), *command]
            kwargs["pass_fds"] = (listener.fileno(),)
        self.proc = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=self.log, env=environment, **kwargs)
        until(lambda: self.path.exists() or self.proc.poll() is not None)
        assert self.proc.poll() is None, self.logs()
        # bind() creates the path before listen()/signal setup. A reply, not a
        # pathname, proves that startup has completed (including on activation).
        def ready():
            assert self.proc.poll() is None, self.logs()
            try:
                return "parameters" in self.call(b'{"method":"org.varlink.service.GetInfo"}\0')
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

    def error(self, data, error):
        self.assertEqual(self.service.call(data)["error"], error)

    def test_fragmented_and_exact_limit(self):
        data = frame()
        with self.service.connect() as s:
            for byte in data[:-1]:
                s.sendall(bytes([byte]))
            self.assertFalse(self.service.workers())
            s.sendall(b"\0")
            self.service.pending()
            self.service.gate(b"C")
            self.assertEqual(response(s)["error"], IFACE + ".Cancelled")
        # A legal frame occupying exactly 65536 bytes, including NUL.
        params = copy.deepcopy(PARAMS)
        params["context"]["app_id"] = "x" * (65536 - len(frame()) + len(PARAMS["context"]["app_id"]))
        data = frame(params=params)
        self.assertEqual(len(data), 65536)
        with self.service.connect(data) as s:
            self.service.pending()
            self.service.gate(b"C")
            self.assertEqual(response(s)["error"], IFACE + ".Cancelled")

    def test_invalid_frames_and_flags(self):
        for data in (b"{\0", b"[]\0", b"\xff\0", b"\0", b'{"method":1}\0', b'{"method":"x","method":"y"}\0', frame() + frame(), b"x" * 65536):
            self.error(data, "org.varlink.service.InvalidParameter")
        for flag in ("more", "oneway", "upgrade"):
            value = json.loads(frame()[:-1])
            value[flag] = True
            self.error(json.dumps(value).encode() + b"\0", "org.varlink.service.InvalidParameter")
        self.assertFalse(self.service.workers())

    def test_partial_reply_backpressure_and_reply_limit(self):
        method = "x" * 50000
        data = json.dumps({"method": IFACE + "." + method}).encode() + b"\0"
        with self.service.connect(data) as sock:
            time.sleep(.1)  # reply exceeds native SO_SNDBUF; do not drain yet
            self.assertIn("parameters", self.service.call(b'{"method":"org.varlink.service.GetInfo"}\0'))
            result = response(sock)
            self.assertEqual(result, {"error": "org.varlink.service.MethodNotFound", "parameters": {"method": method}})
        empty = json.dumps({"method": IFACE + "."}).encode() + b"\0"
        data = json.dumps({"method": IFACE + "." + "x" * (65536 - len(empty))}).encode() + b"\0"
        self.assertEqual(len(data), 65536)
        self.error(data, "org.varlink.service.InvalidParameter")

    def test_wrong_parameter_types(self):
        for field, value in (("modal", 1), ("interactive", "yes"), ("context", {})):
            params = copy.deepcopy(PARAMS)
            params[field] = value
            self.error(frame(params=params), "org.varlink.service.InvalidParameter")
        params = copy.deepcopy(PARAMS)
        del params["context"]["permission_store_checked"]
        self.error(frame(params=params), "org.varlink.service.InvalidParameter")

    def test_introspection_and_standard_errors(self):
        self.error(frame("Absent"), "org.varlink.service.MethodNotFound")
        self.error(b'{"method":"org.example.Absent"}\0', "org.varlink.service.InterfaceNotFound")
        info = self.service.call(b'{"method":"org.varlink.service.GetInfo"}\0')["parameters"]
        self.assertEqual(info["interfaces"], ["org.varlink.service", IFACE])
        for name in info["interfaces"]:
            result = self.service.call(json.dumps({"method": "org.varlink.service.GetInterfaceDescription", "parameters": {"interface": name}}).encode() + b"\0")
            self.assertIn("interface " + name, result["parameters"]["description"])

    def test_no_input_no_success_and_concurrent_busy(self):
        with self.service.connect(frame()) as pending:
            self.service.pending()
            self.assertFalse(select.select([pending], [], [], .15)[0])
            self.error(frame("PickColor"), IFACE + ".Busy")
            self.assertIn("parameters", self.service.call(b'{"method":"org.varlink.service.GetInfo"}\0'))
            self.service.gate()
            result = response(pending)
            self.assertTrue(result["parameters"]["uri"].startswith("file:///"))

    def test_disconnect_cancels_pending_worker(self):
        s = self.service.connect(frame())
        pid = self.service.pending()[0]
        s.close()
        until(lambda: not self.service.workers())
        self.assertFalse(Path("/proc") .joinpath(pid).exists())
        self.assertEqual(list(self.service.captures.iterdir()), [])
        with self.service.connect(frame("PickColor")) as s:
            self.service.pending()
            self.service.gate()
            self.assertEqual(response(s), {"parameters": {"color": [.8, .4, .2]}})

    def test_late_completion_loses_to_eof(self):
        s = self.service.connect(frame())
        pid = self.service.pending()[0]
        self.service.proc.send_signal(signal.SIGSTOP)
        try:
            self.service.gate()
            # The worker closes its PNG and exits; the stopped parent cannot
            # consume the pipe or link the unnamed file into the directory yet.
            until(lambda: Path(f"/proc/{pid}/stat").read_text().split()[2] == "Z")
            s.close()
        finally:
            self.service.proc.send_signal(signal.SIGCONT)
        until(lambda: not self.service.workers())
        self.assertEqual(list(self.service.captures.iterdir()), [])

    def test_timeout_and_shutdown_cancel_pending(self):
        self.service.stop()
        self.service = self.start(["--timeout-ms", "200"])
        with self.service.connect(frame()) as s:
            self.service.pending()
            self.assertEqual(s.recv(1), b"")
        until(lambda: not self.service.workers())
        self.assertEqual(list(self.service.captures.iterdir()), [])
        with self.service.connect(frame()) as s:
            pid = self.service.pending()[0]
            self.service.stop()
            self.assertEqual(s.recv(1), b"")
            self.assertFalse(Path("/proc").joinpath(pid).exists())
        self.assertEqual(list(self.runtime.joinpath("ouro/captures").iterdir()), [])

    def test_partial_frame_timeout_and_eof(self):
        with self.service.connect(b'{"method":'):
            pass
        self.service.stop()
        self.service = self.start(["--timeout-ms", "100"])
        with self.service.connect(b'{"method":') as s:
            self.assertEqual(s.recv(1), b"")
        self.assertFalse(self.service.workers())

    def test_png_uri_modes_retention_idle_reactivation(self):
        self.service.stop()
        listener = socket.socket(socket.AF_UNIX)
        self.addCleanup(listener.close)
        listener.bind(str(self.runtime / "ouro/capture.sock"))
        os.chmod(self.runtime / "ouro/capture.sock", 0o600)
        listener.listen(64)
        self.service = self.start(["--idle-ms", "150"], listener)
        with self.service.connect(frame()) as s:
            self.service.pending()
            time.sleep(.2)  # Idle deadline must not apply while UI is pending.
            self.assertIsNone(self.service.proc.poll())
            self.service.gate()
            uri = response(s)["parameters"]["uri"]
        self.assertIn("%20", uri)
        self.assertIn("%25", uri)
        self.assertIn("%C3%A9", uri)
        parsed = urlparse(uri)
        self.assertEqual((parsed.scheme, parsed.netloc, parsed.query, parsed.fragment), ("file", "", "", ""))
        path = Path(unquote(parsed.path))
        data = path.read_bytes()
        self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n")
        image = Image.open(path)
        self.assertEqual(image.size, (2, 1))
        self.assertEqual([image.convert("RGB").getpixel((x, 0)) for x in range(2)], [(204, 102, 51), (68, 34, 17)])
        self.assertNotIn("srgb", image.info)
        self.assertNotIn("gamma", image.info)
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.assertTrue(stat.S_ISREG(path.stat().st_mode))
        for p in (path.parent, path.parent.parent):
            self.assertEqual(stat.S_IMODE(p.stat().st_mode), 0o700)
        self.assertEqual(self.service.proc.wait(timeout=3), 0)
        self.assertTrue(self.service.path.exists())  # owned by socket activator
        self.assertEqual(path.read_bytes(), data)
        # A queued request survives idle exit and is handled by a fresh daemon.
        with self.service.connect(frame("PickColor")) as s:
            self.service = self.start(["--idle-ms", "150"], listener)
            self.service.pending()
            self.service.gate()
            self.assertEqual(response(s)["parameters"]["color"], [.8, .4, .2])
        self.assertEqual(path.read_bytes(), data)

    def test_user_cancel_and_capture_failure(self):
        for command, error in ((b"C", "Cancelled"), (b"F", "Failed")):
            with self.service.connect(frame()) as s:
                self.service.pending()
                self.service.gate(command)
                self.assertEqual(response(s), {"error": IFACE + "." + error, "parameters": {}})
            self.assertEqual(list(self.service.captures.iterdir()), [])

    def test_connection_limit(self):
        sockets = [self.service.connect() for _ in range(64)]
        try:
            self.error(frame(), IFACE + ".Busy")
        finally:
            for s in sockets:
                s.close()

    def test_peer_credentials_not_claims(self):
        if os.geteuid() == 0 or not shutil.which("sudo") or subprocess.run(["sudo", "-n", "true"], capture_output=True).returncode:
            self.skipTest("requires a distinct local UID via passwordless sudo")
        # Root can traverse the private directory, but is not the daemon's UID.
        code = "import socket,sys; s=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); print(s.recv(4096).decode())"
        result = subprocess.run(["sudo", "-n", sys.executable, "-c", code, str(self.service.path)], capture_output=True, timeout=3, check=True)
        self.assertEqual(json.loads(result.stdout.rstrip(b"\n\0"))["error"], IFACE + ".Denied")
        self.assertFalse(self.service.workers())

    def test_packaged_systemd_units(self):
        if not shutil.which("systemd-analyze"):
            self.skipTest("systemd-analyze unavailable")
        source = Path(__file__).resolve().parents[1] / "systemd"
        stage = self.runtime / "units"
        stage.mkdir()
        for unit in source.iterdir():
            text = unit.read_text().replace("/usr/bin/ouroshot-service", EXE)
            (stage / unit.name).write_text(text)
        result = subprocess.run(["systemd-analyze", "--user", "verify", *map(str, stage.iterdir())],
                                env=dict(os.environ, XDG_RUNTIME_DIR=str(self.runtime)), capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr.decode())

    def test_commit_retained_without_reading_reply(self):
        s = self.service.connect(frame())
        self.service.pending()
        self.service.gate()
        path = until(lambda: next(self.service.captures.glob("*.png"), None))
        s.close()  # frontend may never have consumed the reply; retain anyway
        self.service.stop()
        self.assertTrue(path.exists())

    def test_crash_kills_worker_and_discards_unnamed_file(self):
        with self.service.connect(frame()) as s:
            pid = self.service.pending()[0]
            self.service.proc.kill()
            self.service.proc.wait(timeout=3)
            self.assertEqual(s.recv(1), b"")
            def dead():
                path = Path(f"/proc/{pid}/stat")
                try:
                    return path.read_text().split()[2] == "Z"
                except FileNotFoundError:
                    return True
            until(dead)
            self.assertEqual(list(self.service.captures.iterdir()), [])

    def test_runtime_symlink_and_modes_rejected(self):
        self.service.stop()
        alias = self.runtime / "alias"
        alias.symlink_to(self.runtime, target_is_directory=True)
        result = subprocess.run([EXE], env=dict(os.environ, XDG_RUNTIME_DIR=str(alias / "ouro")), capture_output=True, timeout=3)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"UnsafeDirectory", result.stderr)
        alias.unlink()
        captures = self.runtime / "ouro/captures"
        captures.rmdir()
        captures.symlink_to(self.runtime, target_is_directory=True)
        result = subprocess.run([EXE], env=dict(os.environ, XDG_RUNTIME_DIR=str(self.runtime)), capture_output=True, timeout=3)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"UnsafeDirectory", result.stderr)
        captures.unlink()
        captures.mkdir(mode=0o755)
        result = subprocess.run([EXE], env=dict(os.environ, XDG_RUNTIME_DIR=str(self.runtime)), capture_output=True, timeout=3)
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
