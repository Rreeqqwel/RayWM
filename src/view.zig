//! Windows (xdg-shell toplevels) and their popups.
//!
//! Geometry model: (x, y) is the top-left of the window geometry in layout
//! coordinates. A size change is only a request: it takes effect when the
//! client commits a buffer acknowledging that configure, so a position that
//! must change together with the size waits in `pending` until then.
//!
//! Scene: every view owns `tree`, a node in one of the stacking layers
//! (tiled, floating), positioned at (x, y). The client's surfaces and
//! popups are in `content` inside it, borders are rectangles below them.
//!
//! Visibility: the tree is enabled when no plugin hides the window and it
//! has been revealed. A window mapped while a plugin asked for another
//! size is revealed only once the client has drawn that size (or after
//! `reveal_timeout_ms`), so it never shows up at a wrong size or place.
//!
//! Other code uses the methods here, never `impl` directly, so that
//! another window backend (Xwayland) fits in without touching it.
const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const srv = @import("server.zig");
const Server = srv.Server;
const gpa = srv.gpa;
const LayerSurface = @import("layer.zig").LayerSurface;
const input = @import("input.zig");

/// Longest a newly mapped window stays hidden waiting for its first size.
pub const reveal_timeout_ms = 150;

pub const View = struct {
    pub const Impl = union(enum) {
        xdg: *wlr.XdgToplevel,
    };

    tag: srv.Tag = .view,
    server: *Server,
    impl: Impl,
    /// Ours: the window's node in its stacking layer.
    tree: *wlr.SceneTree,
    /// The client's surfaces and popups (wlroots' xdg surface tree).
    content: *wlr.SceneTree,
    /// Never reused, so a stale id held by Lua cannot alias a new window.
    id: u32,
    /// In server.views while mapped.
    link: wl.list.Link = undefined,
    mapped: bool = false,
    /// view_map has been dispatched: later state changes are view_state.
    announced: bool = false,
    x: i32 = 0,
    y: i32 = 0,
    pending: ?struct { serial: u32, x: i32, y: i32 } = null,
    /// Interactive resize: keeps the edges opposite to `edges` fixed.
    anchor: ?struct { serial: u32, edges: wlr.Edges, box: wlr.Box } = null,
    opacity: f32 = 1.0,
    /// Drawn by plugins (raywm.view_border), e.g. for the focused window.
    border: ?Border = null,
    /// Hidden by a plugin (raywm.view_show).
    hidden: bool = false,
    /// See the file comment. False until the first size is drawn.
    revealed: bool = false,
    reveal_timer: ?*wl.EventSource = null,
    /// Layouts leave floating windows alone (raywm.view_floating).
    floating: bool = false,
    /// Geometry it last had while floating, restored when it floats again.
    float_box: ?wlr.Box = null,
    /// Size the client chose when it mapped, used when it first floats.
    natural: [2]i32 = .{ 0, 0 },
    /// Stacking layer `tree` is in.
    layer: srv.Layer = .floating,

    commit: wl.Listener(*wlr.Surface) = .init(handleCommit),
    map: wl.Listener(void) = .init(handleMap),
    unmap: wl.Listener(void) = .init(handleUnmap),
    destroy: wl.Listener(void) = .init(handleDestroy),
    request_move: wl.Listener(*wlr.XdgToplevel.event.Move) = .init(handleRequestMove),
    request_resize: wl.Listener(*wlr.XdgToplevel.event.Resize) = .init(handleRequestResize),
    request_maximize: wl.Listener(void) = .init(handleRequestState("request_maximize")),
    request_fullscreen: wl.Listener(void) = .init(handleRequestState("request_fullscreen")),
    set_title: wl.Listener(void) = .init(handleSetTitle),
    set_app_id: wl.Listener(void) = .init(handleSetAppId),

    pub fn create(listener: *wl.Listener(*wlr.XdgToplevel), xdg: *wlr.XdgToplevel) void {
        const server: *Server = @fieldParentPtr("new_toplevel", listener);
        const view = gpa.create(View) catch return std.log.err("out of memory", .{});
        const tree = server.layer(.floating).createSceneTree() catch {
            gpa.destroy(view);
            return std.log.err("out of memory", .{});
        };
        // Destroyed with `tree`, or by wlroots with the xdg surface.
        const content = tree.createSceneXdgSurface(xdg.base) catch {
            tree.node.destroy();
            gpa.destroy(view);
            return std.log.err("out of memory", .{});
        };
        view.* = .{ .server = server, .impl = .{ .xdg = xdg }, .tree = tree, .content = content, .id = server.nextId() };
        server.view_ids.put(gpa, view.id, view) catch {
            tree.node.destroy();
            gpa.destroy(view);
            return std.log.err("out of memory", .{});
        };
        tree.node.data = &view.tag;
        tree.node.setEnabled(false);
        // Popups of this window use base.data as their parent tree.
        xdg.base.data = content;

        const wlr_surface = xdg.base.surface;
        wlr_surface.events.commit.add(&view.commit);
        wlr_surface.events.map.add(&view.map);
        wlr_surface.events.unmap.add(&view.unmap);
        xdg.events.destroy.add(&view.destroy);
        xdg.events.request_move.add(&view.request_move);
        xdg.events.request_resize.add(&view.request_resize);
        xdg.events.request_maximize.add(&view.request_maximize);
        xdg.events.request_fullscreen.add(&view.request_fullscreen);
        xdg.events.set_title.add(&view.set_title);
        xdg.events.set_app_id.add(&view.set_app_id);
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

    // ---- backend-neutral accessors ------------------------------------------

    pub fn surface(view: *View) *wlr.Surface {
        return switch (view.impl) {
            .xdg => |t| t.base.surface,
        };
    }

    /// The window geometry inside the surface: offset (client-side
    /// shadows) and size.
    fn windowBox(view: *View) wlr.Box {
        return switch (view.impl) {
            .xdg => |t| t.base.geometry,
        };
    }

    pub fn title(view: *View) ?[*:0]const u8 {
        return switch (view.impl) {
            .xdg => |t| t.title,
        };
    }

    pub fn appId(view: *View) ?[*:0]const u8 {
        return switch (view.impl) {
            .xdg => |t| t.app_id,
        };
    }

    /// Smallest and largest size the client accepts; 0 means no limit.
    pub fn sizeHints(view: *View) struct { min: [2]i32, max: [2]i32 } {
        return switch (view.impl) {
            .xdg => |t| .{
                .min = .{ t.current.min_width, t.current.min_height },
                .max = .{ t.current.max_width, t.current.max_height },
            },
        };
    }

    /// The window this one is a dialog or child window of, if mapped.
    pub fn parent(view: *View) ?*View {
        switch (view.impl) {
            .xdg => |t| {
                const p = t.parent orelse return null;
                const tree = Popup.treeOf(p.base) orelse return null;
                const v = fromNode(&tree.node) orelse return null;
                return if (v.mapped) v else null;
            },
        }
    }

    pub fn pid(view: *View) i32 {
        return view.surface().resource.getClient().getCredentials().pid;
    }

    pub fn setActivated(view: *View, on: bool) void {
        switch (view.impl) {
            .xdg => |t| _ = t.setActivated(on),
        }
    }

    pub fn close(view: *View) void {
        switch (view.impl) {
            .xdg => |t| t.sendClose(),
        }
    }

    /// Asks the client for a size; returns the configure serial.
    fn configureSize(view: *View, w: i32, h: i32) u32 {
        return switch (view.impl) {
            .xdg => |t| t.setSize(w, h),
        };
    }

    /// Serial of the last configure the client acknowledged and committed.
    fn ackedSerial(view: *View) u32 {
        return switch (view.impl) {
            .xdg => |t| t.base.current.configure_serial,
        };
    }

    pub fn setResizing(view: *View, on: bool) u32 {
        return switch (view.impl) {
            .xdg => |t| t.setResizing(on),
        };
    }

    // ---- geometry -------------------------------------------------------------

    pub fn geometry(view: *View) wlr.Box {
        const g = view.windowBox();
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
        const g = view.windowBox();
        // With a resize still unacknowledged, the committed size says nothing
        // about what the client will end up with: always send the request.
        if (view.pending == null and view.anchor == null and w == g.width and h == g.height) return view.move(x, y);
        const serial = view.configureSize(@max(w, 1), @max(h, 1));
        view.anchor = null;
        view.pending = .{ .serial = serial, .x = x, .y = y };
    }

    /// Continues an interactive resize (input.zig): asks for a size and
    /// keeps the edges opposite to `edges` where they were in `box`.
    pub fn resizeAnchored(view: *View, w: i32, h: i32, edges: wlr.Edges, box: wlr.Box) void {
        view.anchor = .{ .serial = view.configureSize(w, h), .edges = edges, .box = box };
    }

    /// During a resize from the left/top edge the opposite edge stays fixed,
    /// using the size the client actually committed (it may round, e.g. to
    /// terminal cells). This continues after the button is released, until
    /// the client has acked the last resize configure.
    fn followAnchor(view: *View) void {
        const a = view.anchor orelse return;
        const geo = view.windowBox();
        if (a.edges.left) view.x = a.box.x +| a.box.width -| geo.width;
        if (a.edges.top) view.y = a.box.y +| a.box.height -| geo.height;
        if (view.server.grab.view != view and srv.serialReached(view.ackedSerial(), a.serial)) view.anchor = null;
    }

    /// Ends an interactive resize; the anchor holds until the client acks.
    pub fn endResize(view: *View) void {
        const serial = view.setResizing(false);
        if (view.anchor) |*a| a.serial = serial;
    }

    /// wlroots' xdg scene tree already shifts the surface by the window
    /// geometry offset (client-side shadows, title bars), so `content`'s
    /// origin is the window geometry's top-left.
    fn syncPosition(view: *View) void {
        view.tree.node.setPosition(view.x, view.y);
    }

    // ---- visibility, stacking and state ---------------------------------------

    /// Logically visible: may have keyboard focus. (It may not be drawn
    /// yet, see `revealed`.)
    pub fn visible(view: *View) bool {
        return view.mapped and !view.hidden;
    }

    pub fn updateVisibility(view: *View) void {
        view.tree.node.setEnabled(view.visible() and view.revealed);
    }

    pub fn setHidden(view: *View, hidden: bool) void {
        view.hidden = hidden;
        view.updateVisibility();
    }

    /// A live plugin lays out this window (ctx.manage).
    pub fn managed(view: *View) bool {
        const rt = view.server.rt orelse return false;
        return rt.managed(view.id);
    }

    /// Puts the window in the stacking layer its state calls for: tiled
    /// (managed by a layout) below floating.
    pub fn restack(view: *View) void {
        const want: srv.Layer = if (view.managed()) .tiled else .floating;
        if (want == view.layer) return;
        view.layer = want;
        // Lands on top of the new layer.
        view.tree.node.reparent(view.server.layer(want));
    }

    fn stateChanged(view: *View) void {
        if (view.announced) view.server.emit(.view_state, view.id);
    }

    pub fn setFloating(view: *View, on: bool) void {
        if (view.floating == on) return;
        if (on) {
            view.floating = true;
            const box = view.float_box orelse view.defaultFloatBox();
            view.place(box.x, box.y, box.width, box.height);
        } else {
            // Remembered for the next time it floats (unless a layout had
            // already taken it over, then its tile is not a floating place).
            if (!view.managed()) view.float_box = view.geometry();
            view.floating = false;
        }
        view.stateChanged();
    }

    /// Centred on its output at the size it had when it mapped, at most
    /// 90 % of the output's usable area.
    fn defaultFloatBox(view: *View) wlr.Box {
        const g = view.geometry();
        const out = view.server.outputAt(g.x +| @divTrunc(g.width, 2), g.y +| @divTrunc(g.height, 2)) orelse
            return g;
        const b = out.box();
        const u: wlr.Box = .{ .x = b.x + out.usable.x, .y = b.y + out.usable.y, .width = out.usable.width, .height = out.usable.height };
        const w = std.math.clamp(if (view.natural[0] > 0) view.natural[0] else g.width, 1, @max(1, @divTrunc(u.width * 9, 10)));
        const h = std.math.clamp(if (view.natural[1] > 0) view.natural[1] else g.height, 1, @max(1, @divTrunc(u.height * 9, 10)));
        return .{ .x = u.x + @divTrunc(u.width - w, 2), .y = u.y + @divTrunc(u.height - h, 2), .width = w, .height = h };
    }

    // ---- reveal -----------------------------------------------------------------

    fn reveal(view: *View) void {
        if (view.reveal_timer) |t| t.remove();
        view.reveal_timer = null;
        view.revealed = true;
        view.updateVisibility();
        input.refocusPointer(view.server);
    }

    /// After mapping: reveal now, or once the size asked for is drawn.
    fn revealWhenReady(view: *View) void {
        if (view.pending == null) return view.reveal();
        // The client waits for a frame callback before it draws again;
        // hidden surfaces get none from the scene, so send them here.
        view.sendFrameDone();
        const loop = view.server.wl_server.getEventLoop();
        const timer = loop.addTimer(*View, handleRevealTimeout, view) catch return view.reveal();
        timer.timerUpdate(reveal_timeout_ms) catch {
            timer.remove();
            return view.reveal();
        };
        view.reveal_timer = timer;
    }

    fn handleRevealTimeout(view: *View) c_int {
        view.reveal();
        return 0;
    }

    fn sendFrameDone(view: *View) void {
        var now = srv.timestamp();
        switch (view.impl) {
            .xdg => |t| t.base.forEachSurface(*std.posix.timespec, struct {
                fn f(s: *wlr.Surface, _: c_int, _: c_int, ts: *std.posix.timespec) void {
                    s.sendFrameDone(ts);
                }
            }.f, &now),
        }
    }

    // ---- border and opacity ---------------------------------------------------

    /// Solid rectangles around the window geometry, outside it: top,
    /// bottom, left, right. Children of the view's tree, below the
    /// surfaces and popups, so they move, hide and stack with the window
    /// and are destroyed with it. A border is not a surface: the pointer
    /// over it is over no client (input.surfaceAt), and clicks do nothing.
    pub const Border = struct {
        rects: [4]*wlr.SceneRect,
        width: i32,
        /// Window size the rectangles were laid out for.
        laid_out: [2]i32 = .{ -1, -1 },
    };

    /// `width` 0 removes the border; `color` is premultiplied RGBA.
    pub fn setBorder(view: *View, width: i32, color: *const [4]f32) !void {
        if (width <= 0) {
            if (view.border) |b| for (b.rects) |r| r.node.destroy();
            view.border = null;
            return;
        }
        if (view.border == null) {
            var rects: [4]*wlr.SceneRect = undefined;
            var n: usize = 0;
            errdefer for (rects[0..n]) |r| r.node.destroy();
            while (n < rects.len) : (n += 1) {
                rects[n] = try view.tree.createSceneRect(0, 0, color);
                rects[n].node.lowerToBottom();
            }
            view.border = .{ .rects = rects, .width = width };
        }
        const b = &view.border.?;
        for (b.rects) |r| r.setColor(color);
        if (b.width != width) b.laid_out = .{ -1, -1 };
        b.width = width;
        view.layoutBorder();
    }

    /// Follows the window's size; cheap when it did not change.
    fn layoutBorder(view: *View) void {
        const b = if (view.border) |*b| b else return;
        const g = view.windowBox();
        if (b.laid_out[0] == g.width and b.laid_out[1] == g.height) return;
        b.laid_out = .{ g.width, g.height };
        const t = b.width;
        const boxes = [4][4]i32{
            .{ -t, -t, g.width + 2 * t, t }, // top
            .{ -t, g.height, g.width + 2 * t, t }, // bottom
            .{ -t, 0, t, g.height }, // left
            .{ g.width, 0, t, g.height }, // right
        };
        for (b.rects, boxes) |r, box| {
            r.node.setPosition(box[0], box[1]);
            r.setSize(@max(box[2], 0), @max(box[3], 0));
        }
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

    // ---- lifecycle ----------------------------------------------------------------

    fn handleCommit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
        const view: *View = @fieldParentPtr("commit", listener);
        switch (view.impl) {
            .xdg => |t| if (t.base.initial_commit) {
                // Initial configure: let the client choose its size.
                _ = t.setSize(0, 0);
                return;
            },
        }
        if (!view.mapped) return;
        if (view.pending) |p| {
            if (srv.serialReached(view.ackedSerial(), p.serial)) {
                view.pending = null;
                view.x = p.x;
                view.y = p.y;
                view.server.emit(.view_resized, view.id);
            }
        }
        view.followAnchor();
        view.syncPosition();
        view.layoutBorder();
        if (view.opacity < 1) view.applyOpacity();
        if (!view.revealed) {
            if (view.pending == null) view.reveal() else view.sendFrameDone();
        }
    }

    fn handleMap(listener: *wl.Listener(void)) void {
        const view: *View = @fieldParentPtr("map", listener);
        const server = view.server;
        const g = view.windowBox();
        view.natural = .{ g.width, g.height };
        if (server.activeOutputBox()) |box| {
            view.x = box.x +| @divTrunc(box.width -| g.width, 2);
            view.y = box.y +| @divTrunc(box.height -| g.height, 2);
        }
        view.syncPosition();
        view.mapped = true;
        view.hidden = false;
        view.revealed = false;
        server.views.prepend(view);
        view.restack();
        // view_new is for window rules (floating, geometry, ...), view_map
        // for everything else (layouts); handlers of both still see the
        // previous focus (a tiler splits it).
        const requests = server.focus_requests;
        server.emit(.view_new, view.id);
        if (!view.mapped) return;
        view.announced = true;
        server.emit(.view_map, view.id);
        if (!view.mapped) return;
        // New windows take focus, unless a plugin chose focus itself
        // (even re-focusing the previous window) while handling view_map.
        if (server.focus_requests == requests and view.visible()) server.focus(view);
        view.revealWhenReady();
        input.refocusPointer(server);
    }

    fn handleUnmap(listener: *wl.Listener(void)) void {
        const view: *View = @fieldParentPtr("unmap", listener);
        const server = view.server;
        view.mapped = false;
        view.announced = false;
        view.pending = null;
        view.anchor = null;
        if (view.reveal_timer) |t| t.remove();
        view.reveal_timer = null;
        view.revealed = false;
        view.link.remove();
        view.updateVisibility();
        // wlroots destroys the popups only after this handler; take them out
        // of the scene now, so the pointer is not refocused onto a popup of
        // a window that is going away (a later click would go to it).
        switch (view.impl) {
            .xdg => |t| {
                var popups = t.base.popups.iterator(.forward);
                while (popups.next()) |p| if (Popup.treeOf(p.base)) |tr| tr.node.setEnabled(false);
            },
        }
        if (server.grab.view == view) input.endGrab(server);
        if (server.focused == view) {
            server.focused = null;
            server.focus(server.focusFallback(view));
        }
        server.emit(.view_unmap, view.id);
        input.refocusPointer(server);
    }

    fn handleDestroy(listener: *wl.Listener(void)) void {
        const view: *View = @fieldParentPtr("destroy", listener);
        std.debug.assert(!view.mapped); // wlroots always unmaps first
        if (view.reveal_timer) |t| t.remove();
        _ = view.server.view_ids.remove(view.id);
        // A client may destroy the toplevel role but keep the xdg_surface and
        // create a new toplevel on it, so the trees must not outlive the view.
        view.tree.node.destroy();
        switch (view.impl) {
            .xdg => |t| t.base.data = null,
        }
        inline for (.{
            "commit",             "map",       "unmap",      "destroy", "request_move", "request_resize", "request_maximize",
            "request_fullscreen", "set_title", "set_app_id",
        }) |name| @field(view, name).link.remove();
        gpa.destroy(view);
    }

    fn handleRequestMove(listener: *wl.Listener(*wlr.XdgToplevel.event.Move), event: *wlr.XdgToplevel.event.Move) void {
        const view: *View = @fieldParentPtr("request_move", listener);
        // origin = null: the press may have hit a CSD subsurface.
        if (!view.mapped or !view.server.seat.validatePointerGrabSerial(null, event.serial)) return;
        input.beginMove(view.server, view, true);
    }

    fn handleRequestResize(listener: *wl.Listener(*wlr.XdgToplevel.event.Resize), event: *wlr.XdgToplevel.event.Resize) void {
        const view: *View = @fieldParentPtr("request_resize", listener);
        if (!view.mapped or !view.server.seat.validatePointerGrabSerial(null, event.serial)) return;
        input.beginResize(view.server, view, event.edges, true);
    }

    /// Maximize/fullscreen are unsupported, but xdg-shell requires a
    /// configure in reply once the surface is initialized.
    fn handleRequestState(comptime field: []const u8) fn (*wl.Listener(void)) void {
        return struct {
            fn f(listener: *wl.Listener(void)) void {
                const view: *View = @fieldParentPtr(field, listener);
                switch (view.impl) {
                    .xdg => |t| if (t.base.initialized) {
                        _ = t.base.scheduleConfigure();
                    },
                }
            }
        }.f;
    }

    fn handleSetTitle(listener: *wl.Listener(void)) void {
        const view: *View = @fieldParentPtr("set_title", listener);
        if (view.mapped) view.server.emit(.view_title, view.id);
    }

    fn handleSetAppId(listener: *wl.Listener(void)) void {
        const view: *View = @fieldParentPtr("set_app_id", listener);
        if (view.mapped) view.server.emit(.view_app_id, view.id);
    }
};

pub const Popup = struct {
    xdg_popup: *wlr.XdgPopup,
    /// Child of the parent's tree. Null once wlroots destroyed it together
    /// with an ancestor (e.g. a toplevel destroyed while this popup is open).
    tree: ?*wlr.SceneTree,
    commit: wl.Listener(*wlr.Surface) = .init(handleCommit),
    reposition: wl.Listener(void) = .init(handleReposition),
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
        xdg_popup.events.reposition.add(&popup.reposition);
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

    /// xdg_popup.reposition (xdg-shell v3): constrain the new position too.
    fn handleReposition(listener: *wl.Listener(void)) void {
        const popup: *Popup = @fieldParentPtr("reposition", listener);
        popup.unconstrain();
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
            const wb = view.windowBox();
            ox = view.x -| wb.x;
            oy = view.y -| wb.y;
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
        popup.reposition.link.remove();
        popup.destroy.link.remove();
        gpa.destroy(popup);
    }
};
