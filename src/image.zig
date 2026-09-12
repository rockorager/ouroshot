const std = @import("std");
const geo = @import("geometry.zig");
pub const Image = struct {
    width: u32,
    height: u32,
    data: []u8,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !Image {
        const size = @as(u64, width) * height * 4;
        if (width == 0 or height == 0 or size > 512 * 1024 * 1024) return error.ImageTooLarge;
        const data = try allocator.alloc(u8, @intCast(size));
        @memset(data, 0);
        var i: usize = 3;
        while (i < data.len) : (i += 4) data[i] = 255;
        return .{ .width = width, .height = height, .data = data };
    }
    pub fn deinit(self: *Image, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        self.* = undefined;
    }
    pub fn pixel(self: Image, x: u32, y: u32) *[4]u8 {
        return self.data[(@as(usize, y) * self.width + x) * 4 ..][0..4];
    }

    // Preserve native pixels on one output. Expand partial edge pixels rather
    // than resampling or assuming rounded logical output sizes are exact.
    pub fn crop(self: Image, allocator: std.mem.Allocator, output: geo.Rect, region: geo.Rect) !Image {
        const rect = try geo.nativeCrop(output, region, self.width, self.height);
        const result = try init(allocator, rect.width, rect.height);
        for (0..result.height) |y| {
            const start = ((@as(usize, @intCast(rect.y)) + y) * self.width + @as(usize, @intCast(rect.x))) * 4;
            @memcpy(result.data[y * result.width * 4 ..][0 .. result.width * 4], self.data[start..][0 .. result.width * 4]);
        }
        return result;
    }

    // Transform the raw output buffer as described by wl_output.transform.
    // Screenshots/previews are opaque. For premultiplied ARGB, retaining the
    // associated RGB and setting alpha to 255 flattens against black in the
    // source encoding. Export conversion happens only after this normalization.
    pub fn fromBuffer(allocator: std.mem.Allocator, bytes: []const u8, width: u32, height: u32, stride: u32, format: u32, y_invert: bool, transform: u32) !Image {
        if (transform > 7 or stride < @as(u64, width) * 4 or bytes.len < @as(u64, stride) * height) return error.InvalidBuffer;
        if (format != 0 and format != 1 and format != 0x34324241 and format != 0x34324258) return error.UnsupportedPixelFormat;
        const swap = transform & 1 != 0;
        const result = try init(allocator, if (swap) height else width, if (swap) width else height);
        // Reflection reverses rotation order when reconstructing the output.
        const rotation = if (transform >= 4) (4 - (transform & 3)) & 3 else transform;
        for (0..height) |y| for (0..width) |x| {
            const fx = if (transform >= 4) width - 1 - x else x;
            const dx = switch (rotation) {
                0 => fx,
                1 => height - 1 - y,
                2 => width - 1 - fx,
                3 => y,
                else => unreachable,
            };
            const dy = switch (rotation) {
                0 => y,
                1 => fx,
                2 => height - 1 - y,
                3 => width - 1 - fx,
                else => unreachable,
            };
            const row = if (y_invert) height - 1 - y else y;
            const src = bytes[row * stride + x * 4 ..][0..4];
            const dst = result.pixel(@intCast(dx), @intCast(dy));
            dst.* = src.*;
            if (format == 0x34324241 or format == 0x34324258) {
                dst[0] = src[2];
                dst[2] = src[0];
            }
            dst[3] = 255;
        };
        return result;
    }

    pub fn composite(self: Image, source: Image, output: geo.Rect, region: geo.Rect, scale120: u32) void {
        _ = output.intersection(region) orelse return;
        for (0..self.height) |y| {
            const ly = @as(f64, @floatFromInt(region.y)) + (@as(f64, @floatFromInt(y)) + 0.5) * 120 / @as(f64, @floatFromInt(scale120));
            if (ly < @as(f64, @floatFromInt(output.y)) or ly >= @as(f64, @floatFromInt(output.bottom()))) continue;
            for (0..self.width) |x| {
                const lx = @as(f64, @floatFromInt(region.x)) + (@as(f64, @floatFromInt(x)) + 0.5) * 120 / @as(f64, @floatFromInt(scale120));
                if (lx < @as(f64, @floatFromInt(output.x)) or lx >= @as(f64, @floatFromInt(output.right()))) continue;
                const sx: u32 = @min(source.width - 1, @as(u32, @intFromFloat((lx - @as(f64, @floatFromInt(output.x))) * @as(f64, @floatFromInt(source.width)) / @as(f64, @floatFromInt(output.width)))));
                const sy: u32 = @min(source.height - 1, @as(u32, @intFromFloat((ly - @as(f64, @floatFromInt(output.y))) * @as(f64, @floatFromInt(source.height)) / @as(f64, @floatFromInt(output.height)))));
                self.pixel(@intCast(x), @intCast(y)).* = source.pixel(sx, sy).*;
            }
        }
    }
};

