//! Capture's MCP wire contract and installed discovery catalog.
const std = @import("std");

pub const version = "2026-07-28";
pub const limit = 4 * 1024 * 1024; // Includes the terminating newline.
pub const Value = std.json.Value;
pub const Context = struct { app_id: []const u8, parent_window: []const u8, origin: []const u8, require_confirmation: bool, permission_store_checked: bool };
pub const Parameters = struct {
    context: Context,
    modal: bool,
    interactive: bool,
    monitor: ?[]const u8 = null,
    region: ?@import("geometry.zig").Rect = null,
};

pub fn parameters(a: std.mem.Allocator, value: Value, screenshot: bool) !Parameters {
    const args = try std.json.parseFromValueLeaky(Parameters, a, value, .{});
    for ([_][]const u8{ "monitor", "region" }) |key| {
        if (value.object.contains(key) and (!screenshot or field(value, key) == .null)) return error.InvalidTarget;
    }
    if (args.monitor) |monitor| {
        if (monitor.len == 0 or monitor.len > 255 or std.mem.indexOfScalar(u8, monitor, 0) != null) return error.InvalidTarget;
    }
    if (args.region) |region| if (!region.valid()) return error.InvalidTarget;
    return args;
}

pub fn field(value: Value, name: []const u8) Value {
    return if (value == .object) value.object.get(name) orelse .null else .null;
}

pub fn isString(value: Value, expected: []const u8) bool {
    return value == .string and std.mem.eql(u8, value.string, expected);
}

pub fn validId(value: Value) bool {
    if (value == .string) return value.string.len <= 1024;
    if (value != .number_string) return false;
    const digits = if (std.mem.startsWith(u8, value.number_string, "-")) value.number_string[1..] else value.number_string;
    if (digits.len == 0 or digits.len > 1024) return false;
    for (digits) |digit| if (!std.ascii.isDigit(digit)) return false;
    return true;
}

const input_schema =
    \\{"type":"object","additionalProperties":false,"required":["context","modal","interactive"],"properties":{"context":{"type":"object","additionalProperties":false,"required":["app_id","parent_window","origin","require_confirmation","permission_store_checked"],"properties":{"app_id":{"type":"string"},"parent_window":{"type":"string"},"origin":{"type":"string"},"require_confirmation":{"type":"boolean"},"permission_store_checked":{"type":"boolean"}}},"modal":{"type":"boolean"},"interactive":{"type":"boolean"}}}
;
const error_schema =
    \\{"type":"object","additionalProperties":false,"required":["error"],"properties":{"error":{"type":"object","additionalProperties":false,"required":["code","message"],"properties":{"code":{"enum":["Cancelled","Denied","Busy","Failed"]},"message":{"type":"string"}}}}}
;
const screenshot_schema =
    \\{"type":"object","additionalProperties":false,"required":["uri"],"properties":{"uri":{"type":"string","pattern":"^file:///"}}}
;
const color_schema =
    \\{"type":"object","additionalProperties":false,"required":["color"],"properties":{"color":{"type":"array","minItems":3,"maxItems":3,"items":{"type":"number","minimum":0,"maximum":1}}}}
;

/// The caller's arena owns the parsed schemas and returned tool values.
pub fn tools(a: std.mem.Allocator) !Value {
    const failure = (try std.json.parseFromSlice(Value, a, error_schema, .{})).value;
    var list = std.array_list.Managed(Value).init(a);
    inline for (.{
        .{ "Screenshot", "Share a monitor or region as a private PNG file URI. With a target, the user confirms the highlighted area by clicking inside or pressing Enter; Escape/right click cancels. Without a target, the user drags to select. Every call requires native consent; caller hints never authorize capture.", screenshot_schema },
        .{ "PickColor", "Pick an sRGB color with native user consent. Currently unavailable; returns Failed without capturing or opening UI.", color_schema },
    }) |entry| {
        var input = (try std.json.parseFromSlice(Value, a, input_schema, .{})).value;
        if (std.mem.eql(u8, entry[0], "Screenshot")) {
            const properties = &input.object.getPtr("properties").?.object;
            try properties.put(a, "monitor", (try std.json.parseFromSlice(Value, a,
                \\{"type":"string","minLength":1,"maxLength":255,"pattern":"^[^\\u0000]+$","description":"Wayland output name, e.g. DP-1. With region, coordinates are relative to this monitor's top-left; without region, select the whole monitor."}
            , .{})).value);
            try properties.put(a, "region", (try std.json.parseFromSlice(Value, a,
                \\{"type":"object","additionalProperties":false,"required":["x","y","width","height"],"description":"Rectangle in logical coordinates: monitor-relative when monitor is supplied, otherwise desktop-wide. A monitor-relative rectangle must fit entirely within that monitor.","properties":{"x":{"type":"integer","minimum":-1000000,"maximum":1000000},"y":{"type":"integer","minimum":-1000000,"maximum":1000000},"width":{"type":"integer","minimum":1,"maximum":32768},"height":{"type":"integer","minimum":1,"maximum":32768}}}
            , .{})).value);
        }
        const success = (try std.json.parseFromSlice(Value, a, entry[2], .{})).value;
        const encoded = try std.json.Stringify.valueAlloc(a, .{
            .name = entry[0],
            .description = entry[1],
            .inputSchema = input,
            .outputSchema = .{ .type = "object", .anyOf = .{ success, failure } },
        }, .{});
        try list.append((try std.json.parseFromSlice(Value, a, encoded, .{})).value);
    }
    return .{ .array = list };
}

pub fn descriptor(a: std.mem.Allocator) ![]const u8 {
    return std.json.Stringify.valueAlloc(a, .{
        .schema_version = 1,
        .application_id = "ouroshot",
        .endpoint = .{ .runtime_path = "ouro/capture.mcp.sock" },
        .tools = try tools(a),
    }, .{});
}
