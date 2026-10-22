//! Keyboard, pointer and interactive move/resize.
const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");
const srv = @import("server.zig");
const View = @import("view.zig").View;
const LayerSurface = @import("layer.zig").LayerSurface;
const Server = srv.Server;
const gpa = srv.gpa;

const BTN_LEFT = 0x110;
const BTN_RIGHT = 0x111;

/// Modifier bits as in wlr.Keyboard.ModifierMask, limited to the ones that
/// matter for bindings (Caps Lock and Num Lock are ignored).
pub const mod_mask: u32 = @bitCast(wlr.Keyboard.ModifierMask{ .shift = true, .ctrl = true, .alt = true, .logo = true });

pub const Grab = struct {
    mode: enum { none, move, resize } = .none,
    view: ?*View = null,
    /// Cursor position at grab start.
    cx: f64 = 0,
    cy: f64 = 0,
    /// Window geometry at grab start.
    box: wlr.Box = undefined,
    edges: wlr.Edges = .{},
    /// xdg move/resize: the client saw the press, so it must see the release
    /// (otherwise wlr_seat keeps counting the button as held).
    forward_release: bool = false,
    w: i32 = 0,
    h: i32 = 0,
};

pub const Keyboard = struct {
    server: *Server,
    device: *wlr.InputDevice,
    link: wl.list.Link = undefined,
    /// Keycodes whose press triggered a binding; their release is swallowed too.
    swallowed: [8]u32 = @splat(0),

    modifiers: wl.Listener(*wlr.Keyboard) = .init(handleModifiers),
    key: wl.Listener(*wlr.Keyboard.event.Key) = .init(handleKey),
    destroy: wl.Listener(*wlr.InputDevice) = .init(handleDestroy),

    fn create(server: *Server, device: *wlr.InputDevice) !void {
        const kb = try gpa.create(Keyboard);
        errdefer gpa.destroy(kb);
        kb.* = .{ .server = server, .device = device };

        const context = xkb.Context.new(.no_flags) orelse return error.XkbContextFailed;
        defer context.unref();
        // Layout comes from XKB_DEFAULT_* environment variables.
        const keymap = xkb.Keymap.newFromNames(context, null, .no_flags) orelse return error.XkbKeymapFailed;
        defer keymap.unref();
        const wlr_kb = device.toKeyboard();
        if (!wlr_kb.setKeymap(keymap)) return error.SetKeymapFailed;
        wlr_kb.setRepeatInfo(25, 600);

        wlr_kb.events.modifiers.add(&kb.modifiers);
        wlr_kb.events.key.add(&kb.key);
        device.events.destroy.add(&kb.destroy);
        server.seat.setKeyboard(wlr_kb);
        server.keyboards.append(kb);
    }

    fn handleModifiers(listener: *wl.Listener(*wlr.Keyboard), wlr_kb: *wlr.Keyboard) void {
        const kb: *Keyboard = @fieldParentPtr("modifiers", listener);
        kb.server.seat.setKeyboard(wlr_kb);
        kb.server.seat.keyboardNotifyModifiers(&wlr_kb.modifiers);
    }

    fn handleKey(listener: *wl.Listener(*wlr.Keyboard.event.Key), event: *wlr.Keyboard.event.Key) void {
        const kb: *Keyboard = @fieldParentPtr("key", listener);
        const wlr_kb = kb.device.toKeyboard();
        const keycode = event.keycode + 8; // libinput -> xkb
        var handled = false;
        if (event.state == .pressed) {
            handled = kb.handlePress(wlr_kb, keycode);
            if (handled) for (&kb.swallowed) |*s| if (s.* == 0) {
                s.* = keycode;
                break;
            };
        } else for (&kb.swallowed) |*s| if (s.* == keycode) {
            s.* = 0;
            handled = true;
        };
        if (!handled) {
            kb.server.seat.setKeyboard(wlr_kb);
            kb.server.seat.keyboardNotifyKey(event.time_msec, event.keycode, event.state);
        }
    }

    fn handlePress(kb: *Keyboard, wlr_kb: *wlr.Keyboard, keycode: u32) bool {
        const state = wlr_kb.xkb_state orelse return false;
        // VT switching only makes sense with a real session (DRM backend).
        for (state.keyGetSyms(keycode)) |sym| {
            const s = @intFromEnum(sym);
            if (s >= xkb.Keysym.XF86Switch_VT_1 and s <= xkb.Keysym.XF86Switch_VT_12) {
                const session = kb.server.session orelse return false;
                session.changeVt(s - xkb.Keysym.XF86Switch_VT_1 + 1) catch {};
                return true;
            }
        }
        // Bindings match the unshifted (level 0) keysym, so "Super+Shift+1"
        // works regardless of what Shift+1 produces in the layout.
        const mods = @as(u32, @bitCast(wlr_kb.getModifiers())) & mod_mask;
        const keymap = wlr_kb.keymap orelse return false;
        for (keymap.keyGetSymsByLevel(keycode, state.keyGetLayout(keycode), 0)) |sym| {
            if (handleBinding(kb.server, mods, @intFromEnum(sym))) return true;
        }
        return false;
    }

    fn handleDestroy(listener: *wl.Listener(*wlr.InputDevice), _: *wlr.InputDevice) void {
        const kb: *Keyboard = @fieldParentPtr("destroy", listener);
        kb.link.remove();
        kb.server.seat.setCapabilities(.{ .pointer = true, .keyboard = kb.server.keyboards.length() > 0 });
        kb.modifiers.link.remove();
        kb.key.link.remove();
        kb.destroy.link.remove();
        gpa.destroy(kb);
    }
};

