const std = @import("std");
const Scanner = @import("wayland").Scanner;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Zig 0.16's self-hosted linker cannot handle SFrame sections emitted by
    // recent GCC crt objects, so LLVM+LLD is the default. -Dllvm=false opts out.
    const use_llvm = b.option(bool, "llvm", "use LLVM and LLD (default: true)") orelse true;

    const scanner = Scanner.create(b, .{});
    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.addSystemProtocol("stable/tablet/tablet-v2.xml");
    scanner.addSystemProtocol("staging/color-management/color-management-v1.xml");
    scanner.addCustomProtocol(b.path("protocol/wlr-layer-shell-unstable-v1.xml"));

    // Versions only control Zig code generation, not what wlroots implements.
    scanner.generate("wl_compositor", 4);
    scanner.generate("wl_subcompositor", 1);
    scanner.generate("wl_shm", 1);
    scanner.generate("wl_output", 4);
    scanner.generate("wl_seat", 7);
    scanner.generate("wl_data_device_manager", 3);
    scanner.generate("xdg_wm_base", 2);
    scanner.generate("zwp_tablet_manager_v2", 1);
    scanner.generate("wp_color_manager_v1", 2);
    scanner.generate("zwlr_layer_shell_v1", 4);

    const wayland = b.createModule(.{ .root_source_file = scanner.result });
    const xkbcommon = b.dependency("xkbcommon", .{}).module("xkbcommon");
    const pixman = b.dependency("pixman", .{}).module("pixman");
    const wlroots = b.dependency("wlroots", .{}).module("wlroots");
    wlroots.addImport("wayland", wayland);
    wlroots.addImport("xkbcommon", xkbcommon);
    wlroots.addImport("pixman", pixman);
    // Exposes the wlroots include path from pkg-config to its @cImport.
    wlroots.resolved_target = target;
    wlroots.linkSystemLibrary("wlroots-0.20", .{});

    // Lua host: depends only on liblua, so it is unit-testable without wlroots.
    const lua = b.createModule(.{
        .root_source_file = b.path("src/lua.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lua.linkSystemLibrary("lua5.4", .{});

    const exe = b.addExecutable(.{
        .name = "raywm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });
    exe.root_module.addImport("wayland", wayland);
    exe.root_module.addImport("xkbcommon", xkbcommon);
    exe.root_module.addImport("wlroots", wlroots);
    exe.root_module.addImport("lua", lua);
    exe.root_module.linkSystemLibrary("wayland-server", .{});
    exe.root_module.linkSystemLibrary("xkbcommon", .{});
    exe.root_module.linkSystemLibrary("pixman-1", .{});
    b.installArtifact(exe);

    // Minimal xdg-shell client used by tests/smoke.sh.
    const client = b.addExecutable(.{
        .name = "raywm-test-client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/client.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });
    client.root_module.addImport("wayland", wayland);
    client.root_module.linkSystemLibrary("wayland-client", .{});
    b.installArtifact(client);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run raywm").dependOn(&run.step);

    const unit_mod = b.createModule(.{
        .root_source_file = b.path("tests/lua_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    unit_mod.addImport("lua", lua);
    const unit = b.addTest(.{ .root_module = unit_mod, .use_llvm = use_llvm, .use_lld = use_llvm });
    const unit_run = b.addRunArtifact(unit);
    unit_run.setCwd(b.path(".")); // fixtures are referenced as tests/lua/...
    const test_step = b.step("test", "Run unit tests (Lua host and dwindle plugin)");
    test_step.dependOn(&unit_run.step);

    // The dwindle plugin is plain Lua, tested against a mock of the API.
    const dwindle = b.addSystemCommand(&.{ "lua5.4", "tests/dwindle_test.lua" });
    dwindle.setCwd(b.path("."));
    dwindle.setEnvironmentVariable("XDG_RUNTIME_DIR", b.cache_root.path orelse ".");
    dwindle.setEnvironmentVariable("WAYLAND_DISPLAY", "raywm-dwindle-test");
    dwindle.has_side_effects = true;
    test_step.dependOn(&dwindle.step);
}
