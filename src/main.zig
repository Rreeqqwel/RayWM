const std = @import("std");
const wlr = @import("wlroots");
const srv = @import("server.zig");

const usage =
    \\Usage: raywm [-c config.lua] [-s startup-command] [-d]
    \\  -c  config file (default: $XDG_CONFIG_HOME/raywm/init.lua)
    \\  -s  command run via /bin/sh once the compositor is ready
    \\  -d  verbose wlroots logging
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
    // Consumed by the Lua host in stage 2.
    std.mem.doNotOptimizeAway(config);
    wlr.log.init(if (debug) .debug else .info, null);

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

    if (startup) |cmd| srv.spawn(cmd);
    std.log.info("running on WAYLAND_DISPLAY={s}", .{socket});
    server.wl_server.run();
}

fn terminate(_: c_int, server: *srv.Server) c_int {
    server.wl_server.terminate();
    return 0;
}
