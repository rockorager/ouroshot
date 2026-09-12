const std = @import("std");
const client = @import("client.zig");
const c = client.c;
const Rect = @import("geometry.zig").Rect;
const allocator = std.heap.smp_allocator;

const help =
    \\Usage: ouroshot [options]
    \\  Drag to select; Escape or right click cancels.
    \\  -o, --output PATH    PNG destination (default ouroshot.png); - writes stdout
    \\  -g, --geometry RECT  Capture "x,y WIDTHxHEIGHT" in logical coordinates
    \\  --fullscreen         Capture all outputs without selecting
    \\  --geometry-only      Select and print slurp-compatible geometry
    \\  --live               Select over live content instead of a frozen capture
    \\  --cursor             Include the cursor in captures
    \\  --record             Record H.264 (default ouroshot.mp4), Ctrl-C stops
    \\  --fps N              Recording frame-rate ceiling (default 30, max 120)
    \\  --duration SECONDS   Stop recording after this duration
    \\  --encoder MODE       auto (default), software, or vaapi
    \\  --capture MODE       auto (default), shm, or dmabuf (recording)
    \\  --device PATH        DRM render node for hardware encoding/capture
    \\  --source-encoding E  unknown (default), srgb, or gamma22 (sRGB primaries)
    \\  --list-outputs       Print logical output geometry
    \\  -h, --help           Print this help
    \\Existing files are never overwritten. Recording prefers ext-image-copy +
    \\DMA-BUF/VAAPI, with SHM/software fallback. gamma22 exports convert to sRGB
    \\and require SHM recording. Unknown sources keep bytes without color claims.
    \\
;

const Options = struct {
    output: ?[:0]const u8 = null,
    geometry: ?Rect = null,
    fullscreen: bool = false,
    geometry_only: bool = false,
    live: bool = false,
    cursor: bool = false,
    record: bool = false,
    list: bool = false,
    fps: u32 = 30,
    duration: ?u32 = null,
    encoder: [:0]const u8 = "auto",
    capture: [:0]const u8 = "auto",
    device: [:0]const u8 = "",
    source_encoding: c_int = c.SHOT_SOURCE_UNKNOWN,
};

fn write(text: []const u8) !void {
    var offset: usize = 0;
    while (offset < text.len) {
        const n = c.write(1, text.ptr + offset, text.len - offset);
        if (n <= 0) return error.OutputFailed;
        offset += @intCast(n);
    }
}

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        if (err != error.Cancelled and err != error.Interrupted) std.debug.print("ouroshot: {s}\n", .{@errorName(err)});
        std.process.exit(if (err == error.Cancelled or err == error.Interrupted) 130 else 1);
    };
}