/// Keys currently held on the seat keyboard, minus those consumed by a
/// binding: a newly focused client must not see them as pressed.
pub fn heldKeys(server: *Server, wlr_kb: *wlr.Keyboard, buf: *[32]u32) []const u32 {
    var swallowed: []const u32 = &.{};
    var it = server.keyboards.iterator(.forward);
    while (it.next()) |kb| if (kb.device.toKeyboard() == wlr_kb) {
        swallowed = &kb.swallowed;
    };
    var n: usize = 0;
    for (wlr_kb.keycodes[0..wlr_kb.num_keycodes]) |code| {
        if (std.mem.indexOfScalar(u32, swallowed, code + 8) == null) {
            buf[n] = code;
            n += 1;
        }
    }
    return buf[0..n];
}

fn handleBinding(server: *Server, mods: u32, sym: u32) bool {
    if (server.rt) |rt| {
        if (rt.key(mods, sym)) return true;
        if (rt.hasBindings()) return false;
    }
    // Fallback bindings so a missing or broken config is never a dead end.
    const logo: u32 = @bitCast(wlr.Keyboard.ModifierMask{ .logo = true });
    const logo_shift: u32 = @bitCast(wlr.Keyboard.ModifierMask{ .logo = true, .shift = true });
    if (mods == logo and sym == xkb.Keysym.Return) {
        srv.spawn("${TERMINAL:-foot}");
    } else if (mods == logo_shift and sym == xkb.Keysym.e) {
        server.wl_server.terminate();
    } else if (mods == logo_shift and sym == xkb.Keysym.r) {
        if (server.rt) |rt| rt.requestReload() else return false;
    } else return false;
    return true;
}

pub fn newInput(listener: *wl.Listener(*wlr.InputDevice), device: *wlr.InputDevice) void {
    const server: *Server = @fieldParentPtr("new_input", listener);
    switch (device.type) {
        .keyboard => Keyboard.create(server, device) catch |err| std.log.err("keyboard setup failed: {}", .{err}),
        .pointer => server.cursor.attachInputDevice(device),
        else => {},
    }
    server.seat.setCapabilities(.{ .pointer = true, .keyboard = server.keyboards.length() > 0 });
}

pub fn requestCursor(listener: *wl.Listener(*wlr.Seat.event.RequestSetCursor), event: *wlr.Seat.event.RequestSetCursor) void {
    const server: *Server = @fieldParentPtr("request_cursor", listener);
    if (event.seat_client == server.seat.pointer_state.focused_client)
        server.cursor.setSurface(event.surface, event.hotspot_x, event.hotspot_y);
}

