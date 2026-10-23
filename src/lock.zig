//! ext-session-lock-v1: screen lockers (swaylock, ...). Security-sensitive.
//!
//! - While locked, every scene layer but `lock` is disabled. Each output
//!   has an opaque background in the lock layer, below the lock surfaces,
//!   so an output without (or before) its lock surface shows a solid
//!   colour, never windows or panels.
//! - `locked` is sent only once every output has presented a frame
//!   committed after the lock state was applied (output `present` events
//!   with a newer commit_seq), as the protocol requires.
//! - Keyboard and pointer go to lock surfaces only. Focus changes to
//!   windows and layer surfaces are refused, and no key binding runs (not
//!   even the core's fallback ones, which could quit the session), except
//!   VT switching.
//! - If the locker goes away without unlock_and_destroy (it crashed), the
//!   session stays locked and the background turns dark red; a new locker
//!   may lock (and unlock) it. Nothing else unlocks it.
const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const srv = @import("server.zig");
const input = @import("input.zig");
const Server = srv.Server;
const Output = srv.Output;
const gpa = srv.gpa;
const log = std.log.scoped(.lock);

const black = [4]f32{ 0, 0, 0, 1 };
/// Shown when the locker died while the session is locked.
const abandoned_color = [4]f32{ 0.35, 0, 0, 1 };

pub const State = enum { unlocked, locking, locked, abandoned };

