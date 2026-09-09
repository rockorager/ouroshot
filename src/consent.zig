const std = @import("std");
const geo = @import("geometry.zig");
const c = @cImport({
    @cInclude("cairo/cairo.h");
});

pub const Mode = enum { none, screenshot, color, region, pick };

fn panel(output: geo.Rect, mode: Mode) geo.Rect {
    const width = @min(output.width, 560);
    const height: u32 = if (mode == .screenshot or mode == .color) 260 else 80;
    return .{ .x = output.x + @as(i32, @intCast((output.width - width) / 2)), .y = output.y + 16, .width = width, .height = height };
}

pub fn action(output: geo.Rect, mode: Mode, point: geo.Point) enum { accept, cancel, none } {
    if (mode != .screenshot and mode != .color) return .none;
    const box = panel(output, mode);
    if (point.y < box.y + 198 or point.y >= box.y + 244) return .none;
    if (point.x >= box.x + 16 and point.x < box.x + @as(i32, @intCast(box.width / 2)) - 8) return .accept;
    if (point.x >= box.x + @as(i32, @intCast(box.width / 2)) + 8 and point.x < box.right() - 16) return .cancel;
    return .none;
}

fn text(cr: *c.cairo_t, x: f64, y: f64, size: f64, value: [:0]const u8) void {
    c.cairo_set_source_rgb(cr, 0.94, 0.95, 0.98);
    c.cairo_set_font_size(cr, size);
    c.cairo_move_to(cr, x, y);
    c.cairo_show_text(cr, value);
}

pub fn draw(bytes: []u8, width: u32, height: u32, stride: u32, scale120: u32, output: geo.Rect, mode: Mode, caption: [:0]const u8, interactive: bool) !void {
    const surface = c.cairo_image_surface_create_for_data(bytes.ptr, c.CAIRO_FORMAT_ARGB32, @intCast(width), @intCast(height), @intCast(stride)) orelse return error.RenderFailed;
    defer c.cairo_surface_destroy(surface);
    const cr = c.cairo_create(surface) orelse return error.RenderFailed;
    defer c.cairo_destroy(cr);
    const scale = @as(f64, @floatFromInt(scale120)) / 120;
    c.cairo_scale(cr, scale, scale);
    const box = panel(output, mode);
    const x: f64 = @floatFromInt(box.x - output.x);
    const y: f64 = @floatFromInt(box.y - output.y);
    const w: f64 = @floatFromInt(box.width);
    c.cairo_rectangle(cr, x, y, w, @floatFromInt(box.height));
    c.cairo_set_source_rgb(cr, 0.08, 0.10, 0.14);
    c.cairo_fill(cr);
    c.cairo_select_font_face(cr, "sans", c.CAIRO_FONT_SLANT_NORMAL, c.CAIRO_FONT_WEIGHT_NORMAL);
    if (mode == .region or mode == .pick) {
        text(cr, x + 16, y + 30, 18, if (mode == .pick) "Click a pixel to share its color" else "Drag a region to share a screenshot");
        text(cr, x + 16, y + 58, 14, "Escape or right click cancels. No result sent yet.");
    } else {
        text(cr, x + 16, y + 34, 22, if (mode == .color) "Allow sharing a screen color?" else "Allow sharing a screenshot?");
        text(cr, x + 16, y + 70, 14, caption);
        text(cr, x + 16, y + 96, 14, "The application's claimed identity is not verified.");
        text(cr, x + 16, y + 132, 16, if (mode == .color) "Next, choose one pixel on the frozen desktop." else if (interactive) "Next, drag a region on the frozen desktop." else "This shares the entire desktop, on all outputs.");
        text(cr, x + 16, y + 163, 14, "Escape / right click cancels. Enter allows this request.");
        c.cairo_rectangle(cr, x + 16, y + 198, w / 2 - 24, 46);
        c.cairo_set_source_rgb(cr, 0.13, 0.35, 0.60);
        c.cairo_fill(cr);
        c.cairo_rectangle(cr, x + w / 2 + 8, y + 198, w / 2 - 24, 46);
        c.cairo_set_source_rgb(cr, 0.22, 0.24, 0.29);
        c.cairo_fill(cr);
        text(cr, x + 30, y + 227, 16, if (mode == .color) "Choose color" else if (interactive) "Select region" else "Share screen");
        text(cr, x + w / 2 + 24, y + 227, 16, "Cancel");
    }
    c.cairo_surface_flush(surface);
    if (c.cairo_status(cr) != c.CAIRO_STATUS_SUCCESS or c.cairo_surface_status(surface) != c.CAIRO_STATUS_SUCCESS) return error.RenderFailed;
}
