const std = @import("std");
const Scanner = @import("wayland").Scanner;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Zig 0.16's self-hosted linker cannot handle SFrame sections emitted by
    // recent GCC crt objects, so LLVM+LLD is the default. -Dllvm=false opts out.
    const use_llvm = b.option(bool, "llvm", "use LLVM and LLD (default: true)") orelse true;
    // TEST ONLY: virtual pointer/keyboard protocols for tests/input.sh.
    // Never enable this for a build that is installed or distributed.
    const test_input = b.option(bool, "test-input", "TEST ONLY: enable virtual input protocols") orelse false;

    const scanner = Scanner.create(b, .{});
    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.addSystemProtocol("stable/tablet/tablet-v2.xml");
    scanner.addSystemProtocol("staging/color-management/color-management-v1.xml");
    scanner.addSystemProtocol("staging/ext-session-lock/ext-session-lock-v1.xml");
    scanner.addSystemProtocol("staging/ext-idle-notify/ext-idle-notify-v1.xml");
    scanner.addSystemProtocol("unstable/idle-inhibit/idle-inhibit-unstable-v1.xml");
    scanner.addSystemProtocol("stable/viewporter/viewporter.xml");
    scanner.addSystemProtocol("stable/linux-dmabuf/linux-dmabuf-v1.xml");
    scanner.addSystemProtocol("staging/single-pixel-buffer/single-pixel-buffer-v1.xml");
    scanner.addSystemProtocol("staging/fractional-scale/fractional-scale-v1.xml");
    scanner.addSystemProtocol("staging/alpha-modifier/alpha-modifier-v1.xml");
    scanner.addSystemProtocol("staging/cursor-shape/cursor-shape-v1.xml");
    scanner.addSystemProtocol("staging/security-context/security-context-v1.xml");
    scanner.addSystemProtocol("staging/ext-data-control/ext-data-control-v1.xml");
    scanner.addSystemProtocol("unstable/primary-selection/primary-selection-unstable-v1.xml");
    scanner.addSystemProtocol("unstable/xdg-foreign/xdg-foreign-unstable-v2.xml");
    scanner.addSystemProtocol("unstable/xdg-decoration/xdg-decoration-unstable-v1.xml");
    scanner.addSystemProtocol("staging/xdg-activation/xdg-activation-v1.xml");
    scanner.addSystemProtocol("staging/ext-foreign-toplevel-list/ext-foreign-toplevel-list-v1.xml");
    scanner.addSystemProtocol("staging/ext-workspace/ext-workspace-v1.xml");
    scanner.addSystemProtocol("staging/tearing-control/tearing-control-v1.xml");
    scanner.addSystemProtocol("staging/linux-drm-syncobj/linux-drm-syncobj-v1.xml");
    scanner.addSystemProtocol("unstable/pointer-constraints/pointer-constraints-unstable-v1.xml");
    scanner.addSystemProtocol("unstable/relative-pointer/relative-pointer-unstable-v1.xml");
    scanner.addSystemProtocol("unstable/keyboard-shortcuts-inhibit/keyboard-shortcuts-inhibit-unstable-v1.xml");
    scanner.addSystemProtocol("unstable/text-input/text-input-unstable-v3.xml");
    scanner.addCustomProtocol(b.path("protocol/input-method-unstable-v2.xml"));
    scanner.addCustomProtocol(b.path("protocol/virtual-keyboard-unstable-v1.xml"));
    // wlr-protocols as shipped with wlroots 0.20.2 (its protocol/ directory).
    scanner.addCustomProtocol(b.path("protocol/wlr-layer-shell-unstable-v1.xml"));
    scanner.addCustomProtocol(b.path("protocol/wlr-output-management-unstable-v1.xml"));
    scanner.addCustomProtocol(b.path("protocol/wlr-output-power-management-unstable-v1.xml"));
    scanner.addCustomProtocol(b.path("protocol/wlr-gamma-control-unstable-v1.xml"));
    scanner.addCustomProtocol(b.path("protocol/wlr-data-control-unstable-v1.xml"));
    scanner.addCustomProtocol(b.path("protocol/wlr-foreign-toplevel-management-unstable-v1.xml"));
    // Client side for raywm-test-client only (presentation feedback); the
    // compositor side is wlroots'. The copy works around a scanner bug.
    scanner.addCustomProtocol(b.path("tests/protocol/presentation-time.xml"));
    if (test_input) {
        const transfer = b.addExecutable(.{
            .name = "raywm-test-data",
            .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
            .use_llvm = use_llvm,
            .use_lld = use_llvm,
        });
        for ([_]struct { std.Build.LazyPath, []const u8 }{
            .{ scanner.wayland_protocols.path(b, "stable/xdg-shell/xdg-shell.xml"), "xdg-shell" },
            .{ scanner.wayland_protocols.path(b, "unstable/text-input/text-input-unstable-v3.xml"), "text-input" },
            .{ b.path("protocol/input-method-unstable-v2.xml"), "input-method" },
            .{ b.path("protocol/virtual-keyboard-unstable-v1.xml"), "virtual-keyboard" },
        }) |protocol| {
            const header_cmd = b.addSystemCommand(&.{ "wayland-scanner", "client-header" });
            header_cmd.addFileArg(protocol[0]);
            const header = header_cmd.addOutputFileArg(b.fmt("{s}-client.h", .{protocol[1]}));
            transfer.root_module.addIncludePath(header.dirname());
            const code_cmd = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
            code_cmd.addFileArg(protocol[0]);
            const code = code_cmd.addOutputFileArg(b.fmt("{s}-protocol.c", .{protocol[1]}));
            transfer.root_module.addCSourceFile(.{ .file = code, .flags = &.{} });
        }
        transfer.root_module.addCSourceFile(.{ .file = b.path("tests/data_client.c"), .flags = &.{ "-Wall", "-Wextra" } });
        transfer.root_module.linkSystemLibrary("wayland-client", .{});
        b.installArtifact(transfer);
        const xclient = b.addExecutable(.{
            .name = "raywm-test-x11",
            .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
            .use_llvm = use_llvm,
            .use_lld = use_llvm,
        });
        xclient.root_module.addCSourceFile(.{ .file = b.path("tests/x11_client.c"), .flags = &.{ "-Wall", "-Wextra" } });
        xclient.root_module.linkSystemLibrary("xcb", .{});
        b.installArtifact(xclient);
        scanner.addCustomProtocol(b.path("tests/protocol/wlr-virtual-pointer-unstable-v1.xml"));
        scanner.generate("zwlr_virtual_pointer_manager_v1", 2);
        // Client side only (tests/screencopy_client.zig); the compositor
        // side is wlroots' own implementation.
        scanner.addCustomProtocol(b.path("tests/protocol/wlr-screencopy-unstable-v1.xml"));
        scanner.generate("zwlr_screencopy_manager_v1", 3);
    }

    // Versions only control Zig code generation, not what wlroots implements.
    scanner.generate("wl_compositor", 4);
    scanner.generate("wl_subcompositor", 1);
    scanner.generate("wl_shm", 1);
    scanner.generate("wl_output", 4);
    scanner.generate("wl_seat", 7);
    scanner.generate("wl_data_device_manager", 3);
    scanner.generate("xdg_wm_base", 7);
    scanner.generate("zwp_tablet_manager_v2", 1);
    scanner.generate("wp_color_manager_v1", 2);
    scanner.generate("zwlr_layer_shell_v1", 5);
    scanner.generate("ext_session_lock_manager_v1", 1);
    scanner.generate("ext_idle_notifier_v1", 2);
    scanner.generate("zwp_idle_inhibit_manager_v1", 1);
    scanner.generate("zwlr_output_manager_v1", 4);
    scanner.generate("zwlr_output_power_manager_v1", 1);
    scanner.generate("zwlr_gamma_control_manager_v1", 1);
    scanner.generate("wp_viewporter", 1);
    scanner.generate("zwp_linux_dmabuf_v1", 5);
    scanner.generate("wp_single_pixel_buffer_manager_v1", 1);
    scanner.generate("wp_fractional_scale_manager_v1", 1);
    scanner.generate("wp_alpha_modifier_v1", 1);
    scanner.generate("wp_cursor_shape_manager_v1", 1);
    scanner.generate("wp_security_context_manager_v1", 1);
    scanner.generate("ext_data_control_manager_v1", 1);
    scanner.generate("zwlr_data_control_manager_v1", 2);
    scanner.generate("zwp_primary_selection_device_manager_v1", 1);
    scanner.generate("zxdg_exporter_v2", 1);
    scanner.generate("zxdg_importer_v2", 1);
    scanner.generate("wp_presentation", 2);
    scanner.generate("zxdg_decoration_manager_v1", 1);
    scanner.generate("xdg_activation_v1", 1);
    scanner.generate("zwlr_foreign_toplevel_manager_v1", 3);
    scanner.generate("ext_foreign_toplevel_list_v1", 1);
    scanner.generate("ext_workspace_manager_v1", 1);
    scanner.generate("wp_tearing_control_manager_v1", 1);
    scanner.generate("wp_linux_drm_syncobj_manager_v1", 1);
    scanner.generate("zwp_pointer_constraints_v1", 1);
    scanner.generate("zwp_relative_pointer_manager_v1", 1);
    scanner.generate("zwp_keyboard_shortcuts_inhibit_manager_v1", 1);
    scanner.generate("zwp_text_input_manager_v3", 1);
    scanner.generate("zwp_input_method_manager_v2", 1);
    scanner.generate("zwp_virtual_keyboard_manager_v1", 1);

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

    // TEST ONLY: DebugAllocator for the compositor and the Lua host (leaks,
    // double frees, poisoned freed memory); see src/alloc.zig.
    const leak_check = b.option(bool, "leak-check", "TEST ONLY: check every allocation at exit") orelse false;
    const alloc_options = b.addOptions();
    alloc_options.addOption(bool, "leak_check", leak_check);
    const alloc_mod = b.createModule(.{ .root_source_file = b.path("src/alloc.zig"), .target = target, .optimize = optimize, .link_libc = true });
    alloc_mod.addOptions("alloc_options", alloc_options);

    // raywm.conf parser: std and libc only, unit-testable on its own.
    const conf = b.createModule(.{
        .root_source_file = b.path("src/conf.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Lua host: depends only on liblua, so it is unit-testable without wlroots.
    const lua = b.createModule(.{
        .root_source_file = b.path("src/lua.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lua.linkSystemLibrary("lua5.4", .{});
    lua.addImport("conf", conf);
    lua.addImport("alloc", alloc_mod);

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
    exe.root_module.addImport("conf", conf);
    exe.root_module.addImport("alloc", alloc_mod);
    const options = b.addOptions();
    options.addOption(bool, "test_input", test_input);
    exe.root_module.addOptions("build_options", options);
    if (test_input) {
        const vi = b.createModule(.{ .root_source_file = b.path("tests/support/virtual_input.zig") });
        vi.addImport("wayland", wayland);
        vi.addImport("wlroots", wlroots);
        exe.root_module.addImport("test_input", vi);

        // Drives the virtual pointer/keyboard from tests/input.sh.
        const driver = b.addExecutable(.{
            .name = "raywm-test-input",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/input_driver.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
            .use_llvm = use_llvm,
            .use_lld = use_llvm,
        });
        driver.root_module.addImport("wayland", wayland);
        driver.root_module.addImport("xkbcommon", xkbcommon);
        driver.root_module.linkSystemLibrary("wayland-client", .{});
        driver.root_module.linkSystemLibrary("xkbcommon", .{});
        b.installArtifact(driver);

        // Requests a capture while tests/screenshot.sh unplugs the output.
        const copier = b.addExecutable(.{
            .name = "raywm-test-screencopy",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/screencopy_client.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
            .use_llvm = use_llvm,
            .use_lld = use_llvm,
        });
        copier.root_module.addImport("wayland", wayland);
        copier.root_module.linkSystemLibrary("wayland-client", .{});
        b.installArtifact(copier);

        // A screen locker for tests/session.sh (lock, unlock, crash).
        const locker = b.addExecutable(.{
            .name = "raywm-test-lock",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/lock_client.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
            .use_llvm = use_llvm,
            .use_lld = use_llvm,
        });
        locker.root_module.addImport("wayland", wayland);
        locker.root_module.linkSystemLibrary("wayland-client", .{});
        b.installArtifact(locker);

        // Protocol probe for the integration suites (power, gamma, ...).
        const probe = b.addExecutable(.{
            .name = "raywm-test-probe",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/probe_client.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
            .use_llvm = use_llvm,
            .use_lld = use_llvm,
        });
        probe.root_module.addImport("wayland", wayland);
        probe.root_module.linkSystemLibrary("wayland-client", .{});
        b.installArtifact(probe);

        const taskbar_client = b.addExecutable(.{
            .name = "raywm-test-taskbar",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/taskbar_client.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
            .use_llvm = use_llvm,
            .use_lld = use_llvm,
        });
        taskbar_client.root_module.addImport("wayland", wayland);
        taskbar_client.root_module.linkSystemLibrary("wayland-client", .{});
        b.installArtifact(taskbar_client);

        // High-frequency client and passive taskbar for tests/perf.sh.
        const perf_client = b.addExecutable(.{
            .name = "raywm-test-perf",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/perf_client.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
            .use_llvm = use_llvm,
            .use_lld = use_llvm,
        });
        perf_client.root_module.addImport("wayland", wayland);
        perf_client.root_module.linkSystemLibrary("wayland-client", .{});
        b.installArtifact(perf_client);

        // Seeded random protocol operations for tests/stress (torture suite).
        const chaos_client = b.addExecutable(.{
            .name = "raywm-test-chaos",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/stress/chaos_client.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
            .use_llvm = use_llvm,
            .use_lld = use_llvm,
        });
        chaos_client.root_module.addImport("wayland", wayland);
        chaos_client.root_module.linkSystemLibrary("wayland-client", .{});
        b.installArtifact(chaos_client);
    }
    exe.root_module.linkSystemLibrary("wayland-server", .{});
    exe.root_module.linkSystemLibrary("xkbcommon", .{});
    exe.root_module.linkSystemLibrary("pixman-1", .{});
    // Pointer and touchpad settings; wlroots depends on it already.
    exe.root_module.linkSystemLibrary("libinput", .{});
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

    // Update manager (src/update.zig): std and libc only; uses curl,
    // vercmp, pacman and makepkg as external programs.
    const update_options = b.addOptions();
    update_options.addOption([]const u8, "version", @import("build.zig.zon").version);
    const update_mod = b.createModule(.{
        .root_source_file = b.path("src/update.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    update_mod.addOptions("build_options", update_options);
    const update = b.addExecutable(.{ .name = "raywm-update", .root_module = update_mod, .use_llvm = use_llvm, .use_lld = use_llvm });
    b.installArtifact(update);

    // The torture suite on this install (docs/TORTURE.md); needs the test
    // build: zig build stress -Dtest-input -p zig-out/test-input -- --level fast
    const stress = b.addSystemCommand(&.{ "sh", "tests/stress/run.sh", "--bin" });
    stress.addArg(b.getInstallPath(.bin, ""));
    if (b.args) |args| stress.addArgs(args);
    stress.setCwd(b.path("."));
    stress.has_side_effects = true;
    stress.step.dependOn(b.getInstallStep());
    b.step("stress", "Torture suite tests/stress/run.sh (build with -Dtest-input)").dependOn(&stress.step);

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
    const test_step = b.step("test", "Run unit tests (core, Lua host and the shipped plugins)");
    test_step.dependOn(&unit_run.step);

    // raywm.conf parser; reads the shipped config/raywm.conf.
    const conf_tests = b.addTest(.{ .root_module = conf, .use_llvm = use_llvm, .use_lld = use_llvm });
    const conf_run = b.addRunArtifact(conf_tests);
    conf_run.setCwd(b.path("."));
    test_step.dependOn(&conf_run.step);

    // Update manager: tags, channels, release lists, metadata checks.
    const update_tests = b.addTest(.{ .root_module = update_mod, .use_llvm = use_llvm, .use_lld = use_llvm });
    test_step.dependOn(&b.addRunArtifact(update_tests).step);

    // Core unit tests: src/main.zig as a module (exposes srv, host).
    const core = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    core.addImport("wayland", wayland);
    core.addImport("xkbcommon", xkbcommon);
    core.addImport("wlroots", wlroots);
    core.addImport("lua", lua);
    core.addImport("conf", conf);
    core.addImport("alloc", alloc_mod);
    core.addOptions("build_options", options);
    if (test_input) core.addImport("test_input", exe.root_module.import_table.get("test_input").?);
    const core_tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/core_test.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    core_tests_mod.addImport("raywm", core);
    core_tests_mod.addImport("xkbcommon", xkbcommon);
    for ([_][]const u8{ "wayland-server", "xkbcommon", "pixman-1", "libinput" }) |lib| core_tests_mod.linkSystemLibrary(lib, .{});
    // An optimized C callee, like the system libraries RayWM calls (see
    // src/cabi.zig): it reads a bool argument as the caller passed it.
    core_tests_mod.addCSourceFile(.{ .file = b.path("tests/support/raw_bool.c"), .flags = &.{"-O2"} });
    const core_tests = b.addTest(.{ .root_module = core_tests_mod, .use_llvm = use_llvm, .use_lld = use_llvm });
    test_step.dependOn(&b.addRunArtifact(core_tests).step);

    // The dwindle plugin is plain Lua, tested against a mock of the API.
    const dwindle = b.addSystemCommand(&.{ "lua5.4", "tests/dwindle_test.lua" });
    dwindle.setCwd(b.path("."));
    dwindle.setEnvironmentVariable("XDG_RUNTIME_DIR", b.cache_root.path orelse ".");
    dwindle.setEnvironmentVariable("WAYLAND_DISPLAY", "raywm-dwindle-test");
    dwindle.has_side_effects = true;
    test_step.dependOn(&dwindle.step);

    // The focus plugin (directional focus, cycle, warp, border), mock API.
    const focus = b.addSystemCommand(&.{ "lua5.4", "tests/focus_test.lua" });
    focus.setCwd(b.path("."));
    focus.has_side_effects = true;
    test_step.dependOn(&focus.step);

    // The workspaces plugin (keys, home outputs, reload), mock API.
    const workspaces = b.addSystemCommand(&.{ "lua5.4", "tests/workspaces_test.lua" });
    workspaces.setCwd(b.path("."));
    workspaces.has_side_effects = true;
    test_step.dependOn(&workspaces.step);

    // The window-rules plugin (matching, dialogs, rules.lua), mock API.
    const rules = b.addSystemCommand(&.{ "lua5.4", "tests/rules_test.lua" });
    rules.setCwd(b.path("."));
    rules.has_side_effects = true;
    test_step.dependOn(&rules.step);

    // The screenshot plugin, against a mock API and fake grim/slurp/wl-copy.
    const screenshot = b.addSystemCommand(&.{ "lua5.4", "tests/screenshot_test.lua" });
    screenshot.setCwd(b.path("."));
    screenshot.setEnvironmentVariable("XDG_RUNTIME_DIR", b.cache_root.path orelse ".");
    screenshot.has_side_effects = true;
    test_step.dependOn(&screenshot.step);
}
