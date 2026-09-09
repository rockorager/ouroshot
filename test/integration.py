#!/usr/bin/env python3
"""Real Wayland tests on a private headless Sway, never the user's compositor.

Requires sway, swaybg, grim, ffmpeg/ffprobe and Python Pillow. Optional first
argument is the executable; second is a new directory for retained artifacts.
"""
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time

from PIL import Image, ImageChops, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
EXE = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / "zig-out/bin/ouroshot").resolve()
ART = Path(sys.argv[2]) if len(sys.argv) > 2 else Path(tempfile.mkdtemp(prefix="ouroshot-integration-"))
ART.mkdir(parents=True, exist_ok=True)
RUNTIME = Path(tempfile.mkdtemp(prefix="ouroshot-test-"))
env = dict(os.environ, XDG_RUNTIME_DIR=str(RUNTIME), WLR_BACKENDS="headless", WLR_RENDERER=os.environ.get("OUROSHOT_TEST_RENDERER", "pixman"), WLR_HEADLESS_OUTPUTS="1")
for key in ("WAYLAND_DISPLAY", "SWAYSOCK", "WAYLAND_DEBUG"):
    env.pop(key, None)
(ART / "sway.conf").write_text("output HEADLESS-1 mode 960x600 scale 1.5 position 0 0\noutput * bg #204060 solid_color\nseat seat0 fallback true\nxwayland disable\n")


def run(args, **kwargs):
    return subprocess.run([str(a) for a in args], env=env, check=True, timeout=15, capture_output=True, **kwargs)


def sway(*args):
    result = run(["swaymsg", "-s", env["SWAYSOCK"], *args])
    return json.loads(result.stdout)


def screenshot(name):
    path = ART / name
    run(["grim", "-s", "1.5", path])
    return Image.open(path).convert("RGB")


def equal(a, b):
    assert a.size == b.size, (a.size, b.size)
    delta = ImageChops.difference(a.convert("RGB"), b.convert("RGB"))
    assert delta.getbbox() is None, (delta.getbbox(), delta.getextrema())


class Pointer:
    def __init__(self):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(3)
        self.sock.connect(str(RUNTIME / env["WAYLAND_DISPLAY"]))
        self.buf = b""
        self.send(1, 1, struct.pack("I", 2))
        self.send(1, 0, struct.pack("I", 3))
        manager = None
        while True:
            obj, op, data = self.read()
            if obj == 2 and op == 0:
                name, n = struct.unpack_from("II", data)
                if data[8:8+n-1] == b"zwlr_virtual_pointer_manager_v1":
                    manager = name
            if obj == 3:
                break
        assert manager is not None
        interface = b"zwlr_virtual_pointer_manager_v1\0"
        self.send(2, 0, struct.pack("II", manager, len(interface)) + interface + bytes(-len(interface) % 4) + struct.pack("II", 1, 4))
        self.send(4, 0, struct.pack("II", 0, 5))

    def send(self, obj, op, payload=b""):
        self.sock.sendall(struct.pack("II", obj, ((8+len(payload)) << 16) | op) + payload)

    def read(self):
        while len(self.buf) < 8:
            self.buf += self.sock.recv(65536)
        obj, header = struct.unpack_from("II", self.buf)
        size = header >> 16
        while len(self.buf) < size:
            self.buf += self.sock.recv(65536)
        data, self.buf = self.buf[8:size], self.buf[size:]
        if obj == 1 and header & 65535 == 0:
            raise RuntimeError(repr(data))
        return obj, header & 65535, data

    def move(self, x, y):
        self.send(5, 1, struct.pack("IIIII", int(time.monotonic()*1000) & 0xffffffff, x, y, 640, 400))
        self.send(5, 4)

    def button(self, state, button=272):
        self.send(5, 2, struct.pack("III", int(time.monotonic()*1000) & 0xffffffff, button, state))
        self.send(5, 4)


children = []
logs = []


def launch(name, args):
    log = (ART / (name + ".log")).open("wb")
    logs.append(log)
    if "--record" in args and name == "video" and env["WLR_RENDERER"] != "pixman":
        args = [*args, "--capture", "dmabuf", "--encoder", "vaapi"]
    proc = subprocess.Popen([str(EXE), *map(str, args)], env=env, stdout=subprocess.PIPE, stderr=log)
    children.append(proc)
    return proc


