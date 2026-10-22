//! xdg-shell toplevels and popups.
//!
//! Geometry model: (x, y) is the top-left of the window geometry in layout
//! coordinates. A size change is only a request: it takes effect when the
//! client commits a buffer acknowledging that configure, so a position that
//! must change together with the size waits in `pending` until then.
const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const srv = @import("server.zig");
const Server = srv.Server;
const gpa = srv.gpa;
const LayerSurface = @import("layer.zig").LayerSurface;

pub const View = struct {
    tag: srv.Tag = .view,
    server: *Server,
    xdg: *wlr.XdgToplevel,
    tree: *wlr.SceneTree,
    /// Never reused, so a stale id held by Lua cannot alias a new window.
    id: u32,
    /// In server.views while mapped.
    link: wl.list.Link = undefined,
    mapped: bool = false,
    x: i32 = 0,
    y: i32 = 0,
    pending: ?struct { serial: u32, x: i32, y: i32 } = null,
    /// Interactive resize: keeps the edges opposite to `edges` fixed.
    anchor: ?struct { serial: u32, edges: wlr.Edges, box: wlr.Box } = null,
    opacity: f32 = 1.0,

    commit: wl.Listener(*wlr.Surface) = .init(handleCommit),
    map: wl.Listener(void) = .init(handleMap),
    unmap: wl.Listener(void) = .init(handleUnmap),
    destroy: wl.Listener(void) = .init(handleDestroy),
    request_move: wl.Listener(*wlr.XdgToplevel.event.Move) = .init(handleRequestMove),
    request_resize: wl.Listener(*wlr.XdgToplevel.event.Resize) = .init(handleRequestResize),
    request_maximize: wl.Listener(void) = .init(handleRequestState("request_maximize")),
    request_fullscreen: wl.Listener(void) = .init(handleRequestState("request_fullscreen")),
    set_title: wl.Listener(void) = .init(handleSetTitle),

    pub fn create(listener: *wl.Listener(*wlr.XdgToplevel), xdg: *wlr.XdgToplevel) void {
        const server: *Server = @fieldParentPtr("new_toplevel", listener);
        const view = gpa.create(View) catch return std.log.err("out of memory", .{});
        // The scene tree is owned by wlroots and destroyed with the xdg surface.
        const tree = server.layer(.views).createSceneXdgSurface(xdg.base) catch {
            gpa.destroy(view);
            return std.log.err("out of memory", .{});
        };
        view.* = .{ .server = server, .xdg = xdg, .tree = tree, .id = server.nextId() };
        tree.node.data = &view.tag;
        xdg.base.data = tree;

        const surface = xdg.base.surface;
        surface.events.commit.add(&view.commit);
        surface.events.map.add(&view.map);
        surface.events.unmap.add(&view.unmap);
        xdg.events.destroy.add(&view.destroy);
        xdg.events.request_move.add(&view.request_move);
        xdg.events.request_resize.add(&view.request_resize);
        xdg.events.request_maximize.add(&view.request_maximize);
        xdg.events.request_fullscreen.add(&view.request_fullscreen);
        xdg.events.set_title.add(&view.set_title);
    }

    /// Finds the view owning a scene node (e.g. a surface buffer or popup).
    pub fn fromNode(node: *wlr.SceneNode) ?*View {
        var it: ?*wlr.SceneNode = node;
        while (it) |n| : (it = if (n.parent) |p| &p.node else null) {
            const tag: *const srv.Tag = @ptrCast(@alignCast(n.data orelse continue));
            if (tag.* == .view) return @constCast(@as(*const View, @alignCast(@fieldParentPtr("tag", tag))));
        }
        return null;
    }

    pub fn geometry(view: *View) wlr.Box {
        const g = view.xdg.base.geometry;
        return .{ .x = view.x, .y = view.y, .width = g.width, .height = g.height };
    }

    /// Moves immediately; drops any position waiting on a resize.
    pub fn move(view: *View, x: i32, y: i32) void {
        view.pending = null;
        view.anchor = null;
        view.x = x;
        view.y = y;
        view.syncPosition();
    }

    /// Requests a new size; the position is applied together with the first
    /// commit that acknowledges this configure.
    pub fn place(view: *View, x: i32, y: i32, w: i32, h: i32) void {
        const g = view.xdg.base.geometry;
        // With a resize still unacknowledged, the committed size says nothing
        // about what the client will end up with: always send the request.
        if (view.pending == null and view.anchor == null and w == g.width and h == g.height) return view.move(x, y);
        const serial = view.xdg.setSize(@max(w, 1), @max(h, 1));
        view.anchor = null;
        view.pending = .{ .serial = serial, .x = x, .y = y };
    }

    pub fn setOpacity(view: *View, opacity: f32) void {
        view.opacity = std.math.clamp(opacity, 0, 1);
        view.applyOpacity();
    }

    /// Subsurfaces may add buffers at any commit, so this is reapplied there.
    fn applyOpacity(view: *View) void {
        view.tree.node.forEachBuffer(*View, struct {
            fn f(buf: *wlr.SceneBuffer, _: c_int, _: c_int, v: *View) void {
                buf.setOpacity(v.opacity);
            }
        }.f, view);
    }

    /// wlroots' xdg scene tree already shifts the surface by the window
    /// geometry offset (client-side shadows, title bars), so the tree's
    /// origin is the window geometry's top-left.
    fn syncPosition(view: *View) void {
        view.tree.node.setPosition(view.x, view.y);
    }

    fn handleCommit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
        const view: *View = @fieldParentPtr("commit", listener);
        const base = view.xdg.base;
        if (base.initial_commit) {
            // Initial configure: let the client choose its size.
            _ = view.xdg.setSize(0, 0);
            return;
        }
        if (!view.mapped) return;
        if (view.pending) |p| {
            if (srv.serialReached(base.current.configure_serial, p.serial)) {
                view.pending = null;
                view.x = p.x;
                view.y = p.y;
                view.server.emit(.view_resized, view.id);
            }
        }
        @import("input.zig").onCommit(view.server, view);
        view.syncPosition();
        if (view.opacity < 1) view.applyOpacity();
    }

    fn handleMap(listener: *wl.Listener(void)) void {
        const view: *View = @fieldParentPtr("map", listener);
        const server = view.server;
        if (server.activeOutputBox()) |box| {
            const g = view.xdg.base.geometry;
            view.x = box.x +| @divTrunc(box.width -| g.width, 2);
            view.y = box.y +| @divTrunc(box.height -| g.height, 2);
        }
        view.syncPosition();
        view.mapped = true;
        server.views.prepend(view);
        // view_map handlers still see the previous focus (a tiler splits it).
        const requests = server.focus_requests;
        server.emit(.view_map, view.id);
        // New windows take focus, unless a plugin chose focus itself
        // (even re-focusing the previous window) while handling view_map.
        if (server.focus_requests == requests and view.mapped and view.tree.node.enabled) server.focus(view);
        @import("input.zig").refocusPointer(server);
    }

    fn handleUnmap(listener: *wl.Listener(void)) void {
        const view: *View = @fieldParentPtr("unmap", listener);
        const server = view.server;
        view.mapped = false;
        view.pending = null;
        view.anchor = null;
        view.link.remove();
        // wlroots destroys the popups only after this handler; take them out
        // of the scene now, so the pointer is not refocused onto a popup of
        // a window that is going away (a later click would go to it).
        var popups = view.xdg.base.popups.iterator(.forward);
        while (popups.next()) |p| if (Popup.treeOf(p.base)) |t| t.node.setEnabled(false);
        if (server.grab.view == view) @import("input.zig").endGrab(server);
        if (server.focused == view) {
            server.focused = null;
            server.focus(server.firstVisible());
        }
        server.emit(.view_unmap, view.id);
        @import("input.zig").refocusPointer(server);
    }

    fn handleDestroy(listener: *wl.Listener(void)) void {
        const view: *View = @fieldParentPtr("destroy", listener);
        std.debug.assert(!view.mapped); // wlroots always unmaps first
        // A client may destroy the toplevel role but keep the xdg_surface and
        // create a new toplevel on it, so the tree must not outlive the view.
        view.tree.node.destroy();
        view.xdg.base.data = null;
        inline for (.{
            "commit",       "map",            "unmap",            "destroy",
            "request_move", "request_resize", "request_maximize", "request_fullscreen",
            "set_title",
        }) |name| @field(view, name).link.remove();
        gpa.destroy(view);
    }

    fn handleRequestMove(listener: *wl.Listener(*wlr.XdgToplevel.event.Move), event: *wlr.XdgToplevel.event.Move) void {
        const view: *View = @fieldParentPtr("request_move", listener);
        // origin = null: the press may have hit a CSD subsurface.
        if (!view.mapped or !view.server.seat.validatePointerGrabSerial(null, event.serial)) return;
        @import("input.zig").beginMove(view.server, view, true);
    }

    fn handleRequestResize(listener: *wl.Listener(*wlr.XdgToplevel.event.Resize), event: *wlr.XdgToplevel.event.Resize) void {
        const view: *View = @fieldParentPtr("request_resize", listener);
        if (!view.mapped or !view.server.seat.validatePointerGrabSerial(null, event.serial)) return;
        @import("input.zig").beginResize(view.server, view, event.edges, true);
    }

    /// Maximize/fullscreen are unsupported, but xdg-shell requires a
    /// configure in reply once the surface is initialized.
    fn handleRequestState(comptime field: []const u8) fn (*wl.Listener(void)) void {
        return struct {
            fn f(listener: *wl.Listener(void)) void {
                const view: *View = @fieldParentPtr(field, listener);
                if (view.xdg.base.initialized) _ = view.xdg.base.scheduleConfigure();
            }
        }.f;
    }

    fn handleSetTitle(listener: *wl.Listener(void)) void {
        const view: *View = @fieldParentPtr("set_title", listener);
        if (view.mapped) view.server.emit(.view_title, view.id);
    }
};

