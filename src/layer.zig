//! wlr-layer-shell: panels, docks, launchers and backgrounds drawn by
//! external clients. Exclusive zones shrink the output's usable area that
//! Lua tilers receive through raywm.outputs().
const std = @import("std");
const wl = @import("wayland").server.wl;
const zwlr = @import("wayland").server.zwlr;
const wlr = @import("wlroots");
const srv = @import("server.zig");
const Popup = @import("view.zig").Popup;
const input = @import("input.zig");
const Server = srv.Server;
const Output = srv.Output;
const gpa = srv.gpa;

pub const LayerSurface = struct {
    tag: srv.Tag = .layer,
    server: *Server,
    /// Null once the output is gone and the surface is being closed.
    output: ?*Output,
    wlr_layer: *wlr.LayerSurfaceV1,
    scene: *wlr.SceneLayerSurfaceV1,
    /// Above all layers, kept at the surface's position by arrange().
    popups: *wlr.SceneTree,
    /// In output.layers.
    link: wl.list.Link = undefined,

    commit: wl.Listener(*wlr.Surface) = .init(handleCommit),
    map: wl.Listener(void) = .init(handleMap),
    unmap: wl.Listener(void) = .init(handleUnmap),
    destroy: wl.Listener(*wlr.LayerSurfaceV1) = .init(handleDestroy),
    new_popup: wl.Listener(*wlr.XdgPopup) = .init(handleNewPopup),

    pub fn create(listener: *wl.Listener(*wlr.LayerSurfaceV1), wlr_layer: *wlr.LayerSurfaceV1) void {
        const server: *Server = @fieldParentPtr("new_layer_surface", listener);
        // Clients may leave the output choice to the compositor.
        if (wlr_layer.output == null) {
            if (server.outputAt(@intFromFloat(server.cursor.x), @intFromFloat(server.cursor.y)) orelse server.outputs.first()) |o|
                wlr_layer.output = o.wlr_output;
        }
        const output = server.outputByWlr(wlr_layer.output) orelse return wlr_layer.destroy();
        const ls = gpa.create(LayerSurface) catch return wlr_layer.destroy();
        const scene = server.layer(sceneLayer(wlr_layer.pending.layer)).createSceneLayerSurfaceV1(wlr_layer) catch {
            gpa.destroy(ls);
            return wlr_layer.destroy();
        };
        const popups = server.layer(.popups).createSceneTree() catch {
            scene.tree.node.destroy();
            gpa.destroy(ls);
            return wlr_layer.destroy();
        };
        ls.* = .{ .server = server, .output = output, .wlr_layer = wlr_layer, .scene = scene, .popups = popups };
        scene.tree.node.data = &ls.tag;
        popups.node.data = &ls.tag;
        wlr_layer.data = ls;
        output.layers.append(ls);

        wlr_layer.surface.events.commit.add(&ls.commit);
        wlr_layer.surface.events.map.add(&ls.map);
        wlr_layer.surface.events.unmap.add(&ls.unmap);
        wlr_layer.events.destroy.add(&ls.destroy);
        wlr_layer.events.new_popup.add(&ls.new_popup);
    }

    pub fn fromNode(node: *wlr.SceneNode) ?*LayerSurface {
        var it: ?*wlr.SceneNode = node;
        while (it) |n| : (it = if (n.parent) |p| &p.node else null) {
            const tag: *const srv.Tag = @ptrCast(@alignCast(n.data orelse continue));
            if (tag.* == .layer) return @constCast(@as(*const LayerSurface, @alignCast(@fieldParentPtr("tag", tag))));
        }
        return null;
    }

    fn sceneLayer(l: zwlr.LayerShellV1.Layer) srv.Layer {
        return switch (l) {
            .background => .background,
            .bottom => .bottom,
            .top => .top,
            .overlay => .overlay,
            _ => .top,
        };
    }

    /// Whether this surface may hold keyboard focus over windows.
    pub fn wantsKeyboard(ls: *LayerSurface) bool {
        return ls.wlr_layer.current.keyboard_interactive != .none and ls.wlr_layer.surface.mapped;
    }

    /// Top and overlay surfaces take the keyboard when they map or ask for it.
    fn claimsKeyboard(ls: *LayerSurface) bool {
        const layer = ls.wlr_layer.current.layer;
        return ls.wantsKeyboard() and (layer == .top or layer == .overlay);
    }

    fn exclusive(ls: *LayerSurface) bool {
        return ls.wlr_layer.current.keyboard_interactive == .exclusive;
    }

    /// An exclusive holder keeps the keyboard against on-demand surfaces and
    /// against exclusive ones in a lower layer; a newer exclusive surface in
    /// the same or a higher layer takes it.
    fn mayTakeKeyboard(ls: *LayerSurface) bool {
        const cur = ls.server.layer_focus orelse return true;
        if (cur == ls or !cur.exclusive()) return true;
        return ls.exclusive() and @intFromEnum(ls.wlr_layer.current.layer) >= @intFromEnum(cur.wlr_layer.current.layer);
    }

    /// Gives up the keyboard: to the remaining exclusive surface in the
    /// highest layer (the last one found on a tie), else to the focused
    /// window. Surfaces of an output being removed (already out of the
    /// layout) are skipped: they are about to be closed.
    fn releaseKeyboard(ls: *LayerSurface) void {
        const server = ls.server;
        var best: ?*LayerSurface = null;
        var outs = server.outputs.iterator(.forward);
        while (outs.next()) |o| {
            if (!o.inLayout()) continue;
            var it = o.layers.iterator(.forward);
            while (it.next()) |c| {
                if (c == ls or !c.claimsKeyboard() or !c.exclusive()) continue;
                if (best == null or @intFromEnum(c.wlr_layer.current.layer) >= @intFromEnum(best.?.wlr_layer.current.layer)) best = c;
            }
        }
        server.focusLayer(best);
    }

    fn handleCommit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
        const ls: *LayerSurface = @fieldParentPtr("commit", listener);
        const output = ls.output orelse return;
        const committed: u32 = @bitCast(ls.wlr_layer.current.committed);
        if (ls.wlr_layer.current.committed.layer) {
            ls.scene.tree.node.reparent(ls.server.layer(sceneLayer(ls.wlr_layer.current.layer)));
        }
        // The initial commit needs a configure; later only real state changes.
        if ((ls.wlr_layer.initial_commit or committed != 0) and output.inLayout()) output.arrangeLayers();
        // Keyboard interactivity may change while mapped (e.g. a launcher).
        if (ls.wlr_layer.current.committed.keyboard_interactivity and ls.wlr_layer.surface.mapped) {
            if (ls.claimsKeyboard()) {
                if (ls.server.layer_focus != ls and ls.mayTakeKeyboard()) ls.server.focusLayer(ls);
            } else if (ls.server.layer_focus == ls) ls.releaseKeyboard();
        }
    }

    fn handleMap(listener: *wl.Listener(void)) void {
        const ls: *LayerSurface = @fieldParentPtr("map", listener);
        if (ls.output) |o| o.arrangeLayers();
        if (ls.claimsKeyboard() and ls.mayTakeKeyboard()) ls.server.focusLayer(ls);
        // The surface may appear under a still cursor (or under an implicit
        // grab, which it must not take over).
        input.refocusPointer(ls.server);
    }

    fn handleUnmap(listener: *wl.Listener(void)) void {
        const ls: *LayerSurface = @fieldParentPtr("unmap", listener);
        if (ls.server.layer_focus == ls) ls.releaseKeyboard();
        if (ls.output) |o| o.arrangeLayers();
        input.refocusPointer(ls.server);
    }

    fn handleDestroy(listener: *wl.Listener(*wlr.LayerSurfaceV1), _: *wlr.LayerSurfaceV1) void {
        const ls: *LayerSurface = @fieldParentPtr("destroy", listener);
        if (ls.server.layer_focus == ls) ls.releaseKeyboard();
        inline for (.{ "commit", "map", "unmap", "destroy", "new_popup" }) |name| @field(ls, name).link.remove();
        ls.popups.node.destroy();
        // The scene tree is destroyed by wlroots together with the surface.
        if (ls.output) |o| {
            ls.link.remove();
            o.arrangeLayers();
        }
        gpa.destroy(ls);
    }

    fn handleNewPopup(listener: *wl.Listener(*wlr.XdgPopup), xdg_popup: *wlr.XdgPopup) void {
        const ls: *LayerSurface = @fieldParentPtr("new_popup", listener);
        Popup.create(xdg_popup, ls.popups);
    }
};

