//! The compositor side of the Lua API: `lua.Runtime(Server).Api`.
//! Every call resolves ids afresh, so Lua can never reach a freed object.
const std = @import("std");
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");
const lua = @import("lua");
const srv = @import("server.zig");
const input = @import("input.zig");
const ws = @import("workspace.zig");
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
    const hints = v.sizeHints();
    return .{
        .box = .{ .x = g.x, .y = g.y, .w = g.width, .h = g.height },
        .title = v.title(),
        .app_id = v.appId(),
        .focused = server.focused == v,
        .output = if (out) |o| o.id else 0,
        .visible = v.visible(),
        .parent = if (v.parent()) |p| p.id else 0,
        .min_w = hints.min[0],
        .min_h = hints.min[1],
        .max_w = hints.max[0],
        .max_h = hints.max[1],
        .floating = v.floating,
        .fullscreen = v.isFullscreen(),
        .fullscreen_output = v.fullscreen_output,
        .maximized = v.maximized,
        .workspace = if (v.workspace) |w| w.id else 0,
        .urgent = v.urgent,
        .managed = v.managed(),
        .pid = v.pid(),
    };
}

pub fn viewCmd(server: *Server, id: u32, cmd: lua.ViewCmd) bool {
    const v = server.viewById(id) orelse return false;
    switch (cmd) {
        .move => |p| v.requestMove(coord(p[0]), coord(p[1])),
        .place => |b| v.request(coord(b.x), coord(b.y), std.math.clamp(b.w, 1, max_coord), std.math.clamp(b.h, 1, max_coord)),
        .opacity => |a| v.setOpacity(a),
        .raise => v.raise(),
        .focus => if (v.visible()) server.focus(v),
        .close => v.close(),
        .show => |on| {
            v.setHidden(!on);
            // Never leave keyboard focus on a window the user cannot see.
            if (!on and server.focused == v) server.focus(server.focusFallback(v));
        },
        .border => |b| v.setBorder(b.width, &b.color) catch std.log.err("out of memory", .{}),
        .floating => |on| v.setFloating(on),
        .fullscreen => |f| {
            v.decisions +%= 1;
            const out = if (f.output != 0) server.outputById(f.output) else null;
            v.setFullscreen(f.on, if (out != null and out.?.inLayout()) out else null);
        },
        .maximize => |on| {
            v.decisions +%= 1;
            v.setMaximized(on);
        },
        .workspace => |wid| {
            const w = if (wid == 0) null else ws.byId(server, wid) orelse return false;
            v.setWorkspace(w);
        },
    }
    input.refocusPointer(server);
    return true;
}

/// From the Lua runtime: view `id` (0: any) may have gained or lost the
/// plugin that lays it out, which decides its stacking layer.
pub fn managedChanged(server: *Server, id: u32) void {
    if (id != 0) {
        if (server.viewById(id)) |v| v.restack();
        return;
    }
    var it = server.views.iterator(.forward);
    while (it.next()) |v| v.restack();
}

pub fn pointer(server: *Server) lua.PointerInfo {
    return .{
        .x = coord(@intFromFloat(@floor(std.math.clamp(server.cursor.x, -max_coord, max_coord)))),
        .y = coord(@intFromFloat(@floor(std.math.clamp(server.cursor.y, -max_coord, max_coord)))),
        .busy = input.pointerBusy(server),
    };
}

pub fn pointerWarp(server: *Server, x: i32, y: i32) lua.WarpResult {
    return input.warpPointer(server, @floatFromInt(coord(x)), @floatFromInt(coord(y)));
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
        .name = o.wlr_output.name,
        .workspace = if (o.active_ws) |w| w.id else 0,
    };
}

// ---- workspaces (see workspace.zig) ---------------------------------------

pub fn workspaces(server: *Server, buf: []u32) usize {
    var n: usize = 0;
    var it = server.workspaces.iterator(.forward);
    while (it.next()) |w| {
        if (n == buf.len) break;
        buf[n] = w.id;
        n += 1;
    }
    return n;
}

pub fn workspace(server: *Server, id: u32) ?lua.WorkspaceInfo {
    const w = ws.byId(server, id) orelse return null;
    return .{
        .name = w.name,
        .home = w.home,
        .output = if (w.output) |o| o.id else 0,
        .active = w.isActive(),
        .urgent = w.urgent,
        .orphan = w.orphan,
    };
}

pub fn workspaceCreate(server: *Server, output_id: u32, name: []const u8) lua.CreateResult {
    const o = server.outputById(output_id) orelse return .stale;
    if (!o.inLayout()) return .stale;
    const w = ws.Workspace.create(server, o, name) catch |err| return switch (err) {
        error.BadName => .bad_name,
        else => .failed,
    };
    return .{ .ok = w.id };
}

pub fn workspaceAdopt(server: *Server, id: u32) lua.AdoptResult {
    const w = ws.byId(server, id) orelse return .stale;
    if (!w.orphan) return .owned;
    w.orphan = false;
    return .ok;
}

/// Its plugin is gone (error, reload): kept until the next settle.
pub fn workspaceOrphan(server: *Server, id: u32) void {
    if (ws.byId(server, id)) |w| w.orphan = true;
}

/// After every (re)load of the configuration.
pub fn workspacesSettled(server: *Server) void {
    ws.settle(server);
}

pub fn workspaceCmd(server: *Server, id: u32, cmd: lua.WorkspaceCmd) lua.WorkspaceResult {
    const w = ws.byId(server, id) orelse return .stale;
    switch (cmd) {
        .activate => if (!w.activate()) return .no_output,
        .rename => |name| w.rename(name) catch return .bad_name,
        .set_output => |oid| {
            const o = server.outputById(oid) orelse return .stale;
            if (!o.inLayout()) return .stale;
            w.setOutput(o);
        },
        .remove => w.destroy(),
    }
    return .ok;
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
