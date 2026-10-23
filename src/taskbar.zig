//! Taskbar protocols. wlroots owns protocol resources; these registries own
//! their native handles, keyed by core ids rather than borrowed View pointers.
//! State is published once at idle, after Lua and native state transitions.
const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const srv = @import("server.zig");
const Server = srv.Server;
const View = @import("view.zig").View;
const workspace = @import("workspace.zig");
const cabi = @import("cabi.zig");
const gpa = srv.gpa;
const log = std.log.scoped(.taskbar);

pub const Taskbar = struct {
    server: *Server = undefined,
    ready: bool = false,
    idle: ?*wl.EventSource = null,
    foreign: *wlr.ForeignToplevelManagerV1 = undefined,
    list: *wlr.ExtForeignToplevelListV1 = undefined,
    manager: *Manager = undefined,
    views: std.AutoHashMapUnmanaged(u32, *Toplevel) = .empty,
    groups: std.AutoHashMapUnmanaged(u32, *Group) = .empty,
    workspaces: std.AutoHashMapUnmanaged(u32, *Handle) = .empty,
    commit: wl.Listener(*Commit) = .init(handleCommit),

    pub fn init(t: *Taskbar, server: *Server) !void {
        t.* = .{
            .server = server,
            .foreign = try wlr.ForeignToplevelManagerV1.create(server.wl_server),
            .list = try wlr.ExtForeignToplevelListV1.create(server.wl_server, 1),
            .manager = wlr_ext_workspace_manager_v1_create(server.wl_server, 1) orelse return error.OutOfMemory,
        };
        t.manager.events.commit.add(&t.commit);
        t.ready = true;
    }

    pub fn deinit(t: *Taskbar) void {
        if (!t.ready) return;
        t.ready = false;
        if (t.idle) |source| source.remove();
        t.idle = null;
        t.commit.link.remove();
        var vs = t.views.valueIterator();
        while (vs.next()) |entry| entry.*.destroy();
        t.views.deinit(gpa);
        var ws = t.workspaces.valueIterator();
        while (ws.next()) |handle| wlr_ext_workspace_handle_v1_destroy(handle.*);
        t.workspaces.deinit(gpa);
        var gs = t.groups.valueIterator();
        while (gs.next()) |group| wlr_ext_workspace_group_handle_v1_destroy(group.*);
        t.groups.deinit(gpa);
        // Managers are freed by wl_display destruction, after these listeners.
    }

    pub fn schedule(t: *Taskbar) void {
        if (!t.ready or t.idle != null) return;
        t.idle = t.server.wl_server.getEventLoop().addIdle(*Taskbar, publish, t) catch {
            log.err("cannot schedule taskbar state", .{});
            return;
        };
    }

    pub fn unmap(t: *Taskbar, id: u32) void {
        if (!t.ready) return;
        if (t.views.fetchRemove(id)) |entry| entry.value.destroy();
    }

    fn publish(t: *Taskbar) void {
        t.idle = null;
        t.sync() catch |err| log.err("cannot publish taskbar state: {s}", .{@errorName(err)});
    }

    fn sync(t: *Taskbar) !void {
        // Drop stale handles before creating replacements. Only ids are retained
        // across turns, including when Lua closes a window during dispatch.
        var stale: std.ArrayList(u32) = .empty;
        defer stale.deinit(gpa);
        var vi = t.views.keyIterator();
        while (vi.next()) |id| if (t.server.viewById(id.*) == null) try stale.append(gpa, id.*);
        for (stale.items) |id| t.views.fetchRemove(id).?.value.destroy();
        stale.clearRetainingCapacity();
        var wi = t.workspaces.keyIterator();
        while (wi.next()) |id| if (workspace.byId(t.server, id.*) == null) try stale.append(gpa, id.*);
        for (stale.items) |id| wlr_ext_workspace_handle_v1_destroy(t.workspaces.fetchRemove(id).?.value);
        stale.clearRetainingCapacity();
        var gi = t.groups.keyIterator();
        while (gi.next()) |id| {
            const output = t.server.outputById(id.*);
            if (output == null or !output.?.inLayout()) try stale.append(gpa, id.*);
        }
        for (stale.items) |id| wlr_ext_workspace_group_handle_v1_destroy(t.groups.fetchRemove(id).?.value);

        var outputs = t.server.outputs.iterator(.forward);
        while (outputs.next()) |o| {
            if (!o.inLayout() or t.groups.contains(o.id)) continue;
            // Creation/removal/assignment is plugin policy. Only activation is
            // advertised, so a shell cannot invalidate plugin registrations.
            const group = wlr_ext_workspace_group_handle_v1_create(t.manager, 0) orelse return error.OutOfMemory;
            t.groups.put(gpa, o.id, group) catch |err| {
                wlr_ext_workspace_group_handle_v1_destroy(group);
                return err;
            };
            wlr_ext_workspace_group_handle_v1_output_enter(group, o.wlr_output);
        }
        var workspaces = t.server.workspaces.iterator(.forward);
        while (workspaces.next()) |ws| {
            const result = try t.workspaces.getOrPut(gpa, ws.id);
            if (!result.found_existing) {
                // Core ids are session-local, so omit the optional persistent id.
                result.value_ptr.* = wlr_ext_workspace_handle_v1_create(t.manager, null, 1) orelse {
                    _ = t.workspaces.remove(ws.id);
                    return error.OutOfMemory;
                };
            }
            const handle = result.value_ptr.*;
            wlr_ext_workspace_handle_v1_set_name(handle, ws.name);
            wlr_ext_workspace_handle_v1_set_group(handle, if (ws.output) |o| t.groups.get(o.id) else null);
            cabi.call(ws.isActive(), wlr_ext_workspace_handle_v1_set_active, .{handle});
            cabi.call(ws.urgent, wlr_ext_workspace_handle_v1_set_urgent, .{handle});
            // Inactive workspaces remain listed: hidden means omitted by shells.
            wlr_ext_workspace_handle_v1_set_hidden(handle, false);
        }
        var views = t.server.views.iterator(.forward);
        while (views.next()) |v| {
            if (!v.announced or t.views.contains(v.id)) continue;
            const entry = try Toplevel.create(t, v);
            t.views.put(gpa, v.id, entry) catch |err| {
                entry.destroy();
                return err;
            };
        }
        views = t.server.views.iterator(.forward);
        while (views.next()) |v| if (t.views.get(v.id)) |entry| entry.update(v);
    }

    fn handleCommit(listener: *wl.Listener(*Commit), event: *Commit) void {
        const t: *Taskbar = @fieldParentPtr("commit", listener);
        if (t.server.session_lock.locked()) return;
        // wlroots invalidates queued pointers when handles are destroyed. No
        // publication occurs until the complete client transaction has run.
        var it = event.requests.iterator(.forward);
        while (it.next()) |request| {
            if (request.kind != .activate) continue;
            const handle = request.payload.workspace orelse continue;
            var ids = t.workspaces.iterator();
            while (ids.next()) |entry| {
                if (entry.value_ptr.* != handle) continue;
                if (workspace.byId(t.server, entry.key_ptr.*)) |ws| _ = ws.activate();
                break;
            }
        }
        t.schedule();
    }
};

