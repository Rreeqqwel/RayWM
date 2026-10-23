//! Client requests used by tests/captures.sh, separate from the main test
//! client's window/popup setup. All actions go through real protocol objects.
const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwp = wayland.client.zwp;

var constraints: ?*zwp.PointerConstraintsV1 = null;
var relative: ?*zwp.RelativePointerManagerV1 = null;
var shortcuts: ?*zwp.KeyboardShortcutsInhibitManagerV1 = null;

pub fn bind(registry: *wl.Registry, name: u32, interface: []const u8) void {
    if (std.mem.eql(u8, interface, std.mem.span(zwp.PointerConstraintsV1.interface.name))) constraints = registry.bind(name, zwp.PointerConstraintsV1, 1) catch null;
    if (std.mem.eql(u8, interface, std.mem.span(zwp.RelativePointerManagerV1.interface.name))) relative = registry.bind(name, zwp.RelativePointerManagerV1, 1) catch null;
    if (std.mem.eql(u8, interface, std.mem.span(zwp.KeyboardShortcutsInhibitManagerV1.interface.name))) shortcuts = registry.bind(name, zwp.KeyboardShortcutsInhibitManagerV1, 1) catch null;
}

pub const Capture = struct {
    compositor: *wl.Compositor,
    surface: *wl.Surface,
    locked: ?*zwp.LockedPointerV1 = null,
    confined: ?*zwp.ConfinedPointerV1 = null,

    pub fn init(c: *Capture, compositor: *wl.Compositor, surface: *wl.Surface, seat: *wl.Seat, pointer: ?*wl.Pointer) !void {
        c.* = .{ .compositor = compositor, .surface = surface };
        if (std.c.getenv("RAYWM_TEST_CONSTRAINT")) |mode| {
            const p = pointer orelse return error.NoPointer;
            const rel = try (relative orelse return error.NoRelativePointer).getRelativePointer(p);
            rel.setListener(?*anyopaque, onRelative, null);
            const region = try compositor.createRegion();
            defer region.destroy();
            if (std.c.getenv("RAYWM_TEST_CONSTRAINT_HOLE") != null) {
                region.add(20, 20, 40, 100);
                region.add(100, 20, 40, 100);
            } else region.add(20, 20, 120, 100);
            const lifetime: zwp.PointerConstraintsV1.Lifetime = if (std.c.getenv("RAYWM_TEST_ONESHOT") != null) .oneshot else .persistent;
            if (std.mem.eql(u8, std.mem.span(mode), "lock")) {
                c.locked = try (constraints orelse return error.NoConstraints).lockPointer(surface, p, region, lifetime);
                c.locked.?.setListener(?*anyopaque, onLocked, null);
                c.locked.?.setCursorPositionHint(wl.Fixed.fromInt(50), wl.Fixed.fromInt(60));
            } else {
                c.confined = try (constraints orelse return error.NoConstraints).confinePointer(surface, p, region, lifetime);
                c.confined.?.setListener(?*anyopaque, onConfined, null);
            }
            surface.commit();
        }
        if (std.c.getenv("RAYWM_TEST_SHORTCUTS") != null) {
            const inhibitor = try (shortcuts orelse return error.NoShortcuts).inhibitShortcuts(surface, seat);
            inhibitor.setListener(?*anyopaque, onShortcuts, null);
        }
    }

    pub fn key(c: *Capture, code: u32) void {
        // F7 explicitly destroys the capture; F8 shrinks the committed
        // region away from the current cursor, testing deactivation.
        if (code == 65) {
            if (c.locked) |p| p.destroy();
            if (c.confined) |p| p.destroy();
            c.locked = null;
            c.confined = null;
            std.debug.print("client: constraint destroyed\n", .{});
        } else if (code == 66) {
            const region = c.compositor.createRegion() catch return;
            defer region.destroy();
            region.add(0, 0, 10, 10);
            if (c.locked) |p| p.setRegion(region);
            if (c.confined) |p| p.setRegion(region);
            c.surface.commit();
            std.debug.print("client: constraint region changed\n", .{});
        }
    }
};

fn onRelative(_: *zwp.RelativePointerV1, event: zwp.RelativePointerV1.Event, _: ?*anyopaque) void {
    switch (event) {
        .relative_motion => |e| std.debug.print("client: relative {d:.1},{d:.1} unaccel={d:.1},{d:.1}\n", .{ e.dx.toDouble(), e.dy.toDouble(), e.dx_unaccel.toDouble(), e.dy_unaccel.toDouble() }),
    }
}
fn onLocked(_: *zwp.LockedPointerV1, event: zwp.LockedPointerV1.Event, _: ?*anyopaque) void {
    std.debug.print("client: constraint {s}\n", .{@tagName(event)});
}
fn onConfined(_: *zwp.ConfinedPointerV1, event: zwp.ConfinedPointerV1.Event, _: ?*anyopaque) void {
    std.debug.print("client: constraint {s}\n", .{@tagName(event)});
}
fn onShortcuts(_: *zwp.KeyboardShortcutsInhibitorV1, event: zwp.KeyboardShortcutsInhibitorV1.Event, _: ?*anyopaque) void {
    std.debug.print("client: shortcuts {s}\n", .{@tagName(event)});
}
