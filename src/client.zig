const std = @import("std");
const wr = @import("wayring");
const p = @import("protocol");
const geo = @import("geometry.zig");
const Image = @import("image.zig").Image;
pub const c = @cImport({
    // Import declarations rather than glibc's inline fortify wrappers, which
    // translate-c cannot compile. encode.c retains its normal C build flags.
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("sys/mman.h");
    @cInclude("unistd.h");
    @cInclude("poll.h");
    @cInclude("time.h");
    @cInclude("encode.h");
});
const Handle = wr.objects.Handle;
const Core = wr.client.Core(p);
const Connection = wr.client.Connection(p);
const Driver = wr.client.Driver(p);
const allocator = std.heap.smp_allocator;

pub fn now() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1_000_000_000 + ts.tv_nsec;
}

const Buffer = struct {
    handle: ?Handle = null,
    fd: c_int = -1,
    bytes: []u8 = &.{},
    width: u32 = 0,
    height: u32 = 0,
    stride: u32 = 0,
    busy: bool = false,
    initialized: bool = false,
    previous: ?geo.Rect = null,

    fn release(self: *Buffer) void {
        if (self.bytes.len != 0) _ = c.munmap(self.bytes.ptr, self.bytes.len);
        if (self.fd >= 0) _ = c.close(self.fd);
        self.* = .{};
    }
};

pub const Output = struct {
    global: u32,
    handle: Handle,
    name: [256]u8 = @splat(0),
    rect: geo.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    physical_width: u32 = 0,
    physical_height: u32 = 0,
    scale: u32 = 1,
    preferred_scale: ?u32 = null,
    transform: u32 = 0,
    logical_size: bool = false,
    snapshot: ?Image = null,
    capture: ?Handle = null,
    captured: bool = false,
    flags: u32 = 0,
    format: u32 = 0,
    timestamp: i64 = 0,
    capture_buffer: Buffer = .{},
    capture_rect: geo.Rect = undefined,
    surface: ?Handle = null,
    layer: ?Handle = null,
    viewport: ?Handle = null,
    fractional: ?Handle = null,
    configured: bool = false,
    callback: ?Handle = null,
    buffers: [2]Buffer = .{ .{}, .{} },
    dirty: bool = false,
    displayed: ?geo.Rect = null,
};

const DmaCapture = struct {
    source: ?Handle = null,
    session: ?Handle = null,
    frame: ?Handle = null,
    params: ?Handle = null,
    buffer: ?Handle = null,
    storage: ?*c.ShotDma = null,
    width: u32 = 0,
    height: u32 = 0,
    device: ?u64 = null,
    shm_format: ?u32 = null,
    allocated_format: u32 = 0,
    shm: Buffer = .{},
    linear: bool = false,
    constraints_done: bool = false,
    import_done: bool = false,
    ready: bool = false,
    initialized: bool = false,
    timestamp: i64 = 0,
    crop: geo.Rect = undefined,
};

// Borrowed SHM or DMA storage remains valid until the next capture. Only the
// multi-output/rotated fallback owns an extra CPU image.
pub const VideoFrame = struct {
    data: ?[*]const u8 = null,
    stride: u32 = 0,
    rgba: bool = false,
    crop: geo.Rect,
    timestamp: i64,
    dma: ?*c.ShotDma = null,
    owned: ?Image = null,

    pub fn deinit(self: *VideoFrame) void {
        if (self.owned) |*image| image.deinit(allocator);
    }
};

