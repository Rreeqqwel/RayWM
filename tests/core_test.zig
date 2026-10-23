//! Unit tests for deterministic parts of the native core (no compositor
//! running). Wayland behaviour is covered by tests/{smoke,focus,input,
//! pointer,navigation}.sh.
const std = @import("std");
const posix = std.posix;
const raywm = @import("raywm");
const srv = raywm.srv;
const host = raywm.host;
const t = std.testing;

extern fn raywm_test_raw_bool(b: bool) c_uint;
var runtime_true = true;
noinline fn yes() bool {
    return runtime_true;
}
// Like View.setSuspendedState(view, !view.visible()): the bool reaches C
// through the parameter of a Zig function.
noinline fn viaHelper(on: bool) c_uint {
    return raywm.cabi.call(on, raywm_test_raw_bool, .{});
}
noinline fn direct(on: bool) c_uint {
    return raywm_test_raw_bool(on);
}

test "computed bools reach C as 0 or 1 (workaround for ziglang/zig#35373)" {
    try t.expectEqual(@as(c_uint, 0), viaHelper(!yes()));
    try t.expectEqual(@as(c_uint, 1), viaHelper(yes()));
    try t.expectEqual(@as(c_uint, 1), viaHelper(!(!yes())));
    try t.expectEqual(@as(c_uint, 0), raywm.cabi.call(!yes(), raywm_test_raw_bool, .{}));
    // What the workaround avoids. Zig 0.16.0 Debug passes 0xfe here; a fixed
    // compiler passes 0, so it is only reported, not asserted.
    const raw = direct(!yes());
    if (raw != 0) std.debug.print("note: this compiler passes !true to C as {d} (ziglang/zig#35373)\n", .{raw});
}

test "configure serials compare correctly across u32 wrap-around" {
    try t.expect(srv.serialReached(10, 10));
    try t.expect(srv.serialReached(11, 10));
    try t.expect(!srv.serialReached(9, 10));
    try t.expect(srv.serialReached(2, 0xffff_fff0)); // wrapped past
    try t.expect(!srv.serialReached(0xffff_fff0, 2));
}

test "relative motion keeps missing axes and bounds fixed-point wire deltas" {
    try t.expectEqual(@as(f64, 105), raywm.input.motionAxis(100, 5));
    try t.expectEqual(@as(f64, 100), raywm.input.motionAxis(100, std.math.nan(f64)));
    try t.expectEqual(@as(f64, 100), raywm.input.motionAxis(100, std.math.inf(f64)));
    try t.expectEqual(std.math.floatMax(f64), raywm.input.motionAxis(std.math.floatMax(f64), std.math.floatMax(f64)));
    const Captures = @FieldType(srv.Server, "constraints");
    try t.expectEqual(@as(f64, 0), Captures.finiteDelta(std.math.nan(f64)));
    try t.expectEqual(@as(f64, 0), Captures.finiteDelta(-std.math.inf(f64)));
    try t.expectEqual(@as(f64, 8388607), Captures.finiteDelta(1e30));
    try t.expectEqual(@as(f64, -8388608), Captures.finiteDelta(-1e30));
    try t.expectEqual(@as(f64, 12.5), Captures.finiteDelta(12.5));
}

test "key specs parse to modifiers and level-0 keysyms" {
    const s: *srv.Server = undefined; // parseKey does not touch the server
    const logo: u32 = 64;
    const shift: u32 = 1;
    const ctrl: u32 = 4;
    const alt: u32 = 8;
    try t.expectEqual(lua_key(logo | shift, 0xff0d), host.parseKey(s, "Super+Shift+Return").?);
    try t.expectEqual(lua_key(ctrl | alt, 'r'), host.parseKey(s, "Ctrl+Alt+r").?);
    try t.expectEqual(lua_key(logo, 'a'), host.parseKey(s, "super+A").?); // case-insensitive
    try t.expectEqual(lua_key(logo, 0xffc9), host.parseKey(s, "Mod4+F12").?);
    try t.expectEqual(lua_key(alt, '1'), host.parseKey(s, "Mod1+1").?);
    // screenshot.lua's bindings (XK_Print = 0xff61).
    try t.expectEqual(lua_key(0, 0xff61), host.parseKey(s, "Print").?);
    try t.expectEqual(lua_key(shift, 0xff61), host.parseKey(s, "Shift+Print").?);
    try t.expectEqual(lua_key(ctrl, 0xff61), host.parseKey(s, "Ctrl+Print").?);
    try t.expectEqual(lua_key(ctrl | shift, 0xff61), host.parseKey(s, "Ctrl+Shift+Print").?);
    try t.expectEqual(lua_key(ctrl | alt, 'p'), host.parseKey(s, "Ctrl+Alt+p").?);
    for ([_][:0]const u8{ "", "Super+", "Hyper+x", "Super+NoSuchKey", "Super+Super", "+" }) |bad| {
        try t.expect(host.parseKey(s, bad) == null);
    }
}

fn lua_key(mods: u32, sym: u32) @TypeOf(host.parseKey(undefined, "").?) {
    return .{ .mods = mods, .sym = sym };
}

