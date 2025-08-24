const std = @import("std");
const test_targets = [_]std.Target.Query{
    .{}, // native
    .{
        .cpu_arch = .x86_64,
        .os_tag = .linux,
    },
    .{
        .cpu_arch = .aarch64,
        .os_tag = .macos,
    },
};
pub fn build(b: *std.Build) void {
    // const target = b.standardTargetOptions(.{});
    //     const optimize = b.standardOptimizeOption(.{});
    //
    //     const libfizzbuzz = b.addLibrary(.{
    //         .name = "fizzbuzz",
    //         .linkage = .static,
    //         .root_module = b.createModule(.{
    //             .root_source_file = b.path("fizzbuzz.zig"),
    //             .target = target,
    //             .optimize = optimize,
    //         }),
    //     });
    //
    //     const exe = b.addExecutable(.{
    //         .name = "demo",
    //         .root_module = b.createModule(.{
    //             .root_source_file = b.path("demo.zig"),
    //             .target = target,
    //             .optimize = optimize,
    //         }),
    //     });
    //
    //     exe.linkLibrary(libfizzbuzz);
    //
    //     b.installArtifact(libfizzbuzz);
    //
    //     if (b.option(bool, "enable-demo", "install the demo too") orelse false) {
    //         b.installArtifact(exe);
    //     }
    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const lib = b.addLibrary(.{
        .name = "yata-zig",
        .linkage = .static,
        .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize }),
    });

    b.installArtifact(lib);

    const test_step = b.step("test", "Run library tests");
    for (test_targets) |test_target| {
        const unit_tests = b.addTest(.{
            .root_module = b.createModule(
                .{
                    .root_source_file = b.path("src/main.zig"),
                    .target = b.resolveTargetQuery(test_target),
                },
            ),
        });

        const run_unit_tests = b.addRunArtifact(unit_tests);
        run_unit_tests.skip_foreign_checks = true;
        test_step.dependOn(&run_unit_tests.step);
    }
}
