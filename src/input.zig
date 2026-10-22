//! Keyboard, pointer and interactive move/resize.
//!
//! Pointer focus has three owners, checked in this order:
//! 1. a compositor grab (`server.grab`: interactive move/resize) — no client
//!    gets pointer events;
//! 2. a wlroots grab (`seat.pointerHasGrab()`: an xdg_popup grab) — RayWM
//!    keeps reporting the surface under the cursor and wlroots decides;
//! 3. the implicit grab of wl_pointer: while a button the seat delivered is
//!    held (`pointer_state.button_count > 0`), the surface that got the
//!    press keeps the pointer, wherever the cursor goes.
//! Otherwise pointer focus follows the cursor (hit-testing the scene).
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
    /// Only the release of this button ends the grab.
    button: u32 = 0,
    w: i32 = 0,
    h: i32 = 0,
};

/// Scene buffer node of the surface that has pointer focus, as last set by
/// hit-testing. Used during an implicit grab, when the cursor may be far
/// from that surface, to compute surface-local coordinates from the
/// surface's current position (it may move while the button is held).
/// Cleared when the node is destroyed (its surface is destroyed or its
/// window's scene tree goes away).
pub const PointerNode = struct {
    node: ?*wlr.SceneNode = null,
    destroy: wl.Listener(void) = .init(handleDestroy),

    fn set(pn: *PointerNode, node: ?*wlr.SceneNode) void {
        if (pn.node == node) return;
        if (pn.node != null) pn.destroy.link.remove();
        pn.node = node;
        if (node) |n| n.events.destroy.add(&pn.destroy);
    }

    fn handleDestroy(listener: *wl.Listener(void)) void {
        const pn: *PointerNode = @fieldParentPtr("destroy", listener);
        pn.destroy.link.remove();
        pn.node = null;
    }
};

