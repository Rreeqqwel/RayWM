//! The compositor side of the Lua API: `lua.Runtime(Server).Api`.
//! Every call resolves ids afresh, so Lua can never reach a freed object.
const std = @import("std");
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");
const lua = @import("lua");
const srv = @import("server.zig");
const input = @import("input.zig");
const ws = @import("workspace.zig");
const output_mod = @import("output.zig");
const inputconfig = @import("inputconfig.zig");
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
        .minimized = v.minimized,
        .decoration = if (v.decorationMode()) |m| switch (m) {
            .server_side => "server",
            .client_side => "client",
            .none => null,
        } else null,
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
        .focus => {
            v.decisions +%= 1;
            if (v.visible()) server.focus(v);
        },
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
        .minimize => |on| {
            v.decisions +%= 1;
            v.setMinimized(on);
        },
        .urgent => |on| {
            v.decisions +%= 1;
            v.setUrgent(on);
        },
        .decoration => |d| v.setDecorationPref(switch (d) {
            .auto => .auto,
            .server => .server,
            .client => .client,
        }),
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

/// raywm.outputs({ all = true }): also outputs that are disabled.
pub fn outputsAll(server: *Server, buf: []u32) usize {
    var n: usize = 0;
    var it = server.outputs.iterator(.forward);
    while (it.next()) |o| {
        if (n == buf.len) break;
        buf[n] = o.id;
        n += 1;
    }
    return n;
}

pub fn output(server: *Server, id: u32) ?lua.OutputInfo {
    const o = server.outputById(id) orelse return null;
    const w = o.wlr_output;
    const in_layout = o.inLayout();
    const b: wlr.Box = if (in_layout) o.box() else .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    const u = o.usable;
    return .{
        .box = .{ .x = b.x, .y = b.y, .w = b.width, .h = b.height },
        .usable = if (in_layout) .{ .x = b.x + u.x, .y = b.y + u.y, .w = u.width, .h = u.height } else .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        .name = w.name,
        .workspace = if (o.active_ws) |a| a.id else 0,
        .description = w.description,
        .make = w.make,
        .model = w.model,
        .serial = w.serial,
        .enabled = in_layout,
        .power = w.enabled,
        .scale = w.scale,
        .transform = transformName(w.transform),
        .mode = .{ w.width, w.height, w.refresh },
        .physical = .{ w.phys_width, w.phys_height },
        .adaptive_sync = w.adaptive_sync_status == .enabled,
    };
}

fn transformName(t: @TypeOf(@as(wlr.Output, undefined).transform)) [*:0]const u8 {
    return switch (@intFromEnum(t)) {
        0 => "normal",
        1 => "90",
        2 => "180",
        3 => "270",
        4 => "flipped",
        5 => "flipped-90",
        6 => "flipped-180",
        7 => "flipped-270",
        else => "normal",
    };
}

pub fn outputModes(server: *Server, id: u32, buf: []lua.ModeInfo) ?[]const lua.ModeInfo {
    const o = server.outputById(id) orelse return null;
    var n: usize = 0;
    var it = o.wlr_output.modes.iterator(.forward);
    while (it.next()) |m| {
        if (n == buf.len) break;
        buf[n] = .{ .w = m.width, .h = m.height, .refresh = m.refresh, .preferred = m.preferred, .current = o.wlr_output.current_mode == m };
        n += 1;
    }
    return buf[0..n];
}

