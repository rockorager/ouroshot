const std = @import("std");
const client = @import("client.zig");
const fixture = @import("service_options").fixture;
const mcp = @import("mcp.zig");
const field = mcp.field;
const c = @cImport({
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/wait.h");
    @cInclude("sys/prctl.h");
    @cInclude("sys/random.h");
    @cInclude("sys/syscall.h");
    @cInclude("linux/openat2.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("signal.h");
    @cInclude("errno.h");
    @cInclude("poll.h");
    @cInclude("stdio.h");
    @cInclude("encode.h");
});
const allocator = std.heap.smp_allocator;
const limit = mcp.limit;
const output_queue_limit = limit;
const receive_chunk = 16 * 1024;

const Connection = struct {
    fd: c_int = -1,
    input: std.ArrayList(u8) = .empty,
    output: ?[]u8 = null,
    sent: usize = 0,
    pending_id: ?[]u8 = null,
    deadline: i64 = 0,

    fn reply(self: *Connection, value: anytype) anyerror!void {
        const json = try std.json.Stringify.valueAlloc(allocator, value, .{ .emit_null_optional_fields = false });
        defer allocator.free(json);
        if (json.len >= limit) return error.ReplyTooLarge;
        const prior = if (self.output) |output| output[self.sent..] else "";
        if (prior.len + json.len + 1 > output_queue_limit) return error.OutputCapacity;
        const output = try allocator.alloc(u8, prior.len + json.len + 1);
        @memcpy(output[0..prior.len], prior);
        @memcpy(output[prior.len..][0..json.len], json);
        output[output.len - 1] = '\n';
        if (self.output) |old| allocator.free(old);
        self.output = output;
        self.sent = 0;
    }
    fn rpcError(self: *Connection, id: mcp.Value, code: i32, message: []const u8) !void {
        try self.reply(.{ .jsonrpc = "2.0", .id = if (id == .null) @as(?mcp.Value, null) else id, .@"error" = .{ .code = code, .message = message } });
    }
    fn toolResult(self: *Connection, id: mcp.Value, data: anytype, is_error: bool) !void {
        const text = try std.json.Stringify.valueAlloc(allocator, data, .{});
        defer allocator.free(text);
        try self.reply(.{ .jsonrpc = "2.0", .id = id, .result = .{
            .resultType = "complete",
            .content = .{.{ .type = "text", .text = text }},
            .structuredContent = data,
            .isError = is_error,
        } });
    }
    fn failure(self: *Connection, id: mcp.Value, code: []const u8) !void {
        try self.toolResult(id, .{ .@"error" = .{ .code = code, .message = code } }, true);
    }
    fn clearPending(self: *Connection) void {
        if (self.pending_id) |id| allocator.free(id);
        self.pending_id = null;
    }
};

const Worker = struct {
    pid: c.pid_t,
    connection: usize,
    fd: c_int,
    bytes: [256]u8 = undefined,
    used: usize = 0,
    image_fd: c_int = -1,
    final_name: [64:0]u8 = @splat(0),
    screenshot: bool,
};

const Service = struct {
    connections: [64]Connection = @splat(.{}),
    worker: ?Worker = null,
    listener: c_int,
    directory: c_int,
    capture_path: []const u8,
    environ: std.process.Environ,
    timeout_ns: i64,
    source_encoding: c_int,

    fn cancel(self: *Service) void {
        if (self.worker) |worker| {
            if (worker.pid > 0) {
                _ = c.kill(worker.pid, c.SIGKILL);
                while (c.waitpid(worker.pid, null, 0) < 0 and errno() == c.EINTR) {}
            }
            _ = c.close(worker.fd);
            if (worker.image_fd >= 0) _ = c.close(worker.image_fd);
            self.connections[worker.connection].clearPending();
            self.worker = null;
        }
    }
    fn close(self: *Service, index: usize) void {
        const connection = &self.connections[index];
        if (self.worker != null and self.worker.?.connection == index) self.cancel();
        if (connection.fd >= 0) _ = c.close(connection.fd);
        connection.input.deinit(allocator);
        if (connection.output) |output| allocator.free(output);
        connection.* = .{};
    }

    fn request(self: *Service, index: usize, bytes: []const u8) !void {
        const connection = &self.connections[index];
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const parsed = std.json.parseFromSlice(mcp.Value, a, bytes, .{ .parse_numbers = false }) catch return connection.rpcError(.null, -32700, "Parse error");
        const root = parsed.value;
        if (root != .object or !mcp.isString(field(root, "jsonrpc"), "2.0") or field(root, "method") != .string)
            return connection.rpcError(.null, -32600, "Invalid request");
        const params = field(root, "params");
        const method = field(root, "method").string;
        if (!root.object.contains("id")) {
            if (std.mem.eql(u8, method, "notifications/cancelled") and connection.pending_id != null) {
                const id = field(params, "requestId");
                if (mcp.validId(id)) {
                    const encoded = try std.json.Stringify.valueAlloc(a, id, .{});
                    if (std.mem.eql(u8, encoded, connection.pending_id.?)) self.cancel();
                }
            }
            return;
        }
        const id = field(root, "id");
        if (!mcp.validId(id)) return connection.rpcError(.null, -32600, "Invalid request ID");
        const encoded_id = try std.json.Stringify.valueAlloc(a, id, .{});
        if (connection.pending_id) |pending| if (std.mem.eql(u8, pending, encoded_id))
            return connection.rpcError(id, -32600, "Request ID already active");
        const meta = field(params, "_meta");
        if (params != .object or meta != .object or field(meta, "io.modelcontextprotocol/protocolVersion") != .string or field(meta, "io.modelcontextprotocol/clientCapabilities") != .object)
            return connection.rpcError(id, -32602, "Required request metadata missing or invalid");
        if (!mcp.isString(field(meta, "io.modelcontextprotocol/protocolVersion"), mcp.version)) {
            return connection.reply(.{ .jsonrpc = "2.0", .id = id, .@"error" = .{
                .code = -32022,
                .message = "Unsupported protocol version",
                .data = .{ .supported = .{mcp.version}, .requested = field(meta, "io.modelcontextprotocol/protocolVersion") },
            } });
        }
        if (std.mem.eql(u8, method, "server/discover")) {
            if (params.object.count() != 1) return connection.rpcError(id, -32602, "Invalid params");
            return connection.reply(.{ .jsonrpc = "2.0", .id = id, .result = .{
                .resultType = "complete",
                .supportedVersions = .{mcp.version},
                .capabilities = .{ .tools = struct {}{} },
                ._meta = .{ .@"io.modelcontextprotocol/serverInfo" = .{ .name = "ouroshot", .version = "0.0.0" } },
                .ttlMs = 60000,
                .cacheScope = "private",
            } });
        }
        if (std.mem.eql(u8, method, "tools/list")) {
            if (params.object.count() != 1) return connection.rpcError(id, -32602, "Invalid params");
            return connection.reply(.{ .jsonrpc = "2.0", .id = id, .result = .{
                .resultType = "complete",
                .tools = try mcp.tools(a),
                .ttlMs = 60000,
                .cacheScope = "private",
            } });
        }
        if (!std.mem.eql(u8, method, "tools/call")) return connection.rpcError(id, -32601, "Method not found");
        const name = field(params, "name");
        const screenshot = mcp.isString(name, "Screenshot");
        if (!screenshot and !mcp.isString(name, "PickColor")) return connection.rpcError(id, -32602, "Unknown tool");
        if (params.object.count() != 3) return connection.rpcError(id, -32602, "Invalid params");
        const arguments = mcp.parameters(a, field(params, "arguments"), screenshot) catch return connection.rpcError(id, -32602, "Invalid arguments");
        // Targets preselect geometry, never authorize sharing without the UI.
        if (!fixture and !screenshot) return connection.failure(id, "Failed");
        if (self.worker != null) return connection.failure(id, "Busy");
        connection.pending_id = try allocator.dupe(u8, encoded_id);
        self.start(index, screenshot, arguments) catch |err| {
            connection.clearPending();
            std.debug.print("ouroshot-service: start: {s}\n", .{@errorName(err)});
            return connection.failure(id, "Failed");
        };
    }

    fn start(self: *Service, index: usize, screenshot: bool, arguments: mcp.Parameters) !void {
        var worker = Worker{ .pid = 0, .connection = index, .fd = -1, .screenshot = screenshot };
        var image_fd: c_int = -1;
        if (screenshot) {
            var random: [16]u8 = undefined;
            if (c.getrandom(&random, random.len, 0) != random.len) return error.RandomFailed;
            const hex = std.fmt.bytesToHex(random, .lower);
            _ = try std.fmt.bufPrintZ(&worker.final_name, "{s}.png", .{hex});
            // Unnamed until commit: even SIGKILL cannot leave an uncommitted PNG.
            image_fd = c.openat(self.directory, ".", c.O_WRONLY | c.O_TMPFILE | c.O_CLOEXEC, @as(c_uint, 0o600));
            if (image_fd < 0) return error.CreateFailed;
        }
        errdefer if (image_fd >= 0) {
            _ = c.close(image_fd);
        };
        var pipe: [2]c_int = undefined;
        if (c.pipe2(&pipe, c.O_CLOEXEC) != 0) return error.PipeFailed;
        errdefer {
            _ = c.close(pipe[0]);
            _ = c.close(pipe[1]);
        }
        const parent = c.getpid();
        const pid = c.fork();
        if (pid < 0) return error.ForkFailed;
        if (pid == 0) {
            // No worker can survive a daemon crash or hold client EOF open.
            if (c.prctl(c.PR_SET_PDEATHSIG, c.SIGKILL, @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0)) != 0 or c.getppid() != parent) c._exit(1);
            _ = c.close(self.listener);
            _ = c.close(self.directory);
            _ = c.close(pipe[0]);
            for (&self.connections) |connection| if (connection.fd >= 0) {
                _ = c.close(connection.fd);
            };
            const color = capture(self.environ, screenshot, image_fd, arguments, self.source_encoding) catch |err| {
                std.debug.print("ouroshot-service: capture: {s}\n", .{@errorName(err)});
                writeAll(pipe[1], if (err == error.Cancelled) "C" else "F") catch {};
                c._exit(0);
            };
            var result: [256]u8 = undefined;
            const bytes = if (screenshot) "S" else std.fmt.bufPrint(&result, "[{d},{d},{d}]", .{ color[0], color[1], color[2] }) catch unreachable;
            writeAll(pipe[1], bytes) catch {};
            c._exit(0);
        }
        _ = c.close(pipe[1]);
        _ = c.fcntl(pipe[0], c.F_SETFL, @as(c_int, c.O_NONBLOCK));
        worker.pid = pid;
        worker.fd = pipe[0];
        worker.image_fd = image_fd;
        self.worker = worker;
    }

    fn finish(self: *Service) !void {
        const worker = if (self.worker) |*value| value else return;
        const connection = &self.connections[worker.connection];
        if (connection.output != null or connection.input.items.len != 0) return;
        const n = c.read(worker.fd, worker.bytes[worker.used..].ptr, worker.bytes.len - worker.used);
        if (n > 0) {
            worker.used += @intCast(n);
            return;
        }
        if (n < 0 and (errno() == c.EAGAIN or errno() == c.EINTR)) return;
        const index = worker.connection;
        // The worker has exited and closed the PNG before this point. Recheck
        // EOF *before* commit; after commit even an ambiguous send retains it.
        var probe: u8 = 0;
        const live = c.recv(self.connections[index].fd, &probe, 1, c.MSG_PEEK | c.MSG_DONTWAIT);
        if (live > 0) return; // Process cancellation/input before committing.
        if (live == 0 or (errno() != c.EAGAIN and errno() != c.EINTR) or client.now() >= connection.deadline or c.shot_stopping() != 0) {
            self.close(index);
            return;
        }
        var status: c_int = 0;
        const waited = c.waitpid(worker.pid, &status, c.WNOHANG);
        if (waited == 0 or (waited < 0 and errno() == c.EINTR)) return;
        worker.pid = 0; // Reaped: cleanup must never signal a reused PID.
        if (waited < 0) status = 1;
        const parsed_id = try std.json.parseFromSlice(mcp.Value, allocator, connection.pending_id.?, .{ .parse_numbers = false });
        defer parsed_id.deinit();
        const id = parsed_id.value;
        const result = worker.bytes[0..worker.used];
        if (status != 0 or result.len == 0 or std.mem.eql(u8, result, "F")) {
            try connection.failure(id, "Failed");
        } else if (std.mem.eql(u8, result, "C")) {
            try connection.failure(id, "Cancelled");
        } else if (worker.screenshot and std.mem.eql(u8, result, "S")) {
            const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.capture_path, std.mem.sliceTo(&worker.final_name, 0) });
            defer allocator.free(path);
            const uri = try fileUri(path);
            defer allocator.free(uri);
            // Allocate the complete reply before the artifact commit. OOM cannot
            // commit an image without even attempting its final reply.
            try connection.toolResult(id, .{ .uri = uri }, false);
            var fd_path: [64]u8 = undefined;
            const source = try std.fmt.bufPrintZ(&fd_path, "/proc/self/fd/{d}", .{worker.image_fd});
            // linkat is atomic and cannot overwrite. /proc/self/fd permits an
            // unprivileged O_TMPFILE owner to publish without CAP_DAC_READ_SEARCH.
            if (c.linkat(c.AT_FDCWD, source, self.directory, &worker.final_name, c.AT_SYMLINK_FOLLOW) != 0) {
                allocator.free(self.connections[index].output.?);
                self.connections[index].output = null;
                try connection.failure(id, "Failed");
            }
        } else if (!worker.screenshot) {
            const parsed = std.json.parseFromSlice([3]f64, allocator, result, .{}) catch {
                try connection.failure(id, "Failed");
                self.cancel();
                return;
            };
            defer parsed.deinit();
            for (parsed.value) |component| if (!std.math.isFinite(component) or component < 0 or component > 1) return error.InvalidWorkerColor;
            try connection.toolResult(id, .{ .color = parsed.value }, false);
        } else try connection.failure(id, "Failed");
        // Reaped already; do not signal a potentially reused PID.
        self.cancel();
    }

    fn loop(self: *Service, idle_ns: i64) !void {
        var idle_since = client.now();
        while (c.shot_stopping() == 0) {
            var polls: [66]c.struct_pollfd = undefined;
            polls[0] = .{ .fd = self.listener, .events = c.POLLIN, .revents = 0 };
            for (&self.connections, 0..) |connection, i| polls[i + 1] = .{ .fd = connection.fd, .events = @intCast(c.POLLIN | (if (connection.output != null) c.POLLOUT else @as(c_int, 0))), .revents = 0 };
            polls[65] = .{ .fd = if (self.worker) |w| w.fd else -1, .events = c.POLLIN, .revents = 0 };
            const n = c.poll(&polls, polls.len, 50);
            if (n < 0 and errno() != c.EINTR) return error.PollFailed;
            // Client EOF always wins over a simultaneously ready worker result.
            for (&self.connections, 0..) |*connection, i| {
                if (connection.fd < 0) continue;
                const events = polls[i + 1].revents;
                if (client.now() >= connection.deadline) {
                    self.close(i);
                    continue;
                }
                if (events & (c.POLLERR | c.POLLNVAL) != 0) {
                    self.close(i);
                    continue;
                }
                if (connection.input.items.len < limit and events & (c.POLLIN | c.POLLHUP) != 0) {
                    const available = limit - connection.input.items.len;
                    const chunk = @min(receive_chunk, available);
                    if (connection.input.capacity - connection.input.items.len < chunk) {
                        const desired = @min(limit, @max(connection.input.items.len + chunk, @max(receive_chunk, connection.input.capacity * 2)));
                        connection.input.ensureTotalCapacityPrecise(allocator, desired) catch {
                            self.close(i);
                            continue;
                        };
                    }
                    const buffer = connection.input.unusedCapacitySlice()[0..chunk];
                    const count = c.recv(connection.fd, buffer.ptr, buffer.len, c.MSG_DONTWAIT);
                    if (count == 0 or (count < 0 and errno() != c.EAGAIN and errno() != c.EINTR)) {
                        self.close(i);
                        continue;
                    }
                    if (count > 0) {
                        if (connection.input.items.len == 0 and connection.pending_id == null and connection.output == null)
                            connection.deadline = client.now() + self.timeout_ns;
                        connection.input.items.len += @intCast(count);
                    }
                }
                // Bound work per client/tick and leave partial frames buffered.
                for (0..16) |_| {
                    const input = connection.input.items;
                    const end = std.mem.indexOfScalar(u8, input, '\n') orelse break;
                    self.request(i, input[0..end]) catch {
                        self.close(i);
                        break;
                    };
                    connection.input.replaceRange(allocator, 0, end + 1, "") catch unreachable;
                }
                if (connection.fd < 0) continue;
                if (connection.input.items.len == limit and std.mem.indexOfScalar(u8, connection.input.items, '\n') == null) {
                    self.close(i);
                    continue;
                }
                if (connection.fd >= 0 and connection.output != null and events & c.POLLOUT != 0) {
                    const output = connection.output.?;
                    const count = c.send(connection.fd, output[connection.sent..].ptr, output.len - connection.sent, c.MSG_NOSIGNAL);
                    if (count > 0) connection.sent += @intCast(count) else if (count == 0 or (errno() != c.EAGAIN and errno() != c.EINTR)) {
                        self.close(i);
                        continue;
                    }
                    if (connection.sent == output.len) {
                        allocator.free(output);
                        connection.output = null;
                        connection.sent = 0;
                    }
                }
            }
            if (self.worker) |worker| if (polls[65].revents != 0) {
                self.finish() catch self.close(worker.connection);
            };
            if (polls[0].revents & c.POLLIN != 0) {
                // Bound accepts per tick; a connect flood must not starve EOF.
                for (0..16) |_| {
                    const fd = c.accept4(self.listener, .{ .__sockaddr__ = null }, null, c.SOCK_NONBLOCK | c.SOCK_CLOEXEC);
                    if (fd < 0) break;
                    const send_buffer: c_int = 16 * 1024;
                    if (c.setsockopt(fd, c.SOL_SOCKET, c.SO_SNDBUF, &send_buffer, @sizeOf(c_int)) != 0) {
                        _ = c.close(fd);
                        continue;
                    }
                    var credentials: c.struct_ucred = undefined;
                    var size: c.socklen_t = @sizeOf(c.struct_ucred);
                    if (c.getsockopt(fd, c.SOL_SOCKET, c.SO_PEERCRED, &credentials, &size) != 0 or size != @sizeOf(c.struct_ucred) or credentials.uid != c.geteuid()) {
                        // No request ID exists yet; reject the transport.
                        _ = c.close(fd);
                        continue;
                    }
                    var slot: ?*Connection = null;
                    for (&self.connections) |*connection| if (connection.fd < 0) {
                        slot = connection;
                        break;
                    };
                    if (slot) |connection| connection.* = .{ .fd = fd, .deadline = client.now() + self.timeout_ns } else {
                        _ = c.close(fd);
                    }
                }
            }
            var active = self.worker != null;
            for (&self.connections) |connection| active = active or connection.fd >= 0;
            if (active or polls[0].revents & c.POLLIN != 0) idle_since = client.now();
            if (client.now() - idle_since >= idle_ns) return;
        }
    }
};

