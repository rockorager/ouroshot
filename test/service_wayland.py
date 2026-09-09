#!/usr/bin/env python3
"""Real service/UI/capture on a private software-rendered Wayland compositor.

Optional --bridge PATH also tests real ourobridge on a private D-Bus session:
dbus-run-session -- env OUROSHOT_PRIVATE_TEST_BUS=1 /usr/bin/python3 \
    test/service_wayland.py --bridge /path/to/ourobridge
The test owns the portal frontend bus name; it does NOT test document export.
"""
import argparse
import copy
import json
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
art = Path(args.artifacts or tempfile.mkdtemp(prefix="ouroshot-service-ui-")).resolve()
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


def run(command):
    return subprocess.run([str(a) for a in command], env=env, check=True, capture_output=True, timeout=10)


def screen(name):
    path = art / name
    run(["grim", "-s", "1.5", path])
    return Image.open(path).convert("RGB")


def equal(actual, expected):
    assert actual.size == expected.size, (actual.size, expected.size)
    diff = ImageChops.difference(actual.convert("RGB"), expected.convert("RGB"))
    assert diff.getbbox() is None, (diff.getbbox(), diff.getextrema())


def saved(result):
    uri = result["parameters"]["uri"]
    path = Path(unquote(urlparse(uri).path))
    assert path.parent == runtime / "ouro/captures", path
    assert path.stat().st_mode & 0o777 == 0o600
    return Image.open(path).convert("RGB")


def pending(method="Screenshot", interactive=False):
    params = copy.deepcopy(PARAMS)
    params["interactive"] = interactive
    sock = service.connect(frame(method, params))
    service.pending()
    time.sleep(.3)
    assert not select.select([sock], [], [], 0)[0], service.logs()
    return sock


