#!/usr/bin/env python3
"""Production Screenshot uses the existing selector on a private compositor.

Optional --bridge PATH exercises real ourobridge under dbus-run-session with
OUROSHOT_PRIVATE_TEST_BUS=1. This does not test frontend document export.
"""
import argparse
import copy
import os
from pathlib import Path
import select
import shutil
import subprocess
import tempfile
import time
from urllib.parse import unquote, urlparse

from PIL import Image, ImageChops
from pointer import Pointer, cursor_environment
from service import Service, PARAMS, IFACE, frame, response, until

parser = argparse.ArgumentParser()
parser.add_argument("--executable", default="zig-out/bin/ouroshot-service")
parser.add_argument("--artifacts")
parser.add_argument("--bridge")
args = parser.parse_args()
art = Path(args.artifacts or tempfile.mkdtemp(prefix="ouroshot-selector-")).resolve()
art.mkdir(parents=True, exist_ok=True)
runtime = Path(tempfile.mkdtemp(prefix="ouroshot-wayland-"))
env = dict(os.environ, XDG_RUNTIME_DIR=str(runtime), WLR_BACKENDS="headless", WLR_RENDERER="pixman", WLR_HEADLESS_OUTPUTS="1")
env.update(cursor_environment(runtime))
for key in ("WAYLAND_DISPLAY", "SWAYSOCK", "WAYLAND_DEBUG"):
    env.pop(key, None)
config = runtime / "sway.conf"
config.write_text("output HEADLESS-1 mode 960x600 scale 1.5 position 0 0\noutput * bg #204060 solid_color\nseat seat0 fallback true\nseat seat0 xcursor_theme ouroshot-test 16\nxwayland disable\n")
log = (art / "sway.log").open("wb")
compositor = subprocess.Popen(["sway", "-c", str(config)], env=env, stdout=log, stderr=subprocess.STDOUT)
service = pointer = bridge = None


def screen(name):
    path = art / name
    subprocess.run(["grim", "-s", "1.5", str(path)], env=env, check=True, capture_output=True, timeout=5)
    return Image.open(path).convert("RGB")


def equal(actual, expected):
    assert actual.size == expected.size, (actual.size, expected.size)
    assert ImageChops.difference(actual.convert("RGB"), expected.convert("RGB")).getbbox() is None


def saved(uri):
    path = Path(unquote(urlparse(uri).path))
    assert path.parent == service.captures and path.stat().st_mode & 0o777 == 0o600
    return Image.open(path).convert("RGB")


def drag():
    pointer.move(100, 120)
    pointer.button(1)
    pointer.move(310, 270)
    time.sleep(.15)
    screen("selection.png")
    pointer.button(0)


def cancel():
    # Refresh virtual-pointer focus after the previous overlay was destroyed.
    pointer.move(400, 320)
    time.sleep(.05)
    pointer.button(1, 273)
    time.sleep(.1)
    pointer.button(0, 273)


