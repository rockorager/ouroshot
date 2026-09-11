//! Capture's MCP wire contract and installed discovery catalog.
const std = @import("std");

pub const version = "2026-07-28";
pub const limit = 65536; // Includes the terminating newline.
pub const Value = std.json.Value;
pub const Context = struct { app_id: []const u8, parent_window: []const u8, origin: []const u8, require_confirmation: bool, permission_store_checked: bool };
pub const Parameters = struct { context: Context, modal: bool, interactive: bool };

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
    const input = (try std.json.parseFromSlice(Value, a, input_schema, .{})).value;
    const failure = (try std.json.parseFromSlice(Value, a, error_schema, .{})).value;
    var list = std.array_list.Managed(Value).init(a);
    inline for (.{
        .{ "Screenshot", "Share a region selected by the user as a private PNG file URI. Every call requires native user selection; caller hints never grant consent.", screenshot_schema },
        .{ "PickColor", "Pick an sRGB color with native user consent. Currently unavailable; returns Failed without capturing or opening UI.", color_schema },
    }) |entry| {
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