pub const Client = struct {
    reactor: wr.io_uring.Reactor = undefined,
    connection: Connection = undefined,
    registry: Handle = undefined,
    compositor: ?Handle = null,
    shm: ?Handle = null,
    screencopy: ?Handle = null,
    layers: ?Handle = null,
    viewporter: ?Handle = null,
    fractional: ?Handle = null,
    xdg_outputs: ?Handle = null,
    seat: ?Handle = null,
    pointer: ?Handle = null,
    keyboard: ?Handle = null,
    cursor_shapes: ?Handle = null,
    cursor_shape: ?Handle = null,
    dmabuf_manager: ?Handle = null,
    dmabuf_linear: bool = false,
    capture_sources: ?Handle = null,
    image_capture: ?Handle = null,
    dma: DmaCapture = .{},
    closing_capture: [2]?Handle = .{ null, null },
    outputs: [16]Output = undefined,
    output_count: usize = 0,
    discovering: bool = true,
    selecting: bool = false,
    freeze: bool = false,
    selected: bool = false,
    cancelled: bool = false,
    pointer_output: ?usize = null,
    position: geo.Point = .{ .x = 0, .y = 0 },
    anchor: ?geo.Point = null,
    selection: ?geo.Rect = null,
    failure: ?anyerror = null,

    pub fn init(self: *Client, environ: std.process.Environ) !void {
        self.* = .{};
        try self.reactor.initOwned(allocator, .{ .entries = 256, .flags = 0 }, .{
            .receive_buffer_size = 16384,
            .receive_buffer_count = 32,
            .receive_control_capacity = 4096,
            .fragment_block_size = 4096,
            .fragment_block_count = 32,
            .transmit_block_size = 4096,
            .transmit_block_count = 128,
            .descriptor_count = 256,
            .send_descriptor_capacity = 64,
        });
        errdefer self.reactor.deinit(allocator);
        var path: [108]u8 = undefined;
        const fd = try wr.unix_socket.connectEnvironment(&path, environ);
        self.connection = try Connection.attach(allocator, &self.reactor, fd, .{
            .received_fd_budget = 64,
            .transmit_byte_budget = 128 * 1024,
            .transmit_fd_budget = 64,
        }, .{ .max_objects = 4096, .max_client_ids = 4096 });
        errdefer self.closeConnection();
        self.registry = try Core.getRegistry(&self.connection.objects, &(try self.connection.actor()).transmit, null);
        try self.roundtrip();
        if (self.xdg_outputs) |manager| {
            for (self.outputs[0..self.output_count], 0..) |*output, i| {
                _ = try p.zxdg_output_manager_v1.construct_get_xdg_output(&self.connection.objects, &(try self.connection.actor()).transmit, manager, .{
                    .output = output.handle.id,
                    .id = .{ .context = &self.outputs[i] },
                });
            }
        }
        try self.roundtrip();
        for (self.outputs[0..self.output_count]) |*output| {
            if (!output.logical_size) {
                const swap = output.transform & 1 != 0;
                output.rect.width = (if (swap) output.physical_height else output.physical_width) / output.scale;
                output.rect.height = (if (swap) output.physical_width else output.physical_height) / output.scale;
            }
            if (output.rect.width == 0 or output.rect.height == 0) return error.InvalidOutputSize;
        }
        self.discovering = false;
        if (self.output_count == 0) return error.NoOutputs;
        if (self.shm == null or self.compositor == null) return error.MissingWaylandGlobals;
    }

    fn closeConnection(self: *Client) void {
        _ = self.connection.prepareClose() catch |err| switch (err) {
            error.CancelAlreadyActive => false,
            else => unreachable,
        };
        var driver = Driver.init(&self.connection);
        _ = driver.schedule() catch return;
        var progress = driver.prepare(self) catch return;
        _ = self.reactor.ring.submit() catch return;
        while (!progress.quiescent) {
            const completion = self.reactor.ring.copy_cqe() catch continue;
            progress = driver.dispatch(&.{completion}, self) catch continue;
            _ = self.reactor.ring.submit() catch {};
        }
        self.connection.deinit(allocator) catch unreachable;
    }
    pub fn deinit(self: *Client) void {
        self.selecting = false;
        self.closeConnection();
        self.reactor.deinit(allocator);
        if (self.dma.storage) |storage| c.shot_dma_destroy(storage);
        self.dma.shm.release();
        for (self.outputs[0..self.output_count]) |*output| {
            output.capture_buffer.release();
            for (&output.buffers) |*buffer| buffer.release();
            if (output.snapshot) |*image| image.deinit(allocator);
        }
    }
    fn pump(self: *Client, handler: anytype, deadline: i64) !void {
        if (c.shot_stopping() != 0) return error.Interrupted;
        if (self.failure) |err| return err;
        var driver = Driver.init(&self.connection);
        _ = try driver.schedule();
        var progress = try driver.prepare(handler);
        _ = try self.reactor.ring.submit();
        var completions: [32]std.os.linux.io_uring_cqe = undefined;
        var count = try self.reactor.ring.copy_cqes(&completions, 0);
        if (count == 0) {
            if (now() >= deadline) return error.CompositorTimeout;
            var pollfd = c.struct_pollfd{ .fd = self.reactor.ring.fd, .events = c.POLLIN, .revents = 0 };
            _ = c.poll(&pollfd, 1, @intCast(@min(100, @max(1, @divTrunc(deadline - now() + 999_999, 1_000_000)))));
            count = try self.reactor.ring.copy_cqes(&completions, 0);
        }
        progress = try driver.dispatch(completions[0..count], handler);
        if (self.failure) |err| return err;
        if (progress.event_errors != 0) return error.WaylandProtocolError;
        if (progress.quiescent) return error.CompositorDisconnected;
        if (self.selecting) try self.draw();
    }
    pub fn roundtrip(self: *Client) !void {
        var trip = wr.client.Roundtrip(p, *Client).init(&self.connection, self);
        _ = try trip.begin();
        const deadline = now() + 5_000_000_000;
        while (!trip.settled()) try self.pump(&trip, deadline);
    }
    fn send(self: *Client, comptime I: type, handle: Handle, request: I.Request) !void {
        try wr.client.sendRequest(I, &self.connection.objects, &(try self.connection.actor()).transmit, handle, request);
    }
    fn decode(self: *Client, comptime I: type, message: wr.wire.Message, fds: *wr.ancillary.FdQueue) !I.Event {
        const handle = self.connection.objects.namespace.lookupHandle(message.header.object_id) orelse return error.UnknownObject;
        return wr.client.decodeEvent(I, &self.connection.objects, handle, message, fds);
    }
    fn bind(self: *Client, comptime I: type, name: u32, version: u32, context: ?*anyopaque) !Handle {
        return Core.bind(&self.connection.objects, &(try self.connection.actor()).transmit, self.registry, name, &I.info, @min(version, I.info.version), context);
    }

    fn allocateBuffer(self: *Client, buffer: *Buffer, width: u32, height: u32, stride: u32, format: u32) !void {
        if (buffer.handle) |handle| {
            try self.send(p.wl_buffer, handle, .{ .destroy = .{} });
            buffer.release();
        }
        const size = @as(u64, stride) * height;
        if (width == 0 or height == 0 or stride < @as(u64, width) * 4 or size > 512 * 1024 * 1024) return error.InvalidBufferSize;
        const fd = c.memfd_create("ouroshot", c.MFD_CLOEXEC);
        if (fd < 0) return error.MemfdFailed;
        errdefer _ = c.close(fd);
        if (c.ftruncate(fd, @intCast(size)) != 0) return error.BufferResizeFailed;
        const mapped = c.mmap(null, @intCast(size), c.PROT_READ | c.PROT_WRITE, c.MAP_SHARED, fd, 0);
        if (mapped == c.MAP_FAILED) return error.BufferMapFailed;
        errdefer _ = c.munmap(mapped, @intCast(size));
        const queue = &(try self.connection.actor()).transmit;
        // Wayring owns transmitted FDs after a successful enqueue. Keep the
        // allocation's descriptor separate from the transport's descriptor.
        const duplicated = std.os.linux.fcntl(fd, std.os.linux.F.DUPFD_CLOEXEC, 0);
        if (std.os.linux.errno(duplicated) != .SUCCESS) return error.DuplicateFdFailed;
        const send_fd: c_int = @intCast(duplicated);
        const pool = (p.wl_shm.construct_create_pool(&self.connection.objects, queue, self.shm.?, .{ .fd = send_fd, .size = @intCast(size) }) catch |err| {
            _ = c.close(send_fd);
            return err;
        }).id;
        const handle = (try p.wl_shm_pool.construct_create_buffer(&self.connection.objects, queue, pool, .{
            .id = .{ .context = buffer },
            .offset = 0,
            .width = @intCast(width),
            .height = @intCast(height),
            .stride = @intCast(stride),
            .format = .{ .value = format },
        })).id;
        try self.send(p.wl_shm_pool, pool, .{ .destroy = .{} });
        buffer.* = .{ .handle = handle, .fd = fd, .bytes = @as([*]u8, @ptrCast(mapped.?))[0..@intCast(size)], .width = width, .height = height, .stride = stride };
    }

    pub fn bounds(self: *Client) geo.Rect {
        var result = self.outputs[0].rect;
        for (self.outputs[1..self.output_count]) |output| result = result.unite(output.rect);
        return result;
    }
    pub fn capture(self: *Client, cursor: bool, region: ?geo.Rect) !i64 {
        const timestamp = try self.captureRaw(cursor, region, false);
        try self.normalize(region);
        return timestamp;
    }
    fn normalize(self: *Client, region: ?geo.Rect) !void {
        for (self.outputs[0..self.output_count]) |*output| {
            if (region != null and output.rect.intersection(region.?) == null) continue;
            const b = &output.capture_buffer;
            const image = try Image.fromBuffer(allocator, b.bytes, b.width, b.height, b.stride, output.format, output.flags & 1 != 0, output.transform);
            if (output.snapshot) |*old| old.deinit(allocator);
            output.snapshot = image;
        }
    }
    fn captureRaw(self: *Client, cursor: bool, region: ?geo.Rect, subregion: bool) !i64 {
        const manager = self.screencopy orelse return error.ScreencopyUnsupported;
        for (self.outputs[0..self.output_count]) |*output| {
            output.captured = region != null and output.rect.intersection(region.?) == null;
            if (output.captured) continue;
            output.flags = 0;
            output.capture_rect = output.rect;
            // Region screencopy rounds differently between compositors. Use it
            // only on exact pixel boundaries; otherwise borrow a native crop
            // from the full SHM buffer without introducing a resample or copy.
            if (subregion and region != null) {
                const r = region.?;
                const xs = [_]i64{ @as(i64, r.x) - output.rect.x, r.right() - output.rect.x };
                const ys = [_]i64{ @as(i64, r.y) - output.rect.y, r.bottom() - output.rect.y };
                var aligned = true;
                for (xs) |x| aligned = aligned and @mod(x * output.physical_width, output.rect.width) == 0;
                for (ys) |y| aligned = aligned and @mod(y * output.physical_height, output.rect.height) == 0;
                if (aligned) output.capture_rect = r;
            }
            const queue = &(try self.connection.actor()).transmit;
            if (!std.meta.eql(output.capture_rect, output.rect)) {
                const r = output.capture_rect;
                output.capture = (try p.zwlr_screencopy_manager_v1.construct_capture_output_region(&self.connection.objects, queue, manager, .{
                    .frame = .{ .context = output },
                    .overlay_cursor = @intFromBool(cursor),
                    .output = output.handle.id,
                    .x = r.x - output.rect.x,
                    .y = r.y - output.rect.y,
                    .width = @intCast(r.width),
                    .height = @intCast(r.height),
                })).frame;
            } else output.capture = (try p.zwlr_screencopy_manager_v1.construct_capture_output(&self.connection.objects, queue, manager, .{
                .frame = .{ .context = output },
                .overlay_cursor = @intFromBool(cursor),
                .output = output.handle.id,
            })).frame;
        }
        const deadline = now() + 5_000_000_000;
        while (true) {
            var complete = true;
            for (self.outputs[0..self.output_count]) |output| complete = complete and output.captured;
            if (complete) break;
            try self.pump(self, deadline);
        }
        var timestamp: i64 = 0;
        for (self.outputs[0..self.output_count]) |*output| {
            if (output.capture) |handle| {
                try self.send(p.zwlr_screencopy_frame_v1, handle, .{ .destroy = .{} });
                output.capture = null;
                timestamp = @max(timestamp, output.timestamp);
            }
        }
        return timestamp;
    }

    fn singleOutput(self: *Client, region: geo.Rect) ?*Output {
        var selected: ?*Output = null;
        for (self.outputs[0..self.output_count]) |*output| {
            if (output.rect.intersection(region)) |overlap| {
                if (selected != null or !std.meta.eql(overlap, region) or output.transform != 0) return null;
                selected = output;
            }
        }
        return selected;
    }

    pub fn startCapture(self: *Client, region: geo.Rect, cursor: bool, device: [:0]const u8, use_dma: bool) !bool {
        const output = self.singleOutput(region) orelse return false;
        if (self.capture_sources == null or self.image_capture == null) return false;
        if (use_dma and (self.dmabuf_manager == null or !self.dmabuf_linear)) return false;
        var success = false;
        defer if (!success) self.stopDma() catch |err| {
            self.failure = err;
            std.debug.print("ouroshot: capture cleanup: {s}\n", .{@errorName(err)});
        };
        const queue = &(try self.connection.actor()).transmit;
        self.dma.source = (try p.ext_output_image_capture_source_manager_v1.construct_create_source(&self.connection.objects, queue, self.capture_sources.?, .{ .output = output.handle.id })).source;
        self.dma.session = (try p.ext_image_copy_capture_manager_v1.construct_create_session(&self.connection.objects, queue, self.image_capture.?, .{ .source = self.dma.source.?.id, .options = .{ .value = @intFromBool(cursor) } })).session;
        const deadline = now() + 5_000_000_000;
        while (!self.dma.constraints_done) try self.pump(self, deadline);
        // Creating a capture session can disable direct scan-out and emit a
        // second constraints batch. Drain already queued updates first.
        try self.roundtrip();
        self.dma.crop = try geo.nativeCrop(output.rect, region, self.dma.width, self.dma.height);
        if (!use_dma) {
            const format = self.dma.shm_format orelse return false;
            try self.allocateBuffer(&self.dma.shm, self.dma.width, self.dma.height, self.dma.width * 4, format);
            self.dma.allocated_format = format;
            self.dma.buffer = self.dma.shm.handle;
            success = true;
            return true;
        }
        if (!self.dma.linear or self.dma.device == null) return false;
        if (self.dma.crop.width & 1 != 0 or self.dma.crop.height & 1 != 0) return false;
        self.dma.storage = c.shot_dma_create(device, self.dma.device.?, @intCast(self.dma.width), @intCast(self.dma.height)) orelse return false;
        const info = c.shot_dma_info(self.dma.storage.?);
        self.dma.params = (try p.zwp_linux_dmabuf_v1.construct_create_params(&self.connection.objects, queue, self.dmabuf_manager.?, .{})).params_id;
        const duplicated = std.os.linux.fcntl(info.fd, std.os.linux.F.DUPFD_CLOEXEC, 0);
        if (std.os.linux.errno(duplicated) != .SUCCESS) return error.DuplicateFdFailed;
        const send_fd: c_int = @intCast(duplicated);
        self.send(p.zwp_linux_buffer_params_v1, self.dma.params.?, .{ .add = .{ .fd = send_fd, .plane_idx = 0, .offset = 0, .stride = @intCast(info.stride), .modifier_hi = 0, .modifier_lo = 0 } }) catch |err| {
            _ = c.close(send_fd);
            return err;
        };
        try self.send(p.zwp_linux_buffer_params_v1, self.dma.params.?, .{ .create = .{ .width = info.width, .height = info.height, .format = info.format, .flags = .{ .value = 0 } } });
        while (!self.dma.import_done) try self.pump(self, deadline);
        try self.send(p.zwp_linux_buffer_params_v1, self.dma.params.?, .{ .destroy = .{} });
        self.dma.params = null;
        success = self.dma.buffer != null;
        return success;
    }

    pub fn stopDma(self: *Client) !void {
        // These objects can still have events in flight when cancelled. Keep
        // their IDs dispatchable until delete_id, and discard the late events.
        const queue = &(try self.connection.actor()).transmit;
        if (self.dma.frame) |handle| {
            try p.ext_image_copy_capture_frame_v1.encodeRequest(queue, handle.id, .{ .destroy = .{} });
            self.closing_capture[0] = handle;
        }
        if (self.dma.params) |handle| try self.send(p.zwp_linux_buffer_params_v1, handle, .{ .destroy = .{} });
        if (self.dma.session) |handle| {
            try p.ext_image_copy_capture_session_v1.encodeRequest(queue, handle.id, .{ .destroy = .{} });
            self.closing_capture[1] = handle;
        }
        if (self.dma.source) |handle| try self.send(p.ext_image_capture_source_v1, handle, .{ .destroy = .{} });
        if (self.dma.buffer) |handle| try self.send(p.wl_buffer, handle, .{ .destroy = .{} });
        try self.roundtrip();
        if (self.dma.storage) |storage| c.shot_dma_destroy(storage);
        self.dma.shm.release();
        self.dma = .{};
    }

    pub fn videoFrame(self: *Client, cursor: bool, region: geo.Rect, deadline: i64) !?VideoFrame {
        if (self.dma.session != null) {
            const d = &self.dma;
            if (d.frame == null) {
                d.ready = false;
                d.frame = (try p.ext_image_copy_capture_session_v1.construct_create_frame(&self.connection.objects, &(try self.connection.actor()).transmit, d.session.?, .{})).frame;
                try self.send(p.ext_image_copy_capture_frame_v1, d.frame.?, .{ .attach_buffer = .{ .buffer = d.buffer.?.id } });
                if (!d.initialized) try self.send(p.ext_image_copy_capture_frame_v1, d.frame.?, .{ .damage_buffer = .{ .x = 0, .y = 0, .width = @intCast(d.width), .height = @intCast(d.height) } });
                try self.send(p.ext_image_copy_capture_frame_v1, d.frame.?, .{ .capture = .{} });
            }
            while (!d.ready) {
                self.pump(self, deadline) catch |err| {
                    if (err == error.CompositorTimeout) return null;
                    return err;
                };
            }
            try self.send(p.ext_image_copy_capture_frame_v1, d.frame.?, .{ .destroy = .{} });
            d.frame = null;
            d.initialized = true;
            const offset = @as(usize, @intCast(d.crop.y)) * d.shm.stride + @as(usize, @intCast(d.crop.x)) * 4;
            return .{ .crop = d.crop, .timestamp = d.timestamp, .dma = d.storage, .data = if (d.storage == null) d.shm.bytes.ptr + offset else null, .stride = d.shm.stride, .rgba = d.allocated_format == 0x34324241 or d.allocated_format == 0x34324258 };
        }
        const single = self.singleOutput(region);
        const timestamp = try self.captureRaw(cursor, region, single != null);
        if (single) |output| {
            const b = &output.capture_buffer;
            if (output.flags & 1 == 0 and (output.format == 0 or output.format == 1 or output.format == 0x34324241 or output.format == 0x34324258)) {
                const crop = try geo.nativeCrop(output.capture_rect, region, b.width, b.height);
                const offset = @as(usize, @intCast(crop.y)) * b.stride + @as(usize, @intCast(crop.x)) * 4;
                return .{ .data = b.bytes.ptr + offset, .stride = b.stride, .crop = crop, .timestamp = timestamp, .rgba = output.format == 0x34324241 or output.format == 0x34324258 };
            }
            // Unsupported raw layout: recapture the complete output for the
            // existing normalization path, which also handles rotations.
            if (!std.meta.eql(output.capture_rect, output.rect)) _ = try self.captureRaw(cursor, region, false);
        }
        try self.normalize(region);
        const image = try self.compose(region);
        return .{ .data = image.data.ptr, .stride = image.width * 4, .crop = .{ .x = 0, .y = 0, .width = image.width, .height = image.height }, .timestamp = timestamp, .owned = image };
    }

    pub fn compose(self: *Client, region: geo.Rect) !Image {
        var scale120: u32 = 120;
        var intersecting: usize = 0;
        var contained: ?usize = null;
        for (self.outputs[0..self.output_count], 0..) |output, i| {
            if (output.rect.intersection(region)) |overlap| {
                intersecting += 1;
                if (std.meta.eql(overlap, region)) contained = i;
                const image = output.snapshot orelse return error.MissingCapture;
                scale120 = @max(scale120, @as(u32, @intCast((@as(u64, image.width) * 120 + output.rect.width - 1) / output.rect.width)));
            }
        }
        if (intersecting == 0) return error.GeometryOutsideOutputs;
        if (intersecting == 1 and contained != null) {
            const output = &self.outputs[contained.?];
            return output.snapshot.?.crop(allocator, output.rect, region);
        }
        const result = try Image.init(allocator, try geo.pixels(region.width, scale120), try geo.pixels(region.height, scale120));
        for (self.outputs[0..self.output_count]) |output| {
            if (output.snapshot) |image| result.composite(image, output.rect, region, scale120);
        }
        return result;
    }

    pub fn select(self: *Client, freeze: bool) !geo.Rect {
        const layers = self.layers orelse return error.LayerShellUnsupported;
        if (self.seat == null) return error.NoInputSeat;
        self.freeze = freeze;
        for (self.outputs[0..self.output_count]) |*output| {
            const queue = &(try self.connection.actor()).transmit;
            output.surface = (try p.wl_compositor.construct_create_surface(&self.connection.objects, queue, self.compositor.?, .{ .id = .{ .context = output } })).id;
            const surface = output.surface.?;
            if (freeze) {
                const opaque_region = (try p.wl_compositor.construct_create_region(&self.connection.objects, queue, self.compositor.?, .{})).id;
                try self.send(p.wl_region, opaque_region, .{ .add = .{ .x = 0, .y = 0, .width = @intCast(output.rect.width), .height = @intCast(output.rect.height) } });
                try self.send(p.wl_surface, surface, .{ .set_opaque_region = .{ .region = opaque_region.id } });
                try self.send(p.wl_region, opaque_region, .{ .destroy = .{} });
            }
            if (self.viewporter) |manager| {
                output.viewport = (try p.wp_viewporter.construct_get_viewport(&self.connection.objects, queue, manager, .{ .surface = surface.id })).id;
                if (self.fractional) |fractional| output.fractional = (try p.wp_fractional_scale_manager_v1.construct_get_fractional_scale(&self.connection.objects, queue, fractional, .{ .surface = surface.id, .id = .{ .context = output } })).id;
            }
            output.layer = (try p.zwlr_layer_shell_v1.construct_get_layer_surface(&self.connection.objects, queue, layers, .{
                .id = .{ .context = output },
                .surface = surface.id,
                .output = output.handle.id,
                .layer = p.zwlr_layer_shell_v1.layer.overlay,
                .namespace = "ouroshot",
            })).id;
            try self.send(p.zwlr_layer_surface_v1, output.layer.?, .{ .set_size = .{ .width = 0, .height = 0 } });
            try self.send(p.zwlr_layer_surface_v1, output.layer.?, .{ .set_anchor = .{ .anchor = .{ .value = 15 } } });
            try self.send(p.zwlr_layer_surface_v1, output.layer.?, .{ .set_exclusive_zone = .{ .zone = -1 } });
            try self.send(p.zwlr_layer_surface_v1, output.layer.?, .{ .set_keyboard_interactivity = .{ .keyboard_interactivity = p.zwlr_layer_surface_v1.keyboard_interactivity.exclusive } });
            try self.send(p.wl_surface, surface, .{ .commit = .{} });
        }
        try self.roundtrip();
        self.selecting = true;
        try self.draw();
        while (!self.selected and !self.cancelled) try self.pump(self, now() + 300_000_000_000);
        self.selecting = false;
        // Drain pointer/keyboard leave events while their surface IDs still
        // exist. Destroying IDs before unmapping races those object references.
        for (self.outputs[0..self.output_count]) |output| {
            try self.send(p.wl_surface, output.surface.?, .{ .attach = .{ .buffer = null, .x = 0, .y = 0 } });
            try self.send(p.wl_surface, output.surface.?, .{ .commit = .{} });
        }
        try self.roundtrip();
        for (self.outputs[0..self.output_count]) |*output| {
            if (output.fractional) |handle| try self.send(p.wp_fractional_scale_v1, handle, .{ .destroy = .{} });
            if (output.viewport) |handle| try self.send(p.wp_viewport, handle, .{ .destroy = .{} });
            try self.send(p.zwlr_layer_surface_v1, output.layer.?, .{ .destroy = .{} });
            try self.send(p.wl_surface, output.surface.?, .{ .destroy = .{} });
            output.surface = null;
        }
        try self.roundtrip();
        if (self.cancelled) return error.Cancelled;
        return self.selection.?;
    }

    fn draw(self: *Client) !void {
        for (self.outputs[0..self.output_count]) |*output| {
            if (!output.dirty or !output.configured or output.callback != null) continue;
            var available: ?*Buffer = null;
            for (&output.buffers) |*buffer| if (!buffer.busy) {
                available = buffer;
                break;
            };
            const buffer = available orelse continue;
            const scale120 = if (output.viewport != null) output.preferred_scale orelse output.scale * 120 else output.scale * 120;
            const width = try geo.pixels(output.rect.width, scale120);
            const height = try geo.pixels(output.rect.height, scale120);
            if (buffer.width != width or buffer.height != height) try self.allocateBuffer(buffer, width, height, width * 4, 0);
            var redraw = output.rect;
            if (buffer.initialized) {
                if (self.selection) |selection| {
                    redraw = selection.expanded(3);
                    if (buffer.previous) |previous| redraw = redraw.unite(previous.expanded(3));
                } else if (buffer.previous) |previous| {
                    redraw = previous.expanded(3);
                }
            }
            if (redraw.intersection(output.rect)) |dirty| {
                const x0: u32 = @intCast(@divFloor((@as(i64, dirty.x) - output.rect.x) * scale120, 120));
                const y0: u32 = @intCast(@divFloor((@as(i64, dirty.y) - output.rect.y) * scale120, 120));
                const x1: u32 = @min(width, @as(u32, @intCast(@divFloor((dirty.right() - output.rect.x) * scale120 + 119, 120))));
                const y1: u32 = @min(height, @as(u32, @intCast(@divFloor((dirty.bottom() - output.rect.y) * scale120 + 119, 120))));
                for (y0..y1) |y| for (x0..x1) |x| {
                    const point = geo.Point{ .x = output.rect.x + @as(i32, @intCast(x * 120 / scale120)), .y = output.rect.y + @as(i32, @intCast(y * 120 / scale120)) };
                    const inside = if (self.selection) |r| r.contains(point) else false;
                    const border = if (self.selection) |r| inside and (point.x < r.x + 2 or point.y < r.y + 2 or point.x >= r.right() - 2 or point.y >= r.bottom() - 2) else false;
                    const dst = buffer.bytes[y * buffer.stride + x * 4 ..][0..4];
                    if (self.freeze and output.snapshot != null) {
                        const image = output.snapshot.?;
                        const src = image.pixel(@intCast(@min(image.width - 1, x * image.width / width)), @intCast(@min(image.height - 1, y * image.height / height)));
                        for (0..3) |channel| dst[channel] = if (border) 255 else if (inside) src[channel] else @intCast(@as(u16, src[channel]) * 3 / 5);
                        dst[3] = 255;
                    } else dst.* = if (border) .{ 255, 255, 255, 255 } else if (inside) .{ 0, 0, 0, 0 } else .{ 0, 0, 0, 102 };
                };
            }
            var damage = output.rect;
            if (buffer.initialized and self.selection != null and output.displayed != null) damage = self.selection.?.expanded(3).unite(output.displayed.?.expanded(3));
            const clipped = damage.intersection(output.rect) orelse output.rect;
            const surface = output.surface.?;
            if (output.viewport) |viewport| try self.send(p.wp_viewport, viewport, .{ .set_destination = .{ .width = @intCast(output.rect.width), .height = @intCast(output.rect.height) } }) else try self.send(p.wl_surface, surface, .{ .set_buffer_scale = .{ .scale = @intCast(output.scale) } });
            try self.send(p.wl_surface, surface, .{ .attach = .{ .buffer = buffer.handle.?.id, .x = 0, .y = 0 } });
            try self.send(p.wl_surface, surface, .{ .damage = .{ .x = clipped.x - output.rect.x, .y = clipped.y - output.rect.y, .width = @intCast(clipped.width), .height = @intCast(clipped.height) } });
            output.callback = (try p.wl_surface.construct_frame(&self.connection.objects, &(try self.connection.actor()).transmit, surface, .{ .callback = .{ .context = output } })).callback;
            try self.send(p.wl_surface, surface, .{ .commit = .{} });
            buffer.busy = true;
            buffer.initialized = true;
            buffer.previous = self.selection;
            output.displayed = self.selection;
            output.dirty = false;
        }
    }

    pub fn event(self: *Client, target: wr.objects.Dispatch, message: wr.wire.Message, fds: *wr.ancillary.FdQueue) !wr.dispatch.Control {
        self.handleEvent(target, message, fds) catch |err| {
            self.failure = err;
            return err;
        };
        return .continue_dispatch;
    }
    pub fn eventError(self: *Client, _: wr.io_uring.Peer, failure: Core.EventFailure) void {
        std.debug.print("ouroshot: Wayland event failure: {any}\n", .{failure});
        self.failure = failure.cause;
    }
    fn handleEvent(self: *Client, target: wr.objects.Dispatch, message: wr.wire.Message, fds: *wr.ancillary.FdQueue) !void {
        const interface = target.object.interface;
        for (self.closing_capture) |closing| if (closing != null and closing.?.id == message.header.object_id) {
            if (interface == &p.ext_image_copy_capture_session_v1.info) _ = try self.decode(p.ext_image_copy_capture_session_v1, message, fds) else _ = try self.decode(p.ext_image_copy_capture_frame_v1, message, fds);
            return;
        };
        if (interface == &p.wl_display.info) {
            switch (try p.wl_display.decodeEvent(message, fds)) {
                .delete_id => |e| for (&self.closing_capture) |*closing| {
                    if (closing.* != null and closing.*.?.id == e.id) {
                        _ = try self.connection.objects.retireLocal(closing.*.?);
                        closing.* = null;
                    }
                },
                else => {},
            }
            _ = try Core.decodeDisplayEvent(&self.connection.objects, message, fds);
            return;
        }
        if (interface == &p.wl_registry.info) {
            switch (try Core.decodeRegistryEvent(&self.connection.objects, self.registry, message, fds)) {
                .global => |g| {
                    if (!self.discovering) return;
                    inline for (.{ .{ p.wl_compositor, "compositor" }, .{ p.wl_shm, "shm" }, .{ p.zwlr_screencopy_manager_v1, "screencopy" }, .{ p.zwlr_layer_shell_v1, "layers" }, .{ p.wp_viewporter, "viewporter" }, .{ p.wp_fractional_scale_manager_v1, "fractional" }, .{ p.zxdg_output_manager_v1, "xdg_outputs" }, .{ p.wl_seat, "seat" }, .{ p.wp_cursor_shape_manager_v1, "cursor_shapes" } }) |entry| {
                        if (std.mem.eql(u8, g.interface, entry[0].info.name) and @field(self, entry[1]) == null) @field(self, entry[1]) = try self.bind(entry[0], g.name, g.version, null);
                    }
                    inline for (.{ .{ p.ext_output_image_capture_source_manager_v1, "capture_sources" }, .{ p.ext_image_copy_capture_manager_v1, "image_capture" } }) |entry| {
                        if (std.mem.eql(u8, g.interface, entry[0].info.name) and @field(self, entry[1]) == null) @field(self, entry[1]) = try self.bind(entry[0], g.name, g.version, null);
                    }
                    // v3 advertises format/modifier pairs without requiring a
                    // surface-specific feedback object (capture has no surface).
                    if (std.mem.eql(u8, g.interface, p.zwp_linux_dmabuf_v1.info.name) and g.version >= 3) self.dmabuf_manager = try self.bind(p.zwp_linux_dmabuf_v1, g.name, 3, null);
                    if (std.mem.eql(u8, g.interface, "wl_output")) {
                        if (self.output_count == self.outputs.len) return error.TooManyOutputs;
                        const output = &self.outputs[self.output_count];
                        output.* = .{ .global = g.name, .handle = try self.bind(p.wl_output, g.name, g.version, output) };
                        self.output_count += 1;
                    }
                },
                .global_remove => |g| for (self.outputs[0..self.output_count]) |output| {
                    if (output.global == g.name) return error.OutputRemoved;
                },
            }
        } else if (interface == &p.wl_output.info) {
            const output: *Output = @ptrCast(@alignCast(target.object.context.?));
            switch (try self.decode(p.wl_output, message, fds)) {
                .geometry => |e| {
                    output.rect.x = e.x;
                    output.rect.y = e.y;
                    output.transform = @intCast(e.transform.value);
                },
                .mode => |e| if (e.flags.value & 1 != 0) {
                    output.physical_width = @intCast(e.width);
                    output.physical_height = @intCast(e.height);
                },
                .scale => |e| {
                    if (e.factor < 1 or e.factor > 16) return error.InvalidScale;
                    output.scale = @intCast(e.factor);
                },
                .name => |e| {
                    @memset(&output.name, 0);
                    @memcpy(output.name[0..@min(e.name.len, 255)], e.name[0..@min(e.name.len, 255)]);
                },
                else => {},
            }
        } else if (interface == &p.zxdg_output_v1.info) {
            const output: *Output = @ptrCast(@alignCast(target.object.context.?));
            switch (try self.decode(p.zxdg_output_v1, message, fds)) {
                .logical_position => |e| {
                    output.rect.x = e.x;
                    output.rect.y = e.y;
                },
                .logical_size => |e| {
                    if (e.width <= 0 or e.height <= 0) return error.InvalidOutputSize;
                    output.rect.width = @intCast(e.width);
                    output.rect.height = @intCast(e.height);
                    output.logical_size = true;
                },
                .name => |e| {
                    @memset(&output.name, 0);
                    @memcpy(output.name[0..@min(e.name.len, 255)], e.name[0..@min(e.name.len, 255)]);
                },
                else => {},
            }
        } else if (interface == &p.wl_shm.info) {
            _ = try self.decode(p.wl_shm, message, fds);
        } else if (interface == &p.wl_seat.info) {
            switch (try self.decode(p.wl_seat, message, fds)) {
                .capabilities => |e| {
                    const queue = &(try self.connection.actor()).transmit;
                    if (e.capabilities.value & 1 != 0 and self.pointer == null) self.pointer = (try p.wl_seat.construct_get_pointer(&self.connection.objects, queue, self.seat.?, .{})).id;
                    if (e.capabilities.value & 2 != 0 and self.keyboard == null) self.keyboard = (try p.wl_seat.construct_get_keyboard(&self.connection.objects, queue, self.seat.?, .{})).id;
                },
                else => {},
            }
        } else if (interface == &p.wl_keyboard.info) {
            switch (try self.decode(p.wl_keyboard, message, fds)) {
                .keymap => |e| {
                    _ = c.close(e.fd);
                },
                .key => |e| {
                    if (e.key == 1 and e.state.value == 1) self.cancelled = true;
                },
                else => {},
            }
        } else if (interface == &p.wl_pointer.info) {
            switch (try self.decode(p.wl_pointer, message, fds)) {
                .enter => |e| {
                    if (self.cursor_shapes) |manager| {
                        if (self.cursor_shape == null) self.cursor_shape = (try p.wp_cursor_shape_manager_v1.construct_get_pointer(&self.connection.objects, &(try self.connection.actor()).transmit, manager, .{ .pointer = self.pointer.?.id })).cursor_shape_device;
                        try self.send(p.wp_cursor_shape_device_v1, self.cursor_shape.?, .{ .set_shape = .{ .serial = e.serial, .shape = p.wp_cursor_shape_device_v1.shape.crosshair } });
                    }
                    for (self.outputs[0..self.output_count], 0..) |output, i| if (output.surface != null and output.surface.?.id == e.surface) {
                        self.pointer_output = i;
                        break;
                    };
                    try self.motion(e.surface_x, e.surface_y);
                },
                .motion => |e| try self.motion(e.surface_x, e.surface_y),
                .button => |e| {
                    if (!self.selecting) return;
                    if (e.button == 273 and e.state.value == 1) self.cancelled = true;
                    if (e.button == 272) {
                        if (e.state.value == 1) self.anchor = self.position else if (self.anchor != null) {
                            const rect = geo.Rect.between(self.anchor.?, self.position);
                            if (rect.width > 0 and rect.height > 0) {
                                self.selection = rect.intersection(self.bounds());
                                self.selected = self.selection != null;
                            }
                        }
                    }
                },
                else => {},
            }
        } else if (interface == &p.zwlr_screencopy_frame_v1.info) {
            const output: *Output = @ptrCast(@alignCast(target.object.context.?));
            switch (try self.decode(p.zwlr_screencopy_frame_v1, message, fds)) {
                .buffer => |e| {
                    const buffer = &output.capture_buffer;
                    if (buffer.width != e.width or buffer.height != e.height or buffer.stride != e.stride or output.format != e.format.value) try self.allocateBuffer(buffer, e.width, e.height, e.stride, e.format.value);
                    output.format = e.format.value;
                    try self.send(p.zwlr_screencopy_frame_v1, output.capture.?, .{ .copy = .{ .buffer = buffer.handle.?.id } });
                },
                .flags => |e| output.flags = e.flags.value,
                .ready => |e| {
                    output.timestamp = @intCast(((@as(u64, e.tv_sec_hi) << 32) | e.tv_sec_lo) * 1_000_000_000 + e.tv_nsec);
                    output.captured = true;
                },
                .failed => return error.CaptureFailed,
                else => {},
            }
        } else if (interface == &p.zwp_linux_dmabuf_v1.info) {
            switch (try self.decode(p.zwp_linux_dmabuf_v1, message, fds)) {
                .modifier => |e| if (e.format == 0x34325258 and e.modifier_hi == 0 and e.modifier_lo == 0) {
                    self.dmabuf_linear = true;
                },
                else => {},
            }
        } else if (interface == &p.zwp_linux_buffer_params_v1.info) {
            switch (try self.decode(p.zwp_linux_buffer_params_v1, message, fds)) {
                .created => |e| self.dma.buffer = try self.connection.objects.insertPeer(e.buffer, &p.wl_buffer.info, 1, null),
                .failed => {},
            }
            self.dma.import_done = true;
        } else if (interface == &p.ext_image_copy_capture_session_v1.info) {
            const d = &self.dma;
            switch (try self.decode(p.ext_image_copy_capture_session_v1, message, fds)) {
                .buffer_size => |e| {
                    if (d.constraints_done and (d.width != e.width or d.height != e.height)) return error.OutputChanged;
                    if (e.width == 0 or e.height == 0 or @as(u64, e.width) * e.height > 128 * 1024 * 1024) return error.InvalidBufferSize;
                    d.width = e.width;
                    d.height = e.height;
                },
                .shm_format => |e| if (e.format.value == 0 or e.format.value == 1 or e.format.value == 0x34324241 or e.format.value == 0x34324258) {
                    d.shm_format = e.format.value;
                },
                .dmabuf_device => |e| {
                    if (e.device.len != 8) return error.InvalidDmaDevice;
                    d.device = @bitCast(e.device[0..8].*);
                },
                .dmabuf_format => |e| {
                    if (e.format == 0x34325258) {
                        var modifiers = std.mem.window(u8, e.modifiers, 8, 8);
                        while (modifiers.next()) |modifier| if (@as(u64, @bitCast(modifier[0..8].*)) == 0) {
                            d.linear = true;
                        };
                    }
                },
                .done => d.constraints_done = true,
                .stopped => return error.CaptureStopped,
            }
        } else if (interface == &p.ext_image_copy_capture_frame_v1.info) {
            switch (try self.decode(p.ext_image_copy_capture_frame_v1, message, fds)) {
                .transform => |e| if (e.transform.value != 0) {
                    return error.CaptureTransformUnsupported;
                },
                .presentation_time => |e| self.dma.timestamp = @intCast(((@as(u64, e.tv_sec_hi) << 32) | e.tv_sec_lo) * 1_000_000_000 + e.tv_nsec),
                .ready => self.dma.ready = true,
                .failed => return error.CaptureFailed,
                else => {},
            }
        } else if (interface == &p.wl_buffer.info) {
            _ = try self.decode(p.wl_buffer, message, fds);
            if (target.object.context) |context| {
                const buffer: *Buffer = @ptrCast(@alignCast(context));
                buffer.busy = false;
            }
        } else if (interface == &p.zwlr_layer_surface_v1.info) {
            const output: *Output = @ptrCast(@alignCast(target.object.context.?));
            switch (try self.decode(p.zwlr_layer_surface_v1, message, fds)) {
                .configure => |e| {
                    try self.send(p.zwlr_layer_surface_v1, output.layer.?, .{ .ack_configure = .{ .serial = e.serial } });
                    if (e.width != output.rect.width or e.height != output.rect.height) return error.OutputChanged;
                    output.configured = true;
                    output.dirty = true;
                },
                .closed => self.cancelled = true,
            }
        } else if (interface == &p.wp_fractional_scale_v1.info) {
            const output: *Output = @ptrCast(@alignCast(target.object.context.?));
            const value = (try self.decode(p.wp_fractional_scale_v1, message, fds)).preferred_scale.scale;
            if (value < 30 or value > 1920) return error.InvalidScale;
            output.preferred_scale = value;
            output.dirty = true;
        } else if (interface == &p.wl_callback.info) {
            _ = try self.decode(p.wl_callback, message, fds);
            const output: *Output = @ptrCast(@alignCast(target.object.context.?));
            output.callback = null;
        } else if (interface == &p.wl_surface.info) {
            _ = try self.decode(p.wl_surface, message, fds);
        } else return error.UnexpectedWaylandEvent;
    }
    fn motion(self: *Client, x: i32, y: i32) !void {
        const index = self.pointer_output orelse return;
        const output = &self.outputs[index];
        self.position = .{ .x = output.rect.x + @divFloor(x, 256), .y = output.rect.y + @divFloor(y, 256) };
        if (self.anchor) |anchor| {
            self.selection = geo.Rect.between(anchor, self.position);
            for (self.outputs[0..self.output_count]) |*other| other.dirty = true;
        }
    }
};
