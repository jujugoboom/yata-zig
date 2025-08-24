const std = @import("std");
const ws = @import("websocket");

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
        const main_tests = b.addTest(.{
            .root_module = b.createModule(
                .{
                    .root_source_file = b.path("src/main.zig"),
                    .target = b.resolveTargetQuery(test_target),
                },
            ),
        });

        const run_main_tests = b.addRunArtifact(main_tests);
        test_step.dependOn(&run_main_tests.step);

        const doc_tests = b.addTest(.{
            .root_module = b.createModule(
                .{
                    .root_source_file = b.path("src/structs/doc.zig"),
                    .target = b.resolveTargetQuery(test_target),
                },
            ),
        });

        const run_doc_tests = b.addRunArtifact(doc_tests);
        test_step.dependOn(&run_doc_tests.step);

        const item_tests = b.addTest(.{
            .root_module = b.createModule(
                .{
                    .root_source_file = b.path("src/structs/item.zig"),
                    .target = b.resolveTargetQuery(test_target),
                },
            ),
        });

        const run_item_tests = b.addRunArtifact(item_tests);
        test_step.dependOn(&run_item_tests.step);
    }
}