pub fn outputConfigure(server: *Server, target: lua.OutputTarget, cfg: lua.OutputConfig) lua.OutputResult {
    const o = switch (target) {
        .id => |id| server.outputById(id),
        .name => |name| blk: {
            var it = server.outputs.iterator(.forward);
            while (it.next()) |x| if (std.mem.eql(u8, std.mem.span(x.wlr_output.name), name)) break :blk x;
            break :blk null;
        },
    } orelse return .stale;
    var c: output_mod.Config = .{ .enabled = cfg.enabled, .adaptive_sync = cfg.adaptive_sync };
    if (cfg.mode) |m| c.mode = .{ .size = .{ .width = m[0], .height = m[1], .refresh = m[2] } };
    if (cfg.scale) |sc| c.scale = @floatCast(sc);
    if (cfg.transform) |t| c.transform = output_mod.parseTransform(t) orelse return .bad_transform;
    if (cfg.position) |p| c.position = switch (p) {
        .auto => .auto,
        .at => |xy| .{ .at = xy },
    };
    output_mod.configure(server, &.{.{ .output = o, .config = c }}, false) catch |err| return switch (err) {
        error.NoOutputLeft => .no_output_left,
        error.BadMode => .bad_mode,
        error.BadScale => .bad_scale,
        error.Rejected => .rejected,
        error.Failed, error.OutOfMemory => .failed,
    };
    return .ok;
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

// ---- input devices (see inputconfig.zig) ---------------------------------------

/// A (re)load of the configuration starts: its input settings start afresh.
pub fn configBegin(server: *Server) void {
    server.input_store.clear();
}

/// The configuration has run: every device gets its settings.
pub fn configEnd(server: *Server) void {
    inputconfig.applyAll(server);
}

fn enumOf(comptime E: type, s: ?[]const u8) error{BadValue}!?E {
    const v = s orelse return null;
    return std.meta.stringToEnum(E, v) orelse error.BadValue;
}

pub fn inputConfigure(server: *Server, match: []const u8, in: lua.InputSettings, apply_now: bool) lua.InputResult {
    const m = inputconfig.parseMatch(match) orelse return .bad_match;
    var st: inputconfig.Settings = .{
        .xkb_rules = in.xkb_rules,
        .xkb_model = in.xkb_model,
        .xkb_layout = in.xkb_layout,
        .xkb_variant = in.xkb_variant,
        .xkb_options = in.xkb_options,
        .repeat_rate = in.repeat_rate,
        .repeat_delay = in.repeat_delay,
        .accel_speed = in.accel_speed,
        .natural_scroll = in.natural_scroll,
        .left_handed = in.left_handed,
        .tap = in.tap,
        .tap_drag = in.tap_drag,
        .drag_lock = in.drag_lock,
        .dwt = in.dwt,
        .middle_emulation = in.middle_emulation,
    };
    st.accel_profile = enumOf(inputconfig.AccelProfile, in.accel_profile) catch return .bad_value;
    st.scroll_method = enumOf(inputconfig.ScrollMethod, in.scroll_method) catch return .bad_value;
    st.click_method = enumOf(inputconfig.ClickMethod, in.click_method) catch return .bad_value;
    st.send_events = enumOf(inputconfig.SendEvents, in.send_events) catch return .bad_value;
    if (in.scroll_button) |b| st.scroll_button = if (b >= 0) @intCast(b) else return .bad_value;
    st.validate() catch return .bad_value;
    // A layout that does not compile is refused before it is stored.
    if (in.xkb_rules != null or in.xkb_model != null or in.xkb_layout != null or in.xkb_variant != null or in.xkb_options != null) {
        const keymap = inputconfig.compileKeymap(st) orelse return .bad_keymap;
        keymap.unref();
    }
    server.input_store.set(m, st) catch |err| return switch (err) {
        error.BadValue => .bad_value,
        else => .failed,
    };
    if (apply_now) {
        var it = server.devices.iterator(.forward);
        while (it.next()) |d| {
            const hit = switch (m) {
                .all => true,
                .kind => |k| d.kind == k or (k == .pointer and d.kind == .touchpad),
                .name => |n| std.mem.eql(u8, d.name(), n),
            };
            if (hit) d.apply() catch return .bad_keymap;
        }
    }
    return .ok;
}

pub fn inputDevices(server: *Server, buf: []lua.DeviceInfo) []const lua.DeviceInfo {
    var n: usize = 0;
    var it = server.devices.iterator(.forward);
    while (it.next()) |d| {
        if (n == buf.len) break;
        buf[n] = .{
            .id = d.id,
            .name = d.wlr_device.name orelse "",
            .kind = @tagName(d.kind),
            .virtual = d.isVirtual() or (d.wlr_device.type == .pointer and !d.wlr_device.isLibinput() and !d.wlr_device.isWl() and !d.wlr_device.isX11()),
            .libinput = d.wlr_device.isLibinput(),
        };
        n += 1;
    }
    return buf[0..n];
}

pub fn keyboardLayout(server: *Server, names: [][*:0]const u8) ?lua.LayoutInfo {
    const kb = server.seat.getKeyboard() orelse return null;
    const keymap = kb.keymap orelse return null;
    const count = @min(keymap.numLayouts(), names.len);
    for (0..count) |i| names[i] = keymap.layoutGetName(@intCast(i)) orelse "?";
    return .{ .active = kb.modifiers.group + 1, .names = names[0..count] };
}

/// Locks layout `index` (from 0) on every keyboard that has it.
pub fn keyboardSetLayout(server: *Server, index: u32) bool {
    var any = false;
    var it = server.keyboards.iterator(.forward);
    while (it.next()) |k| {
        const kb = k.device.toKeyboard();
        const keymap = kb.keymap orelse continue;
        if (index >= keymap.numLayouts()) continue;
        var mods = kb.modifiers;
        mods.group = index;
        kb.notifyModifiers(mods);
        any = true;
    }
    return any;
}

/// raywm.locked(): the session is locked (ext-session-lock-v1).
pub fn locked(server: *Server) bool {
    return server.session_lock.locked();
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
