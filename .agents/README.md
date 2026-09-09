# Orb environment

Run `.agents/setup` from a Debian 12 Amp orb. It installs Zig 0.16.0,
native development dependencies, Pillow 11.3.0 for the orb's Python, and
fetches the packages pinned in `build.zig.zon`. Repeated runs reuse installed
packages and toolchains. No secrets, resume hook, or persistent services are
needed.

Debian's FFmpeg 5 is too old for the C bridge. Setup builds checksum-pinned
FFmpeg 8.1.2 shared libraries with the x264/VAAPI encoders and MP4/Matroska
muxers under `/opt/ouroshot-ffmpeg`. Debian's `ffmpeg` and `ffprobe` executables remain
available for decoding test output. This is a minimal development library
build, not a replacement general-purpose FFmpeg distribution. Its private
include prefix avoids mixing system FFmpeg headers with newer libraries.

Setup persists the pkg-config path in `.bash_profile` and registers the library
directory with ldconfig. Fresh login shells need no manual activation:

```sh
zig build test
zig build -Doptimize=ReleaseSafe
./zig-out/bin/ouroshot --help
```

## Integration limitations

Debian's Sway 1.7 lacks ext-image-copy-capture. Setup also builds a pinned,
headless-only Sway 1.11/wlroots 0.19.3 stack under `/opt/ouroshot-wayland`
using `.agents/setup-wayland`. The `sway` and `swaymsg` wrappers use its private
libraries without changing other programs' library search paths. Cairo,
Pango and Pixman are test-compositor dependencies, not ouroshot UI dependencies.
The CLI suite uses private transparent cursors and deterministic backgrounds;
it does not verify cursor inclusion. Service Screenshot uses the same region
selector; PickColor stays deferred and its production tests verify failure.

The orb has no DRM render device, so DMA-BUF/VAAPI runtime tests need a
GPU-equipped machine. The setup does not start or modify the active desktop.