test "padded inverted buffer and asymmetric rotation preserve pixels" {
    const bytes = [_]u8{ 1, 0, 0, 0, 2, 0, 0, 0, 3, 0, 0, 0, 99, 99, 99, 99, 4, 0, 0, 0, 5, 0, 0, 0, 6, 0, 0, 0, 99, 99, 99, 99 };
    var image = try Image.fromBuffer(std.testing.allocator, &bytes, 3, 2, 16, 1, true, 1);
    defer image.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 2), image.width);
    try std.testing.expectEqual(@as(u32, 3), image.height);
    // Reconstructed rows are [1,4], [2,5], [3,6].
    try std.testing.expectEqual(@as(u8, 1), image.pixel(0, 0)[0]);
    try std.testing.expectEqual(@as(u8, 6), image.pixel(1, 2)[0]);
    try std.testing.expectEqual(@as(u8, 255), image.pixel(1, 2)[3]);
}

test "native crop includes partial edge pixels and preserves uneven output dimensions" {
    var source = try Image.init(std.testing.allocator, 17, 11);
    defer source.deinit(std.testing.allocator);
    for (0..11) |y| for (0..17) |x| {
        source.pixel(@intCast(x), @intCast(y)).* = .{ @intCast(x), @intCast(y), 91, 255 };
    };
    const output = geo.Rect{ .x = -10, .y = 3, .width = 10, .height = 7 };
    var full = try source.crop(std.testing.allocator, output, output);
    defer full.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, source.data, full.data);
    var cropped = try source.crop(std.testing.allocator, output, .{ .x = -7, .y = 5, .width = 3, .height = 3 });
    defer cropped.deinit(std.testing.allocator);
    // x = floor(3*17/10)..ceil(6*17/10) = 5..11;
    // y = floor(2*11/7)..ceil(5*11/7) = 3..8.
    try std.testing.expectEqual(@as(u32, 6), cropped.width);
    try std.testing.expectEqual(@as(u32, 5), cropped.height);
    try std.testing.expectEqual([4]u8{ 5, 3, 91, 255 }, cropped.pixel(0, 0).*);
    try std.testing.expectEqual([4]u8{ 10, 7, 91, 255 }, cropped.pixel(5, 4).*);
}

test "capture alpha is flattened before export, not interpreted as straight RGB" {
    const bytes = [_]u8{ 16, 32, 64, 128, 0, 0, 0, 0 };
    for ([_]u32{ 0, 1, 0x34324241, 0x34324258 }) |format| {
        var image = try Image.fromBuffer(std.testing.allocator, &bytes, 2, 1, 8, format, false, 0);
        defer image.deinit(std.testing.allocator);
        const rgb_swap = format == 0x34324241 or format == 0x34324258;
        try std.testing.expectEqual(if (rgb_swap) [4]u8{ 64, 32, 16, 255 } else [4]u8{ 16, 32, 64, 255 }, image.pixel(0, 0).*);
        try std.testing.expectEqual([4]u8{ 0, 0, 0, 255 }, image.pixel(1, 0).*);
    }
}
