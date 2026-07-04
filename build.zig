const std = @import("std");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Expose plugin version from build.zig.zon to source code
    const options = b.addOptions();
    const version = try std.SemanticVersion.parse(zon.version);
    options.addOption(std.SemanticVersion, "version", version);
    mod.addOptions("zon", options);

    // Build as shared library
    const lib = b.addLibrary(.{
        .name = "tivtc",
        .linkage = .dynamic,
        .root_module = mod,
    });

    // Pull in ZAPI dependency
    const vapoursynth_dep = b.dependency("vapoursynth", .{
        .target = target,
        .optimize = optimize,
    });

    lib.root_module.addImport("vapoursynth", vapoursynth_dep.module("vapoursynth"));
    lib.root_module.link_libc = true;

    // Strip debug symbols in ReleaseFast
    if (lib.root_module.optimize == .ReleaseFast) {
        lib.root_module.strip = true;
    }

    // Install the plugin to zig-out/
    b.installArtifact(lib);
}
