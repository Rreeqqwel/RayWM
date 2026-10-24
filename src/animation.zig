//! Time-based scene transforms. No Lua code runs on output frames. Jobs
//! retain ids, or a separately owned snapshot tree, never a borrowed View.
const std = @import("std");
const wlr = @import("wlroots");
const lua = @import("lua");
const srv = @import("server.zig");
const View = @import("view.zig").View;

pub const capacity = 256;

// wlroots 0.20.2 explicit-sync helpers without zig-wlroots 0.20.1 bindings.
// Only the public prefix of the surface state is declared; C owns it.
const SyncobjState = extern struct {
    acquire_timeline: ?*wlr.DrmSyncobjTimeline,
    acquire_point: u64,
};
const SetBufferOptions = extern struct {
    damage: ?*const anyopaque = null,
    wait_timeline: ?*wlr.DrmSyncobjTimeline = null,
    wait_point: u64 = 0,
};
extern fn wlr_linux_drm_syncobj_v1_get_surface_state(surface: *wlr.Surface) ?*SyncobjState;
extern fn wlr_linux_drm_syncobj_v1_state_signal_release_with_buffer(state: *SyncobjState, buffer: *wlr.Buffer) bool;
extern fn wlr_scene_buffer_set_buffer_with_options(buffer: *wlr.SceneBuffer, wlr_buffer: ?*wlr.Buffer, options: *const SetBufferOptions) void;
const Snapshot = struct {
    tag: srv.Tag = .visual,
    tree: *wlr.SceneTree,
    base: [2]i32,
    count: usize = 0,
    bytes: usize = 0,
    alphas: [256]f32 = undefined,

    fn create(v: *View) !*Snapshot {
        const s = try srv.gpa.create(Snapshot);
        errdefer srv.gpa.destroy(s);
        s.* = .{ .tree = try v.server.layer(v.layer).createSceneTree(), .base = .{ v.x, v.y } };
        errdefer s.tree.node.destroy();
        s.tree.node.data = &s.tag;
        s.tree.node.setPosition(v.x, v.y);
        // unmap is emitted before the client's old buffer is replaced.
        // Native scene helpers may already have disabled its subtree.
        try s.copy(&v.content.node, 0, 0, !v.surface().mapped);
        if (s.count == 0) return error.NoBuffer;
        return s;
    }

    fn copy(s: *Snapshot, node: *wlr.SceneNode, x: i32, y: i32, unmapping: bool) !void {
        if (!node.enabled and !unmapping) return;
        const nx = x +| node.x;
        const ny = y +| node.y;
        switch (node.type) {
            .tree => {
                var it = wlr.SceneTree.fromNode(node).children.iterator(.forward);
                while (it.next()) |child| try s.copy(child, nx, ny, unmapping);
            },
            .buffer => {
                const source = wlr.SceneBuffer.fromNode(node);
                const buffer = source.buffer orelse return;
                if (s.count >= 256) return error.TooManyBuffers;
                const bytes = @as(u64, @intCast(@max(0, buffer.width))) * @as(u64, @intCast(@max(0, buffer.height))) * 4;
                if (bytes > 128 << 20 or s.bytes > (128 << 20) - bytes) return error.SnapshotTooLarge;
                const dest = try s.tree.createSceneBuffer(null);
                // SceneBuffer locks the client buffer. The additional lock
                // prevents wlroots from updating its texture in place.
                // With explicit sync the client ignores wl_buffer.release:
                // wait for its acquire point, and delay its release point
                // until the snapshot drops the buffer.
                var options: SetBufferOptions = .{};
                const sync = if (wlr.SceneSurface.tryFromBuffer(source)) |ss| wlr_linux_drm_syncobj_v1_get_surface_state(ss.surface) else null;
                if (sync) |state| {
                    options.wait_timeline = state.acquire_timeline;
                    options.wait_point = state.acquire_point;
                }
                wlr_scene_buffer_set_buffer_with_options(dest, buffer, &options);
                if (sync) |state| if (!wlr_linux_drm_syncobj_v1_state_signal_release_with_buffer(state, buffer)) {
                    dest.node.destroy();
                    return error.OutOfMemory;
                };
                dest.node.setPosition(nx, ny);
                dest.setSourceBox(&source.src_box);
                dest.setDestSize(source.dst_width, source.dst_height);
                dest.setTransform(source.transform);
                dest.setFilterMode(source.filter_mode);
                dest.setOpacity(source.opacity);
                s.alphas[s.count] = source.opacity;
                s.count += 1;
                s.bytes += @intCast(bytes);
            },
            .rect => {}, // snapshots contain client content, not plugin borders
        }
    }

    fn apply(s: *Snapshot, xy: [2]f64, alpha: f32) void {
        s.tree.node.setPosition(s.base[0] +| @as(i32, @intFromFloat(@round(xy[0]))), s.base[1] +| @as(i32, @intFromFloat(@round(xy[1]))));
        // Snapshot buffers already contain base view opacity.
        var it = s.tree.children.iterator(.forward);
        var i: usize = 0;
        while (it.next()) |node| : (i += 1) wlr.SceneBuffer.fromNode(node).setOpacity(s.alphas[i] * alpha);
    }

    fn destroy(s: *Snapshot) void {
        s.tree.node.destroy();
        srv.gpa.destroy(s);
    }
};

const Job = struct {
    id: u32,
    target: union(enum) { view: u32, snapshot: *Snapshot },
    from: [3]f64,
    to: [3]f64,
    start: u64,
    duration: u64,
    easing: lua.Easing,
    active: bool = true,
    waiting: bool = false,
};

