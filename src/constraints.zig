//! Pointer constraints and shortcut inhibitors. wlroots owns protocol
//! resources; this object only borrows the currently active constraint.
//! Clear that borrow before deactivation: a oneshot constraint is freed by
//! sendDeactivated. Relative motion is sent before locking/confining the
//! visible cursor, and never changes wl_pointer's implicit grab ownership.
const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const srv = @import("server.zig");

pub const Constraints = struct {
    server: *srv.Server,
    manager: *wlr.PointerConstraintsV1,
    relative: *wlr.RelativePointerManagerV1,
    shortcuts: *wlr.KeyboardShortcutsInhibitManagerV1,
    active: ?*wlr.PointerConstraintV1 = null,
    /// Ctrl+Alt+Escape releases client captures until keyboard focus changes.
    suspended: bool = false,
    syncing: bool = false,
    new_constraint: wl.Listener(*wlr.PointerConstraintV1) = .init(onNew),
    active_destroy: wl.Listener(*wlr.PointerConstraintV1) = .init(onDestroy),
    active_region: wl.Listener(void) = .init(onRegion),
    pointer_focus: wl.Listener(*wlr.Seat.event.PointerFocusChange) = .init(onPointerFocus),
    keyboard_focus: wl.Listener(*wlr.Seat.event.KeyboardFocusChange) = .init(onKeyboardFocus),
    new_inhibitor: wl.Listener(*wlr.KeyboardShortcutsInhibitorV1) = .init(onInhibitor),

    pub fn init(c: *Constraints, server: *srv.Server) !void {
        c.* = .{
            .server = server,
            .manager = try wlr.PointerConstraintsV1.create(server.wl_server),
            .relative = try wlr.RelativePointerManagerV1.create(server.wl_server),
            .shortcuts = try wlr.KeyboardShortcutsInhibitManagerV1.create(server.wl_server),
        };
        c.manager.events.new_constraint.add(&c.new_constraint);
        c.shortcuts.events.new_inhibitor.add(&c.new_inhibitor);
        server.seat.pointer_state.events.focus_change.add(&c.pointer_focus);
        server.seat.keyboard_state.events.focus_change.add(&c.keyboard_focus);
    }

    pub fn deinit(c: *Constraints) void {
        c.deactivate(false);
        inline for (.{ "new_constraint", "new_inhibitor", "pointer_focus", "keyboard_focus" }) |name| @field(c, name).link.remove();
    }

    /// The scene buffer's origin is surface-local (including shadows and
    /// subsurfaces), unlike a view's window geometry.
    fn origin(c: *Constraints, surface: *wlr.Surface) ?[2]f64 {
        const node = c.server.pointer_node.node orelse return null;
        const ss = wlr.SceneSurface.tryFromBuffer(wlr.SceneBuffer.fromNode(node)) orelse return null;
        if (ss.surface != surface) return null;
        var x: c_int = undefined;
        var y: c_int = undefined;
        if (!node.coords(&x, &y)) return null;
        return .{ @floatFromInt(x), @floatFromInt(y) };
    }

    fn contains(c: *Constraints, constraint: *wlr.PointerConstraintV1) bool {
        const xy = c.origin(constraint.surface) orelse return false;
        const sx = c.server.cursor.x - xy[0];
        const sy = c.server.cursor.y - xy[1];
        if (!std.math.isFinite(sx) or !std.math.isFinite(sy) or sx < std.math.minInt(i32) or sx >= std.math.maxInt(i32) or sy < std.math.minInt(i32) or sy >= std.math.maxInt(i32)) return false;
        return constraint.region.containsPoint(@intFromFloat(@floor(sx)), @intFromFloat(@floor(sy)), null);
    }

    fn eligible(c: *Constraints, constraint: *wlr.PointerConstraintV1) bool {
        const server = c.server;
        if (c.suspended or server.session_lock.locked() or server.grab.mode != .none) return false;
        if (constraint.seat != server.seat or server.seat.pointer_state.focused_surface != constraint.surface) return false;
        const keyboard = server.seat.keyboard_state.focused_surface orelse return false;
        return keyboard.getRootSurface() == constraint.surface.getRootSurface() and c.contains(constraint);
    }

    /// Called after focus changes and before motion. Disabled scene nodes
    /// make a constraint ineligible even when an implicit grab retains the
    /// raw pointer focus while a window is being hidden.
    pub fn sync(c: *Constraints) void {
        if (c.syncing) return;
        c.syncing = true;
        defer c.syncing = false;
        if (c.active) |active| if (!c.eligible(active)) c.deactivate(true);
        if (c.active == null) if (c.server.seat.pointer_state.focused_surface) |surface| {
            if (c.manager.constraintForSurface(surface, c.server.seat)) |candidate| if (c.eligible(candidate)) {
                c.active = candidate;
                candidate.events.destroy.add(&c.active_destroy);
                candidate.events.set_region.add(&c.active_region);
                candidate.sendActivated();
            };
        };
        c.syncShortcuts();
    }

    fn hint(c: *Constraints, active: *wlr.PointerConstraintV1) void {
        if (active.type != .locked or !active.current.cursor_hint.enabled or c.server.session_lock.locked()) return;
        const xy = c.origin(active.surface) orelse return;
        const x = active.current.cursor_hint.x;
        const y = active.current.cursor_hint.y;
        if (!std.math.isFinite(x) or !std.math.isFinite(y) or x < 0 or y < 0 or x >= active.surface.current.width or y >= active.surface.current.height) return;
        c.server.cursor.warpClosest(null, xy[0] + x, xy[1] + y);
    }

    fn forget(c: *Constraints) void {
        if (c.active == null) return;
        c.active = null;
        c.active_destroy.link.remove();
        c.active_region.link.remove();
    }

    fn deactivate(c: *Constraints, apply_hint: bool) void {
        const active = c.active orelse return;
        if (apply_hint) c.hint(active);
        c.forget();
        active.sendDeactivated(); // may free active
    }

    /// Returns the allowed endpoint. Lock keeps the cursor still, whereas
    /// confinement clips the entire motion segment against the region (it
    /// cannot jump across holes or disconnected rectangles).
    pub fn endpoint(c: *Constraints, x: *f64, y: *f64) void {
        c.sync();
        const active = c.active orelse return;
        const cursor = c.server.cursor;
        if (active.type == .locked) {
            x.* = cursor.x;
            y.* = cursor.y;
            return;
        }
        const xy = c.origin(active.surface) orelse return;
        var sx = x.* - xy[0];
        var sy = y.* - xy[1];
        if (wlr.region.confine(&active.region, cursor.x - xy[0], cursor.y - xy[1], sx, sy, &sx, &sy)) {
            x.* = sx + xy[0];
            y.* = sy + xy[1];
        } else {
            x.* = cursor.x;
            y.* = cursor.y;
        }
    }

    pub fn relativeMotion(c: *Constraints, time_msec: u32, dx: f64, dy: f64, ux: f64, uy: f64) void {
        // A missing axis is zero in relative-pointer's fixed-point wire
        // format; wl_fixed cannot represent NaN or infinity.
        c.relative.sendRelativeMotion(c.server.seat, @as(u64, time_msec) * 1000, finiteDelta(dx), finiteDelta(dy), finiteDelta(ux), finiteDelta(uy));
    }

    pub fn finiteDelta(value: f64) f64 {
        return if (std.math.isFinite(value)) std.math.clamp(value, -8388608, 8388607) else 0;
    }

    fn syncShortcuts(c: *Constraints) void {
        const server = c.server;
        var it = c.shortcuts.inhibitors.iterator(.forward);
        while (it.next()) |inhibitor| {
            const want = !c.suspended and !server.session_lock.locked() and inhibitor.seat == server.seat and inhibitor.surface == server.seat.keyboard_state.focused_surface;
            if (want and !inhibitor.active) inhibitor.activate() else if (!want and inhibitor.active) inhibitor.deactivate();
        }
    }

    pub fn inhibited(c: *Constraints) bool {
        c.syncShortcuts();
        var it = c.shortcuts.inhibitors.iterator(.forward);
        while (it.next()) |inhibitor| if (inhibitor.active and inhibitor.seat == c.server.seat and inhibitor.surface == c.server.seat.keyboard_state.focused_surface) return true;
        return false;
    }

    pub fn escape(c: *Constraints) void {
        c.suspended = true;
        c.deactivate(true);
        c.syncShortcuts();
    }

    fn onNew(listener: *wl.Listener(*wlr.PointerConstraintV1), _: *wlr.PointerConstraintV1) void {
        const c: *Constraints = @fieldParentPtr("new_constraint", listener);
        c.sync();
    }
    fn onDestroy(listener: *wl.Listener(*wlr.PointerConstraintV1), constraint: *wlr.PointerConstraintV1) void {
        const c: *Constraints = @fieldParentPtr("active_destroy", listener);
        c.hint(constraint);
        c.forget();
    }
    fn onRegion(listener: *wl.Listener(void)) void {
        const c: *Constraints = @fieldParentPtr("active_region", listener);
        c.sync();
    }
    fn onPointerFocus(listener: *wl.Listener(*wlr.Seat.event.PointerFocusChange), _: *wlr.Seat.event.PointerFocusChange) void {
        const c: *Constraints = @fieldParentPtr("pointer_focus", listener);
        c.sync();
    }
    fn onKeyboardFocus(listener: *wl.Listener(*wlr.Seat.event.KeyboardFocusChange), _: *wlr.Seat.event.KeyboardFocusChange) void {
        const c: *Constraints = @fieldParentPtr("keyboard_focus", listener);
        c.suspended = false;
        c.sync();
    }
    fn onInhibitor(listener: *wl.Listener(*wlr.KeyboardShortcutsInhibitorV1), _: *wlr.KeyboardShortcutsInhibitorV1) void {
        const c: *Constraints = @fieldParentPtr("new_inhibitor", listener);
        c.syncShortcuts();
    }
};