/// Positions all layer surfaces of `output` (exclusive zones first, as the
/// protocol intends) and recomputes the area left for windows.
pub fn arrange(output: *Output) void {
    const full = output.box();
    var usable = full;
    for ([_]bool{ true, false }) |exclusive_pass| {
        for ([_]zwlr.LayerShellV1.Layer{ .overlay, .top, .bottom, .background }) |layer| {
            var it = output.layers.iterator(.forward);
            while (it.next()) |ls| {
                const state = &ls.wlr_layer.current;
                if (!ls.wlr_layer.initialized or state.layer != layer) continue;
                if ((state.exclusive_zone > 0) != exclusive_pass) continue;
                ls.scene.configure(&full, &usable);
                ls.popups.node.setPosition(ls.scene.tree.node.x, ls.scene.tree.node.y);
            }
        }
    }
    const new: wlr.Box = .{ .x = usable.x - full.x, .y = usable.y - full.y, .width = usable.width, .height = usable.height };
    const changed = !std.meta.eql(new, output.usable);
    output.usable = new;
    if (changed) {
        output.server.refitViews(); // maximized windows follow the usable area
        output.server.emit(.layout, output.id);
    }
}

/// Closes every layer surface of a disappearing output.
pub fn closeAll(output: *Output) void {
    while (output.layers.first()) |ls| {
        ls.output = null;
        ls.link.remove();
        ls.wlr_layer.destroy(); // emits destroy synchronously
    }
}
