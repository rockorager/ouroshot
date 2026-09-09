# Recording measurements — 2026-09-09

Measured on Arch Linux, Intel Lunar Lake integrated graphics (`xe`,
`/dev/dri/renderD128`), Mesa 26.2.2, Sway 1.12, FFmpeg 9.0.1, Zig 0.16.0
ReleaseFast. Tests used a private GLES2 headless Sway, not the active Ouro
session. The Intel media driver 26.2.4 and gmmlib 22.10.0 were extracted into
an isolated directory; no system packages or session configuration changed.

Five-second recordings, 60 fps ceiling, 1× output scale, looping 60 fps testsrc2
video displayed by mpv. CPU time covers the recorder, including initialization
and finalization, not Sway/mpv. These are single-run observations, not stable
benchmark distributions. H.264 quality differs: x264 CRF 18 versus VAAPI CQP 20.

| Moving content | Original SHM/x264 | New ext SHM/x264 | New ext SHM/VAAPI upload | New ext DMA-BUF/VAAPI |
|---|---:|---:|---:|---:|
| 1080p CPU seconds | 4.03 | 3.48 | 0.71 | 0.51 |
| 1080p captured frames | 156 | 260 | 214 | 295 |
| 1080p encoded frames | 156 | 301 | 297 | 301 |
| 1080p peak RSS MiB | 189 | 183 | 80 | 91 |
| 4K CPU seconds | 7.40 | 8.73 | 1.79 | 0.69 |
| 4K captured frames | 102 | 129 | 154 | 157 |
| 4K encoded frames | 102 | 257 | 297 | 274 |
| 4K peak RSS MiB | 594 | 540 | 127 | 91 |

Cached repeats maintain the recording timeline, but do not add new motion
samples. The 4K DMA run therefore delivered about **31 fresh captures/sec**, not
55 distinct frames/sec. This test does not establish 4K60 capture. The capture,
headless compositor/player, and synchronous conversion limits need separate
stage timing before attributing the remaining ceiling to one component.

For static 4K content, DMA/VAAPI used 0.145 CPU-seconds and one capture plus
300 cached repeats, versus 5.62 CPU-seconds and 109 repeated full captures in
the original version. Both software and hardware caches avoid recopying and
reconverting unchanged pixels; hardware also removes most encoder CPU work.

Retained machine-local artifacts:

- `/home/tim/ouroshot-test-results/performance-20260909/record-1080-final/`
- `/home/tim/ouroshot-test-results/performance-20260909/record-4k/`
- `/home/tim/ouroshot-test-results/performance-20260909/final-gpu/`
- `/home/tim/ouroshot-test-results/performance-20260909/final-shm/`

Each benchmark directory contains `results.json`, videos, decoded sample
images, and client/compositor/player logs. Integration tests verify off-center
native crops with odd origins, colors, static frames, missing-driver fallback,
odd-size padding, cancellation/signals, and partial-file finalization. The
hardware decoded sample was also visually inspected. The 400 ms induced stall
remained a 405 ms timestamp gap, rather than shortening the movie.

Executable SHA-256 provenance (local, uncommitted ouroshot repository):

- Original: `8c3fac5ade8d8201df16d46bff1d1b256a2aa19d16ec59dfcf0983355ef65616`
- Profiled optimized build (`ouroshot-profiled` in the artifact root):
  `47d2c230b8157779fa20d10b80a5e3a5acf475f117cfaf697d10bbd26f410d06`
- Final ReleaseFast build: `2803158e1d67ca45692a62bd931440923cbb3eb9012db410b73811f5abbe3850`

After profiling, the final build changed only the cold-path descriptor
duplication call and C header import configuration to support ReleaseSafe with
Arch's fortified glibc headers. Encoding and frame pacing are unchanged.
The ReleaseSafe GPU integration suite passed afterward (`safe-gpu/` artifacts).

Run `record.py OLD_EXE NEW_EXE NEW_ARTIFACT_DIR [WIDTH HEIGHT]` to reproduce.
`encode.py LIBRARY OUTPUT WIDTH HEIGHT [baseline|software|vaapi]` is an
encoder-only control; compile `src/encode.c` as a shared library using the same
pkg-config dependencies as `build.zig`. It excludes capture and source creation,
so its throughput is not a screen-recording frame rate.
