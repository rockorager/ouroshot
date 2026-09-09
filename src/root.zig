const std = @import("std");

pub const wayring = @import("wayring");
pub const protocol = @import("protocol");
pub const geometry = @import("geometry.zig");
pub const image = @import("image.zig");

test {
    _ = geometry;
    _ = image;
}

test "generated protocols satisfy the wayring client core" {
    comptime {
        @setEvalBranchQuota(10_000);
        _ = @sizeOf(wayring.client.Connection(protocol));
        std.testing.refAllDecls(wayring.client.Core(protocol));
        for (std.meta.declarations(protocol)) |decl| {
            const Interface = @field(protocol, decl.name);
            if (@TypeOf(Interface) == type and @hasDecl(Interface, "info")) {
                std.testing.refAllDecls(Interface);
            }
        }
    }
}
