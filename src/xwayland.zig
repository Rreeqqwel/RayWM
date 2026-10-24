//! Xwayland's process and X11 roles. wlroots owns the XWM, selections and
//! native X11 surfaces; regular associations use the common View model.
//! Override-redirect menus stay outside layout/plugin window registries.
const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const srv = @import("server.zig");
const View = @import("view.zig").View;
const input = @import("input.zig");
const gpa = srv.gpa;
const log = std.log.scoped(.xwayland);

extern "c" fn setenv([*:0]const u8, [*:0]const u8, c_int) c_int;
extern "c" fn unsetenv([*:0]const u8) c_int;

fn milliseconds() u64 {
    const ts = srv.timestamp();
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

pub const Manager = struct {
    server: *srv.Server = undefined,
    x: ?*wlr.Xwayland = null,
    timer: ?*wl.EventSource = null,
    ready_at: u64 = 0,
    retries: u8 = 0,
    stopping: bool = false,
    client: ?*wl.Client = null,
    surfaces: wl.list.Head(Surface, .link) = undefined,
    ready: wl.Listener(void) = .init(handleReady),
    new_surface: wl.Listener(*wlr.XwaylandSurface) = .init(handleSurface),
    client_destroy: wl.Listener(*wl.Client) = .init(handleClientDestroy),

    pub fn init(m: *Manager, server: *srv.Server) !void {
        m.* = .{ .server = server };
        m.surfaces.init();
        const env_off = if (std.c.getenv("RAYWM_XWAYLAND")) |value| std.mem.eql(u8, std.mem.span(value), "0") else false;
        if (env_off or !server.settings.general.xwayland) {
            _ = unsetenv("DISPLAY");
            log.info("Xwayland disabled ({s})", .{if (env_off) "RAYWM_XWAYLAND=0" else "raywm.conf general.xwayland"});
            return;
        }
        m.timer = try server.wl_server.getEventLoop().addTimer(*Manager, recover, m);
        m.start() catch |err| {
            _ = unsetenv("DISPLAY");
            log.warn("Xwayland unavailable: {s}", .{@errorName(err)});
        };
    }

    fn start(m: *Manager) !void {
        const x = try wlr.Xwayland.create(m.server.wl_server, m.server.compositor, true);
        m.x = x;
        x.setSeat(m.server.seat); // X11/Wayland clipboard and primary-selection bridge
        x.events.ready.add(&m.ready);
        x.events.new_surface.add(&m.new_surface);
        _ = setenv("DISPLAY", x.display_name, 1);
        log.info("lazy Xwayland display {s}", .{x.display_name});
    }

    fn stop(m: *Manager) void {
        if (m.client != null) m.client_destroy.link.remove();
        m.client = null;
        const x = m.x orelse return;
        m.x = null;
        m.ready.link.remove();
        m.new_surface.link.remove();
        x.destroy(); // destroys its XWM/surfaces and process/socket resources
    }

    pub fn deinit(m: *Manager) void {
        m.stopping = true;
        if (m.timer) |timer| timer.remove();
        m.timer = null;
        m.stop();
    }

    /// XwaylandServer's 0.20.1 Zig binding differs from 0.20.2 after its
    /// wl_server member. Only the stable client prefix is read here.
    pub fn ownsClient(m: *Manager, client: *const wl.Client) bool {
        const x = m.x orelse return false;
        const server = x.server orelse return false;
        return server.client == client;
    }

    fn handleReady(listener: *wl.Listener(void)) void {
        const m: *Manager = @fieldParentPtr("ready", listener);
        const x = m.x orelse return;
        if (m.client != null) m.client_destroy.link.remove();
        m.client = x.server.?.client;
        if (m.client) |client| client.addDestroyListener(&m.client_destroy);
        m.ready_at = milliseconds();
        log.info("Xwayland ready on {s}", .{x.display_name});
    }

    fn handleClientDestroy(listener: *wl.Listener(*wl.Client), _: *wl.Client) void {
        const m: *Manager = @fieldParentPtr("client_destroy", listener);
        m.client_destroy.link.remove();
        m.client = null;
        if (m.stopping) return;
        // wlroots rearms its lazy server after runs longer than 5 seconds.
        // It intentionally refuses rapid restart loops; provide at most
        // three delayed retries for an early crash, keeping Wayland alive.
        if (milliseconds() - m.ready_at > 5000) {
            m.retries = 0;
            return;
        }
        if (m.retries >= 3) {
            log.warn("Xwayland crashed repeatedly; restart RayWM to retry X11", .{});
            return;
        }
        m.retries += 1;
        if (m.timer) |timer| timer.timerUpdate(@as(c_int, 250) << @intCast(m.retries)) catch {};
    }

    fn recover(m: *Manager) c_int {
        if (m.stopping) return 0;
        m.stop();
        m.start() catch |err| log.warn("Xwayland recovery failed: {s}", .{@errorName(err)});
        return 0;
    }

    fn handleSurface(listener: *wl.Listener(*wlr.XwaylandSurface), xs: *wlr.XwaylandSurface) void {
        const m: *Manager = @fieldParentPtr("new_surface", listener);
        Surface.create(m, xs) catch log.err("out of memory for an X11 surface", .{});
    }

    pub fn syncVisibility(m: *Manager) void {
        if (m.x == null) return;
        var it = m.surfaces.iterator(.forward);
        while (it.next()) |s| s.visibility();
    }
};

const Surface = struct {
    manager: *Manager,
    xs: *wlr.XwaylandSurface,
    link: wl.list.Link = undefined,
    tree: ?*wlr.SceneTree = null,
    /// Stable core id, never an untracked View pointer.
    owner: u32 = 0,
    associate: wl.Listener(void) = .init(handleAssociate),
    dissociate: wl.Listener(void) = .init(handleDissociate),
    destroy: wl.Listener(void) = .init(handleDestroy),
    configure: wl.Listener(*wlr.XwaylandSurface.event.Configure) = .init(handleConfigure),
    redirect: wl.Listener(void) = .init(handleRedirect),
    geometry: wl.Listener(void) = .init(handleGeometry),
    parent: wl.Listener(void) = .init(handleParent),
    map: wl.Listener(void) = .init(handleMap),
    unmap: wl.Listener(void) = .init(handleUnmap),

    fn create(m: *Manager, xs: *wlr.XwaylandSurface) !void {
        const s = try gpa.create(Surface);
        s.* = .{ .manager = m, .xs = xs };
        m.surfaces.append(s);
        xs.events.associate.add(&s.associate);
        xs.events.dissociate.add(&s.dissociate);
        xs.events.destroy.add(&s.destroy);
        xs.events.request_configure.add(&s.configure);
        xs.events.set_override_redirect.add(&s.redirect);
        xs.events.set_geometry.add(&s.geometry);
        xs.events.set_parent.add(&s.parent);
        if (xs.surface != null) handleAssociate(&s.associate);
    }

    fn handleAssociate(listener: *wl.Listener(void)) void {
        const s: *Surface = @fieldParentPtr("associate", listener);
        const server = s.manager.server;
        if (!s.xs.override_redirect) {
            View.createXwayland(server, s.xs) catch log.err("cannot create X11 view", .{});
            return;
        }
        const surface = s.xs.surface orelse return;
        const tree = server.layer(.unmanaged).createSceneTree() catch return;
        _ = tree.createSceneSubsurfaceTree(surface) catch {
            tree.node.destroy();
            return;
        };
        s.tree = tree;
        tree.node.setPosition(s.xs.x, s.xs.y);
        tree.node.setEnabled(false);
        surface.events.map.add(&s.map);
        surface.events.unmap.add(&s.unmap);
        if (surface.mapped) handleMap(&s.map);
    }

    fn handleDissociate(listener: *wl.Listener(void)) void {
        const s: *Surface = @fieldParentPtr("dissociate", listener);
        s.dropTree(); // regular View has its own dissociate listener
    }

    fn dropTree(s: *Surface) void {
        const tree = s.tree orelse return;
        s.map.link.remove();
        s.unmap.link.remove();
        tree.node.destroy();
        s.tree = null;
    }

    fn handleDestroy(listener: *wl.Listener(void)) void {
        const s: *Surface = @fieldParentPtr("destroy", listener);
        s.dropTree();
        inline for (.{ "associate", "dissociate", "destroy", "configure", "redirect", "geometry", "parent" }) |name| @field(s, name).link.remove();
        s.link.remove();
        gpa.destroy(s);
    }

    fn handleConfigure(listener: *wl.Listener(*wlr.XwaylandSurface.event.Configure), event: *wlr.XwaylandSurface.event.Configure) void {
        const s: *Surface = @fieldParentPtr("configure", listener);
        if (View.fromXwayland(s.xs) == null) s.xs.configure(event.x, event.y, @max(1, event.width), @max(1, event.height));
    }

    fn handleRedirect(listener: *wl.Listener(void)) void {
        const s: *Surface = @fieldParentPtr("redirect", listener);
        if (View.fromXwayland(s.xs)) |view| view.dropXwayland();
        s.dropTree();
        if (s.xs.surface != null) handleAssociate(&s.associate);
    }

    fn handleGeometry(listener: *wl.Listener(void)) void {
        const s: *Surface = @fieldParentPtr("geometry", listener);
        if (s.tree) |tree| tree.node.setPosition(s.xs.x, s.xs.y);
        input.refocusPointer(s.manager.server);
    }

    fn handleParent(listener: *wl.Listener(void)) void {
        const s: *Surface = @fieldParentPtr("parent", listener);
        s.chooseOwner();
        s.visibility();
    }

    fn chooseOwner(s: *Surface) void {
        var parent = s.xs.parent;
        var depth: u32 = 0;
        while (parent) |p| : (parent = p.parent) {
            if (View.fromXwayland(p)) |v| {
                s.owner = v.id;
                return;
            }
            depth += 1;
            if (depth > 32) break;
        }
        if (s.manager.server.focused) |v| if (v.impl == .xwayland) {
            s.owner = v.id;
            return;
        };
        s.owner = 0;
    }

    fn visibility(s: *Surface) void {
        const tree = s.tree orelse return;
        const surface = s.xs.surface orelse return;
        const server = s.manager.server;
        const owner_visible = if (s.owner == 0) true else if (server.viewById(s.owner)) |v| v.visible() else false;
        const visible = surface.mapped and owner_visible;
        @import("cabi.zig").call(visible, wlr.SceneNode.setEnabled, .{&tree.node});
        if (!visible and server.seat.keyboard_state.focused_surface == surface and !server.session_lock.locked()) server.restoreKeyboard();
    }

    fn handleMap(listener: *wl.Listener(void)) void {
        const s: *Surface = @fieldParentPtr("map", listener);
        s.chooseOwner();
        s.visibility();
        const server = s.manager.server;
        if (!server.session_lock.locked() and server.layer_focus == null and s.xs.overrideRedirectWantsFocus()) {
            const owner_visible = if (s.owner == 0) true else if (server.viewById(s.owner)) |v| v.visible() else false;
            if (owner_visible) server.keyboardEnter(s.xs.surface.?);
        }
        input.refocusPointer(server);
    }

    fn handleUnmap(listener: *wl.Listener(void)) void {
        const s: *Surface = @fieldParentPtr("unmap", listener);
        if (s.tree) |tree| tree.node.setEnabled(false);
        const server = s.manager.server;
        if (server.seat.keyboard_state.focused_surface == s.xs.surface and !server.session_lock.locked()) server.restoreKeyboard();
        input.refocusPointer(server);
    }
};
