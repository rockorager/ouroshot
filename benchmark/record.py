#!/usr/bin/env python3
"""Compare end-to-end recording on a private GPU-backed headless Sway.

Usage: record.py BASELINE_EXE NEW_EXE NEW_ARTIFACT_DIR [WIDTH HEIGHT]
Requires sway, mpv, ffmpeg, ffprobe, a render node and VAAPI driver.
Each run records the same looping 60fps testsrc2 clip, or a static background.
CPU is recorder-only; it excludes compositor/player. This is not a display
latency test or a matched-quality encoder comparison.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

baseline, current, directory = sys.argv[1:4]
baseline, current = str(Path(baseline).resolve()), str(Path(current).resolve())
art = Path(directory).resolve()
art.mkdir(parents=True, exist_ok=False)
width, height = map(int, sys.argv[4:6]) if len(sys.argv) > 4 else (1920, 1080)
runtime = art / "runtime"
runtime.mkdir(mode=0o700)
env = dict(os.environ, XDG_RUNTIME_DIR=str(runtime), WLR_BACKENDS="headless",
           WLR_RENDERER="gles2", WLR_HEADLESS_OUTPUTS="1",
           WLR_RENDER_DRM_DEVICE=os.environ.get("WLR_RENDER_DRM_DEVICE", "/dev/dri/renderD128"))
for key in ("WAYLAND_DISPLAY", "SWAYSOCK", "WAYLAND_DEBUG"):
    env.pop(key, None)
(art / "sway.conf").write_text(f"output HEADLESS-1 mode {width}x{height}@60Hz scale 1\noutput * bg #204080 solid_color\nseat seat0 fallback true\nxwayland disable\n")

def run(args, **kwargs):
    return subprocess.run([str(a) for a in args], env=env, capture_output=True,
                          check=True, timeout=90, **kwargs)

run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", f"testsrc2=size={width}x{height}:rate=60",
     "-t", "3", "-c:v", "libx264", "-preset", "ultrafast", "-threads", "2", art / "source.mkv"])
results = []
player = None
with (art / "sway.log").open("wb") as log:
    compositor = subprocess.Popen(["sway", "-c", str(art / "sway.conf")], env=env, stdout=log, stderr=log)
    try:
        deadline = time.monotonic() + 5
        while not list(runtime.glob("sway-ipc*.sock")):
            assert compositor.poll() is None and time.monotonic() < deadline
            time.sleep(.05)
        env["WAYLAND_DISPLAY"] = next(p.name for p in runtime.glob("wayland-*") if not p.name.endswith(".lock"))
        env["SWAYSOCK"] = str(next(runtime.glob("sway-ipc*.sock")))
        time.sleep(.3)
        for workload in ("static", "motion"):
            for mode, exe, flags in [
                ("baseline", baseline, []),
                ("software", current, ["--capture", "shm", "--encoder", "software"]),
                ("upload", current, ["--capture", "shm", "--encoder", "vaapi"]),
                ("dmabuf", current, ["--capture", "dmabuf", "--encoder", "vaapi"]),
            ]:
                name = workload + "-" + mode
                with (art / (name + "-player.log")).open("wb") as player_log:
                    if workload == "motion":
                        player = subprocess.Popen(["mpv", "--no-config", "--no-audio", "--loop-file=inf",
                            "--fullscreen", "--vo=gpu", "--gpu-context=wayland", "--hwdec=no",
                            "--osd-level=0", "--input-default-bindings=no", str(art / "source.mkv")],
                            env=env, stdout=player_log, stderr=player_log)
                        time.sleep(.6)
                        assert player.poll() is None
                    output = art / (name + ".mp4")
                    with (art / (name + ".log")).open("wb") as capture_log:
                        start = time.monotonic()
                        recorder = subprocess.Popen([exe, "--record", "--fullscreen", "--fps", "60",
                            "--duration", "5", "-o", str(output), *flags], env=env,
                            stdout=subprocess.DEVNULL, stderr=capture_log)
                        while True:
                            pid, status, usage = os.wait4(recorder.pid, os.WNOHANG)
                            if pid:
                                recorder.returncode = os.waitstatus_to_exitcode(status)
                                break
                            if time.monotonic() - start > 15:
                                recorder.terminate()
                                recorder.wait(timeout=5)
                                raise TimeoutError(name)
                            time.sleep(.01)
                        wall = time.monotonic() - start
                    capture_log = (art / (name + ".log")).read_text()
                    assert recorder.returncode == 0, capture_log
                    if mode == "dmabuf":
                        assert "encoder=vaapi input=dma-buf" in capture_log
                    info = json.loads(run(["ffprobe", "-v", "error", "-show_streams", "-show_frames", "-of", "json", output]).stdout)
                    pts = [float(f["best_effort_timestamp_time"]) for f in info["frames"]]
                    assert len(pts) > 2 and all(b > a for a, b in zip(pts, pts[1:]))
                    run(["ffmpeg", "-v", "error", "-i", output, "-f", "null", "-"])
                    run(["ffmpeg", "-v", "error", "-ss", "2", "-i", output, "-frames:v", "1", art / (name + ".png")])
                    gaps = sorted((b-a)*1000 for a, b in zip(pts, pts[1:]))
                    row = dict(workload=workload, mode=mode, width=width, height=height,
                        frames=len(pts), duration=info["streams"][0]["duration"],
                        fps=(len(pts)-1)/(pts[-1]-pts[0]), gap_ms_p95=gaps[int(len(gaps)*.95)],
                        gap_ms_max=max(gaps), cpu_seconds=usage.ru_utime+usage.ru_stime,
                        wall_seconds=wall, rss_kib=usage.ru_maxrss, log=capture_log)
                    results.append(row)
                    (art / "results.json").write_text(json.dumps(results, indent=2))
                    print(json.dumps(row), flush=True)
                    if player:
                        player.terminate()
                        player.wait(timeout=5)
                        player = None
                    time.sleep(.3)
    finally:
        if player and player.poll() is None:
            player.terminate()
            player.wait(timeout=5)
        if compositor.poll() is None:
            if "SWAYSOCK" in env:
                subprocess.run(["swaymsg", "-s", env["SWAYSOCK"], "exit"], env=env, capture_output=True, timeout=5)
            else:
                compositor.terminate()
            compositor.wait(timeout=5)
print(f"Artifacts: {art}")