const Toplevel = struct {
    taskbar: *Taskbar,
    id: u32,
    foreign: *wlr.ForeignToplevelHandleV1,
    list: *wlr.ExtForeignToplevelHandleV1,
    maximize: wl.Listener(*wlr.ForeignToplevelHandleV1.event.Maximized) = .init(handleMaximize),
    minimize: wl.Listener(*wlr.ForeignToplevelHandleV1.event.Minimized) = .init(handleMinimize),
    activate: wl.Listener(*wlr.ForeignToplevelHandleV1.event.Activated) = .init(handleActivate),
    fullscreen: wl.Listener(*wlr.ForeignToplevelHandleV1.event.Fullscreen) = .init(handleFullscreen),
    close: wl.Listener(*wlr.ForeignToplevelHandleV1) = .init(handleClose),

    fn create(taskbar: *Taskbar, v: *View) !*Toplevel {
        const entry = try gpa.create(Toplevel);
        errdefer gpa.destroy(entry);
        const foreign = try wlr.ForeignToplevelHandleV1.create(taskbar.foreign);
        errdefer foreign.destroy();
        entry.* = .{
            .taskbar = taskbar,
            .id = v.id,
            .foreign = foreign,
            .list = try wlr.ExtForeignToplevelHandleV1.create(taskbar.list, &.{ .title = v.title() orelse "", .app_id = v.appId() orelse "" }),
        };
        foreign.events.request_maximize.add(&entry.maximize);
        foreign.events.request_minimize.add(&entry.minimize);
        foreign.events.request_activate.add(&entry.activate);
        foreign.events.request_fullscreen.add(&entry.fullscreen);
        foreign.events.request_close.add(&entry.close);
        return entry;
    }

    fn destroy(entry: *Toplevel) void {
        inline for (.{ "maximize", "minimize", "activate", "fullscreen", "close" }) |name| @field(entry, name).link.remove();
        entry.foreign.destroy();
        entry.list.destroy();
        gpa.destroy(entry);
    }

    fn update(entry: *Toplevel, v: *View) void {
        const handle = entry.foreign;
        handle.setTitle(v.title() orelse "");
        handle.setAppId(v.appId() orelse "");
        cabi.call(v.maximized, wlr.ForeignToplevelHandleV1.setMaximized, .{handle});
        cabi.call(v.minimized, wlr.ForeignToplevelHandleV1.setMinimized, .{handle});
        cabi.call(v.server.focused == v, wlr.ForeignToplevelHandleV1.setActivated, .{handle});
        cabi.call(v.isFullscreen(), wlr.ForeignToplevelHandleV1.setFullscreen, .{handle});
        const parent = if (v.parent()) |p| entry.taskbar.views.get(p.id) else null;
        handle.setParent(if (parent) |p| p.foreign else null);
        entry.list.updateState(&.{ .title = v.title() orelse "", .app_id = v.appId() orelse "" });
        // Membership follows actual window geometry, including spanning outputs.
        var old = handle.outputs.safeIterator(.forward);
        while (old.next()) |o| {
            const out = v.server.outputByWlr(o.output);
            if (out == null or !overlaps(v, out.?)) handle.outputLeave(o.output);
        }
        var outputs = v.server.outputs.iterator(.forward);
        while (outputs.next()) |o| if (overlaps(v, o)) handle.outputEnter(o.wlr_output);
    }

    fn view(entry: *Toplevel) ?*View {
        if (!entry.taskbar.ready or entry.taskbar.server.session_lock.locked()) return null;
        return entry.taskbar.server.viewById(entry.id);
    }

    fn handleMaximize(listener: *wl.Listener(*wlr.ForeignToplevelHandleV1.event.Maximized), event: *wlr.ForeignToplevelHandleV1.event.Maximized) void {
        const entry: *Toplevel = @fieldParentPtr("maximize", listener);
        if (entry.view()) |v| v.setMaximized(event.maximized);
    }

    fn handleMinimize(listener: *wl.Listener(*wlr.ForeignToplevelHandleV1.event.Minimized), event: *wlr.ForeignToplevelHandleV1.event.Minimized) void {
        const entry: *Toplevel = @fieldParentPtr("minimize", listener);
        if (entry.view()) |v| v.setMinimized(event.minimized);
    }

    fn handleActivate(listener: *wl.Listener(*wlr.ForeignToplevelHandleV1.event.Activated), event: *wlr.ForeignToplevelHandleV1.event.Activated) void {
        const entry: *Toplevel = @fieldParentPtr("activate", listener);
        const v = entry.view() orelse return;
        const server = entry.taskbar.server;
        if (event.seat != server.seat) return;
        // A taskbar is a trusted shell action: restore and show its workspace.
        const id = v.id;
        v.setMinimized(false);
        const live = server.viewById(id) orelse return;
        if (live.workspace) |ws| _ = ws.activate();
        const shown = server.viewById(id) orelse return;
        if (server.focusable(shown)) server.focus(shown);
    }

    fn handleFullscreen(listener: *wl.Listener(*wlr.ForeignToplevelHandleV1.event.Fullscreen), event: *wlr.ForeignToplevelHandleV1.event.Fullscreen) void {
        const entry: *Toplevel = @fieldParentPtr("fullscreen", listener);
        const v = entry.view() orelse return;
        // The upstream binding marks output non-null, but the C API permits
        // NULL. Read through the accurate C layout, without loading an invalid
        // non-null Zig pointer (which an optimizer may assume cannot be NULL).
        const RequestFullscreen = extern struct {
            toplevel: *wlr.ForeignToplevelHandleV1,
            fullscreen: bool,
            output: ?*wlr.Output,
        };
        const request: *const RequestFullscreen = @ptrCast(event);
        v.setFullscreen(request.fullscreen, v.server.outputByWlr(request.output));
    }

    fn handleClose(listener: *wl.Listener(*wlr.ForeignToplevelHandleV1), _: *wlr.ForeignToplevelHandleV1) void {
        const entry: *Toplevel = @fieldParentPtr("close", listener);
        if (entry.view()) |v| v.close();
    }
};

