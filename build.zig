const std = @import("std");

pub fn build(b: *std.build.Builder) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.createModule(.{
        .source_file = .{ .path = "borsh.zig" },
    });

    try b.modules.put(b.dupe("borsh"), module);

    const lib = b.addStaticLibrary(.{
        .name = "borsh",
        .root_source_file = .{ .path = "borsh.zig" },
        .target = target,
        .optimize = optimize,
    });

    b.installArtifact(lib);

    const tests = b.addTest(.{
        .root_source_file = .{ .path = "borsh.zig" },
        .target = target,
        .optimize = optimize,
    });

    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