compositor_log = (ART / "sway.log").open("wb")
compositor = subprocess.Popen(["sway", "-c", str(ART / "sway.conf"), "-d"], env=env, stdout=compositor_log, stderr=subprocess.STDOUT)
pointer = None
try:
    deadline = time.monotonic() + 5
    while not list(RUNTIME.glob("wayland-*")) or not list(RUNTIME.glob("sway-ipc*.sock")):
        assert compositor.poll() is None, "headless Sway failed"
        assert time.monotonic() < deadline
        time.sleep(.05)
    env["WAYLAND_DISPLAY"] = next(p.name for p in RUNTIME.glob("wayland-*") if not p.name.endswith(".lock"))
    env["SWAYSOCK"] = str(next(RUNTIME.glob("sway-ipc*.sock")))
    time.sleep(.3)
    pointer = Pointer()
    pointer.move(10, 10)
    time.sleep(.1)

    pattern = Image.new("RGB", (960, 600), "#172435")
    draw = ImageDraw.Draw(pattern)
    for y in range(0, 600, 40):
        for x in range(0, 960, 40):
            draw.rectangle((x, y, x+38, y+38), fill=(30+x//5, 40+y//3, 80+(x+y)//12))
    draw.rectangle((100, 110, 650, 380), fill="#f3f0e8")
    draw.text((130, 135), "ouroshot / fractional-scale capture test", fill="#172435", font_size=24)
    draw.text((130, 185), "Native pixels. Frozen selection. Clean crop.", fill="#35516f", font_size=18)
    draw.rectangle((130, 240, 230, 325), fill="#e06c75")
    draw.rectangle((260, 240, 395, 325), fill="#98c379")
    draw.rectangle((425, 240, 620, 325), fill="#61afef")
    pattern.save(ART / "pattern.png")
    sway(f"output HEADLESS-1 bg {ART / 'pattern.png'} stretch")
    time.sleep(.25)
    baseline = screenshot("baseline.png")
    run([EXE, "--fullscreen", "-o", ART / "full.png"])
    equal(baseline, Image.open(ART / "full.png"))
    run([EXE, "-g", "80,60 321x201", "-o", ART / "crop.png"])
    equal(baseline.crop((120, 90, 602, 392)), Image.open(ART / "crop.png"))
    stdout_png = run([EXE, "-g", "80,60 320x200", "-o", "-"]).stdout
    (ART / "stdout.png").write_bytes(stdout_png)
    equal(baseline.crop((120, 90, 600, 390)), Image.open(ART / "stdout.png"))
    existed = subprocess.run([str(EXE), "--fullscreen", "-o", str(ART / "full.png")], env=env, capture_output=True, timeout=10)
    assert existed.returncode != 0
    equal(baseline, Image.open(ART / "full.png"))
    print("PASS full/cropped/stdout PNG at 150%, existing-file protection", flush=True)

    proc = launch("frozen", ["-o", ART / "selected.png"])
    time.sleep(.3)
    assert proc.poll() is None
    pointer.move(80, 60)
    time.sleep(.1)
    pointer.button(1)
    pointer.move(480, 320)
    time.sleep(.2)
    screenshot("selection-large.png")
    # Change the real desktop after the frozen capture; it must not leak in.
    # A new background client avoids reconfiguring Sway's output/input mapping
    # during an active implicit pointer grab.
    background = subprocess.Popen(["swaybg", "-c", "#802010"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    children.append(background)
    time.sleep(.15)
    for x, y in [(440, 290), (380, 240), (300, 200)]:
        pointer.move(x, y)
        time.sleep(.08)
    time.sleep(.3)
    preview = screenshot("selection.png")
    # No pointer cursor in grim's default capture. Border is 2 logical pixels.
    assert preview.getpixel((120, 90)) == (255, 255, 255)
    assert preview.getpixel((180, 150)) == baseline.getpixel((180, 150))
    outside = baseline.getpixel((650, 450))
    assert preview.getpixel((650, 450)) == tuple(v*3//5 for v in outside), (preview.getpixel((650, 450)), outside)
    pointer.button(0)
    assert proc.wait(timeout=5) == 0
    equal(baseline.crop((120, 90, 450, 300)), Image.open(ART / "selected.png"))
    print("PASS frozen pixels, fractional selection, shrinking redraw, clean saved crop", flush=True)

    proc = launch("geometry", ["--geometry-only"])
    time.sleep(.2)
    pointer.move(320, 250)
    time.sleep(.05)
    pointer.button(1)
    pointer.move(100, 80)
    time.sleep(.1)
    pointer.button(0)
    out, _ = proc.communicate(timeout=5)
    assert proc.returncode == 0 and out == b"100,80 220x170\n", out
    proc = launch("cancel", ["-o", ART / "cancel.png"])
    time.sleep(.2)
    pointer.move(150, 100)
    time.sleep(.1)
    pointer.button(1, 273)
    pointer.button(0, 273)
    assert proc.wait(timeout=5) == 130
    assert not (ART / "cancel.png").exists()

    proc = launch("live", ["--live", "-o", ART / "live.png"])
    time.sleep(.2)
    pointer.move(100, 80)
    time.sleep(.05)
    pointer.button(1)
    pointer.move(300, 200)
    time.sleep(.1)
    live_preview = screenshot("live-selection.png")
    assert live_preview.getpixel((150, 120)) == (255, 255, 255)
    assert live_preview.getpixel((200, 150)) == (128, 32, 16)
    assert live_preview.getpixel((500, 350)) != (128, 32, 16)
    pointer.button(0)
    assert proc.wait(timeout=5) == 0
    live = Image.open(ART / "live.png").convert("RGB")
    assert live.getextrema() == ((128, 128), (32, 32), (16, 16)), live.getextrema()
    print("PASS geometry-only reverse drag, cancellation, live overlay exclusion", flush=True)

    # Asymmetric patterned reference catches rotation/mirroring, not just sizes.
    sway(f"output HEADLESS-1 bg {ART / 'pattern.png'} stretch")
    for transform in ["90", "180", "270", "flipped", "flipped-90", "flipped-180", "flipped-270"]:
        sway(f"output HEADLESS-1 transform {transform}")
        time.sleep(.2)
        reference = screenshot(f"reference-{transform}.png")
        run([EXE, "--fullscreen", "-o", ART / f"transform-{transform}.png"])
        equal(reference, Image.open(ART / f"transform-{transform}.png"))
    sway("output HEADLESS-1 transform normal")
    print("PASS all rotated/mirrored output transforms against grim", flush=True)

    sway("output HEADLESS-1 scale 1.75")
    time.sleep(.2)
    run([EXE, "--fullscreen", "-o", ART / "uneven-scale.png"])
    assert Image.open(ART / "uneven-scale.png").size == (960, 600)
    sway("output HEADLESS-1 scale 1.5")
    time.sleep(.2)

    proc = launch("video", ["--record", "-g", "81,61 321x201", "--duration", "3", "-o", ART / "record.mp4"])
    time.sleep(.7)
    # Stall only our recorder; a fixed frame-counter timeline would lose .4s.
    proc.send_signal(signal.SIGSTOP)
    time.sleep(.4)
    proc.send_signal(signal.SIGCONT)
    sway("output HEADLESS-1 bg #204080 solid_color")
    assert proc.wait(timeout=8) == 0
    video_log = (ART / "video.log").read_text()
    assert "capture=ext-image-copy-capture-v1" in video_log, video_log
    if env["WLR_RENDERER"] != "pixman":
        assert "encoder=vaapi input=dma-buf" in video_log, video_log
    info = json.loads(run(["ffprobe", "-v", "error", "-show_streams", "-show_frames", "-of", "json", ART / "record.mp4"]).stdout)
    stream = info["streams"][0]
    pts = [float(f["best_effort_timestamp_time"]) for f in info["frames"]]
    assert (stream["width"], stream["height"]) == (482, 302)
    assert 2.7 < float(stream["duration"]) < 3.4
    assert all(b > a for a, b in zip(pts, pts[1:]))
    assert max(b-a for a, b in zip(pts, pts[1:])) > .35
    run(["ffmpeg", "-v", "error", "-i", ART / "record.mp4", "-f", "null", "-"])
    run(["ffmpeg", "-v", "error", "-i", ART / "record.mp4", "-frames:v", "1", ART / "video-first.png"])
    first = Image.open(ART / "video-first.png").convert("RGB")
    # Native off-center crop, not a downscaled whole output. Solid patch centers
    # avoid expected H.264 chroma loss around text and color boundaries.
    for x, y in [(40, 160), (170, 180), (340, 180), (20, 20), (450, 270)]:
        expected = baseline.getpixel((121+x, 91+y))
        actual = first.getpixel((x, y))
        assert max(abs(a-b) for a, b in zip(actual, expected)) < 8, (x, y, expected, actual)
    run(["ffmpeg", "-v", "error", "-sseof", "-0.2", "-i", ART / "record.mp4", "-frames:v", "1", ART / "video-last.png"])
    pixel = Image.open(ART / "video-last.png").getpixel((30, 30))
    assert all(abs(a-b) < 5 for a, b in zip(pixel, (32, 64, 128))), pixel
    proc = launch("signal-stop", ["--record", "-g", "0,0 201x101", "-o", ART / "signal.mkv"])
    time.sleep(.8)
    proc.send_signal(signal.SIGINT)
    assert proc.wait(timeout=5) == 0
    run(["ffmpeg", "-v", "error", "-i", ART / "signal.mkv", "-f", "null", "-"])
    print(f"PASS video: {len(pts)} frames, {stream['duration']}s, stall preserved, colors, SIGINT finalization", flush=True)

    # Static ext capture may never send another ready event. Both software and
    # hardware paths must retain a separate converted frame while capture waits.
    proc = launch("static", ["--record", "--fullscreen", "--duration", "1", "-o", ART / "static.mp4"])
    assert proc.wait(timeout=5) == 0
    counts = re.search(r"(\d+) captures, (\d+) cached repeats", (ART / "static.log").read_text())
    assert counts and int(counts[1]) < 5 and int(counts[2]) > 20, counts
    run(["ffmpeg", "-v", "error", "-i", ART / "static.mp4", "-f", "null", "-"])

    # Auto hardware selection falls back before opening the destination; an
    # explicitly required hardware backend must instead report failure.
    fallback = run([EXE, "--record", "--fullscreen", "--device", "/dev/null", "--duration", "1", "-o", ART / "fallback.mp4"])
    assert b"encoder=software input=shm" in fallback.stderr
    strict = subprocess.run([str(EXE), "--record", "--fullscreen", "--device", "/dev/null", "--encoder", "vaapi", "-o", str(ART / "strict.mp4")], env=env, capture_output=True, timeout=5)
    assert strict.returncode == 1 and not (ART / "strict.mp4").exists(), strict.stderr

    # Odd native dimensions use software padding, preserving the last source
    # column/row instead of scaling the crop to an even size.
    sway("output HEADLESS-1 scale 1")
    time.sleep(.2)
    odd = run([EXE, "--record", "-g", "3,5 201x101", "--duration", "1", "-o", ART / "odd.mp4"])
    assert b"encoder=software" in odd.stderr
    run(["ffmpeg", "-v", "error", "-i", ART / "odd.mp4", "-frames:v", "1", ART / "odd.png"])
    odd_image = Image.open(ART / "odd.png")
    assert odd_image.size == (202, 102)
    assert max(abs(a-b) for a, b in zip(odd_image.getpixel((180, 80)), (32, 64, 128))) < 5
    sway("output HEADLESS-1 scale 1.5")
    time.sleep(.2)
    print("PASS static-frame cache, unavailable-driver fallback, strict hardware mode, odd dimensions", flush=True)

    sway("create_output")
    sway("output HEADLESS-1 bg #204080 solid_color")
    sway("output HEADLESS-2 mode 400x300 scale 2 position -200 50 bg #b04020 solid_color")
    background.terminate()
    background.wait(timeout=5)
    time.sleep(.3)
    run([EXE, "--fullscreen", "-o", ART / "mixed.png"])
    mixed = Image.open(ART / "mixed.png").convert("RGB")
    assert mixed.size == (1680, 800), mixed.size
    assert mixed.getpixel((200, 150)) == (176, 64, 32)
    assert mixed.getpixel((100, 50)) == (0, 0, 0)
    assert mixed.getpixel((400, 150)) == (32, 64, 128)
    assert mixed.getpixel((1679, 799)) == (32, 64, 128)
    run([EXE, "-g", "-40,60 100x71", "-o", ART / "mixed-crop.png"])
    crop = Image.open(ART / "mixed-crop.png").convert("RGB")
    assert crop.size == (200, 142)
    assert crop.getpixel((79, 30)) == (176, 64, 32)
    assert crop.getpixel((80, 30)) == (32, 64, 128)
    print("PASS mixed-scale outputs, negative origin, cross-output crop and black gaps", flush=True)

    proc = launch("disconnect", ["--record", "--fullscreen", "-o", ART / "disconnect.mp4"])
    time.sleep(.6)
    # IPC may close before swaymsg reads the exit reply; verify Sway itself.
    subprocess.run(["swaymsg", "-s", env["SWAYSOCK"], "exit"], env=env, capture_output=True, timeout=5)
    assert compositor.wait(timeout=5) == 0
    assert proc.wait(timeout=7) == 1
    run(["ffmpeg", "-v", "error", "-i", ART / "disconnect.mp4", "-f", "null", "-"])
    assert b"panic" not in (ART / "disconnect.log").read_bytes()
    print("PASS compositor disconnect finalizes partial video and exits cleanly", flush=True)
    (ART / "result.json").write_text(json.dumps({"passed": True, "video_frames": len(pts), "video_duration": stream["duration"], "largest_gap": max(b-a for a, b in zip(pts, pts[1:]))}, indent=2))
finally:
    if pointer:
        pointer.sock.close()
    for proc in children:
        if proc.poll() is None:
            proc.send_signal(signal.SIGCONT)
            proc.terminate()
            proc.wait(timeout=5)
    if compositor.poll() is None:
        if "SWAYSOCK" in env:
            subprocess.run(["swaymsg", "-s", env["SWAYSOCK"], "exit"], env=env, capture_output=True, timeout=5)
        else:
            compositor.terminate()
        compositor.wait(timeout=5)
    for log in logs:
        log.close()
    compositor_log.close()
    shutil.rmtree(RUNTIME)
    print(f"Artifacts: {ART}", flush=True)