fn capture(environ: std.process.Environ, screenshot: bool, image_fd: c_int, arguments: mcp.Parameters, source_encoding: c_int) ![3]f64 {
    if (fixture) {
        // Only in the separately named test binary, never in ouroshot-service.
        // stdin is a deterministic UI gate: S=accept, C=cancel, F=fail.
        var gate: u8 = 0;
        if (c.read(0, &gate, 1) != 1) return error.FixtureClosed;
        if (gate == 'C') return error.Cancelled;
        if (gate != 'S') return error.FixtureFailed;
        if (screenshot and c.shot_png_fd(image_fd, &[_]u8{ 51, 102, 204, 255, 17, 34, 68, 255 }, 2, 1, source_encoding) != 0) return error.PngWriteFailed;
        return .{ 0.8, 0.4, 0.2 };
    }
    if (!screenshot) return error.CaptureUnavailable;
    var app: client.Client = undefined;
    try app.init(environ);
    defer app.deinit();
    const preset = try app.resolveTarget(arguments.monitor, arguments.region);
    _ = try app.capture(false, null);
    // The frozen overlay requires a drag or explicit preset confirmation.
    const region = try app.select(true, preset);
    var image = try app.compose(region);
    defer image.deinit(allocator);
    if (c.shot_png_fd(image_fd, image.data.ptr, @intCast(image.width), @intCast(image.height), source_encoding) != 0) return error.PngWriteFailed;
    return .{ 0, 0, 0 };
}

