#!/usr/bin/env python3
"""Real encoder outputs and service policy, without a GPU or compositor.

Build the fixture with zig build -Dservice-test-fixture=true first.
Optional output directory retains PNGs, videos and ffprobe metadata.
"""
import bisect
import ctypes as C
import json
import os
from pathlib import Path
import shlex
import struct
import subprocess
import sys
import tempfile
from urllib.parse import unquote, urlparse
import zlib

from PIL import Image
from service import Service, response, structured, tool_frame

ROOT = Path(__file__).resolve().parents[1]


def srgb_linear(value):
    return value / 12.92 if value <= 0.04045 else ((value + 0.055) / 1.055) ** 2.4


# Derive expected quantization from inverse-sRGB bin boundaries, rather than
# reproducing encode.c's forward function or reading its lookup table.
BOUNDARIES = [srgb_linear((i + .5) / 255) for i in range(255)]


def expected_channel(value):
    return bisect.bisect_right(BOUNDARIES, (value / 255) ** 2.2)


def chunks(path):
    data = Path(path).read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n"
    result = {}
    offset = 8
    while offset < len(data):
        size = struct.unpack_from(">I", data, offset)[0]
        name = data[offset + 4:offset + 8]
        payload = data[offset + 8:offset + 8 + size]
        crc = struct.unpack_from(">I", data, offset + 8 + size)[0]
        assert zlib.crc32(name + payload) == crc
        result[name] = payload
        offset += size + 12
    assert offset == len(data) and b"IEND" in result
    return result


def check_png(path, source, expected):
    metadata = chunks(path)
    assert not ({b"iCCP", b"gAMA", b"cHRM", b"cICP"} & metadata.keys()), metadata.keys()
    if source == "unknown":
        assert b"sRGB" not in metadata
    else:
        assert metadata[b"sRGB"] == b"\x01"  # relative colorimetric intent
    image = Image.open(path)
    assert list(image.convert("RGBA").getdata()) == expected


def check_video(path, expected, known, width, height):
    probe = subprocess.check_output(["ffprobe", "-v", "error", "-show_streams", "-show_frames", "-of", "json", str(path)])
    Path(str(path) + ".json").write_bytes(probe)
    info = json.loads(probe)
    assert (info["streams"][0]["width"], info["streams"][0]["height"]) == (width, height)
    for metadata in [info["streams"][0], *info["frames"]]:
        assert metadata["color_space"] == "bt709", metadata
        assert metadata["color_range"] == "tv", metadata
        assert metadata.get("color_transfer", "unknown") == ("iec61966-2-1" if known else "unknown"), metadata
        assert metadata.get("color_primaries", "unknown") == ("bt709" if known else "unknown"), metadata
    decoded = subprocess.check_output(["ffmpeg", "-v", "error", "-i", str(path), "-f", "rawvideo", "-pix_fmt", "rgb24", "-"])
    size = width * height * 3
    assert len(decoded) >= size * 2
    for offset in range(0, len(decoded), size):
        for x, y, pixel in expected:
            start = offset + (y * width + x) * 3
            actual = decoded[start:start + 3]
            assert max(abs(a - b) for a, b in zip(actual, pixel)) <= 3, (path, x, y, list(actual), pixel)


