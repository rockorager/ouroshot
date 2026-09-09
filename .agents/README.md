# Orb environment

Run `.agents/setup` from a Debian 12 Amp orb. It installs Zig 0.16.0,
native development dependencies, Pillow 11.3.0 for the orb's Python, and
fetches the packages pinned in `build.zig.zon`. Repeated runs reuse installed
packages and toolchains. No secrets, resume hook, or persistent services are
needed.

Debian's FFmpeg 5 is too old for the C bridge. Setup builds checksum-pinned
FFmpeg 8.1.2 shared libraries with the x264/VAAPI encoders and MP4/Matroska
muxers under `/usr/local`. Debian's `ffmpeg` and `ffprobe` executables remain
available for decoding test output. This is a minimal development library
build, not a replacement general-purpose FFmpeg distribution.

The tools are available to fresh login shells without activation:

```sh
zig build test
zig build -Doptimize=ReleaseSafe
./zig-out/bin/ouroshot --help
```

## Integration limitations

Setup installs Debian's Sway, swaybg, and grim for private headless testing.
Sway 1.7 is not sufficient for the full `test/integration.py` suite: it lacks
the ext-image-copy-capture protocol required by the recording assertions.
Verification also encountered a live-preview pixel assertion failure after
the initial PNG and frozen-selection checks passed. Do not treat this
environment as a passing integration-test baseline. Full integration testing
needs a newer Sway/wlroots stack (the repository's recorded test environment
uses Sway 1.12).

The orb has no DRM render device, so DMA-BUF/VAAPI runtime tests need a
GPU-equipped machine. The setup does not start or modify the active desktop.
