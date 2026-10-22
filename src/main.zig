const std = @import("std");
const wlr = @import("wlroots");
// Public for tests/core_test.zig.
pub const srv = @import("server.zig");
pub const host = @import("host.zig");
pub const input = @import("input.zig");

const usage =
    \\Usage: raywm [-c config.lua] [-s startup-command] [-d]
    \\  -c  config file (default: $XDG_CONFIG_HOME/raywm/init.lua)
    \\  -s  command run via /bin/sh once the compositor is ready
    \\  -d  verbose logging (wlroots, and key presses with Super/Ctrl/Alt)
    \\
;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

pub fn main(init: std.process.Init) !void {
    var config: ?[*:0]const u8 = null;
    var startup: ?[*:0]const u8 = null;
    var debug = false;
    const argv = init.minimal.args.vector;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = std.mem.span(argv[i]);
        if (std.mem.eql(u8, arg, "-d")) {
            debug = true;
        } else if ((std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "-s")) and i + 1 < argv.len) {
            i += 1;
            if (arg[1] == 'c') config = argv[i] else startup = argv[i];
        } else {
            std.debug.print(usage, .{});
            return if (std.mem.eql(u8, arg, "-h")) {} else error.InvalidArgument;
        }
    }
    wlr.log.init(if (debug) .debug else .info, null);
    srv.verbose = debug;

    var server: srv.Server = undefined;
    try server.init();
    defer server.deinit();

    const loop = server.wl_server.getEventLoop();
    const sigint = try loop.addSignal(*srv.Server, @intFromEnum(std.posix.SIG.INT), terminate, &server);
    defer sigint.remove();
    const sigterm = try loop.addSignal(*srv.Server, @intFromEnum(std.posix.SIG.TERM), terminate, &server);
    defer sigterm.remove();

    var buf: [11]u8 = undefined;
    const socket = try server.wl_server.addSocketAuto(&buf);
    if (setenv("WAYLAND_DISPLAY", socket, 1) != 0) return error.SetenvFailed;
    try server.backend.start();

    // Started after the backend so plugins see the initial outputs in setup.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = if (config) |p| std.mem.span(p) else defaultConfig(&path_buf) orelse "init.lua";
    server.rt = try host.Runtime.create(&server, path, .{});
    defer {
        const rt = server.rt.?;
        server.rt = null; // no events into Lua while it shuts down
        rt.destroy();
    }

    if (startup) |cmd| srv.spawn(cmd);
    std.log.info("running on WAYLAND_DISPLAY={s}", .{socket});
    server.wl_server.run();
}

fn defaultConfig(buf: []u8) ?[:0]const u8 {
    if (std.c.getenv("XDG_CONFIG_HOME")) |dir| if (dir[0] != 0)
        return std.fmt.bufPrintZ(buf, "{s}/raywm/init.lua", .{dir}) catch null;
    const home = std.c.getenv("HOME") orelse return null;
    return std.fmt.bufPrintZ(buf, "{s}/.config/raywm/init.lua", .{home}) catch null;
}

fn terminate(_: c_int, server: *srv.Server) c_int {
    server.wl_server.terminate();
    return 0;
}
