const std = @import("std");
const client = @import("client.zig");
const fixture = @import("service_options").fixture;
const idl = @embedFile("capture_idl");
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
const interface = "dev.rockorager.ouro.Capture";
const limit = 65536; // Includes the terminating NUL.
const Context = struct { app_id: []const u8, parent_window: []const u8, origin: []const u8, require_confirmation: bool, permission_store_checked: bool };
const Parameters = struct { context: Context, modal: bool, interactive: bool };
const Request = struct { method: []const u8, parameters: std.json.Value = .null, more: bool = false, oneway: bool = false, upgrade: bool = false };

const Connection = struct {
    fd: c_int = -1,
    input: [limit]u8 = undefined,
    used: usize = 0,
    output: ?[]u8 = null,
    sent: usize = 0,
    pending: bool = false,
    deadline: i64 = 0,

    fn reply(self: *Connection, value: anytype) anyerror!void {
        const json = try std.json.Stringify.valueAlloc(allocator, value, .{});
        defer allocator.free(json);
        if (json.len >= limit) return self.invalid("request");
        self.output = try allocator.alloc(u8, json.len + 1);
        @memcpy(self.output.?[0..json.len], json);
        self.output.?[json.len] = 0;
        self.pending = false;
    }
    fn failure(self: *Connection, name: []const u8) !void {
        try self.reply(.{ .@"error" = name, .parameters = struct {}{} });
    }
    fn invalid(self: *Connection, parameter: []const u8) !void {
        try self.reply(.{ .@"error" = "org.varlink.service.InvalidParameter", .parameters = .{ .parameter = parameter } });
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

    fn cancel(self: *Service) void {
        if (self.worker) |worker| {
            if (worker.pid > 0) {
                _ = c.kill(worker.pid, c.SIGKILL);
                while (c.waitpid(worker.pid, null, 0) < 0 and errno() == c.EINTR) {}
            }
            _ = c.close(worker.fd);
            if (worker.image_fd >= 0) _ = c.close(worker.image_fd);
            self.worker = null;
        }
    }
    fn close(self: *Service, index: usize) void {
        const connection = &self.connections[index];
        if (self.worker != null and self.worker.?.connection == index) self.cancel();
        if (connection.fd >= 0) _ = c.close(connection.fd);
        if (connection.output) |output| allocator.free(output);
        connection.* = .{};
    }

    fn request(self: *Service, index: usize, bytes: []const u8) !void {
        const connection = &self.connections[index];
        // Parsing is bounded independently of frame size (including nested JSON).
        var memory: [1024 * 1024]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&memory);
        const parsed = std.json.parseFromSlice(Request, fixed.allocator(), bytes, .{}) catch return connection.invalid("request");
        const request_value = parsed.value;
        if (request_value.more or request_value.oneway or request_value.upgrade) return connection.invalid("flags");
        if (std.mem.eql(u8, request_value.method, "org.varlink.service.GetInfo")) {
            return connection.reply(.{ .parameters = .{ .vendor = "rockorager", .product = "ouroshot", .version = "0.0.0", .url = "https://github.com/rockorager/ouroshot", .interfaces = .{ "org.varlink.service", interface } } });
        }
        if (std.mem.eql(u8, request_value.method, "org.varlink.service.GetInterfaceDescription")) {
            const params = std.json.parseFromValue(struct { interface: []const u8 }, fixed.allocator(), request_value.parameters, .{}) catch return connection.invalid("parameters");
            if (std.mem.eql(u8, params.value.interface, interface)) return connection.reply(.{ .parameters = .{ .description = idl } });
            if (std.mem.eql(u8, params.value.interface, "org.varlink.service")) return connection.reply(.{ .parameters = .{ .description = service_idl } });
            return connection.reply(.{ .@"error" = "org.varlink.service.InterfaceNotFound", .parameters = .{ .interface = params.value.interface } });
        }
        const screenshot = std.mem.eql(u8, request_value.method, interface ++ ".Screenshot");
        if (!screenshot and !std.mem.eql(u8, request_value.method, interface ++ ".PickColor")) {
            const dot = std.mem.lastIndexOfScalar(u8, request_value.method, '.') orelse return connection.invalid("method");
            const name = request_value.method[0..dot];
            if (!std.mem.eql(u8, name, interface) and !std.mem.eql(u8, name, "org.varlink.service")) return connection.reply(.{ .@"error" = "org.varlink.service.InterfaceNotFound", .parameters = .{ .interface = name } });
            return connection.reply(.{ .@"error" = "org.varlink.service.MethodNotFound", .parameters = .{ .method = request_value.method[dot + 1 ..] } });
        }
        _ = std.json.parseFromValue(Parameters, fixed.allocator(), request_value.parameters, .{}) catch return connection.invalid("parameters");
        // Color selection is deferred. Screenshots use the existing selector;
        // caller hints never bypass the user's explicit region selection.
        if (!fixture and !screenshot) return connection.failure(interface ++ ".Failed");
        if (self.worker != null) return connection.failure(interface ++ ".Busy");
        self.start(index, screenshot) catch |err| {
            std.debug.print("ouroshot-service: start: {s}\n", .{@errorName(err)});
            return connection.failure(interface ++ ".Failed");
        };
    }

    fn start(self: *Service, index: usize, screenshot: bool) !void {
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
            const color = capture(self.environ, screenshot, image_fd) catch |err| {
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
        self.connections[index].pending = true;
    }

    fn finish(self: *Service) !void {
        const worker = if (self.worker) |*value| value else return;
        const n = c.read(worker.fd, worker.bytes[worker.used..].ptr, worker.bytes.len - worker.used);
        if (n > 0) {
            worker.used += @intCast(n);
            return;
        }
        if (n < 0 and (errno() == c.EAGAIN or errno() == c.EINTR)) return;
        const index = worker.connection;
        var status: c_int = 0;
        const waited = c.waitpid(worker.pid, &status, c.WNOHANG);
        if (waited == 0 or (waited < 0 and errno() == c.EINTR)) return;
        worker.pid = 0; // Reaped: cleanup must never signal a reused PID.
        if (waited < 0) status = 1;
        // The worker has exited and closed the PNG before this point. Recheck
        // EOF *before* commit; after commit even an ambiguous send retains it.
        var probe: u8 = 0;
        const live = c.recv(self.connections[index].fd, &probe, 1, c.MSG_PEEK | c.MSG_DONTWAIT);
        if (live >= 0 or (errno() != c.EAGAIN and errno() != c.EINTR) or client.now() >= self.connections[index].deadline or c.shot_stopping() != 0) {
            self.close(index);
            return;
        }
        const result = worker.bytes[0..worker.used];
        if (status != 0 or result.len == 0 or std.mem.eql(u8, result, "F")) {
            try self.connections[index].failure(interface ++ ".Failed");
        } else if (std.mem.eql(u8, result, "C")) {
            try self.connections[index].failure(interface ++ ".Cancelled");
        } else if (worker.screenshot and std.mem.eql(u8, result, "S")) {
            const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.capture_path, std.mem.sliceTo(&worker.final_name, 0) });
            defer allocator.free(path);
            const uri = try fileUri(path);
            defer allocator.free(uri);
            // Allocate the complete reply before the artifact commit. OOM cannot
            // commit an image without even attempting its final reply.
            try self.connections[index].reply(.{ .parameters = .{ .uri = uri } });
            var fd_path: [64]u8 = undefined;
            const source = try std.fmt.bufPrintZ(&fd_path, "/proc/self/fd/{d}", .{worker.image_fd});
            // linkat is atomic and cannot overwrite. /proc/self/fd permits an
            // unprivileged O_TMPFILE owner to publish without CAP_DAC_READ_SEARCH.
            if (c.linkat(c.AT_FDCWD, source, self.directory, &worker.final_name, c.AT_SYMLINK_FOLLOW) != 0) {
                allocator.free(self.connections[index].output.?);
                self.connections[index].output = null;
                try self.connections[index].failure(interface ++ ".Failed");
            }
        } else if (!worker.screenshot) {
            const parsed = std.json.parseFromSlice([3]f64, allocator, result, .{}) catch {
                try self.connections[index].failure(interface ++ ".Failed");
                self.cancel();
                return;
            };
            defer parsed.deinit();
            for (parsed.value) |component| if (!std.math.isFinite(component) or component < 0 or component > 1) return error.InvalidWorkerColor;
            try self.connections[index].reply(.{ .parameters = .{ .color = parsed.value } });
        } else try self.connections[index].failure(interface ++ ".Failed");
        // Reaped already; do not signal a potentially reused PID.
        _ = c.close(worker.fd);
        if (worker.image_fd >= 0) _ = c.close(worker.image_fd);
        self.worker = null;
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
                if (events & (c.POLLIN | c.POLLHUP) != 0) {
                    var extra: [1]u8 = undefined;
                    const buffer = if (connection.pending or connection.output != null) &extra else connection.input[connection.used..];
                    const count = c.recv(connection.fd, buffer.ptr, buffer.len, c.MSG_DONTWAIT);
                    if (count == 0 or (count < 0 and errno() != c.EAGAIN and errno() != c.EINTR)) {
                        self.close(i);
                        continue;
                    }
                    if (count > 0) {
                        if (connection.pending or connection.output != null) {
                            self.close(i);
                            continue;
                        }
                        connection.used += @intCast(count);
                        const input = connection.input[0..connection.used];
                        if (std.mem.indexOfScalar(u8, input, 0)) |end| {
                            if (end + 1 != input.len) try connection.invalid("framing") else try self.request(i, input[0..end]);
                        } else if (connection.used == limit) try connection.invalid("request");
                    }
                }
                if (connection.fd >= 0 and connection.output != null and events & c.POLLOUT != 0) {
                    const output = connection.output.?;
                    const count = c.send(connection.fd, output[connection.sent..].ptr, output.len - connection.sent, c.MSG_NOSIGNAL);
                    if (count > 0) connection.sent += @intCast(count) else if (count == 0 or (errno() != c.EAGAIN and errno() != c.EINTR)) {
                        self.close(i);
                        continue;
                    }
                    if (connection.sent == output.len) self.close(i);
                }
            }
            if (self.worker != null and polls[65].revents != 0) try self.finish();
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
                        _ = c.send(fd, denied.ptr, denied.len, c.MSG_NOSIGNAL);
                        _ = c.close(fd);
                        continue;
                    }
                    var slot: ?*Connection = null;
                    for (&self.connections) |*connection| if (connection.fd < 0) {
                        slot = connection;
                        break;
                    };
                    if (slot) |connection| connection.* = .{ .fd = fd, .deadline = client.now() + self.timeout_ns } else {
                        _ = c.send(fd, busy.ptr, busy.len, c.MSG_NOSIGNAL);
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

fn capture(environ: std.process.Environ, screenshot: bool, image_fd: c_int) ![3]f64 {
    if (fixture) {
        // Only in the separately named test binary, never in ouroshot-service.
        // stdin is a deterministic UI gate: S=accept, C=cancel, F=fail.
        var gate: u8 = 0;
        if (c.read(0, &gate, 1) != 1) return error.FixtureClosed;
        if (gate == 'C') return error.Cancelled;
        if (gate != 'S') return error.FixtureFailed;
        if (screenshot and c.shot_png_fd(image_fd, &[_]u8{ 51, 102, 204, 255, 17, 34, 68, 255 }, 2, 1) != 0) return error.PngWriteFailed;
        return .{ 0.8, 0.4, 0.2 };
    }
    if (!screenshot) return error.CaptureUnavailable;
    var app: client.Client = undefined;
    try app.init(environ);
    defer app.deinit();
    _ = try app.capture(false, null);
    // Reuse the CLI's frozen selector: finishing a drag approves only that
    // region. No separate card, automatic full-desktop capture or new UI.
    const region = try app.select(true);
    var image = try app.compose(region);
    defer image.deinit(allocator);
    if (c.shot_png_fd(image_fd, image.data.ptr, @intCast(image.width), @intCast(image.height)) != 0) return error.PngWriteFailed;
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
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--help")) return writeAll(1, "ouroshot-service [--idle-ms N] [--timeout-ms N]\nSocket: $XDG_RUNTIME_DIR/ouro/capture.sock, or systemd LISTEN_FDS=1.\nScreenshot uses the existing region selector. PickColor is not yet available.\n");
        if (i + 1 >= args.len) return error.UnknownOption;
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
    const path = try std.fmt.allocPrintSentinel(allocator, "{s}/ouro/capture.sock", .{runtime}, 0);
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
        errdefer _ = c.unlinkat(ouro, "capture.sock", 0);
        if (c.chmod(path, 0o600) != 0 or c.listen(listener, 64) != 0) return error.ListenFailed;
    }
    defer _ = c.close(listener);
    defer if (!activated) {
        _ = c.unlinkat(ouro, "capture.sock", 0);
    };
    var socket_stat: c.struct_stat = undefined;
    if (c.fstatat(ouro, "capture.sock", &socket_stat, c.AT_SYMLINK_NOFOLLOW) != 0 or socket_stat.st_uid != c.geteuid() or socket_stat.st_mode & c.S_IFMT != c.S_IFSOCK or socket_stat.st_mode & 0o777 != 0o600) return error.UnsafeSocket;
    if (c.fcntl(listener, c.F_SETFL, @as(c_int, c.O_NONBLOCK)) != 0 or c.fcntl(listener, c.F_SETFD, @as(c_int, c.FD_CLOEXEC)) != 0) return error.InvalidActivation;
    const capture_path = try std.fmt.allocPrint(allocator, "{s}/ouro/captures", .{runtime});
    defer allocator.free(capture_path);
    const service = try allocator.create(Service);
    defer allocator.destroy(service);
    service.* = .{ .listener = listener, .directory = directory, .capture_path = capture_path, .environ = init.minimal.environ, .timeout_ns = timeout_ms * 1_000_000 };
    defer for (0..service.connections.len) |index| service.close(index);
    try service.loop(idle_ms * 1_000_000);
}

const denied = "{\"error\":\"dev.rockorager.ouro.Capture.Denied\",\"parameters\":{}}\x00";
const busy = "{\"error\":\"dev.rockorager.ouro.Capture.Busy\",\"parameters\":{}}\x00";
const service_idl =
    \\interface org.varlink.service
    \\method GetInfo() -> (vendor: string, product: string, version: string, url: string, interfaces: []string)
    \\method GetInterfaceDescription(interface: string) -> (description: string)
    \\error InterfaceNotFound(interface: string)
    \\error MethodNotFound(method: string)
    \\error MethodNotImplemented(method: string)
    \\error InvalidParameter(parameter: string)
;