fn run(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var options: Options = .{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) return write(help);
        if (std.mem.eql(u8, arg, "--record")) {
            options.record = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--fullscreen")) {
            options.fullscreen = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--geometry-only")) {
            options.geometry_only = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--live")) {
            options.live = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--cursor")) {
            options.cursor = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--list-outputs")) {
            options.list = true;
            continue;
        }
        if (i + 1 >= args.len) return error.MissingOptionValue;
        i += 1;
        if (std.mem.eql(u8, arg, "--encoder")) {
            options.encoder = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--capture")) {
            options.capture = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--device")) {
            options.device = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--source-encoding")) {
            options.source_encoding = c.shot_source_encoding(args[i]);
            if (options.source_encoding < 0) return error.InvalidSourceEncoding;
            continue;
        }
        if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) options.output = args[i] else if (std.mem.eql(u8, arg, "-g") or std.mem.eql(u8, arg, "--geometry")) options.geometry = try Rect.parse(args[i]) else if (std.mem.eql(u8, arg, "--fps")) options.fps = try std.fmt.parseInt(u32, args[i], 10) else if (std.mem.eql(u8, arg, "--duration")) options.duration = try std.fmt.parseInt(u32, args[i], 10) else return error.UnknownOption;
    }
    if (!std.mem.eql(u8, options.encoder, "auto") and !std.mem.eql(u8, options.encoder, "software") and !std.mem.eql(u8, options.encoder, "vaapi")) return error.InvalidEncoder;
    if (!std.mem.eql(u8, options.capture, "auto") and !std.mem.eql(u8, options.capture, "shm") and !std.mem.eql(u8, options.capture, "dmabuf")) return error.InvalidCaptureMode;
    if (std.mem.eql(u8, options.capture, "dmabuf") and std.mem.eql(u8, options.encoder, "software")) return error.DmaRequiresHardwareEncoder;
    if (options.source_encoding == c.SHOT_SOURCE_GAMMA22 and std.mem.eql(u8, options.capture, "dmabuf")) return error.Gamma22RequiresShmCapture;
    if (options.fps == 0 or options.fps > 120 or (options.duration != null and (options.duration.? == 0 or options.duration.? > 86400))) return error.InvalidRecordingRateOrDuration;
    if (options.geometry_only and (options.record or options.output != null)) return error.IncompatibleOptions;
    if (options.fullscreen and options.geometry != null) return error.IncompatibleOptions;
    if (!options.record and options.duration != null) return error.DurationRequiresRecording;
    const path = options.output orelse if (options.record) "ouroshot.mp4" else "ouroshot.png";
    if (options.record and !std.mem.endsWith(u8, path, ".mp4") and !std.mem.endsWith(u8, path, ".mkv")) return error.VideoRequiresMp4OrMkv;
    c.shot_signals();
    var app: client.Client = undefined;
    try app.init(init.minimal.environ);
    defer app.deinit();
    var text: [512]u8 = undefined;
    if (options.list) {
        for (app.outputs[0..app.output_count]) |output| try write(try std.fmt.bufPrint(&text, "{s}: {d},{d} {d}x{d}\n", .{ std.mem.sliceTo(&output.name, 0), output.rect.x, output.rect.y, output.rect.width, output.rect.height }));
        return;
    }
    const interactive = !options.fullscreen and options.geometry == null;
    const frozen = interactive and !options.live and !options.record and !options.geometry_only;
    if (frozen) _ = try app.capture(options.cursor, null);
    const region = if (options.geometry) |r| r.intersection(app.bounds()) orelse return error.GeometryOutsideOutputs else if (options.fullscreen) app.bounds() else try app.select(frozen, null);
    if (options.geometry_only) {
        try write(try std.fmt.bufPrint(&text, "{d},{d} {d}x{d}\n", .{ region.x, region.y, region.width, region.height }));
    } else if (options.record) {
        try record(&app, region, path, options);
    } else {
        if (!frozen) _ = try app.capture(options.cursor, region);
        var image = try app.compose(region);
        defer image.deinit(allocator);
        if (c.shot_png(path, image.data.ptr, @intCast(image.width), @intCast(image.height), options.source_encoding) != 0) return error.PngWriteFailed;
    }
}