pub const SessionLock = struct {
    server: *Server,
    manager: *wlr.SessionLockManagerV1,
    state: State = .unlocked,
    /// The locker's lock object, while it exists.
    lock: ?*wlr.SessionLockV1 = null,
    /// Lock surface with the keyboard.
    focus: ?*LockSurface = null,
    surfaces: wl.list.Head(LockSurface, .link) = undefined,

    new_lock: wl.Listener(*wlr.SessionLockV1) = .init(handleNewLock),
    new_surface: wl.Listener(*wlr.SessionLockSurfaceV1) = .init(handleNewSurface),
    unlock: wl.Listener(void) = .init(handleUnlock),
    lock_destroy: wl.Listener(void) = .init(handleLockDestroy),
    manager_destroy: wl.Listener(void) = .init(handleManagerDestroy),

    pub fn init(sl: *SessionLock, server: *Server) !void {
        sl.* = .{ .server = server, .manager = try wlr.SessionLockManagerV1.create(server.wl_server) };
        sl.surfaces.init();
        sl.manager.events.new_lock.add(&sl.new_lock);
        sl.manager.events.destroy.add(&sl.manager_destroy);
    }

    pub fn locked(sl: *SessionLock) bool {
        return sl.state != .unlocked;
    }

    fn handleManagerDestroy(listener: *wl.Listener(void)) void {
        const sl: *SessionLock = @fieldParentPtr("manager_destroy", listener);
        sl.new_lock.link.remove();
        sl.manager_destroy.link.remove();
    }

    fn handleNewLock(listener: *wl.Listener(*wlr.SessionLockV1), lock: *wlr.SessionLockV1) void {
        const sl: *SessionLock = @fieldParentPtr("new_lock", listener);
        if (sl.lock != null) {
            log.info("refusing a second session lock", .{});
            return lock.destroy(); // sends finished
        }
        sl.lock = lock;
        lock.events.new_surface.add(&sl.new_surface);
        lock.events.unlock.add(&sl.unlock);
        lock.events.destroy.add(&sl.lock_destroy);
        switch (sl.state) {
            .unlocked => sl.enter(),
            // A new locker for a session that stayed locked: it is still
            // locked, so the new one can be told at once.
            .abandoned, .locked => {
                sl.state = .locked;
                sl.setBackground(&black);
                lock.sendLocked();
            },
            .locking => unreachable, // only with a lock object, refused above
        }
    }

    /// Hides everything and waits for every output to present that.
    fn enter(sl: *SessionLock) void {
        const server = sl.server;
        log.info("session locked", .{});
        sl.state = .locking;
        server.data.cancel();
        input.endGrab(server);
        for (server.layers, 0..) |tree, i| {
            if (i != @intFromEnum(srv.Layer.lock)) tree.node.setEnabled(false);
        }
        var it = server.outputs.iterator(.forward);
        while (it.next()) |o| sl.prepareOutput(o);
        // The keyboard leaves windows and layer surfaces.
        server.seat.keyboardNotifyClearFocus();
        input.refocusPointer(server);
        server.emit(.session_lock, 0);
        sl.maybeLocked();
    }

    /// Background, and a frame to present in the locked state.
    pub fn prepareOutput(sl: *SessionLock, o: *Output) void {
        if (sl.state == .unlocked) return;
        if (o.lock_bg == null) {
            o.lock_bg = sl.server.layer(.lock).createSceneRect(0, 0, if (sl.state == .abandoned) &abandoned_color else &black) catch null;
            if (o.lock_bg) |r| r.node.lowerToBottom();
        }
        o.layoutLockBackground();
        o.lock_seq = o.wlr_output.commit_seq;
        o.lock_presented = !o.inLayout(); // a disabled output shows nothing
        o.wlr_output.scheduleFrame();
    }

    /// From an output's present event.
    pub fn presented(sl: *SessionLock, o: *Output, commit_seq: u32) void {
        if (sl.state != .locking or o.lock_presented) return;
        if (commit_seq -% o.lock_seq > 0 and commit_seq -% o.lock_seq < 1 << 31) {
            o.lock_presented = true;
            sl.maybeLocked();
        }
    }

    fn maybeLocked(sl: *SessionLock) void {
        if (sl.state != .locking) return;
        var it = sl.server.outputs.iterator(.forward);
        while (it.next()) |o| if (o.inLayout() and !o.lock_presented) return;
        sl.state = .locked;
        if (sl.lock) |l| l.sendLocked();
    }

    fn setBackground(sl: *SessionLock, color: *const [4]f32) void {
        var it = sl.server.outputs.iterator(.forward);
        while (it.next()) |o| if (o.lock_bg) |r| r.setColor(color);
    }

    fn handleNewSurface(listener: *wl.Listener(*wlr.SessionLockSurfaceV1), wlr_ls: *wlr.SessionLockSurfaceV1) void {
        const sl: *SessionLock = @fieldParentPtr("new_surface", listener);
        // Without a scene tree the surface is never shown: the output keeps
        // its opaque background, so nothing leaks.
        LockSurface.create(sl, wlr_ls) catch log.err("out of memory for a lock surface", .{});
    }

    fn handleUnlock(listener: *wl.Listener(void)) void {
        const sl: *SessionLock = @fieldParentPtr("unlock", listener);
        const server = sl.server;
        log.info("session unlocked", .{});
        sl.state = .unlocked;
        sl.focus = null;
        for (server.layers) |tree| tree.node.setEnabled(true);
        var it = server.outputs.iterator(.forward);
        while (it.next()) |o| if (o.lock_bg) |r| {
            r.node.destroy();
            o.lock_bg = null;
        };
        server.restoreKeyboard();
        input.refocusPointer(server);
        server.emit(.session_unlock, 0);
    }

    fn handleLockDestroy(listener: *wl.Listener(void)) void {
        const sl: *SessionLock = @fieldParentPtr("lock_destroy", listener);
        sl.new_surface.link.remove();
        sl.unlock.link.remove();
        sl.lock_destroy.link.remove();
        sl.lock = null;
        if (sl.state == .unlocked) return;
        // The locker is gone without unlocking: stay locked.
        log.warn("the screen locker exited without unlocking; the session stays locked until a new locker unlocks it", .{});
        sl.state = .abandoned;
        sl.focus = null;
        sl.setBackground(&abandoned_color);
        sl.server.seat.keyboardNotifyClearFocus();
        var it = sl.server.outputs.iterator(.forward);
        while (it.next()) |o| o.wlr_output.scheduleFrame();
    }

    /// Gives the keyboard to `ls`, bypassing the lock's focus refusal.
    fn focusSurface(sl: *SessionLock, ls: ?*LockSurface) void {
        sl.focus = ls;
        const server = sl.server;
        const s = ls orelse return server.seat.keyboardNotifyClearFocus();
        if (server.seat.getKeyboard()) |kb| {
            var buf: [32]u32 = undefined;
            server.seat.keyboardNotifyEnter(s.wlr_ls.surface, input.heldKeys(server, kb, &buf), &kb.modifiers);
        } else server.seat.keyboardNotifyEnter(s.wlr_ls.surface, &.{}, null);
    }

    /// The lock surface of the output under the cursor, else any.
    fn pickFocus(sl: *SessionLock, skip: ?*LockSurface) ?*LockSurface {
        const at = sl.server.activeOutput();
        var any: ?*LockSurface = null;
        var it = sl.surfaces.iterator(.forward);
        while (it.next()) |s| {
            if (s == skip or !s.wlr_ls.surface.mapped) continue;
            if (s.output == at) return s;
            any = any orelse s;
        }
        return any;
    }

    /// Output geometry changed: lock surfaces and backgrounds follow.
    pub fn arrange(sl: *SessionLock) void {
        var it = sl.surfaces.iterator(.forward);
        while (it.next()) |s| s.place();
        var outs = sl.server.outputs.iterator(.forward);
        while (outs.next()) |o| o.layoutLockBackground();
    }
};