pub fn requestSelection(listener: *wl.Listener(*wlr.Seat.event.RequestSetSelection), event: *wlr.Seat.event.RequestSetSelection) void {
    const server: *Server = @fieldParentPtr("request_selection", listener);
    server.seat.setSelection(event.source, event.serial);
}

pub fn motion(listener: *wl.Listener(*wlr.Pointer.event.Motion), event: *wlr.Pointer.event.Motion) void {
    const server: *Server = @fieldParentPtr("cursor_motion", listener);
    server.cursor.move(event.device, event.delta_x, event.delta_y);
    processMotion(server, event.time_msec);
}

pub fn motionAbsolute(listener: *wl.Listener(*wlr.Pointer.event.MotionAbsolute), event: *wlr.Pointer.event.MotionAbsolute) void {
    const server: *Server = @fieldParentPtr("cursor_motion_abs", listener);
    server.cursor.warpAbsolute(event.device, event.x, event.y);
    processMotion(server, event.time_msec);
}

const Hit = struct { surface: *wlr.Surface, sx: f64, sy: f64, view: ?*View, layer: ?*LayerSurface };

fn surfaceAt(server: *Server, lx: f64, ly: f64) ?Hit {
    var sx: f64 = undefined;
    var sy: f64 = undefined;
    const node = server.scene.tree.node.at(lx, ly, &sx, &sy) orelse return null;
    if (node.type != .buffer) return null;
    const scene_surface = wlr.SceneSurface.tryFromBuffer(wlr.SceneBuffer.fromNode(node)) orelse return null;
    return .{ .surface = scene_surface.surface, .sx = sx, .sy = sy, .view = View.fromNode(node), .layer = LayerSurface.fromNode(node) };
}

/// Re-evaluates pointer focus after the scene changed under a still cursor.
pub fn refocusPointer(server: *Server) void {
    if (server.grab.mode != .none) return;
    if (surfaceAt(server, server.cursor.x, server.cursor.y)) |hit| {
        server.seat.pointerNotifyEnter(hit.surface, hit.sx, hit.sy);
    } else {
        server.cursor.setXcursor(server.cursor_mgr, "default");
        server.seat.pointerClearFocus();
    }
}

fn processMotion(server: *Server, time_msec: u32) void {
    const g = &server.grab;
    const view = g.view orelse {
        if (surfaceAt(server, server.cursor.x, server.cursor.y)) |hit| {
            server.seat.pointerNotifyEnter(hit.surface, hit.sx, hit.sy);
            server.seat.pointerNotifyMotion(time_msec, hit.sx, hit.sy);
        } else {
            server.cursor.setXcursor(server.cursor_mgr, "default");
            server.seat.pointerClearFocus();
        }
        return;
    };
    const dx: i32 = @intFromFloat(server.cursor.x - g.cx);
    const dy: i32 = @intFromFloat(server.cursor.y - g.cy);
    switch (g.mode) {
        .none => unreachable,
        .move => view.move(g.box.x + dx, g.box.y + dy),
        .resize => {
            var w = g.box.width;
            var h = g.box.height;
            if (g.edges.left) w -= dx else if (g.edges.right) w += dx;
            if (g.edges.top) h -= dy else if (g.edges.bottom) h += dy;
            w = @max(w, 1);
            h = @max(h, 1);
            if (w == g.w and h == g.h) return;
            g.w = w;
            g.h = h;
            // Position follows in onCommit, once the client picked its size.
            view.anchor = .{ .serial = view.xdg.setSize(w, h), .edges = g.edges, .box = g.box };
        },
    }
}

/// During a resize from the left/top edge the opposite edge stays fixed,
/// using the size the client actually committed (it may round, e.g. to
/// terminal cells). This continues after the button is released, until the
/// client has acked the last resize configure.
pub fn onCommit(server: *Server, view: *View) void {
    const a = view.anchor orelse return;
    const geo = view.xdg.base.geometry;
    if (a.edges.left) view.x = a.box.x + a.box.width - geo.width;
    if (a.edges.top) view.y = a.box.y + a.box.height - geo.height;
    if (server.grab.view != view and srv.serialReached(view.xdg.base.current.configure_serial, a.serial)) view.anchor = null;
}