fn errno() c_int {
    return c.__errno_location().*;
}
fn writeAll(fd: c_int, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = c.write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (n < 0 and errno() == c.EINTR) continue;
        if (n <= 0) return error.WriteFailed;
        offset += @intCast(n);
    }
}
fn fileUri(path: []const u8) ![]u8 {
    var result: std.Io.Writer.Allocating = .init(allocator);
    errdefer result.deinit();
    try result.writer.writeAll("file://");
    for (path) |byte| {
        if (std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "/-._~", byte) != null) try result.writer.writeByte(byte) else try result.writer.print("%{X:0>2}", .{byte});
    }
    return result.toOwnedSlice();
}

fn privateDirectory(parent: c_int, name: [:0]const u8, create: bool) !c_int {
    if (create and c.mkdirat(parent, name, @as(c_uint, 0o700)) != 0 and errno() != c.EEXIST) return error.DirectoryCreateFailed;
    var how = c.struct_open_how{ .flags = c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC, .resolve = c.RESOLVE_NO_SYMLINKS, .mode = 0 };
    const fd: c_int = @intCast(c.syscall(c.SYS_openat2, parent, name.ptr, &how, @as(c_ulong, @sizeOf(c.struct_open_how))));
    if (fd < 0) return error.UnsafeDirectory;
    errdefer _ = c.close(fd);
    var stat: c.struct_stat = undefined;
    if (c.fstat(fd, &stat) != 0 or stat.st_uid != c.geteuid() or stat.st_mode & 0o777 != 0o700) return error.UnsafeDirectory;
    return fd;
}

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        std.debug.print("ouroshot-service: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    c.shot_signals();
    _ = c.umask(0o077);
    var idle_ms: i64 = 30_000;
    var timeout_ms: i64 = 300_000;
    var source_encoding: c_int = c.SHOT_SOURCE_UNKNOWN;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--help")) return writeAll(1, "ouroshot-service [--idle-ms N] [--timeout-ms N] [--export-mcp-descriptor]\n  [--source-encoding unknown|srgb|gamma22] (default unknown; known sRGB primaries)\nMCP socket: $XDG_RUNTIME_DIR/ouro/capture.mcp.sock, or systemd LISTEN_FDS=1.\nScreenshot uses the existing region selector. PickColor is not yet available.\n");
        if (std.mem.eql(u8, args[i], "--export-mcp-descriptor")) {
            try writeAll(1, try mcp.descriptor(init.arena.allocator()));
            return writeAll(1, "\n");
        }
        if (i + 1 >= args.len) return error.UnknownOption;
        if (std.mem.eql(u8, args[i], "--source-encoding")) {
            source_encoding = c.shot_source_encoding(args[i + 1]);
            if (source_encoding < 0) return error.InvalidSourceEncoding;
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, args[i], "--idle-ms")) idle_ms = try std.fmt.parseInt(i64, args[i + 1], 10) else if (std.mem.eql(u8, args[i], "--timeout-ms")) timeout_ms = try std.fmt.parseInt(i64, args[i + 1], 10) else return error.UnknownOption;
        i += 1;
    }
    if (idle_ms < 1 or idle_ms > 300_000 or timeout_ms < 1 or timeout_ms > 300_000) return error.InvalidTimeout;
    const runtime = init.minimal.environ.getPosix("XDG_RUNTIME_DIR") orelse return error.MissingRuntimeDirectory;
    if (runtime.len == 0 or runtime[0] != '/' or std.mem.indexOf(u8, runtime, "/../") != null) return error.UnsafeDirectory;
    const root = try privateDirectory(c.AT_FDCWD, runtime, false);
    defer _ = c.close(root);
    const ouro = try privateDirectory(root, "ouro", true);
    defer _ = c.close(ouro);
    const directory = try privateDirectory(ouro, "captures", true);
    defer _ = c.close(directory);
    const path = try std.fmt.allocPrintSentinel(allocator, "{s}/ouro/capture.mcp.sock", .{runtime}, 0);
    defer allocator.free(path);
    var address: c.struct_sockaddr_un = std.mem.zeroes(c.struct_sockaddr_un);
    address.sun_family = c.AF_UNIX;
    if (path.len >= address.sun_path.len) return error.SocketPathTooLong;
    @memcpy(@as([*]u8, @ptrCast(&address.sun_path))[0..path.len], path);
    var activated = false;
    var listener: c_int = -1;
    if (init.minimal.environ.getPosix("LISTEN_FDS")) |fds| {
        const pid = init.minimal.environ.getPosix("LISTEN_PID") orelse return error.InvalidActivation;
        if (!std.mem.eql(u8, fds, "1") or (try std.fmt.parseInt(c.pid_t, pid, 10)) != c.getpid()) return error.InvalidActivation;
        listener = 3;
        var actual: c.struct_sockaddr_un = std.mem.zeroes(c.struct_sockaddr_un);
        var size: c.socklen_t = @sizeOf(c.struct_sockaddr_un);
        var accepting: c_int = 0;
        var socket_type: c_int = 0;
        var option_size: c.socklen_t = @sizeOf(c_int);
        if (c.getsockname(listener, .{ .__sockaddr_un__ = &actual }, &size) != 0 or actual.sun_family != c.AF_UNIX or !std.mem.eql(u8, std.mem.sliceTo(&actual.sun_path, 0), path) or c.getsockopt(listener, c.SOL_SOCKET, c.SO_ACCEPTCONN, &accepting, &option_size) != 0 or accepting != 1) return error.InvalidActivation;
        if (c.getsockopt(listener, c.SOL_SOCKET, c.SO_TYPE, &socket_type, &option_size) != 0 or socket_type != c.SOCK_STREAM) return error.InvalidActivation;
        activated = true;
    } else {
        listener = c.socket(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_NONBLOCK | c.SOCK_CLOEXEC, 0);
        if (listener < 0) return error.SocketFailed;
        errdefer _ = c.close(listener);
        // Do not unlink an existing endpoint: it could belong to a live daemon.
        if (c.bind(listener, .{ .__sockaddr_un__ = &address }, @sizeOf(c.struct_sockaddr_un)) != 0) return error.BindFailed;
        errdefer _ = c.unlinkat(ouro, "capture.mcp.sock", 0);
        if (c.chmod(path, 0o600) != 0 or c.listen(listener, 64) != 0) return error.ListenFailed;
    }
    defer _ = c.close(listener);
    defer if (!activated) {
        _ = c.unlinkat(ouro, "capture.mcp.sock", 0);
    };
    var socket_stat: c.struct_stat = undefined;
    if (c.fstatat(ouro, "capture.mcp.sock", &socket_stat, c.AT_SYMLINK_NOFOLLOW) != 0 or socket_stat.st_uid != c.geteuid() or socket_stat.st_mode & c.S_IFMT != c.S_IFSOCK or socket_stat.st_mode & 0o777 != 0o600) return error.UnsafeSocket;
    if (c.fcntl(listener, c.F_SETFL, @as(c_int, c.O_NONBLOCK)) != 0 or c.fcntl(listener, c.F_SETFD, @as(c_int, c.FD_CLOEXEC)) != 0) return error.InvalidActivation;
    const capture_path = try std.fmt.allocPrint(allocator, "{s}/ouro/captures", .{runtime});
    defer allocator.free(capture_path);
    const service = try allocator.create(Service);
    defer allocator.destroy(service);
    service.* = .{ .listener = listener, .directory = directory, .capture_path = capture_path, .environ = init.minimal.environ, .timeout_ns = timeout_ms * 1_000_000, .source_encoding = source_encoding };
    defer for (0..service.connections.len) |index| service.close(index);
    try service.loop(idle_ms * 1_000_000);
}