fn record(app: *client.Client, region: Rect, path: [:0]const u8, options: Options) !void {
    var video: ?*c.ShotVideo = null;
    defer if (video) |v| {
        if (c.shot_video_close(v) != 0) std.debug.print("ouroshot: could not finalize partial recording\n", .{});
    };
    const strict_dma = std.mem.eql(u8, options.capture, "dmabuf");
    if (options.source_encoding != c.SHOT_SOURCE_GAMMA22 and !std.mem.eql(u8, options.capture, "shm") and !std.mem.eql(u8, options.encoder, "software")) {
        if (try app.startCapture(region, options.cursor, options.device, true)) {
            const crop = app.dma.crop;
            video = c.shot_video_open(path, @intCast(crop.width), @intCast(crop.height), @intCast(options.fps), options.encoder, options.device, app.dma.storage, 0, options.source_encoding);
            if (video == null) try app.stopDma();
        }
        if (strict_dma and video == null) return error.DmaRecordingUnavailable;
    }
    if (app.dma.session == null) _ = try app.startCapture(region, options.cursor, options.device, false);
    std.debug.print("ouroshot: capture={s}\n", .{if (app.dma.session != null) "ext-image-copy-capture-v1" else "wlr-screencopy (compatibility fallback)"});
    const start = client.now();
    const interval: i64 = @intCast(1_000_000_000 / options.fps);
    var next = start;
    var first_timestamp: ?i64 = null;
    var last_pts: i64 = -1;
    var frames: u64 = 0;
    var captures: u64 = 0;
    var rgba = false;
    var width: u32 = if (video != null) app.dma.crop.width else 0;
    var height: u32 = if (video != null) app.dma.crop.height else 0;
    while (c.shot_stopping() == 0) {
        const current = client.now();
        if (options.duration) |duration| if (current - start >= @as(i64, duration) * 1_000_000_000) break;
        if (current < next and app.dma.session == null) {
            var delay = c.struct_timespec{ .tv_sec = 0, .tv_nsec = next - current };
            _ = c.nanosleep(&delay, null);
            continue;
        }
        const deadline = if (first_timestamp == null) @min(start + 5_000_000_000, if (options.duration) |d| start + @as(i64, d) * 1_000_000_000 else std.math.maxInt(i64)) else next;
        var frame = app.videoFrame(options.cursor, region, deadline) catch |err| {
            if (err == error.Interrupted) break;
            return err;
        };
        defer if (frame) |*f| f.deinit();
        if (frame == null and first_timestamp == null) return error.NoFrames;
        // Submit the next ext capture while waiting for the encode tick. A
        // ready frame may arrive early; a static source waits until this tick
        // then uses the cache. Don't add a whole interval after each timeout.
        const remaining = next - client.now();
        if (remaining > 0) {
            var delay = c.struct_timespec{ .tv_sec = 0, .tv_nsec = remaining };
            _ = c.nanosleep(&delay, null);
            if (c.shot_stopping() != 0) break;
        }
        // A static source's presentation timestamp can predate recording.
        // Use monotonic arrival time for the timeline, including cached frames,
        // so stale source timestamps and stalls never speed up the video.
        if (first_timestamp == null) first_timestamp = client.now();
        const pts = @max(last_pts + 1, @divTrunc(client.now() - first_timestamp.?, 1000));
        if (frame) |f| {
            if (video == null) {
                width = f.crop.width;
                height = f.crop.height;
                rgba = f.rgba;
                video = c.shot_video_open(path, @intCast(width), @intCast(height), @intCast(options.fps), options.encoder, options.device, null, @intFromBool(rgba), options.source_encoding) orelse return error.VideoOpenFailed;
            }
            if (width != f.crop.width or height != f.crop.height or rgba != f.rgba) return error.OutputChanged;
            const result = if (f.dma) |dma| c.shot_video_dma_frame(video.?, dma, f.crop.x, f.crop.y, pts) else c.shot_video_frame(video.?, f.data.?, @intCast(f.stride), pts);
            if (result != 0) return error.VideoEncodeFailed;
            captures += 1;
        } else if (c.shot_video_repeat(video.?, pts) != 0) return error.VideoEncodeFailed;
        if (frames == 0) std.debug.print("Recording {d}x{d} to {s}; Ctrl-C stops.\n", .{ width, height, path });
        frames += 1;
        last_pts = pts;
        // No unbounded queue and no catch-up burst.
        next += interval;
        if (next < client.now()) next = client.now();
    }
    if (video) |v| {
        video = null;
        if (c.shot_video_close(v) != 0) return error.VideoFinalizeFailed;
        std.debug.print("Saved {d} frames ({d:.2}s capture span); {d} captures, {d} cached repeats.\n", .{ frames, @as(f64, @floatFromInt(last_pts)) / 1_000_000, captures, frames - captures });
    } else return error.NoFrames;
}