test "bindings use a Latin keysym when the active layout is not Latin" {
    const xkb = @import("xkbcommon");
    const context = xkb.Context.new(.no_flags) orelse return error.XkbContext;
    defer context.unref();
    // Evdev keycodes + 8, as xkb numbers them.
    const key_j = 36 + 8;
    const key_z = 44 + 8;
    const key_1 = 2 + 8;
    const key_enter = 28 + 8;
    const key_f12 = 88 + 8;

    const us_ru = try keymapOf(context, "us,ru");
    defer us_ru.unref();
    try t.expectEqual(@as(?u32, 'j'), raywm.input.bindingSym(us_ru, key_j, 0));
    // ru active: J is Cyrillic_o there; the us keysym is used.
    try t.expectEqual(@as(?u32, 'j'), raywm.input.bindingSym(us_ru, key_j, 1));
    try t.expectEqual(@as(?u32, '1'), raywm.input.bindingSym(us_ru, key_1, 1));
    try t.expectEqual(@as(?u32, 0xff0d), raywm.input.bindingSym(us_ru, key_enter, 1));
    try t.expectEqual(@as(?u32, 0xffc9), raywm.input.bindingSym(us_ru, key_f12, 1));

    // Layout order does not matter: ru first, us second.
    const ru_us = try keymapOf(context, "ru,us");
    defer ru_us.unref();
    try t.expectEqual(@as(?u32, 'j'), raywm.input.bindingSym(ru_us, key_j, 0));

    // Only a non-Latin layout: its own keysym (bindable as Cyrillic_o).
    const ru = try keymapOf(context, "ru");
    defer ru.unref();
    try t.expectEqual(@as(?u32, 0x06cf), raywm.input.bindingSym(ru, key_j, 0));

    // Latin layouts keep their own keysyms (German Z/Y swap stays).
    const de_us = try keymapOf(context, "de,us");
    defer de_us.unref();
    try t.expectEqual(@as(?u32, 'y'), raywm.input.bindingSym(de_us, key_z, 0));
    try t.expectEqual(@as(?u32, 'z'), raywm.input.bindingSym(de_us, key_z, 1));

    try t.expect(raywm.input.nonLatinChar(0x06cf)); // Cyrillic_o
    try t.expect(raywm.input.nonLatinChar(0x07e9)); // Greek_iota
    try t.expect(raywm.input.nonLatinChar(0x0100_0444)); // U+0444 as a keysym
    try t.expect(!raywm.input.nonLatinChar('j'));
    try t.expect(!raywm.input.nonLatinChar(0xe4)); // adiaeresis (Latin-1)
    try t.expect(!raywm.input.nonLatinChar(0xff0d)); // Return
    try t.expect(!raywm.input.nonLatinChar(0xfe51)); // dead_acute
}

fn keymapOf(context: *@import("xkbcommon").Context, layout: [*:0]const u8) !*@import("xkbcommon").Keymap {
    const names: @import("xkbcommon").RuleNames = .{ .rules = null, .model = null, .layout = layout, .variant = null, .options = null };
    return @import("xkbcommon").Keymap.newFromNames(context, &names, .no_flags) orelse error.XkbKeymap;
}

test "coordinates from Lua are clamped far from i32 overflow" {
    try t.expectEqual(@as(i32, 1 << 24), host.coord(std.math.maxInt(i32)));
    try t.expectEqual(@as(i32, -(1 << 24)), host.coord(std.math.minInt(i32)));
    try t.expectEqual(@as(i32, 123), host.coord(123));
}

test "spawn: child runs detached, no zombie, empty signal mask" {
    // Block INT/TERM like signalfd does in the compositor.
    var set = posix.sigemptyset();
    posix.sigaddset(&set, .INT);
    posix.sigaddset(&set, .TERM);
    var old: posix.sigset_t = undefined;
    posix.sigprocmask(posix.SIG.BLOCK, &set, &old);
    defer posix.sigprocmask(posix.SIG.SETMASK, &old, null);

    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/raywm-core-test-{d}", .{std.c.getpid()});
    defer _ = std.c.unlink(path);
    var cmd_buf: [160]u8 = undefined;
    const cmd = try std.fmt.bufPrintZ(&cmd_buf, "grep SigBlk /proc/self/status > {s}.part && mv {s}.part {s}", .{ path, path, path });
    srv.spawn(cmd);

    // spawn() already reaped its intermediate child: nothing left to wait for.
    try t.expectEqual(@as(c_int, -1), std.c.waitpid(-1, null, 1)); // WNOHANG
    try t.expectEqual(@as(c_int, @intFromEnum(posix.E.CHILD)), std.c._errno().*);

    // The grandchild writes its own signal mask.
    var content: [128]u8 = undefined;
    var len: usize = 0;
    for (0..200) |_| {
        const fd = std.c.open(path, .{});
        if (fd >= 0) {
            const n = std.c.read(fd, &content, content.len);
            _ = std.c.close(fd);
            if (n > 0) {
                len = @intCast(n);
                break;
            }
        }
        var ts: posix.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
        _ = posix.system.nanosleep(&ts, &ts);
    }
    try t.expect(len > 0);
    const line = std.mem.trim(u8, content[0..len], " \n\t");
    const hex = std.mem.trim(u8, line["SigBlk:".len..], " \t");
    const mask = try std.fmt.parseInt(u64, hex, 16);
    try t.expectEqual(@as(u64, 0), mask & ((1 << 1) | (1 << 14))); // SIGINT=2, SIGTERM=15
}