pub const Engine = struct {
    server: *srv.Server = undefined,
    slots: [capacity]?Job = @splat(null),
    generation: u32 = 0,

    pub fn init(e: *Engine, server: *srv.Server) void {
        e.* = .{ .server = server };
    }

    fn get(e: *Engine, id: u32) ?*Job {
        const job = if (e.slots[id & (capacity - 1)]) |*j| j else return null;
        return if (job.id == id) job else null;
    }

    pub fn alive(e: *Engine, id: u32) bool {
        return e.get(id) != null;
    }

    pub fn cancel(e: *Engine, id: u32, reset: bool) void {
        const job = e.get(id) orelse return;
        switch (job.target) {
            .view => |vid| if (reset) {
                if (e.server.viewById(vid)) |v| v.setVisual(.{ 0, 0 }, 1);
            },
            .snapshot => |s| s.destroy(),
        }
        e.slots[id & (capacity - 1)] = null;
    }

    pub fn clear(e: *Engine) void {
        for (&e.slots) |*slot| if (slot.*) |job| e.cancel(job.id, true);
    }

    pub fn viewGone(e: *Engine, id: u32) void {
        for (&e.slots) |*slot| if (slot.*) |job| if (job.target == .view and job.target.view == id) e.cancel(job.id, false);
    }

    pub fn start(e: *Engine, vid: u32, options: lua.AnimationOptions) lua.ResourceResult {
        const v = e.server.viewById(vid) orelse return .stale;
        if (e.server.session_lock.locked() or !v.visible() or (options.snapshot and !v.revealed)) return .hidden;
        const from = [3]f64{ options.from_x orelse v.visual_offset[0], options.from_y orelse v.visual_offset[1], options.from_opacity orelse (if (options.snapshot) @as(f32, 1) else v.visual_alpha) };
        var snap: ?*Snapshot = null;
        if (options.snapshot) {
            snap = Snapshot.create(v) catch return .failed;
            var bytes = snap.?.bytes;
            for (e.slots) |slot| if (slot) |job| if (job.target == .snapshot) {
                bytes += job.target.snapshot.bytes;
            };
            if (bytes > 128 << 20) {
                snap.?.destroy();
                return .limit;
            }
        } else {
            // Replace, preserving the exact current transform for interruption.
            for (&e.slots) |*slot| if (slot.*) |job| if (job.target == .view and job.target.view == vid) e.cancel(job.id, false);
        }
        const index = for (e.slots, 0..) |slot, i| {
            if (slot == null) break i;
        } else {
            if (snap) |s| s.destroy();
            return .limit;
        };
        if (e.generation == std.math.maxInt(u32) >> 8) {
            if (snap) |s| s.destroy();
            return .limit;
        }
        e.generation += 1;
        const id = (e.generation << 8) | @as(u32, @intCast(index));
        e.slots[index] = .{
            .id = id,
            .target = if (snap) |s| .{ .snapshot = s } else .{ .view = vid },
            .from = from,
            .to = .{ options.x, options.y, options.opacity },
            .start = lua.monotonicNs(),
            .duration = @as(u64, options.duration) * std.time.ns_per_ms,
            .easing = options.easing,
            .waiting = !v.revealed,
        };
        e.apply(&e.slots[index].?, from);
        e.schedule();
        return .{ .ok = id };
    }

    /// Jobs still animating (diagnostics).
    pub fn running(e: *const Engine) usize {
        var n: usize = 0;
        for (e.slots) |slot| if (slot) |job| {
            n += @intFromBool(job.active);
        };
        return n;
    }

    fn schedule(e: *Engine) void {
        var it = e.server.outputs.iterator(.forward);
        while (it.next()) |o| if (o.inLayout() and o.wlr_output.enabled) o.wlr_output.scheduleFrame();
    }

    fn apply(e: *Engine, job: *Job, values: [3]f64) void {
        const xy = [2]f64{ values[0], values[1] };
        const alpha: f32 = @floatCast(std.math.clamp(values[2], 0, 1));
        switch (job.target) {
            .view => |id| if (e.server.viewById(id)) |v| v.setVisual(xy, alpha),
            .snapshot => |s| s.apply(xy, alpha),
        }
    }

    /// Before committing an output frame. Only active jobs request more
    /// frames; there is no timer or Lua callback on an idle desktop.
    pub fn frame(e: *Engine, now: u64) bool {
        var active = false;
        var retired = false;
        for (&e.slots) |*slot| {
            const job = if (slot.*) |*j| j else continue;
            if (!job.active) continue;
            if (job.target == .view and e.server.viewById(job.target.view) == null) {
                e.cancel(job.id, false);
                retired = true;
                continue;
            }
            if (job.waiting) {
                const view = e.server.viewById(job.target.view) orelse continue;
                if (!view.revealed) continue;
                job.waiting = false;
                job.start = now;
            }
            const elapsed = now -| job.start;
            const p: f64 = if (job.duration == 0) 1 else @min(1, @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(job.duration)));
            const t = ease(job.easing, p);
            var values: [3]f64 = undefined;
            for (&values, job.from, job.to) |*out, a, b| out.* = a + (b - a) * t;
            e.apply(job, values);
            if (p == 1) {
                if (job.target == .snapshot or std.meta.eql(job.to, [3]f64{ 0, 0, 1 })) {
                    e.cancel(job.id, false);
                    retired = true;
                } else job.active = false;
            } else active = true;
        }
        if (retired) if (e.server.rt) |rt| rt.collectResources();
        return active;
    }
};

pub fn ease(kind: lua.Easing, t: f64) f64 {
    const p = std.math.clamp(t, 0, 1);
    return switch (kind) {
        .linear => p,
        .in_quad => p * p,
        .out_quad => p * (2 - p),
        .in_out_cubic => if (p < 0.5) 4 * p * p * p else 1 - std.math.pow(f64, -2 * p + 2, 3) / 2,
    };
}
