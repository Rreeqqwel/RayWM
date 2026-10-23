//! wl_data_device drag lifecycle. wlroots owns offers, sources and grabs;
//! RayWM validates the initiating press and owns only the drag icon tree.
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const srv = @import("server.zig");
const input = @import("input.zig");

pub const Data = struct {
    server: *srv.Server,
    drag: ?*wlr.Drag = null,
    icon_tree: ?*wlr.SceneTree = null,
    request: wl.Listener(*wlr.Seat.event.RequestStartDrag) = .init(onRequest),
    start: wl.Listener(*wlr.Drag) = .init(onStart),
    destroy: wl.Listener(*wlr.Drag) = .init(onDestroy),

    pub fn init(d: *Data, server: *srv.Server) void {
        d.* = .{ .server = server };
        server.seat.events.request_start_drag.add(&d.request);
        server.seat.events.start_drag.add(&d.start);
    }

    pub fn deinit(d: *Data) void {
        d.cancel();
        d.request.link.remove();
        d.start.link.remove();
    }

    pub fn cancel(d: *Data) void {
        const drag = d.drag orelse return;
        reject(drag);
    }

    fn reject(drag: *wlr.Drag) void {
        // Destroying the source notifies its client of cancellation and
        // destroys the drag via wlroots' source listener. Ending only the
        // grab silently leaves the source alive and its client waiting.
        if (drag.source) |source| {
            source.destroy();
        } else if (drag.keyboard_grab.interface.cancel) |cancel_fn| {
            // Source-less, intra-client drags have no cancellation event.
            cancel_fn(&drag.keyboard_grab);
        }
    }

    fn onRequest(listener: *wl.Listener(*wlr.Seat.event.RequestStartDrag), event: *wlr.Seat.event.RequestStartDrag) void {
        const d: *Data = @fieldParentPtr("request", listener);
        const server = d.server;
        if (server.session_lock.locked() or server.grab.mode != .none or !server.seat.validatePointerGrabSerial(event.origin, event.serial)) return reject(event.drag);
        server.seat.startPointerDrag(event.drag, event.serial);
    }

    fn onStart(listener: *wl.Listener(*wlr.Drag), drag: *wlr.Drag) void {
        const d: *Data = @fieldParentPtr("start", listener);
        d.drag = drag;
        drag.events.destroy.add(&d.destroy);
        if (drag.icon) |icon| {
            const tree = d.server.layer(.drag).createSceneTree() catch return;
            _ = tree.createSceneDragIcon(icon) catch {
                tree.node.destroy();
                return;
            };
            d.icon_tree = tree;
            d.move();
        }
        input.refocusPointer(d.server);
    }

    pub fn move(d: *Data) void {
        if (d.icon_tree) |tree| tree.node.setPosition(@intFromFloat(d.server.cursor.x), @intFromFloat(d.server.cursor.y));
    }

    fn onDestroy(listener: *wl.Listener(*wlr.Drag), _: *wlr.Drag) void {
        const d: *Data = @fieldParentPtr("destroy", listener);
        d.destroy.link.remove();
        d.drag = null;
        if (d.icon_tree) |tree| tree.node.destroy();
        d.icon_tree = null;
        input.refocusPointer(d.server);
    }
};
