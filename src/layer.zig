//! wlr-layer-shell: panels, docks, launchers and backgrounds drawn by
//! external clients. Exclusive zones shrink the output's usable area that
//! Lua tilers receive through raywm.outputs().
const std = @import("std");
const wl = @import("wayland").server.wl;
const zwlr = @import("wayland").server.zwlr;
const wlr = @import("wlroots");
const srv = @import("server.zig");
const Popup = @import("view.zig").Popup;
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
        ls.* = .{ .server = server, .output = output, .wlr_layer = wlr_layer, .scene = scene };
        scene.tree.node.data = &ls.tag;
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

    fn handleCommit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
        const ls: *LayerSurface = @fieldParentPtr("commit", listener);
        const output = ls.output orelse return;
        const committed: u32 = @bitCast(ls.wlr_layer.current.committed);
        if (ls.wlr_layer.current.committed.layer) {
            ls.scene.tree.node.reparent(ls.server.layer(sceneLayer(ls.wlr_layer.current.layer)));
        }
        // The initial commit needs a configure; later only real state changes.
        if (ls.wlr_layer.initial_commit or committed != 0) output.arrangeLayers();
    }

    fn handleMap(listener: *wl.Listener(void)) void {
        const ls: *LayerSurface = @fieldParentPtr("map", listener);
        if (ls.output) |o| o.arrangeLayers();
        const layer = ls.wlr_layer.current.layer;
        if (ls.wantsKeyboard() and (layer == .top or layer == .overlay)) ls.server.focusLayer(ls);
    }

    fn handleUnmap(listener: *wl.Listener(void)) void {
        const ls: *LayerSurface = @fieldParentPtr("unmap", listener);
        if (ls.server.layer_focus == ls) ls.server.focusLayer(null);
        if (ls.output) |o| o.arrangeLayers();
    }

    fn handleDestroy(listener: *wl.Listener(*wlr.LayerSurfaceV1), _: *wlr.LayerSurfaceV1) void {
        const ls: *LayerSurface = @fieldParentPtr("destroy", listener);
        if (ls.server.layer_focus == ls) ls.server.focusLayer(null);
        inline for (.{ "commit", "map", "unmap", "destroy", "new_popup" }) |name| @field(ls, name).link.remove();
        // The scene tree is destroyed by wlroots together with the surface.
        if (ls.output) |o| {
            ls.link.remove();
            o.arrangeLayers();
        }
        gpa.destroy(ls);
    }

    fn handleNewPopup(listener: *wl.Listener(*wlr.XdgPopup), xdg_popup: *wlr.XdgPopup) void {
        const ls: *LayerSurface = @fieldParentPtr("new_popup", listener);
        Popup.create(xdg_popup, ls.scene.tree);
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
            }
        }
    }
    const new: wlr.Box = .{ .x = usable.x - full.x, .y = usable.y - full.y, .width = usable.width, .height = usable.height };
    const changed = !std.meta.eql(new, output.usable);
    output.usable = new;
    if (changed) output.server.emit(.layout, output.id);
}

/// Closes every layer surface of a disappearing output.
pub fn closeAll(output: *Output) void {
    while (output.layers.first()) |ls| {
        ls.output = null;
        ls.link.remove();
        ls.wlr_layer.destroy(); // emits destroy synchronously
    }
}
