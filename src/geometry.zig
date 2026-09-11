const std = @import("std");

pub const Point = struct { x: i32, y: i32 };
pub const Rect = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,

    pub fn between(a: Point, b: Point) Rect {
        return .{ .x = @min(a.x, b.x), .y = @min(a.y, b.y), .width = @intCast(@abs(@as(i64, a.x) - b.x)), .height = @intCast(@abs(@as(i64, a.y) - b.y)) };
    }
    pub fn right(r: Rect) i64 {
        return @as(i64, r.x) + r.width;
    }
    pub fn bottom(r: Rect) i64 {
        return @as(i64, r.y) + r.height;
    }
    pub fn contains(r: Rect, p: Point) bool {
        return p.x >= r.x and p.y >= r.y and p.x < r.right() and p.y < r.bottom();
    }
    pub fn valid(r: Rect) bool {
        return r.width > 0 and r.height > 0 and r.width <= 32768 and r.height <= 32768 and
            @abs(@as(i64, r.x)) <= 1_000_000 and @abs(@as(i64, r.y)) <= 1_000_000;
    }
    pub fn relativeTo(r: Rect, output: Rect) !Rect {
        if (!r.valid() or r.x < 0 or r.y < 0 or r.right() > output.width or r.bottom() > output.height)
            return error.GeometryOutsideOutput;
        const absolute = Rect{
            .x = std.math.cast(i32, @as(i64, output.x) + r.x) orelse return error.InvalidGeometry,
            .y = std.math.cast(i32, @as(i64, output.y) + r.y) orelse return error.InvalidGeometry,
            .width = r.width,
            .height = r.height,
        };
        if (!absolute.valid()) return error.InvalidGeometry;
        return absolute;
    }
    pub fn intersection(a: Rect, b: Rect) ?Rect {
        const x = @max(a.x, b.x);
        const y = @max(a.y, b.y);
        const r = @min(a.right(), b.right());
        const d = @min(a.bottom(), b.bottom());
        if (r <= x or d <= y) return null;
        return .{ .x = x, .y = y, .width = @intCast(r - x), .height = @intCast(d - y) };
    }
    pub fn unite(a: Rect, b: Rect) Rect {
        const x = @min(a.x, b.x);
        const y = @min(a.y, b.y);
        return .{ .x = x, .y = y, .width = @intCast(@max(a.right(), b.right()) - x), .height = @intCast(@max(a.bottom(), b.bottom()) - y) };
    }
    pub fn expanded(r: Rect, margin: i32) Rect {
        return .{ .x = r.x - margin, .y = r.y - margin, .width = r.width + @as(u32, @intCast(margin * 2)), .height = r.height + @as(u32, @intCast(margin * 2)) };
    }
    pub fn parse(text: []const u8) !Rect {
        var parts = std.mem.tokenizeAny(u8, text, ", x");
        const x = try std.fmt.parseInt(i32, parts.next() orelse return error.InvalidGeometry, 10);
        const y = try std.fmt.parseInt(i32, parts.next() orelse return error.InvalidGeometry, 10);
        const width = try std.fmt.parseInt(u32, parts.next() orelse return error.InvalidGeometry, 10);
        const height = try std.fmt.parseInt(u32, parts.next() orelse return error.InvalidGeometry, 10);
        if (parts.next() != null or width == 0 or height == 0 or width > 32768 or height > 32768 or @abs(@as(i64, x)) > 1_000_000 or @abs(@as(i64, y)) > 1_000_000) return error.InvalidGeometry;
        return .{ .x = x, .y = y, .width = width, .height = height };
    }
};

pub fn pixels(logical: u32, scale120: u32) !u32 {
    const result = (@as(u64, logical) * scale120 + 119) / 120;
    if (result == 0 or result > 32768) return error.InvalidDimensions;
    return @intCast(result);
}

pub fn nativeCrop(output: Rect, region: Rect, width: u32, height: u32) !Rect {
    const overlap = output.intersection(region) orelse return error.InvalidCrop;
    if (!std.meta.eql(overlap, region)) return error.InvalidCrop;
    const x0: u32 = @intCast(@as(u64, @intCast(@as(i64, region.x) - output.x)) * width / output.width);
    const y0: u32 = @intCast(@as(u64, @intCast(@as(i64, region.y) - output.y)) * height / output.height);
    const x1: u32 = @intCast((@as(u64, @intCast(region.right() - output.x)) * width + output.width - 1) / output.width);
    const y1: u32 = @intCast((@as(u64, @intCast(region.bottom() - output.y)) * height + output.height - 1) / output.height);
    return .{ .x = @intCast(x0), .y = @intCast(y0), .width = x1 - x0, .height = y1 - y0 };
}

test "negative output origins, reverse drag, and half-open intersections" {
    const a = Rect.between(.{ .x = 50, .y = 90 }, .{ .x = -130, .y = 20 });
    try std.testing.expectEqual(Rect{ .x = -130, .y = 20, .width = 180, .height = 70 }, a);
    try std.testing.expect(a.intersection(.{ .x = 50, .y = 20, .width = 10, .height = 10 }) == null);
    try std.testing.expectEqual(Rect{ .x = -10, .y = 30, .width = 60, .height = 60 }, a.intersection(.{ .x = -10, .y = 30, .width = 100, .height = 80 }).?);
    try std.testing.expectEqual(@as(u32, 152), try pixels(101, 180));
    try std.testing.expectEqual(@as(u32, 127), try pixels(101, 150));
    try std.testing.expectError(error.InvalidGeometry, Rect.parse("0,0 0x10"));
    try std.testing.expectError(error.InvalidGeometry, Rect.parse("0,0 10x10 extra"));
}

test "monitor-relative regions translate logical origins without clipping" {
    const output = Rect{ .x = -1920, .y = 120, .width = 1280, .height = 720 };
    const region = Rect{ .x = 37, .y = 91, .width = 401, .height = 203 };
    try std.testing.expectEqual(Rect{ .x = -1883, .y = 211, .width = 401, .height = 203 }, try region.relativeTo(output));
    const edge = Rect{ .x = 1000, .y = 500, .width = 280, .height = 220 };
    try std.testing.expectEqual(Rect{ .x = -920, .y = 620, .width = 280, .height = 220 }, try edge.relativeTo(output));
    var outside = edge;
    outside.width += 1;
    try std.testing.expectError(error.GeometryOutsideOutput, outside.relativeTo(output));
    outside = region;
    outside.x = -1;
    try std.testing.expectError(error.GeometryOutsideOutput, outside.relativeTo(output));
    outside = region;
    outside.height = 0;
    try std.testing.expectError(error.GeometryOutsideOutput, outside.relativeTo(output));
    try std.testing.expectError(error.InvalidGeometry, region.relativeTo(.{ .x = std.math.maxInt(i32), .y = 0, .width = 1280, .height = 720 }));
}
