const std = @import("std");

const wasm_exports = [_][]const u8{ "zs_version", "zs_prove", "zs_verify", "zs_free" };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    // Use ReleaseSmall for WASM to avoid @intCast panics on valid data (wasm32 usize=u32)
    const wasm_optimize = .ReleaseSmall;

    const zig_stark = b.dependency("zig_stark", .{ .target = target, .optimize = optimize });
    const zig_stark_wasm = b.dependency("zig_stark", .{ .target = wasm_target, .optimize = wasm_optimize });

    // --- Demo 1: sorted-sequence ---
    const ss_circuit_mod = b.addModule("circuit", .{
        .root_source_file = b.path("demos/sorted-sequence/src/circuit.zig"),
        .target = target,
        .optimize = optimize,
    });
    ss_circuit_mod.addImport("zig-stark", zig_stark.module("zig-stark"));

    const ss_exe = b.addExecutable(.{
        .name = "sorted_seq",
        .root_module = b.createModule(.{
            .root_source_file = b.path("demos/sorted-sequence/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "circuit", .module = ss_circuit_mod },
                .{ .name = "zig-stark", .module = zig_stark.module("zig-stark") },
            },
        }),
    });
    b.installArtifact(ss_exe);

    // --- Demo 2: gf-mul-table ---
    const gm_circuit_mod = b.addModule("circuit", .{
        .root_source_file = b.path("demos/gf-mul-table/src/circuit.zig"),
        .target = target,
        .optimize = optimize,
    });
    gm_circuit_mod.addImport("zig-stark", zig_stark.module("zig-stark"));

    const gm_exe = b.addExecutable(.{
        .name = "gf_mul_table",
        .root_module = b.createModule(.{
            .root_source_file = b.path("demos/gf-mul-table/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "circuit", .module = gm_circuit_mod },
                .{ .name = "zig-stark", .module = zig_stark.module("zig-stark") },
            },
        }),
    });
    b.installArtifact(gm_exe);

    // --- WASM for both demos ---
    var ss_wasm_step: *std.Build.Step = undefined;
    var gm_wasm_step: *std.Build.Step = undefined;

    // sorted_seq WASM
    {
        const wasm_circuit_mod = b.addModule("circuit", .{
            .root_source_file = b.path("demos/sorted-sequence/src/circuit.zig"),
            .target = wasm_target,
            .optimize = wasm_optimize,
        });
        wasm_circuit_mod.addImport("zig-stark", zig_stark_wasm.module("zig-stark"));
        const wasm_mod = b.createModule(.{
            .root_source_file = b.path("demos/sorted-sequence/src/wasm_capi.zig"),
            .target = wasm_target,
            .optimize = wasm_optimize,
        });
        wasm_mod.addImport("zig-stark", zig_stark_wasm.module("zig-stark"));
        wasm_mod.addImport("circuit", wasm_circuit_mod);
        const wasm_exe = b.addExecutable(.{
            .name = "sorted_seq_wasm",
            .root_module = wasm_mod,
        });
        wasm_exe.entry = .disabled;
        wasm_exe.root_module.export_symbol_names = &wasm_exports;
        const install_wasm = b.addInstallArtifact(wasm_exe, .{ .dest_sub_path = "sorted_seq_wasm.wasm" });
        const wasm_src = b.pathJoin(&[_][]const u8{ b.exe_dir, "sorted_seq_wasm.wasm" });
        const copy = b.addSystemCommand(&[_][]const u8{ "cp", wasm_src, "demos/sorted-sequence/www/binius_wasm.wasm" });
        copy.step.dependOn(&install_wasm.step);
        ss_wasm_step = b.step("sorted_seq-wasm", "Build sorted_sequence WASM");
        ss_wasm_step.dependOn(&copy.step);
    }

    // gf_mul_table WASM
    {
        const wasm_circuit_mod = b.addModule("circuit", .{
            .root_source_file = b.path("demos/gf-mul-table/src/circuit.zig"),
            .target = wasm_target,
            .optimize = wasm_optimize,
        });
        wasm_circuit_mod.addImport("zig-stark", zig_stark_wasm.module("zig-stark"));
        const wasm_mod = b.createModule(.{
            .root_source_file = b.path("demos/gf-mul-table/src/wasm_capi.zig"),
            .target = wasm_target,
            .optimize = wasm_optimize,
        });
        wasm_mod.addImport("zig-stark", zig_stark_wasm.module("zig-stark"));
        wasm_mod.addImport("circuit", wasm_circuit_mod);
        const wasm_exe = b.addExecutable(.{
            .name = "gf_mul_table_wasm",
            .root_module = wasm_mod,
        });
        wasm_exe.entry = .disabled;
        wasm_exe.root_module.export_symbol_names = &wasm_exports;
        const install_wasm = b.addInstallArtifact(wasm_exe, .{ .dest_sub_path = "gf_mul_table_wasm.wasm" });
        const wasm_src = b.pathJoin(&[_][]const u8{ b.exe_dir, "gf_mul_table_wasm.wasm" });
        const copy = b.addSystemCommand(&[_][]const u8{ "cp", wasm_src, "demos/gf-mul-table/www/binius_wasm.wasm" });
        copy.step.dependOn(&install_wasm.step);
        gm_wasm_step = b.step("gf_mul_table-wasm", "Build gf_mul_table WASM");
        gm_wasm_step.dependOn(&copy.step);
    }

    const wasm_all = b.step("wasm", "Build all WASM modules");
    wasm_all.dependOn(ss_wasm_step);
    wasm_all.dependOn(gm_wasm_step);

    const www_all = b.step("www", "Build all WASM + copy to www/");
    www_all.dependOn(ss_wasm_step);
    www_all.dependOn(gm_wasm_step);

    const fmt_step = b.step("fmt", "Check code formatting (zig fmt --check)");
    const fmt = b.addFmt(.{ .paths = &.{ "demos", "build.zig", "build.zig.zon" }, .check = true });
    fmt_step.dependOn(&fmt.step);
}
