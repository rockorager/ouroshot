#!/usr/bin/env python3
"""Bounded encoder-only benchmark. Excludes capture and input generation.

Usage: encode.py LIBRARY OUTPUT WIDTH HEIGHT [software|vaapi|baseline]
The baseline API is retained for comparing the original encoder shared library.
"""
import ctypes as C
import json
from pathlib import Path
import resource
import sys
import time
from PIL import Image, ImageDraw

library, output, width, height = sys.argv[1:5]
mode = sys.argv[5] if len(sys.argv) > 5 else "software"
width, height = int(width), int(height)
lib = C.CDLL(library)
lib.shot_video_open.restype = C.c_void_p
lib.shot_video_open.argtypes = [C.c_char_p, C.c_int, C.c_int, C.c_int]
lib.shot_video_frame.argtypes = [C.c_void_p, C.c_void_p, C.c_int64]
lib.shot_video_close.argtypes = [C.c_void_p]
if mode != "baseline":
    lib.shot_video_open.argtypes += [C.c_char_p, C.c_char_p, C.c_void_p, C.c_int]
    lib.shot_video_frame.argtypes = [C.c_void_p, C.c_void_p, C.c_int, C.c_int64]
frames = []
for i in range(8):
    image = Image.new("RGB", (width, height))
    draw = ImageDraw.Draw(image)
    for y in range(0, height, 64):
        for x in range(0, width, 64):
            draw.rectangle((x, y, x+63, y+63), fill=((x//8+37)%256, (y//8+71)%256, (x//16+y//8)%256))
    draw.rectangle((i*width//16, height//4, i*width//16+width//4, height//2), fill=(240, 210, 150))
    frames.append(C.create_string_buffer(image.tobytes("raw", "BGRX")))
args = [output.encode(), width, height, 60]
if mode != "baseline": args += [mode.encode(), b"/dev/dri/renderD128", None, 0]
video = lib.shot_video_open(*args)
assert video, "encoder initialization failed"
usage = resource.getrusage(resource.RUSAGE_SELF)
cpu_start = usage.ru_utime + usage.ru_stime
start = time.monotonic()
times = []
for i in range(180):
    before = time.monotonic()
    args = [video, frames[i % len(frames)]]
    if mode != "baseline": args += [width*4]
    args += [i*1000000//60]
    assert lib.shot_video_frame(*args) == 0
    times.append((time.monotonic()-before)*1000)
assert lib.shot_video_close(video) == 0
wall = time.monotonic()-start
usage = resource.getrusage(resource.RUSAGE_SELF)
times.sort()
result = dict(mode=mode, width=width, height=height, frames=180, wall_seconds=wall,
              cpu_seconds=usage.ru_utime+usage.ru_stime-cpu_start,
              encode_fps=180/wall, frame_ms_p50=times[90], frame_ms_p95=times[171],
              max_rss_kib=usage.ru_maxrss)
Path(output+".json").write_text(json.dumps(result, indent=2)+"\n")
print(json.dumps(result))
