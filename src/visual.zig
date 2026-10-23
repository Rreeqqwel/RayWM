//! Plugin-owned, input-transparent scene rectangles. Lua holds only a
//! registration id; this table owns scene nodes and generation handles.
const std = @import("std");
const wlr = @import("wlroots");
const lua = @import("lua");
const srv = @import("server.zig");
const cabi = @import("cabi.zig");
const Rect = struct {
    tag: srv.Tag = .visual,
    id: u32,
    view: u32,
    tree: *wlr.SceneTree,
    rect: *wlr.SceneRect,
};
pub const Visuals = struct {
    server: *srv.Server = undefined,
    slots: [256]?*Rect = @splat(null),
    generation: u32 = 0,

    pub fn init(v: *Visuals, server: *srv.Server) void {
        v.* = .{ .server = server };
    }
    fn get(v: *Visuals, id: u32) ?*Rect {
        const r = v.slots[id & 255] orelse return null;
        return if (r.id == id) r else null;
    }
    pub fn alive(v: *Visuals, id: u32) bool {
        return v.get(id) != null;
    }
    pub fn create(v: *Visuals, options: lua.RectOptions) lua.ResourceResult {
        const parent = if (options.view != 0)
            (v.server.viewById(options.view) orelse return .stale).tree
        else
            v.server.layer(if (options.background) .background else .overlay);
        const index = for (v.slots, 0..) |slot, i| {
            if (slot == null) break i;
        } else return .limit;
        if (v.generation == std.math.maxInt(u32) >> 8) return .limit;
        const r = srv.gpa.create(Rect) catch return .failed;
        const tree = parent.createSceneTree() catch {
            srv.gpa.destroy(r);
            return .failed;
        };
        const rect = tree.createSceneRect(options.w, options.h, &options.color) catch {
            tree.node.destroy();
            srv.gpa.destroy(r);
            return .failed;
        };
        v.generation += 1;
        const id = (v.generation << 8) | @as(u32, @intCast(index));
        r.* = .{ .id = id, .view = options.view, .tree = tree, .rect = rect };
        tree.node.data = &r.tag;
        v.slots[index] = r;
        _ = v.update(id, options);
        return .{ .ok = id };
    }
    pub fn update(v: *Visuals, id: u32, options: lua.RectOptions) bool {
        const r = v.get(id) orelse return false;
        r.tree.node.setPosition(options.x, options.y);
        r.rect.setSize(options.w, options.h);
        r.rect.setColor(&options.color);
        cabi.call(options.visible, wlr.SceneNode.setEnabled, .{&r.tree.node});
        return true;
    }
    pub fn remove(v: *Visuals, id: u32) void {
        const r = v.get(id) orelse return;
        v.slots[id & 255] = null;
        r.tree.node.destroy();
        srv.gpa.destroy(r);
    }
    pub fn viewGone(v: *Visuals, id: u32) void {
        for (v.slots) |slot| if (slot) |r| if (r.view == id) v.remove(r.id);
    }
    pub fn clear(v: *Visuals) void {
        for (v.slots) |slot| if (slot) |r| v.remove(r.id);
    }
};