pub const Keyboard = struct {
    server: *Server,
    device: *wlr.InputDevice,
    link: wl.list.Link = undefined,
    /// Keycodes whose press triggered a binding; their release is swallowed
    /// too. As large as wlr_keyboard's own array of pressed keys.
    swallowed: [32]u32 = @splat(0),

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
            // Marked before the binding runs: if it changes focus, the newly
            // focused client must not see this key as held.
            const slot = for (&kb.swallowed) |*s| {
                if (s.* == 0) break s;
            } else null;
            if (slot) |s| s.* = keycode;
            handled = kb.handlePress(wlr_kb, keycode);
            if (!handled) if (slot) |s| {
                s.* = 0;
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
        const seat = kb.server.seat;
        kb.link.remove();
        // Otherwise wlroots leaves the seat without a keyboard although
        // another one remains: new clients would get no keymap and no focus.
        if (seat.getKeyboard() == kb.device.toKeyboard())
            seat.setKeyboard(if (kb.server.keyboards.first()) |other| other.device.toKeyboard() else null);
        seat.setCapabilities(.{ .pointer = true, .keyboard = kb.server.keyboards.length() > 0 });
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
    addDevice(@fieldParentPtr("new_input", listener), device);
}

pub fn addDevice(server: *Server, device: *wlr.InputDevice) void {
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

const Hit = struct { surface: *wlr.Surface, node: *wlr.SceneNode, sx: f64, sy: f64, view: ?*View, layer: ?*LayerSurface };

fn surfaceAt(server: *Server, lx: f64, ly: f64) ?Hit {
    var sx: f64 = undefined;
    var sy: f64 = undefined;
    const node = server.scene.tree.node.at(lx, ly, &sx, &sy) orelse return null;
    if (node.type != .buffer) return null;
    const scene_surface = wlr.SceneSurface.tryFromBuffer(wlr.SceneBuffer.fromNode(node)) orelse return null;
    return .{ .surface = scene_surface.surface, .node = node, .sx = sx, .sy = sy, .view = View.fromNode(node), .layer = LayerSurface.fromNode(node) };
}

/// True while wl_pointer's implicit grab holds: a button that the seat
/// delivered (or tried to deliver) is still pressed, and no wlroots grab
/// (xdg_popup) is in charge. wlroots counts the held buttons; RayWM keeps
/// no counter of its own.
pub fn implicitGrab(server: *Server) bool {
    const seat = server.seat;
    return seat.pointer_state.button_count > 0 and !seat.pointerHasGrab();
}

/// Layout position of the surface holding the implicit grab, or null if
/// there is none or it is no longer shown (unmapped, hidden, destroyed).
fn grabOrigin(server: *Server) ?[2]f64 {
    const focused = server.seat.pointer_state.focused_surface orelse return null;
    const node = server.pointer_node.node orelse return null;
    const scene_surface = wlr.SceneSurface.tryFromBuffer(wlr.SceneBuffer.fromNode(node)) orelse return null;
    if (scene_surface.surface != focused) return null;
    var lx: c_int = undefined;
    var ly: c_int = undefined;
    if (!node.coords(&lx, &ly)) return null; // disabled itself or by an ancestor
    return .{ @floatFromInt(lx), @floatFromInt(ly) };
}

/// Gives pointer focus to `hit` (or to nothing) and, with a time, sends
/// the motion. wlroots sends enter/leave only when the surface changes.
fn focusHit(server: *Server, hit: ?Hit, time_msec: ?u32) void {
    if (hit) |h| {
        server.pointer_node.set(h.node);
        server.seat.pointerNotifyEnter(h.surface, h.sx, h.sy);
        if (time_msec) |t| server.seat.pointerNotifyMotion(t, h.sx, h.sy);
    } else {
        server.pointer_node.set(null);
        server.cursor.setXcursor(server.cursor_mgr, "default");
        server.seat.pointerNotifyClearFocus();
    }
}

/// Re-evaluates pointer focus after the scene changed under a still cursor
/// (windows mapped, moved, hidden; layer surfaces; layouts). During a grab
/// focus stays where it is: the implicit grab surface keeps the pointer
/// while it is shown. If it was unmapped or hidden, it gets a leave and no
/// surface has the pointer until the last button is released, so no other
/// client sees the release of a press it never got.
pub fn refocusPointer(server: *Server) void {
    if (server.grab.mode != .none) return;
    if (implicitGrab(server)) {
        if (server.seat.pointer_state.focused_surface != null and grabOrigin(server) == null) {
            server.pointer_node.set(null);
            // Not the notify_ variant: that one would make wlroots forget the
            // held buttons, ending the grab.
            server.seat.pointerClearFocus();
        }
        return;
    }
    focusHit(server, surfaceAt(server, server.cursor.x, server.cursor.y), null);
}

fn processMotion(server: *Server, time_msec: u32) void {
    const g = &server.grab;
    const view = g.view orelse {
        if (implicitGrab(server)) {
            // Motion goes to the grab surface in its own coordinates, which
            // may lie outside it. Nothing is sent while it is gone.
            const origin = grabOrigin(server) orelse return;
            server.seat.pointerNotifyMotion(time_msec, server.cursor.x - origin[0], server.cursor.y - origin[1]);
            return;
        }
        focusHit(server, surfaceAt(server, server.cursor.x, server.cursor.y), time_msec);
        return;
    };
    // Became managed mid-grab (ctx.manage, reload): stop changing geometry,
    // but keep the grab until release so the release is still delivered.
    if (layoutManaged(server, view)) return;
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
    if (a.edges.left) view.x = a.box.x +| a.box.width -| geo.width;
    if (a.edges.top) view.y = a.box.y +| a.box.height -| geo.height;
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
    server.grab = .{ .mode = .move, .view = view, .cx = server.cursor.x, .cy = server.cursor.y, .box = view.geometry(), .forward_release = from_client, .button = server.seat.pointer_state.grab_button };
    startGrab(server, "grabbing");
}

pub fn beginResize(server: *Server, view: *View, edges: wlr.Edges, from_client: bool) void {
    if (layoutManaged(server, view)) return;
    endGrab(server);
    view.pending = null;
    const box = view.geometry();
    server.grab = .{ .mode = .resize, .view = view, .cx = server.cursor.x, .cy = server.cursor.y, .box = box, .edges = edges, .forward_release = from_client, .button = server.seat.pointer_state.grab_button, .w = box.width, .h = box.height };
    _ = view.xdg.setResizing(true);
    startGrab(server, "se-resize");
}

/// Clearing pointer focus makes the client set its cursor again on re-enter.
/// (Not the notify_ variant, which would make wlroots forget the held
/// button: a client-side move/resize must still see its release.)
fn startGrab(server: *Server, cursor: [*:0]const u8) void {
    server.pointer_node.set(null);
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
    if (server.grab.mode != .none) {
        // Other buttons are ignored during a grab; only the grab's own
        // release ends it. Super+drag: the client never saw the press, so
        // it gets no release either.
        if (event.state != .released or event.button != server.grab.button) return;
        if (server.grab.forward_release) _ = server.seat.pointerNotifyButton(event.time_msec, event.button, event.state);
        endGrab(server);
        return;
    }
    // Only the first press of an interaction picks its target: focus,
    // click-to-focus and compositor bindings. Later presses, while a
    // client holds the implicit grab, belong to that client.
    if (event.state == .pressed and !implicitGrab(server)) {
        const hit = surfaceAt(server, server.cursor.x, server.cursor.y);
        // Focus normally follows motion already; the scene may have changed
        // since the last motion, so the press goes to what is shown now.
        focusHit(server, hit, null);
        if (hit) |h| if (h.layer) |ls| {
            const exclusive = if (server.layer_focus) |cur| cur.wlr_layer.current.keyboard_interactive == .exclusive else false;
            if (ls.wantsKeyboard() and server.layer_focus != ls and !exclusive) server.focusLayer(ls);
        } else if (h.view) |view| {
            server.focus(view);
            const kb = server.seat.getKeyboard();
            // On a managed window Super+click is an ordinary click.
            if (kb != null and kb.?.getModifiers().logo and (event.button == BTN_LEFT or event.button == BTN_RIGHT) and !layoutManaged(server, view)) {
                if (event.button == BTN_LEFT) {
                    beginMove(server, view, false);
                    server.grab.button = event.button;
                    return;
                }
                const g = view.geometry();
                const fx: i32 = @intFromFloat(server.cursor.x);
                const fy: i32 = @intFromFloat(server.cursor.y);
                const left = fx < g.x + @divTrunc(g.width, 2);
                const top = fy < g.y + @divTrunc(g.height, 2);
                beginResize(server, view, .{ .left = left, .right = !left, .top = top, .bottom = !top }, false);
                server.grab.button = event.button;
                return;
            }
        };
    }
    _ = server.seat.pointerNotifyButton(event.time_msec, event.button, event.state);
    // The last held button is up: the implicit grab is over and focus
    // follows the cursor again.
    if (event.state == .released and server.seat.pointer_state.button_count == 0) refocusPointer(server);
}

pub fn axis(listener: *wl.Listener(*wlr.Pointer.event.Axis), event: *wlr.Pointer.event.Axis) void {
    const server: *Server = @fieldParentPtr("cursor_axis", listener);
    server.seat.pointerNotifyAxis(event.time_msec, event.orientation, event.delta, event.delta_discrete, event.source, event.relative_direction);
}

pub fn frame(listener: *wl.Listener(*wlr.Cursor), _: *wlr.Cursor) void {
    const server: *Server = @fieldParentPtr("cursor_frame", listener);
    server.seat.pointerNotifyFrame();
}