fn overlaps(v: *View, o: *srv.Output) bool {
    if (!o.inLayout()) return false;
    const a = v.geometry();
    const b = o.box();
    return @as(i64, a.x) < @as(i64, b.x) + b.width and @as(i64, b.x) < @as(i64, a.x) + a.width and
        @as(i64, a.y) < @as(i64, b.y) + b.height and @as(i64, b.y) < @as(i64, a.y) + a.height;
}

// wlroots 0.20.2 wlr_ext_workspace_v1.h. zig-wlroots 0.20.1 has no
// binding. Only the public prefixes used here are declared; C owns storage.
const Manager = extern struct {
    global: *wl.Global,
    groups: wl.list.Head(Group, .link),
    workspaces: wl.list.Head(Handle, .link),
    events: extern struct { commit: wl.Signal(*Commit), destroy: wl.Signal(void) },
    data: ?*anyopaque,
};
const Group = extern struct {
    manager: *Manager,
    caps: u32,
    events: extern struct { destroy: wl.Signal(void) },
    link: wl.list.Link,
    data: ?*anyopaque,
};
const Handle = extern struct {
    manager: *Manager,
    group: ?*Group,
    id: ?[*:0]u8,
    name: ?[*:0]u8,
    coordinates: wl.Array,
    caps: u32,
    state: u32,
    events: extern struct { destroy: wl.Signal(void) },
    link: wl.list.Link,
    data: ?*anyopaque,
};
const Request = extern struct {
    kind: enum(c_int) { create, activate, deactivate, assign, remove },
    link: wl.list.Link,
    payload: extern union {
        workspace: ?*Handle,
        create: extern struct { name: [*:0]u8, group: ?*Group },
        assign: extern struct { workspace: ?*Handle, group: ?*Group },
    },
};
const Commit = extern struct { requests: *wl.list.Head(Request, .link) };

extern fn wlr_ext_workspace_manager_v1_create(*wl.Server, u32) ?*Manager;
extern fn wlr_ext_workspace_group_handle_v1_create(*Manager, u32) ?*Group;
extern fn wlr_ext_workspace_group_handle_v1_destroy(*Group) void;
extern fn wlr_ext_workspace_group_handle_v1_output_enter(*Group, *wlr.Output) void;
extern fn wlr_ext_workspace_handle_v1_create(*Manager, ?[*:0]const u8, u32) ?*Handle;
extern fn wlr_ext_workspace_handle_v1_destroy(*Handle) void;
extern fn wlr_ext_workspace_handle_v1_set_group(*Handle, ?*Group) void;
extern fn wlr_ext_workspace_handle_v1_set_name(*Handle, [*:0]const u8) void;
extern fn wlr_ext_workspace_handle_v1_set_active(*Handle, bool) void;
extern fn wlr_ext_workspace_handle_v1_set_urgent(*Handle, bool) void;
extern fn wlr_ext_workspace_handle_v1_set_hidden(*Handle, bool) void;