def main():
    art = Path(sys.argv[1] if len(sys.argv) > 1 else tempfile.mkdtemp(prefix="ouroshot-encoding-")).resolve()
    art.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="ouroshot-encoder-lib-") as scratch:
        library = Path(scratch) / "encode.so"
        flags = shlex.split(subprocess.check_output(["pkg-config", "--cflags", "--libs", "libpng", "libavcodec", "libavformat", "libavutil", "libavfilter", "libswscale", "libva", "gbm", "libdrm"], text=True))
        subprocess.run(["cc", "-shared", "-fPIC", "-O2", "-std=c11", "-D_POSIX_C_SOURCE=200809L", "-Wall", "-Wextra", str(ROOT / "src/encode.c"), "-o", str(library), *flags, "-lm"], check=True)
        lib = C.CDLL(str(library))
        lib.shot_source_encoding.argtypes = [C.c_char_p]
        lib.shot_png.argtypes = [C.c_char_p, C.c_void_p, C.c_int, C.c_int, C.c_int]
        lib.shot_png_fd.argtypes = [C.c_int, C.c_void_p, C.c_int, C.c_int, C.c_int]
        lib.shot_video_open.argtypes = [C.c_char_p, C.c_int, C.c_int, C.c_int, C.c_char_p, C.c_char_p, C.c_void_p, C.c_int, C.c_int]
        lib.shot_video_open.restype = C.c_void_p
        lib.shot_video_frame.argtypes = [C.c_void_p, C.c_void_p, C.c_int, C.c_int64]
        lib.shot_video_repeat.argtypes = [C.c_void_p, C.c_int64]
        lib.shot_video_close.argtypes = [C.c_void_p]

        assert expected_channel(16) == 7
        assert round(srgb_linear(7 / 255) ** (1 / 2.2) * 255) == 16
        # If the converted byte is instead redisplayed untagged as gamma22,
        # its luminance is much lower than the original capture's luminance.
        assert (7 / 255) ** 2.2 < (16 / 255) ** 2.2 / 5
        assert [expected_channel(i) for i in (0, 1, 2, 3, 4, 16, 20, 21, 255)] == [0, 0, 0, 0, 0, 7, 12, 13, 255]

        # All 256 codes, asymmetric channels, and straight alpha at 0..255.
        # Two rows catch row stepping; nonopaque pixels catch alpha conversion
        # and accidental premultiplication/unpremultiplication by PNG writers.
        pixels = [(i, 255 - i, (i * 37) % 256, i) for i in range(256)] * 2
        bgra = bytes(c for r, g, b, a in pixels for c in (b, g, r, a))
        data = C.create_string_buffer(bgra)
        for source in ("unknown", "srgb", "gamma22"):
            encoding = lib.shot_source_encoding(source.encode())
            expected = [(expected_channel(r), expected_channel(g), expected_channel(b), a) for r, g, b, a in pixels] if source == "gamma22" else pixels
            for fd_writer in (False, True):
                path = art / f"{source}-{'fd' if fd_writer else 'path'}.png"
                if fd_writer:
                    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                    assert lib.shot_png_fd(fd, data, 256, 2, encoding) == 0
                else:
                    assert lib.shot_png(os.fsencode(path), data, 256, 2, encoding) == 0
                check_png(path, source, expected)
                assert data.raw[:-1] == bgra, "export mutated source/preview storage"

            # Padded RGB0 and BGR0 with deliberately nonopaque unused bytes.
            # Solid quadrants avoid chroma-edge ambiguity, but distinguish the
            # transfer, channels, stride, and repeated cached-frame behavior.
            colors = [(16, 16, 16), (16, 64, 128), (0, 21, 255), (204, 34, 68)]
            expected_colors = [tuple(map(expected_channel, color)) for color in colors] if source == "gamma22" else colors
            for rgba in (0, 1):
                width, height, stride = 128, 96, 128 * 4 + 28
                raw = bytearray()
                for y in range(height):
                    for x in range(width):
                        rgb = colors[(y >= 48) * 2 + (x >= 64)]
                        raw.extend((*(rgb if rgba else rgb[::-1]), (x + y) % 256))
                    raw.extend(b"\xef" * 28)
                frame = C.create_string_buffer(bytes(raw))
                path = art / f"{source}-{'rgb' if rgba else 'bgr'}.mp4"
                video = lib.shot_video_open(os.fsencode(path), width, height, 30, b"software", b"", None, rgba, encoding)
                assert video
                assert lib.shot_video_frame(video, frame, stride, 0) == 0
                assert lib.shot_video_repeat(video, 33333) == 0
                assert lib.shot_video_frame(video, frame, stride, 66666) == 0
                assert lib.shot_video_close(video) == 0
                assert frame.raw[:-1] == bytes(raw)
                samples = [(32, 24), (96, 24), (32, 72), (96, 72)]
                check_video(path, [(x, y, color) for (x, y), color in zip(samples, expected_colors)], source != "unknown", width, height)

            # Exercise configuration -> worker -> secure artifact publication.
            with tempfile.TemporaryDirectory(prefix="ouroshot-policy-") as runtime:
                service = Service(runtime, ["--source-encoding", source])
                try:
                    with service.connect(tool_frame()) as sock:
                        service.pending()
                        service.gate()
                        path = Path(unquote(urlparse(structured(response(sock))["uri"]).path))
                    pixels_fixture = [(204, 102, 51, 255), (68, 34, 17, 255)]
                    expected_fixture = [(*map(expected_channel, p[:3]), p[3]) for p in pixels_fixture] if source == "gamma22" else pixels_fixture
                    check_png(path, source, expected_fixture)
                    (art / f"service-{source}.png").write_bytes(path.read_bytes())
                finally:
                    service.stop()

        for binary in ("ouroshot", "ouroshot-service"):
            result = subprocess.run([str(ROOT / "zig-out/bin" / binary), "--source-encoding", "monitor"], capture_output=True)
            assert result.returncode != 0 and b"InvalidSourceEncoding" in result.stderr
        result = subprocess.run([str(ROOT / "zig-out/bin/ouroshot"), "--record", "--source-encoding", "gamma22", "--capture", "dmabuf"], capture_output=True)
        assert result.returncode != 0 and b"Gamma22RequiresShmCapture" in result.stderr
    print(f"PASS PNG path/fd/alpha/all codes, video pixels/metadata/stride/cache, service policies; artifacts: {art}")


if __name__ == "__main__":
    main()