try:
    until(lambda: list(runtime.glob("sway-ipc*.sock")))
    env["WAYLAND_DISPLAY"] = next(p.name for p in runtime.glob("wayland-*") if not p.name.endswith(".lock"))
    env["SWAYSOCK"] = str(next(runtime.glob("sway-ipc*.sock")))
    pointer = Pointer(runtime, env["WAYLAND_DISPLAY"])
    pointer.move(10, 350)
    # Deliberately asymmetric native pixels, including adjacent pixels inside
    # one logical pixel at fractional scale, catch rounding/channel swaps.
    pattern = Image.new("RGB", (960, 600))
    pattern.putdata([((x * 3) % 256, (y * 5) % 256, (x + y * 2) % 256) for y in range(600) for x in range(960)])
    pattern.save(runtime / "pattern.png")
    run(["swaymsg", "output", "HEADLESS-1", "bg", runtime / "pattern.png", "stretch"])
    time.sleep(.3)
    baseline = screen("baseline.png")
    service = Service(runtime, ["--capture-source-srgb"], executable=str(Path(args.executable).resolve()), env=env)

    with pending() as sock:
        screen("consent.png")
        assert all(p.stat().st_size == 0 for p in service.captures.iterdir()), "pixels acquired before consent"
        pointer.click(450, 240)
        assert response(sock)["error"] == IFACE + ".Cancelled"
    time.sleep(.15)
    equal(screen("cancelled.png"), baseline)
    print("PASS real native consent: forged hints do not bypass; Cancel dismisses without pixels", flush=True)

    with pending() as sock:
        pointer.click(150, 240)
        equal(saved(response(sock)), baseline)
    print("PASS real full screenshot: explicit consent, original pixels, no overlay", flush=True)

    with pending(interactive=True) as sock:
        screen("region-consent.png")
        pointer.click(150, 240)
        time.sleep(.3)
        pointer.move(100, 150)
        pointer.button(1)
        pointer.move(300, 300)
        time.sleep(.2)
        screen("region-pending.png")
        assert not select.select([sock], [], [], 0)[0]
        pointer.button(0)
        equal(saved(response(sock)), baseline.crop((150, 225, 450, 450)))
    print("PASS real region selection at 150%: consent plus pending drag, exact native crop", flush=True)

    with pending("PickColor") as sock:
        screen("color-consent.png")
        pointer.click(150, 240)
        time.sleep(.3)
        screen("picker-pending.png")
        pointer.click(210.75, 210.75)
        result = response(sock)["parameters"]["color"]
        expected = [v / 255 for v in baseline.getpixel((316, 316))]
        assert result == expected, (result, expected)
    print("PASS real color picker: sRGB-configured software source, fractional location and RGB ordering", flush=True)

    with pending("PickColor") as sock:
        pointer.click(150, 240)
        time.sleep(.3)
        pointer.click(400, 320, 273)
        assert response(sock)["error"] == IFACE + ".Cancelled"
    print("PASS real picker cancellation", flush=True)

    for accepted in (False, True):
        before = set(service.captures.iterdir())
        sock = pending(interactive=True)
        if accepted:
            pointer.click(150, 240)
            time.sleep(.3)
        sock.close()
        until(lambda: not service.workers())
        time.sleep(.15)
        equal(screen("disconnect-after-consent.png" if accepted else "disconnect-before-consent.png"), baseline)
        assert set(service.captures.iterdir()) == before
    print("PASS real pending-UI EOF: consent and frozen selector dismissed, no late artifact", flush=True)

    if args.bridge:
        assert os.environ.get("OUROSHOT_PRIVATE_TEST_BUS") == "1", "use dbus-run-session with explicit private-test marker"
        import dbus
        from dbus.mainloop.glib import DBusGMainLoop
        from gi.repository import GLib
        DBusGMainLoop(set_as_default=True)
        bus = dbus.bus.BusConnection(os.environ["DBUS_SESSION_BUS_ADDRESS"])
        assert bus.request_name("org.freedesktop.portal.Desktop", dbus.bus.NAME_FLAG_DO_NOT_QUEUE) == 1
        name = "org.freedesktop.impl.portal.desktop.ouro"
        path = "/org/freedesktop/portal/desktop"
        bridge_log = (art / "bridge.log").open("wb")
        bridge = subprocess.Popen([str(Path(args.bridge).resolve())], env=env, stderr=bridge_log)
        until(lambda: bus.name_has_owner(name))

        def call(method, suffix, options=None):
            result, errors = [], []
            handle = path + "/request/test/" + suffix
            bus.call_async(name, path, "org.freedesktop.impl.portal.Screenshot", method, "ossa{sv}",
                           (dbus.ObjectPath(handle), "org.example.Test", "invalid-parent", dbus.Dictionary(options or {}, signature="sv")),
                           reply_handler=lambda *r: result.append(r), error_handler=errors.append, timeout=5)
            return handle, result, errors

        def pump():
            while GLib.MainContext.default().iteration(False):
                pass

        def done(result, errors):
            def ready():
                pump()
                return result or errors
            until(ready)
            assert not errors, errors
            return result[0]

        _, result, errors = call("Screenshot", "full")
        service.pending()
        time.sleep(.3)
        pointer.click(150, 240)
        code, values = done(result, errors)
        assert code == 0, (code, values)
        equal(saved({"parameters": {"uri": str(values["uri"])}}), baseline)

        _, result, errors = call("PickColor", "color")
        service.pending()
        time.sleep(.3)
        pointer.click(150, 240)
        time.sleep(.3)
        pointer.click(210.75, 210.75)
        code, values = done(result, errors)
        assert code == 0 and list(values["color"]) == expected, (code, values)

        _, result, errors = call("Screenshot", "cancel")
        service.pending()
        time.sleep(.3)
        pointer.click(450, 240)
        assert done(result, errors)[0] == 1

        handle, result, errors = call("Screenshot", "close", {"interactive": dbus.Boolean(True)})
        service.pending()
        time.sleep(.3)
        pointer.click(150, 240)
        time.sleep(.3)
        bus.call_blocking(name, handle, "org.freedesktop.impl.portal.Request", "Close", "", ())
        until(lambda: not service.workers())
        # Bridge Close is frontend abandonment (response 2), distinct from the
        # native user's Cancelled reply (response 1). No late success is valid.
        assert done(result, errors)[0] == 2
        time.sleep(.15)
        equal(screen("bridge-close.png"), baseline)
        print("PASS real ourobridge -> real ouroshot: Screenshot, PickColor, user cancellation and Request.Close during selection", flush=True)
        bridge.terminate()
        bridge.wait(timeout=3)
        bridge_log.close()
        bus.close()

    run(["swaymsg", "create_output"])
    run(["swaymsg", "output HEADLESS-2 mode 800x600 scale 1 position -800 0 bg #28496a solid_color"])
    pointer.width, pointer.height = 1440, 600
    time.sleep(.3)
    # grim's combined output resamples (and can round channels); ouroshot's
    # contract uses nearest native pixels. Build this expectation independently.
    run(["grim", "-o", "HEADLESS-2", "-s", "1", art / "second-native.png"])
    second = Image.open(art / "second-native.png").convert("RGB")
    mixed = Image.new("RGB", (2160, 900))
    mixed.paste(second.resize((1200, 900), Image.Resampling.NEAREST), (0, 0))
    mixed.paste(baseline, (1200, 0))
    with pending() as sock:
        pointer.click(200, 240)  # consent on the negative-origin output
        equal(saved(response(sock)), mixed)
    with pending("PickColor") as sock:
        pointer.click(200, 240)
        time.sleep(.3)
        pointer.click(210.75, 310.75)
        assert response(sock)["parameters"]["color"] == [40/255, 73/255, 106/255]
    print("PASS native mixed-scale full capture and color on negative-origin output", flush=True)

    print("All service Wayland checks passed. Artifacts:", art, flush=True)
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
