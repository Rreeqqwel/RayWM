//! Unit tests for deterministic parts of the native core (no compositor
//! running). Wayland behaviour is covered by tests/{smoke,focus,input}.sh.
const std = @import("std");
const posix = std.posix;
const raywm = @import("raywm");
const srv = raywm.srv;
const host = raywm.host;
const t = std.testing;

test "configure serials compare correctly across u32 wrap-around" {
    try t.expect(srv.serialReached(10, 10));
    try t.expect(srv.serialReached(11, 10));
    try t.expect(!srv.serialReached(9, 10));
    try t.expect(srv.serialReached(2, 0xffff_fff0)); // wrapped past
    try t.expect(!srv.serialReached(0xffff_fff0, 2));
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
