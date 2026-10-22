//! The compositor side of the Lua API: `lua.Runtime(Server).Api`.
//! Every call resolves ids afresh, so Lua can never reach a freed object.
const std = @import("std");
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");
const lua = @import("lua");
const srv = @import("server.zig");
const input = @import("input.zig");
const Server = srv.Server;

pub const Runtime = lua.Runtime(Server);

pub fn views(server: *Server, buf: []u32) usize {
    var n: usize = 0;
    var it = server.views.iterator(.forward);
    while (it.next()) |v| : (n += 1) {
        if (n == buf.len) break;
        buf[n] = v.id;
    }
    return n;
}

pub fn view(server: *Server, id: u32) ?lua.ViewInfo {
    const v = server.viewById(id) orelse return null;
    const g = v.geometry();
    const out = server.outputAt(g.x +| @divTrunc(g.width, 2), g.y +| @divTrunc(g.height, 2));
    return .{
        .box = .{ .x = g.x, .y = g.y, .w = g.width, .h = g.height },
        .title = v.xdg.title,
        .app_id = v.xdg.app_id,
        .focused = server.focused == v,
        .output = if (out) |o| o.id else 0,
    };
}

pub fn viewCmd(server: *Server, id: u32, cmd: lua.ViewCmd) bool {
    const v = server.viewById(id) orelse return false;
    switch (cmd) {
        .move => |p| v.move(coord(p[0]), coord(p[1])),
        .place => |b| v.place(coord(b.x), coord(b.y), std.math.clamp(b.w, 1, max_coord), std.math.clamp(b.h, 1, max_coord)),
        .opacity => |a| v.setOpacity(a),
        .raise => v.tree.node.raiseToTop(),
        .focus => if (v.tree.node.enabled) server.focus(v),
        .close => v.xdg.sendClose(),
        .show => |on| {
            v.tree.node.setEnabled(on);
            // Never leave keyboard focus on a window the user cannot see.
            if (!on and server.focused == v) server.focus(server.firstVisible());
        },
    }
    input.refocusPointer(server);
    return true;
}

/// Lua may pass any i32; keep geometry far from overflow in later math.
const max_coord = 1 << 24;
pub fn coord(v: i32) i32 {
    return std.math.clamp(v, -max_coord, max_coord);
}

pub fn outputs(server: *Server, buf: []u32) usize {
    var n: usize = 0;
    var it = server.outputs.iterator(.forward);
    while (it.next()) |o| if (o.inLayout()) {
        if (n == buf.len) break;
        buf[n] = o.id;
        n += 1;
    };
    return n;
}

pub fn output(server: *Server, id: u32) ?lua.OutputInfo {
    const o = server.outputById(id) orelse return null;
    if (!o.inLayout()) return null;
    const b = o.box();
    const u = o.usable;
    return .{
        .box = .{ .x = b.x, .y = b.y, .w = b.width, .h = b.height },
        .usable = .{ .x = b.x + u.x, .y = b.y + u.y, .w = u.width, .h = u.height },
    };
}

/// "Super+Shift+Return" -> modifiers + level-0 keysym (see input.zig).
pub fn parseKey(_: *Server, spec: [*:0]const u8) ?lua.Key {
    var mods: wlr.Keyboard.ModifierMask = .{};
    var it = std.mem.splitScalar(u8, std.mem.span(spec), '+');
    while (it.next()) |part| {
        if (it.peek() == null) {
            var buf: [64]u8 = undefined;
            const name = std.fmt.bufPrintZ(&buf, "{s}", .{part}) catch return null;
            const sym = @intFromEnum(xkb.Keysym.fromName(name, .case_insensitive));
            if (sym == 0) return null; // NoSymbol
            return .{ .mods = @bitCast(mods), .sym = sym };
        }
        if (eqlAny(part, &.{ "Super", "Logo", "Mod4" })) {
            mods.logo = true;
        } else if (eqlAny(part, &.{"Shift"})) {
            mods.shift = true;
        } else if (eqlAny(part, &.{ "Ctrl", "Control" })) {
            mods.ctrl = true;
        } else if (eqlAny(part, &.{ "Alt", "Mod1" })) {
            mods.alt = true;
        } else return null;
    }
    return null;
}

fn eqlAny(s: []const u8, names: []const []const u8) bool {
    for (names) |n| if (std.ascii.eqlIgnoreCase(s, n)) return true;
    return false;
}

pub fn spawn(_: *Server, cmd: [*:0]const u8) void {
    srv.spawn(cmd);
}

pub fn quit(server: *Server) void {
    server.wl_server.terminate();
}

/// One event-loop timer serves all Lua timers; null disarms it.
pub fn armTimer(server: *Server, ms: ?u32) void {
    const source = server.timer orelse return;
    const delay: c_int = if (ms) |m| @intCast(@min(m, std.math.maxInt(c_int))) else 0;
    source.timerUpdate(delay) catch std.log.err("timer update failed", .{});
}