pub const LockSurface = struct {
    lock: *SessionLock,
    wlr_ls: *wlr.SessionLockSurfaceV1,
    output: ?*Output,
    tree: *wlr.SceneTree,
    /// In SessionLock.surfaces.
    link: wl.list.Link = undefined,

    map: wl.Listener(void) = .init(handleMap),
    destroy: wl.Listener(void) = .init(handleDestroy),

    fn create(sl: *SessionLock, wlr_ls: *wlr.SessionLockSurfaceV1) !void {
        const ls = try gpa.create(LockSurface);
        errdefer gpa.destroy(ls);
        const tree = try sl.server.layer(.lock).createSceneSubsurfaceTree(wlr_ls.surface);
        ls.* = .{ .lock = sl, .wlr_ls = wlr_ls, .output = sl.server.outputByWlr(wlr_ls.output), .tree = tree };
        sl.surfaces.append(ls);
        wlr_ls.surface.events.map.add(&ls.map);
        wlr_ls.events.destroy.add(&ls.destroy);
        ls.place();
    }

    /// Covers its output: configured to its size, at its position.
    fn place(ls: *LockSurface) void {
        const o = ls.output orelse return;
        if (!o.inLayout()) return;
        const b = o.box();
        ls.tree.node.setPosition(b.x, b.y);
        if (ls.wlr_ls.pending.width != @as(u32, @intCast(b.width)) or ls.wlr_ls.pending.height != @as(u32, @intCast(b.height)) or !ls.wlr_ls.configured)
            _ = ls.wlr_ls.configure(@intCast(b.width), @intCast(b.height));
    }

    fn handleMap(listener: *wl.Listener(void)) void {
        const ls: *LockSurface = @fieldParentPtr("map", listener);
        const sl = ls.lock;
        if (sl.focus == null or ls.output == sl.server.activeOutput()) sl.focusSurface(ls);
        input.refocusPointer(sl.server);
    }

    fn handleDestroy(listener: *wl.Listener(void)) void {
        const ls: *LockSurface = @fieldParentPtr("destroy", listener);
        const sl = ls.lock;
        ls.map.link.remove();
        ls.destroy.link.remove();
        ls.link.remove();
        ls.tree.node.destroy();
        if (sl.focus == ls) sl.focusSurface(if (sl.state == .unlocked) null else sl.pickFocus(ls));
        gpa.destroy(ls);
        input.refocusPointer(sl.server);
    }
};
