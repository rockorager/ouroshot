#!/usr/bin/env python3
"""Production PickColor must not capture or open UI while its picker is deferred.

Optional --bridge PATH checks real ourobridge failure mapping on a private bus:
dbus-run-session -- env OUROSHOT_PRIVATE_TEST_BUS=1 /usr/bin/python3 \
    test/service_unavailable.py --bridge /path/to/ourobridge
"""
import argparse
import copy
import os
from pathlib import Path
import select
import socket
import subprocess
import tempfile

from service import Service, PARAMS, structured, tool_error, tool_frame, until

parser = argparse.ArgumentParser()
parser.add_argument("--executable", default="zig-out/bin/ouroshot-service")
parser.add_argument("--bridge")
args = parser.parse_args()

with tempfile.TemporaryDirectory(prefix="ouroshot-unavailable-") as directory:
    runtime = Path(directory)
    env = dict(os.environ, XDG_RUNTIME_DIR=directory, WAYLAND_DISPLAY="wayland-test")
    # A listening endpoint catches even an attempted compositor connection.
    # No real desktop or compositor is involved.
    with socket.socket(socket.AF_UNIX) as wayland:
        wayland.bind(str(runtime / env["WAYLAND_DISPLAY"]))
        wayland.listen(16)
        service = Service(runtime, executable=str(Path(args.executable).resolve()), env=env)
        try:
            # Even bytes that approve the separately built fixture cannot enable
            # capture in the production executable.
            service.gate(b"SSSS")
            for method in ("PickColor",):
                for interactive in (False, True):
                    params = copy.deepcopy(PARAMS)
                    params["interactive"] = interactive
                    tool_error(service.call(tool_frame(method, params)), "Failed")
                    params["context"].update(require_confirmation=True, permission_store_checked=False, origin="xdg-desktop-portal")
                    tool_error(service.call(tool_frame(method, params)), "Failed")
            assert not service.workers()
            assert not list(service.captures.iterdir())
            assert not select.select([wayland], [], [], .1)[0], "service contacted Wayland"
            print("PASS production PickColor fails closed for all hints; no worker, Wayland connection or artifact", flush=True)

            if args.bridge:
                assert os.environ.get("OUROSHOT_PRIVATE_TEST_BUS") == "1", "use dbus-run-session with explicit private-test marker"
                import dbus
                bus = dbus.bus.BusConnection(os.environ["DBUS_SESSION_BUS_ADDRESS"])
                assert bus.request_name("org.freedesktop.portal.Desktop", dbus.bus.NAME_FLAG_DO_NOT_QUEUE) == 1
                name = "org.freedesktop.impl.portal.desktop.ouro"
                path = "/org/freedesktop/portal/desktop"
                with tempfile.TemporaryFile() as log:
                    bridge = subprocess.Popen([str(Path(args.bridge).resolve())], env=env, stderr=log)
                    try:
                        until(lambda: bus.name_has_owner(name))
                        for method in ("PickColor",):
                            result = bus.call_blocking(name, path, "org.freedesktop.impl.portal.Screenshot", method, "ossa{sv}",
                                                      (dbus.ObjectPath(path + "/request/test/" + method), "org.example.Test", "", dbus.Dictionary({}, signature="sv")), timeout=3)
                            assert result[0] == 2 and not result[1], result
                        assert not service.workers() and not list(service.captures.iterdir())
                        assert not select.select([wayland], [], [], .1)[0]
                        print("PASS real ourobridge -> real ouroshot: deferred PickColor maps to portal response 2", flush=True)
                    finally:
                        bridge.terminate()
                        bridge.wait(timeout=3)
                        bus.close()
        finally:
            service.stop()
