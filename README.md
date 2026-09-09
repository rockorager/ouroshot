# ouroshot

A Wayland region selector, screenshot tool, and screen recorder in Zig 0.16
using [wayring](https://github.com/rockorager/wayring) for the Wayland connection,
generated protocols, and io_uring event loop. No slurp, grim, or FFmpeg subprocess
is used by the application. A small C bridge calls libpng and FFmpeg libraries.

Recording prefers the newer `ext-image-copy-capture-v1` protocol and a GPU path
on compatible outputs: DMA-BUF capture → VAAPI crop/color conversion → H.264.

## Build and run

Requires Linux, Zig 0.16.0, pkg-config, libpng, and FFmpeg development libraries
(`libavcodec`, `libavformat`, `libavutil`, `libavfilter`, `libswscale`) with libx264
and VAAPI support, plus libva, GBM, and libdrm. On Arch: `libpng`, `ffmpeg`,
`libva`, `mesa`, and `libdrm`. Hardware encoding also needs the GPU's VAAPI driver
(for recent Intel GPUs, `intel-media-driver`). Without it, auto mode uses libx264.

```sh
zig build -Doptimize=ReleaseFast
zig build test
./zig-out/bin/ouroshot --help
```

The executable stays in `zig-out/bin`; this does not install it into the session
or change any keybindings. Wayring and protocol XML dependencies are pinned in
`build.zig.zon`. No libwayland connection is used.

```sh
# Freeze the desktop, drag a rectangle, save its original pixels.
./zig-out/bin/ouroshot -o screenshot.png

# Select over live content, then capture after removing the overlay.
./zig-out/bin/ouroshot --live -o screenshot.png

# Full desktop or explicit logical-coordinate region, no selector.
./zig-out/bin/ouroshot --fullscreen -o desktop.png
./zig-out/bin/ouroshot -g '100,80 640x360' -o region.png

# Slurp-compatible geometry or PNG on stdout.
./zig-out/bin/ouroshot --geometry-only
./zig-out/bin/ouroshot -o - > screenshot.png

# Open a successful capture in Gradia, keeping it as the image editor.
./zig-out/bin/ouroshot -o screenshot.png && gradia screenshot.png

# Select a region and record it. Ctrl-C or SIGTERM finalizes the file.
./zig-out/bin/ouroshot --record -o recording.mp4
./zig-out/bin/ouroshot --record --fullscreen --fps 30 --duration 10 -o recording.mkv

# Require the hardware path (fail rather than silently use a fallback).
./zig-out/bin/ouroshot --record --capture dmabuf --encoder vaapi -o gpu.mp4

# Explicit fallback/control, still using ext-image-copy when available.
./zig-out/bin/ouroshot --record --capture shm --encoder software -o cpu.mp4
```

Escape or right click cancels selection (exit status 130, no output file).
Existing destination files are never overwritten. `--cursor` includes the
cursor in captures; it is excluded by default. `--list-outputs` prints logical
output geometry. Run from the target Wayland session or explicitly set its
`XDG_RUNTIME_DIR` and `WAYLAND_DISPLAY`.

## Capture and selection

Screenshots and compatibility recording use **wlr-screencopy**. Single-output,
untransformed recording prefers **ext-image-copy-capture-v1**, with either SHM
or DMA-BUF buffers. Interactive selection also needs
layer-shell and a pointer seat. Xdg-output supplies logical coordinates;
fractional-scale plus viewporter avoid integer-scale oversizing where supported.
Without these protocols, integer buffer scaling is the fallback. Cursor-shape
selects a crosshair when available.

The default screenshot captures before opening the selector. Its opaque frozen
preview is separate from the original capture, so neither the dimming nor the
border appears in the saved image. `--live`, geometry-only, and recording use a
translucent live selector instead. Selection surfaces are unmapped and input
leave events drained before live capture starts.

Selection uses two SHM buffers per output. Rendering waits for buffer release
and coalesces pointer updates with frame callbacks. Each reused buffer repairs
its previous selection; compositor damage covers the last displayed selection
and the new one, not the entire output on every movement. The initial buffer
fill is full-size. Large selection bounds can still cause substantial work.

Geometry is in logical compositor coordinates, including negative origins.
Regions are clipped to the desktop bounds. Single-output crops copy native
pixels without filtering and round partial edge pixels outward. Multi-output
captures use the highest intersecting output's scale, rounded up to 1/120,
with nearest-neighbor sampling of lower-resolution outputs. Gaps are black.
All eight output transforms and padded/inverted capture buffers are handled.

## Recording behavior and limits

Recording records live frames, not the frozen selector image. Defaults are
30 fps maximum and automatic capture/encoder selection:

- DMA-BUF: negotiates a single-plane linear XRGB8888 buffer on the compositor's
  GPU, imports it into VAAPI, and crops/converts to a separate NV12 surface on
  the GPU. The recorder does not map/copy RGB pixels through CPU memory.
- SHM: borrows the native crop using its row stride, avoiding extra full-image
  copies for ordinary single-output recording. VAAPI can upload that crop and
  encode it; software encoding uses libswscale and libx264. Rotated and
  multi-output captures still use CPU normalization/composition.
- Unchanged ext capture: keeps one request pending and reuses the last converted
  video frame. It does not reread a buffer the compositor may be writing.

VAAPI uses H.264 CQP 20; software uses CRF 18, `veryfast`, two encoder threads.
These are different quality controls, not quality-equivalent settings. Video
is lossy 8-bit YUV420 SDR; PNG is the lossless path. Odd dimensions fall back to
software and are padded to even dimensions on the right/bottom, not rescaled.
There is no audio.

`--encoder auto|software|vaapi` and `--capture auto|shm|dmabuf` choose recording
paths. Explicit `vaapi`/`dmabuf` requirements fail when unavailable. `--device`
selects a DRM render node; DMA allocation must match the compositor's GPU.
Startup prints the actual capture protocol, encoder, and buffer path. Auto
falls back during setup; a runtime capture/encoding failure ends the partial
recording rather than silently changing its format.

Monotonic arrival time drives the video timeline, including static-frame
repeats: source presentation timestamps can predate the start of recording.
Capture and encoding have no unbounded pending-frame queue: overload reduces
frame rate rather than accumulating frames or speeding up playback. The
DMA-BUF is reused only after capture readiness and GPU conversion completion;
the encoder retains its own converted surfaces. Captures from multiple outputs
are not synchronized. Normal stop flushes encoder packets and the container trailer.
On capture failure/disconnect, the program attempts to finalize the partial
recording and exits nonzero. SIGKILL or a machine crash cannot finalize MP4.

Current limitations:

- The fast path currently requires one untransformed output, even crop
  dimensions, a shared render device, and linear XRGB8888 DMA-BUF support.
  Multi-output/rotated recording and screenshots retain the older protocol.
- Ext capture buffers cover the output even for small crops; the compositor
  may optimize their updates using damage. The encoder only converts the crop.
- No audio or PipeWire ScreenCast portal. No promise of 4K/120 Hz recording.
- 8-bit SDR capture only; no HDR conversion or ICC profile embedding. Captured
  bytes are used as supplied by the compositor; video conversion assumes sRGB
  primaries/transfer and BT.709 YUV coefficients.
- No promise of seamless output hotplug or layout changes during selection or
  recording. Restart capture after changing the output layout.

## Tests

```sh
zig build test
python test/integration.py
```

The integration test starts its own **headless Sway** with a private runtime
directory, generates a known background, injects virtual pointer events there,
and tears down that compositor. It never uses the active desktop. Requires
Sway, swaybg, grim, ffmpeg/ffprobe, and Python Pillow. Optional arguments are the
executable path and a new artifact directory.

Tests cover native/cropped/stdout PNG pixels, 150% and uneven fractional scaling,
rotation/reflection against grim, frozen-image integrity, shrinking/reversed
selection, cancellation, live overlay exclusion, mixed-scale negative-origin
outputs, video colors/timestamps, a deliberately stalled recorder, signal stop,
and partial-file finalization on compositor disconnect. Screenshots and logs
are retained in the printed artifact directory.

For GPU-backed headless tests, set `OUROSHOT_TEST_RENDERER=gles2` and
`WLR_RENDER_DRM_DEVICE=/dev/dri/renderD128`, with a working VAAPI driver. This
requires actual DMA-BUF recording and checks decoded native crops (including
odd crop origins), colors, static-frame reuse, fallback, and signal finalization.
It still does not test the active Ouro desktop or physical input-to-photon latency.

`benchmark/record.py OLD_EXE NEW_EXE NEW_ARTIFACT_DIR [WIDTH HEIGHT]` compares
recorder-only CPU time, frame timestamps, and memory using a private GPU-backed
headless Sway and the same looping 60 fps clip. It includes capture and encoding,
but excludes compositor/player CPU and does not equate encoder quality settings.
`benchmark/encode.py` is an encoder-only control excluding capture and input
generation. Both retain videos and machine-readable results.

## Native Varlink capture service

`zig build` also produces **ouroshot-service**. This is independent of the CLI:
normal screenshot, geometry and recording commands do not acquire service
consent prompts. No D-Bus code runs in ouroshot. The separately developed
ourobridge Screenshot adapter translates portal requests to this native API.

**Native service UI is deferred.** Both `Screenshot` and `PickColor` currently
return `dev.rockorager.ouro.Capture.Failed` for valid requests (portal response 2
through ourobridge). They do not connect to Wayland, start a capture worker, or
create images. Removing the UI does not grant silent approval. The existing
direct CLI selector, screenshots and recording still work normally.

The wire contract is [dev.rockorager.ouro.Capture](protocol/dev.rockorager.ouro.Capture.varlink),
copied from the renamed ourobridge contract. Method validation and
`org.varlink.service` discovery remain available. One connection carries one
NUL-terminated JSON request and one final reply. Frames are limited to 64 KiB
including NUL; pipelining, streaming, upgrade and one-way calls are unsupported.
There are at most 64 live connections. Worker cancellation, Busy policy and
artifact publication infrastructure remain covered by the isolated test fixture.

### Launch and socket activation

From a Wayland session, run `zig-out/bin/ouroshot-service` directly for native
clients. It binds `$XDG_RUNTIME_DIR/ouro/capture.sock` without replacing an
existing endpoint. `XDG_RUNTIME_DIR` must be an absolute, user-owned 0700
directory with no symlink components. Service storage uses Linux `openat2`,
`O_TMPFILE`, and `/proc/self/fd`; unsupported runtime filesystems fail closed.

The files in [systemd/](systemd/) are **inert packaging examples**. Nothing in
the build installs/enables user units or changes portal routing. A packager can
place them in the systemd user unit directory and adjust `ExecStart` for the
installed executable. The desktop must supply `WAYLAND_DISPLAY` and
`XDG_RUNTIME_DIR` to its user service manager (for example, import the session's
Wayland environment before starting `graphical-session.target`).

`ouroshot-capture.socket` uses `%t/ouro/capture.sock`, `Accept=no`, socket mode
0600 and directory mode 0700. systemd owns the listener and starts one
`Type=exec` service when a client connects. The service validates `LISTEN_PID`,
exactly one listening AF_UNIX/SOCK_STREAM fd, its address, ownership and mode.
It is not `Type=oneshot` and does not spawn overlapping selectors per connection.

The daemon exits normally after **30 seconds with no connections or worker**;
systemd's listener remains available for reactivation. A request has a five-minute
monotonic deadline, including input and response I/O. `--idle-ms` and
`--timeout-ms` permit shorter isolated tests (both limited to 1–300000 ms).
The retained worker infrastructure cancels work on EOF before final result
commit or on service shutdown. A parent-death signal prevents orphan workers
after a crash; these paths are currently exercised only by the test fixture.

Initial deployment assumes **one active desktop per Unix user/runtime**. It
does not choose among simultaneous desktop sessions. No unit or portal setting
has been enabled automatically; desktop routing and frontend document export
must be configured and verified separately through ourobridge.

### Consent, colors, and artifacts

Future successful service operations must require native user input, regardless of
`require_confirmation`, `permission_store_checked`, `origin`, or `app_id`.
`SO_PEERCRED` must identify the service's effective UID. Claimed application
identity is attribution, not authorization.
This is not an isolation boundary against malicious processes already able to
modify the same user's runtime, inject compositor input, or trace its processes.

The service's Cairo consent card, region instructions and color picker have
been removed pending a future UI design. Ouroshot does not link Cairo or Pango.
`modal`, `interactive` and `parent_window` remain hints, not authority.

The color contract still requires exactly three finite sRGB-encoded components
in [0,1]. Wlr-screencopy and 8-bit SDR alone do not establish sRGB. A future
picker must supply reliable source metadata/conversion or an explicit native
desktop guarantee. The former `--capture-source-srgb` option is removed along
with the picker; no request parameter can enable capture.

The retained artifact writer does not falsely attach an sRGB/gamma profile.
An unnamed 0600 PNG is written and closed by the worker; only then is it atomically
linked under a random name in the user-owned 0700 `ouro/captures` directory.
No destination is overwritten and no caller supplies an output path. Successful
fixture replies contain correctly percent-encoded absolute `file:///` URIs;
the production service currently returns no images.

Once committed, a successful file survives disconnects, idle exit, and service
or bridge restarts. Ambiguous send/disconnect races retain the file rather than
deleting an image a frontend may already be exporting. There is no export ack,
idle cleanup or eviction: runtime/session teardown owns cleanup. Uncommitted
files disappear on cancellation/crash without scanning or deleting other files.
There is currently no storage quota; runtime filesystem limits can reject new
captures, but existing results are never evicted.

Native example (requires `varlinkctl`):

```sh
varlinkctl info "$XDG_RUNTIME_DIR/ouro/capture.sock"
varlinkctl introspect "$XDG_RUNTIME_DIR/ouro/capture.sock" dev.rockorager.ouro.Capture
varlinkctl call "$XDG_RUNTIME_DIR/ouro/capture.sock" dev.rockorager.ouro.Capture.Screenshot \
  '{"context":{"app_id":"org.example.Native","parent_window":"","origin":"native","require_confirmation":true,"permission_store_checked":false},"modal":true,"interactive":true}'
# Screenshot and PickColor currently return dev.rockorager.ouro.Capture.Failed.
```

### Service verification

```sh
zig build test
zig build -Dservice-test-fixture=true
python3 test/service.py
python3 test/service_unavailable.py
# Real bridge/native integration; the test owns the frontend name, not a real
# xdg-desktop-portal instance. Requires Python dbus in that interpreter.
dbus-run-session -- env OUROSHOT_PRIVATE_TEST_BUS=1 /usr/bin/python3 \
  test/service_unavailable.py --bridge /path/to/ourobridge
```

The additional **ouroshot-service-fixture** executable replaces only the capture
worker with a deterministic stdin consent gate. Never install it as the service.
The production binary has no fixture or confirmation-bypass option. Transport
tests use real Unix sockets, real worker processes, and inherited listening fds;
they cover framing/type errors, Busy, cancellation of pending work, late results,
PNG modes/URI encoding, and idle exit/reactivation with retained results.

The production test verifies both methods fail regardless of caller hints,
without a worker, image, or even an attempted Wayland connection. Optional real
ourobridge integration checks that these failures become portal response 2.
This is not successful capture or document-export verification.

The CLI integration suite still renders its selector on private headless Sway.
Test cursors are transparent to isolate image pixels; cursor inclusion is not
verified. Orb setup includes Cairo/Pango/Pixman dependencies for building that
test compositor, not for ouroshot's UI. GPU/DRM/VAAPI, future service UI, real
portal document export and Gradia still need their own verification.
