const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const wayring_dependency = b.dependency("wayring", .{
        .target = target,
        .optimize = optimize,
    });
    const wayring = wayring_dependency.module("wayring");
    const wayland = b.dependency("wayland", .{});
    const wayland_protocols = b.dependency("wayland_protocols", .{});
    const wlr_protocols = b.dependency("wlr_protocols", .{});

    const generate = b.addRunArtifact(wayring_dependency.artifact("wayring-scanner"));
    generate.addFileArg(wayland.path("protocol/wayland.xml"));
    generate.addFileArg(wayland_protocols.path("stable/xdg-shell/xdg-shell.xml"));
    generate.addFileArg(wayland_protocols.path("unstable/xdg-output/xdg-output-unstable-v1.xml"));
    generate.addFileArg(wayland_protocols.path("stable/viewporter/viewporter.xml"));
    generate.addFileArg(wayland_protocols.path("stable/tablet/tablet-v2.xml"));
    generate.addFileArg(wayland_protocols.path("staging/cursor-shape/cursor-shape-v1.xml"));
    generate.addFileArg(wayland_protocols.path("staging/fractional-scale/fractional-scale-v1.xml"));
    generate.addFileArg(wayland_protocols.path("stable/linux-dmabuf/linux-dmabuf-v1.xml"));
    generate.addFileArg(wayland_protocols.path("staging/ext-image-capture-source/ext-image-capture-source-v1.xml"));
    generate.addFileArg(wayland_protocols.path("staging/ext-image-copy-capture/ext-image-copy-capture-v1.xml"));
    generate.addFileArg(wlr_protocols.path("unstable/wlr-layer-shell-unstable-v1.xml"));
    generate.addFileArg(wlr_protocols.path("unstable/wlr-screencopy-unstable-v1.xml"));
    const protocol = b.createModule(.{
        .root_source_file = generate.addOutputFileArg("protocol.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "wayring", .module = wayring }},
    });
    const ouroshot = b.addModule("ouroshot", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "wayring", .module = wayring },
            .{ .name = "protocol", .module = protocol },
        },
    });
    const tests = b.addTest(.{ .root_module = ouroshot });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run ouroshot tests").dependOn(&run_tests.step);

    const app = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "wayring", .module = wayring },
            .{ .name = "protocol", .module = protocol },
        },
    });
    app.addIncludePath(b.path("src"));
    app.addCSourceFile(.{ .file = b.path("src/encode.c"), .flags = &.{ "-std=c11", "-D_POSIX_C_SOURCE=200809L", "-Wall", "-Wextra" } });
    for ([_][]const u8{ "libpng", "libavcodec", "libavformat", "libavutil", "libavfilter", "libswscale", "libva", "gbm", "libdrm", "cairo" }) |lib| app.linkSystemLibrary(lib, .{});
    const exe = b.addExecutable(.{ .name = "ouroshot", .root_module = app });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run ouroshot").dependOn(&run.step);

    const fixture = b.option(bool, "service-test-fixture", "Build an additional gated fake-capture test executable (never install as the service)") orelse false;
    for (0..if (fixture) @as(usize, 2) else 1) |index| {
        const service = b.createModule(.{
            .root_source_file = b.path("src/service.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{ .{ .name = "wayring", .module = wayring }, .{ .name = "protocol", .module = protocol } },
        });
        const options = b.addOptions();
        options.addOption(bool, "fixture", index == 1);
        service.addOptions("service_options", options);
        service.addAnonymousImport("capture_idl", .{ .root_source_file = b.path("protocol/dev.rockorager.ouro.Capture.varlink") });
        service.addIncludePath(b.path("src"));
        service.addCSourceFile(.{ .file = b.path("src/encode.c"), .flags = &.{ "-std=c11", "-D_POSIX_C_SOURCE=200809L", "-Wall", "-Wextra" } });
        for ([_][]const u8{ "libpng", "libavcodec", "libavformat", "libavutil", "libavfilter", "libswscale", "libva", "gbm", "libdrm", "cairo" }) |lib| service.linkSystemLibrary(lib, .{});
        b.installArtifact(b.addExecutable(.{ .name = if (index == 0) "ouroshot-service" else "ouroshot-service-fixture", .root_module = service }));
    }
}