/// A layout plugin (ctx.manage) owns the geometry of this window, so free
/// interactive move/resize must not start, whoever asks for it.
fn layoutManaged(server: *Server, view: *View) bool {
    const rt = server.rt orelse return false;
    return rt.managed(view.id);
}

pub fn beginMove(server: *Server, view: *View, from_client: bool) void {
    if (layoutManaged(server, view)) return;
    endGrab(server);
    server.grab = .{ .mode = .move, .view = view, .cx = server.cursor.x, .cy = server.cursor.y, .box = view.geometry(), .forward_release = from_client };
    startGrab(server, "grabbing");
}

pub fn beginResize(server: *Server, view: *View, edges: wlr.Edges, from_client: bool) void {
    if (layoutManaged(server, view)) return;
    endGrab(server);
    view.pending = null;
    const box = view.geometry();
    server.grab = .{ .mode = .resize, .view = view, .cx = server.cursor.x, .cy = server.cursor.y, .box = box, .edges = edges, .forward_release = from_client, .w = box.width, .h = box.height };
    _ = view.xdg.setResizing(true);
    startGrab(server, "se-resize");
}

/// Clearing pointer focus makes the client set its cursor again on re-enter.
fn startGrab(server: *Server, cursor: [*:0]const u8) void {
    server.seat.pointerClearFocus();
    server.cursor.setXcursor(server.cursor_mgr, cursor);
}

/// Ends any grab (also used when the grabbed view unmaps).
pub fn endGrab(server: *Server) void {
    const g = server.grab;
    server.grab = .{};
    if (g.mode == .resize) if (g.view) |v| if (v.mapped) {
        const serial = v.xdg.setResizing(false);
        if (v.anchor) |*a| a.serial = serial;
    };
    refocusPointer(server);
}

pub fn button(listener: *wl.Listener(*wlr.Pointer.event.Button), event: *wlr.Pointer.event.Button) void {
    const server: *Server = @fieldParentPtr("cursor_button", listener);
    if (event.state == .released and server.grab.mode != .none) {
        // Super+drag: the client never saw the press, so it gets no release.
        if (server.grab.forward_release) _ = server.seat.pointerNotifyButton(event.time_msec, event.button, event.state);
        endGrab(server);
        return;
    }
    if (event.state == .pressed) if (surfaceAt(server, server.cursor.x, server.cursor.y)) |hit| if (hit.layer) |ls| {
        if (ls.wantsKeyboard() and server.layer_focus != ls) server.focusLayer(ls);
    } else if (hit.view) |view| {
        server.focus(view);
        const kb = server.seat.getKeyboard();
        // On a managed window Super+click is an ordinary click.
        if (kb != null and kb.?.getModifiers().logo and (event.button == BTN_LEFT or event.button == BTN_RIGHT) and !layoutManaged(server, view)) {
            if (event.button == BTN_LEFT) return beginMove(server, view, false);
            const g = view.geometry();
            const fx: i32 = @intFromFloat(server.cursor.x);
            const fy: i32 = @intFromFloat(server.cursor.y);
            const left = fx < g.x + @divTrunc(g.width, 2);
            const top = fy < g.y + @divTrunc(g.height, 2);
            return beginResize(server, view, .{ .left = left, .right = !left, .top = top, .bottom = !top }, false);
        }
    };
    _ = server.seat.pointerNotifyButton(event.time_msec, event.button, event.state);
}

pub fn axis(listener: *wl.Listener(*wlr.Pointer.event.Axis), event: *wlr.Pointer.event.Axis) void {
    const server: *Server = @fieldParentPtr("cursor_axis", listener);
    server.seat.pointerNotifyAxis(event.time_msec, event.orientation, event.delta, event.delta_discrete, event.source, event.relative_direction);
}

pub fn frame(listener: *wl.Listener(*wlr.Cursor), _: *wlr.Cursor) void {
    const server: *Server = @fieldParentPtr("cursor_frame", listener);
    server.seat.pointerNotifyFrame();
}