pub const Popup = struct {
    xdg_popup: *wlr.XdgPopup,
    /// Child of the parent's tree. Null once wlroots destroyed it together
    /// with an ancestor (e.g. a toplevel destroyed while this popup is open).
    tree: ?*wlr.SceneTree,
    commit: wl.Listener(*wlr.Surface) = .init(handleCommit),
    destroy: wl.Listener(void) = .init(handleDestroy),
    tree_destroy: wl.Listener(void) = .init(handleTreeDestroy),

    /// `parent_tree` is the scene tree of the parent xdg surface; the popup
    /// tree becomes its child so it moves (and fades) with the window.
    pub fn create(xdg_popup: *wlr.XdgPopup, parent_tree: *wlr.SceneTree) void {
        const tree = parent_tree.createSceneXdgSurface(xdg_popup.base) catch
            return std.log.err("out of memory", .{});
        const popup = gpa.create(Popup) catch {
            tree.node.destroy();
            return std.log.err("out of memory", .{});
        };
        popup.* = .{ .xdg_popup = xdg_popup, .tree = tree };
        // base.data is what nested popups use as their parent tree, so it
        // must never point to a freed tree.
        xdg_popup.base.data = tree;
        tree.node.events.destroy.add(&popup.tree_destroy);
        xdg_popup.base.surface.events.commit.add(&popup.commit);
        xdg_popup.events.destroy.add(&popup.destroy);
    }

    /// Scene tree of an xdg surface (toplevel or popup), if it still has one.
    pub fn treeOf(base: *wlr.XdgSurface) ?*wlr.SceneTree {
        return @ptrCast(@alignCast(base.data orelse return null));
    }

    fn handleCommit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
        const popup: *Popup = @fieldParentPtr("commit", listener);
        if (!popup.xdg_popup.base.initial_commit) return;
        popup.unconstrain();
        _ = popup.xdg_popup.base.scheduleConfigure();
    }

    /// Keeps the popup inside the output its root toplevel is on. The box is
    /// in the root toplevel's surface coordinates (wlroots' contract).
    fn unconstrain(popup: *Popup) void {
        const tree = popup.tree orelse return;
        var box: wlr.Box = undefined;
        // Layout position of the root surface's (0, 0).
        var ox: i32 = undefined;
        var oy: i32 = undefined;
        if (View.fromNode(&tree.node)) |view| {
            const g = view.geometry();
            const out = view.server.outputAt(g.x +| @divTrunc(g.width, 2), g.y +| @divTrunc(g.height, 2)) orelse return;
            box = out.box();
            ox = view.x -| view.xdg.base.geometry.x;
            oy = view.y -| view.xdg.base.geometry.y;
        } else if (LayerSurface.fromNode(&tree.node)) |ls| {
            box = (ls.output orelse return).box();
            ox = ls.popups.node.x;
            oy = ls.popups.node.y;
        } else return;
        box.x -|= ox;
        box.y -|= oy;
        popup.xdg_popup.unconstrainFromBox(&box);
    }

    /// The parent's tree (and with it this one) was destroyed first.
    fn handleTreeDestroy(listener: *wl.Listener(void)) void {
        const popup: *Popup = @fieldParentPtr("tree_destroy", listener);
        popup.tree_destroy.link.remove();
        popup.tree = null;
        popup.xdg_popup.base.data = null;
    }

    fn handleDestroy(listener: *wl.Listener(void)) void {
        const popup: *Popup = @fieldParentPtr("destroy", listener);
        // Like a view's tree, a popup's tree must not outlive the role: the
        // client may keep the xdg_surface and give it a new popup role.
        if (popup.tree) |t| t.node.destroy(); // runs handleTreeDestroy
        popup.commit.link.remove();
        popup.destroy.link.remove();
        gpa.destroy(popup);
    }
};