try:
    until(lambda: list(runtime.glob("sway-ipc*.sock")))
    env["WAYLAND_DISPLAY"] = next(p.name for p in runtime.glob("wayland-*") if not p.name.endswith(".lock"))
    env["SWAYSOCK"] = str(next(runtime.glob("sway-ipc*.sock")))
    pointer = Pointer(runtime, env["WAYLAND_DISPLAY"])
    pointer.move(20, 350)
    pattern = Image.new("RGB", (960, 600))
    pattern.putdata([((x * 3) % 256, (y * 5) % 256, (x + y * 2) % 256) for y in range(600) for x in range(960)])
    pattern.save(runtime / "pattern.png")
    subprocess.run(["swaymsg", "output", "HEADLESS-1", "bg", str(runtime / "pattern.png"), "stretch"], env=env, check=True, capture_output=True)
    time.sleep(.3)
    baseline = screen("baseline.png")
    expected = baseline.crop((150, 180, 465, 405))
    service = Service(runtime, executable=str(Path(args.executable).resolve()), env=env)

    for interactive in (False, True):
        params = copy.deepcopy(PARAMS)
        params["interactive"] = interactive
        with service.connect(frame(params=params)) as sock:
            service.pending()
            time.sleep(.3)
            assert not select.select([sock], [], [], .1)[0], "succeeded without selection"
            assert service.call(frame())["error"] == IFACE + ".Busy"
            screen("pending.png")
            drag()
            equal(saved(response(sock)["parameters"]["uri"]), expected)
    print("PASS real Screenshot: both interactive hints require selection, Busy, exact 150% pixels, no card", flush=True)

    for disconnect in (False, True):
        before = set(service.captures.iterdir())
        with service.connect(frame()) as sock:
            service.pending()
            time.sleep(.3)
            if disconnect:
                sock.close()
            else:
                cancel()
                assert response(sock) == {"error": IFACE + ".Cancelled", "parameters": {}}
        until(lambda: not service.workers())
        time.sleep(.15)
        equal(screen("disconnected.png" if disconnect else "cancelled.png"), baseline)
        assert set(service.captures.iterdir()) == before
    print("PASS real selection cancellation and EOF: UI dismissed, no extra artifacts", flush=True)

    if args.bridge:
        assert os.environ.get("OUROSHOT_PRIVATE_TEST_BUS") == "1"
        import dbus
        from dbus.mainloop.glib import DBusGMainLoop
        from gi.repository import GLib
        DBusGMainLoop(set_as_default=True)
        bus = dbus.bus.BusConnection(os.environ["DBUS_SESSION_BUS_ADDRESS"])
        assert bus.request_name("org.freedesktop.portal.Desktop", dbus.bus.NAME_FLAG_DO_NOT_QUEUE) == 1
        name = "org.freedesktop.impl.portal.desktop.ouro"
        path = "/org/freedesktop/portal/desktop"
        with (art / "bridge.log").open("wb") as bridge_log:
            bridge = subprocess.Popen([str(Path(args.bridge).resolve())], env=env, stderr=bridge_log)
            until(lambda: bus.name_has_owner(name))
            for action, code in (("select", 0), ("cancel", 1), ("close", 2)):
                replies, errors = [], []
                handle = path + "/request/test/" + action
                bus.call_async(name, path, "org.freedesktop.impl.portal.Screenshot", "Screenshot", "ossa{sv}",
                               (dbus.ObjectPath(handle), "org.example.Test", "", dbus.Dictionary({}, signature="sv")),
                               reply_handler=lambda *r: replies.append(r), error_handler=errors.append, timeout=5)
                service.pending()
                time.sleep(.3)
                if action == "select":
                    drag()
                elif action == "cancel":
                    cancel()
                else:
                    bus.call_blocking(name, handle, "org.freedesktop.impl.portal.Request", "Close", "", ())
                def done():
                    while GLib.MainContext.default().iteration(False):
                        pass
                    return replies or errors
                until(done)
                assert not errors and replies[0][0] == code, (replies, errors)
                if action == "select":
                    equal(saved(str(replies[0][1]["uri"])), expected)
                until(lambda: not service.workers())
                time.sleep(.15)
                equal(screen("bridge-" + action + ".png"), baseline)
            bridge.terminate()
            bridge.wait(timeout=3)
            bus.close()
        print("PASS real ourobridge Screenshot: selected pixels, native Cancelled and Request.Close", flush=True)
    assert "Wayland event failure" not in service.logs(), service.logs()
    print("Artifacts:", art, flush=True)
finally:
    if bridge is not None and bridge.poll() is None:
        bridge.terminate()
        bridge.wait(timeout=3)
    if service is not None:
        (art / "service.log").write_text(service.logs())
        service.stop()
    if pointer is not None:
        pointer.sock.close()
    compositor.terminate()
    compositor.wait(timeout=5)
    log.close()
    shutil.rmtree(runtime)
