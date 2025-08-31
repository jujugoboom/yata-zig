const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const websocket = b.dependency(
        "websocket",
        .{
            .target = target,
            .optimize = optimize,
        },
    ).module("websocket");

    const yata_lib = b.addLibrary(.{
        .name = "yata-zig",
        .linkage = .static,
        .root_module = b.createModule(
            .{
                .root_source_file = b.path("src/lib.zig"),
                .target = target,
                .optimize = optimize,
            },
        ),
    });

    b.installArtifact(yata_lib);

    const client_lib = b.addLibrary(.{
        .name = "client",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/client.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    client_lib.root_module.addImport("websocket", websocket);

    b.installArtifact(client_lib);

    const exe = b.addExecutable(
        .{
            .name = "yata-zig",
            .root_module = b.createModule(
                .{
                    .root_source_file = b.path("src/main.zig"),
                    .target = target,
                    .optimize = optimize,
                },
            ),
        },
    );

    exe.root_module.addImport("websocket", websocket);

    b.installArtifact(exe);

    const run_step = b.addRunArtifact(exe);
    const run_cmd = b.step("run", "Run the app");
    run_cmd.dependOn(&run_step.step);

    const client_example = b.addExecutable(
        .{
            .name = "example-client",
            .root_module = b.createModule(
                .{
                    .root_source_file = b.path("examples/client.zig"),
                    .target = target,
                    .optimize = optimize,
                },
            ),
        },
    );

    client_example.root_module.addImport("websocket", websocket);
    b.installArtifact(client_example);

    const run_client_example = b.addRunArtifact(client_example);
    const run_client_cmd = b.step("client", "Run example client");
    run_client_cmd.dependOn(&run_client_example.step);

    const test_step = b.step("test", "Run library tests");
    const doc_tests = b.addTest(.{
        .name = "doc test",
        .root_module = b.createModule(
            .{
                .root_source_file = b.path("src/structs/doc.zig"),
                .target = target,
                .optimize = optimize,
            },
        ),
    });

    const run_doc_tests = b.addRunArtifact(doc_tests);
    test_step.dependOn(&run_doc_tests.step);

    const item_tests = b.addTest(.{
        .name = "item test",
        .root_module = b.createModule(
            .{
                .root_source_file = b.path("src/structs/item.zig"),
                .target = target,
                .optimize = optimize,
            },
        ),
    });

    const run_item_tests = b.addRunArtifact(item_tests);
    test_step.dependOn(&run_item_tests.step);
}
