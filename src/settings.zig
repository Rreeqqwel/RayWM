//! Loads raywm.conf for the compositor (layers and parsing: conf.zig).
//! Logs every diagnostic with its file and line.
const std = @import("std");
const conf = @import("conf");

const log = std.log.scoped(.conf);

pub const Loaded = struct {
    settings: conf.Settings,
    /// False when a file was rejected: `settings` then lacks that file.
    ok: bool,
};

/// Built-in defaults, then the system file, then `<dir>/raywm.conf`.
pub fn load(dir: []const u8) Loaded {
    var buf: [conf.max_file_size + 1]u8 = undefined;
    var s: conf.Settings = .{};
    var ok = true;
    var sys_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (systemPath(&sys_buf)) |path| ok = layer(path, &s, &buf) and ok;
    var user_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.fmt.bufPrintZ(&user_buf, "{s}/raywm.conf", .{dir})) |path| {
        ok = layer(path, &s, &buf) and ok;
    } else |_| {
        log.err("configuration directory path too long: {s}", .{dir});
        ok = false;
    }
    return .{ .settings = s, .ok = ok };
}

/// RAYWM_SYSTEM_CONF overrides the system file; set to "" for none.
fn systemPath(buf: []u8) ?[:0]const u8 {
    const env = std.c.getenv("RAYWM_SYSTEM_CONF") orelse return conf.system_path;
    const path = std.mem.span(env);
    if (path.len == 0) return null;
    return std.fmt.bufPrintZ(buf, "{s}", .{path}) catch null;
}

fn layer(path: [:0]const u8, s: *conf.Settings, buf: *[conf.max_file_size + 1]u8) bool {
    var d: conf.Diag = .{};
    const result = conf.applyFile(path.ptr, s, &d, buf);
    for (d.slice()) |item| {
        if (item.is_error) {
            log.err("{s}:{d}: {s}", .{ path, item.line, item.text() });
        } else log.warn("{s}:{d}: {s}", .{ path, item.line, item.text() });
    }
    const dropped = d.errors + d.warnings - d.n;
    if (dropped > 0) log.warn("{s}: {d} more messages not shown", .{ path, dropped });
    switch (result) {
        .applied => log.info("loaded {s}", .{path}),
        .missing => log.debug("{s} not found (optional)", .{path}),
        .rejected => log.err("{s} ignored: fix the errors above (raywm -t checks it)", .{path}),
    }
    return result != .rejected;
}

/// Directory of the configuration (where init.lua and raywm.conf live).
pub fn configDir(init_lua: []const u8) []const u8 {
    return std.fs.path.dirname(init_lua) orelse ".";
}

/// `raywm -t`: prints the effective settings; false if a file was rejected.
pub fn check(dir: []const u8) bool {
    const loaded = load(dir);
    const Print = struct {
        fn line(_: void, section: []const u8, key: []const u8, v: conf.Value) void {
            switch (v) {
                .boolean => |b| std.debug.print("{s}.{s} = {}\n", .{ section, key, b }),
                .integer => |i| std.debug.print("{s}.{s} = {d}\n", .{ section, key, i }),
                .string => |s| std.debug.print("{s}.{s} = {s}\n", .{ section, key, s }),
            }
        }
    };
    conf.each(&loaded.settings, {}, Print.line);
    std.debug.print("{s}\n", .{if (loaded.ok) "configuration OK" else "configuration has errors (see above); the rejected file would be ignored"});
    return loaded.ok;
}