test "RAYWM_OUTPUT_MODE specs parse and match the nearest mode" {
    const spec = srv.parseModeSpec("1920x1080@240").?;
    try t.expectEqual(srv.ModeSpec{ .width = 1920, .height = 1080, .refresh_mhz = 240000 }, spec);
    try t.expectEqual(@as(i32, 59950), srv.parseModeSpec("2560x1440@59.95").?.refresh_mhz);
    for ([_][]const u8{ "", "1920x1080", "1920@240", "x1080@240", "1920x@240", "0x1080@60", "1920x1080@", "1920x1080@0", "1920x1080@nan", "1920x1080@inf", "-1x1080@60", "1920x1080@60x" }) |bad| {
        try t.expect(srv.parseModeSpec(bad) == null);
    }
    // EDID timings rarely land on whole Hz: 240.000699 Hz is 240001 mHz.
    try t.expectEqual(@as(?u32, 1), srv.modeDistance(spec, 1920, 1080, 240001));
    try t.expectEqual(@as(?u32, null), srv.modeDistance(spec, 1920, 1080, 180000));
    try t.expectEqual(@as(?u32, null), srv.modeDistance(spec, 2560, 1440, 240000));
}

test "input settings: layers all < type < name, field by field; clear; checks" {
    const ic = raywm.inputconfig;
    var st: ic.Store = .{};
    defer st.deinit();
    try st.set(.all, .{ .repeat_rate = 30, .natural_scroll = false, .xkb_layout = "us" });
    try st.set(.{ .kind = .pointer }, .{ .accel_speed = 0.5, .natural_scroll = true });
    try st.set(.{ .kind = .touchpad }, .{ .tap = true });
    try st.set(.{ .name = "My Mouse" }, .{ .accel_speed = -0.2 });
    try st.set(.{ .kind = .keyboard }, .{ .xkb_layout = "de", .repeat_delay = 250 });

    const kbd = st.effective(.keyboard, "AT keyboard");
    try t.expectEqualStrings("de", kbd.xkb_layout.?);
    try t.expectEqual(@as(?i32, 30), kbd.repeat_rate);
    try t.expectEqual(@as(?i32, 250), kbd.repeat_delay);
    try t.expectEqual(@as(?f64, null), kbd.accel_speed);

    // A touchpad is a pointer too; names override types.
    const pad = st.effective(.touchpad, "Touchpad");
    try t.expectEqual(@as(?bool, true), pad.tap);
    try t.expectEqual(@as(?bool, true), pad.natural_scroll);
    try t.expectEqual(@as(?f64, 0.5), pad.accel_speed);
    const mouse = st.effective(.pointer, "My Mouse");
    try t.expectEqual(@as(?f64, -0.2), mouse.accel_speed);
    try t.expectEqual(@as(?bool, null), mouse.tap);

    // Setting a layer again merges into it (strings replaced, not leaked:
    // the testing allocator is not used here, but deinit frees all).
    try st.set(.all, .{ .xkb_layout = "fr" });
    try t.expectEqualStrings("fr", st.effective(.touch, "").xkb_layout.?);
    try t.expectEqual(@as(?i32, 30), st.effective(.touch, "").repeat_rate);

    // A new configuration starts without any layer.
    st.clear();
    const fresh = st.effective(.touchpad, "Touchpad");
    try t.expectEqual(@as(?bool, null), fresh.tap);
    try t.expectEqual(@as(?[]const u8, null), fresh.xkb_layout);

    try t.expectError(error.BadValue, st.set(.all, .{ .repeat_rate = 5000 }));
    try t.expectError(error.BadValue, st.set(.all, .{ .accel_speed = 2 }));
    try t.expectError(error.BadValue, st.set(.all, .{ .xkb_layout = "a\x00b" }));

    try t.expect(ic.parseMatch("*").? == .all);
    try t.expectEqual(ic.Kind.touchpad, ic.parseMatch("type:touchpad").?.kind);
    try t.expectEqualStrings("SynPS/2 Synaptics TouchPad", ic.parseMatch("SynPS/2 Synaptics TouchPad").?.name);
    try t.expect(ic.parseMatch("type:mouse") == null);
    try t.expect(ic.parseMatch("") == null);
}

test "keymaps compile from the configured names; bad names do not" {
    const ic = raywm.inputconfig;
    const km = ic.compileKeymap(.{ .xkb_layout = "us,ru", .xkb_options = "grp:alt_shift_toggle" }) orelse return error.TestKeymap;
    defer km.unref();
    try t.expectEqual(@as(u32, 2), km.numLayouts());
    try t.expect(ic.compileKeymap(.{ .xkb_layout = "nosuchlayout" }) == null);
}
