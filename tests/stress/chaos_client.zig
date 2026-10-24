//! raywm-test-chaos: a Wayland client that performs a seeded random
//! sequence of protocol operations, for tests/stress (docs/TORTURE.md).
//!
//! Every operation is valid xdg-shell / layer-shell / subsurface usage
//! unless RAYWM_CHAOS_INVALID=1, which ends the run with one deliberate
//! protocol violation (the compositor must disconnect only this client).
//! In valid mode, being disconnected is a failure (exit 1): the compositor
//! refused correct requests.
//!
//! Environment:
//!   RAYWM_CHAOS_SEED=N      PRNG seed (required; printed for reproduction)
//!   RAYWM_CHAOS_OPS=N       operations before settling (default 500)
//!   RAYWM_CHAOS_MAX=N       most windows at once (default 6)
//!   RAYWM_CHAOS_TAG=s       title prefix (default "chaos")
//!   RAYWM_CHAOS_HOLD=path   after settling, keep acking until path exists
//!   RAYWM_CHAOS_INVALID=1   end with a protocol violation
//!   RAYWM_CHAOS_CRASH=1     end with _exit() instead of a clean teardown
//!   RAYWM_CHAOS_VERBOSE=1   print every operation
//!   RAYWM_CHAOS_DELAY_MS=N  wait up to N ms (seeded) between operations
//!   RAYWM_CHAOS_ONLY=a,b    only these operations (new ack destroy title appid
//!                           state popup unpopup sub unsub unmap rerole burst
//!                           layer unlayer acklayers close), drawn uniformly
//! Output: "chaos: seed=N", optional op lines, then after settling one line
//! "chaos: mapped <title>" per window, "chaos: settled windows=N", and
//! "chaos: done" (or the invalid/crash outcome).
const std = @import("std");
const posix = std.posix;
const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;
const zwlr = wayland.client.zwlr;

const gpa = std.heap.c_allocator;

var shm: *wl.Shm = undefined;
var compositor: *wl.Compositor = undefined;
var wm_base: *xdg.WmBase = undefined;
var subcompositor: ?*wl.Subcompositor = null;
var layer_shell: ?*zwlr.LayerShellV1 = null;
var output: ?*wl.Output = null;
var display: *wl.Display = undefined;
var verbose = false;
var tag: []const u8 = "chaos";

fn say(comptime fmt: []const u8, args: anytype) void {
    var buf: [1200]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "chaos: " ++ fmt ++ "\n", args) catch return;
    _ = std.c.write(1, s.ptr, s.len);
}

const Popup = struct {
    surface: *wl.Surface,
    xs: *xdg.Surface,
    popup: *xdg.Popup,
    serial: u32 = 0,
    pending: bool = false,
    mapped: bool = false,
    done: bool = false,
    buffer: ?*wl.Buffer = null,
};

const Win = struct {
    id: u32,
    surface: *wl.Surface,
    xs: *xdg.Surface,
    toplevel: ?*xdg.Toplevel,
    serial: u32 = 0,
    pending: bool = false,
    /// Got a first configure and acked it (a buffer may be attached).
    configured: bool = false,
    /// A buffer is attached: the window is mapped (or about to be).
    mapped: bool = false,
    /// After an unmap (null buffer) the initial commit must happen again.
    needs_initial: bool = false,
    width: i32 = 0,
    height: i32 = 0,
    buffer: ?*wl.Buffer = null,
    popups: [2]?*Popup = .{ null, null },
    sub: ?*wl.Surface = null,
    subsurface: ?*wl.Subsurface = null,
    sub_buffer: ?*wl.Buffer = null,
    close_requested: bool = false,
    geometry_set: bool = false,
    /// Size of the attached main buffer.
    buf_w: i32 = 1,
    buf_h: i32 = 1,
};

const Layer = struct {
    surface: *wl.Surface,
    ls: *zwlr.LayerSurfaceV1,
    serial: u32 = 0,
    pending: bool = false,
    mapped: bool = false,
    closed: bool = false,
    buffer: ?*wl.Buffer = null,
};

var wins: std.ArrayList(*Win) = .empty;
var layers: std.ArrayList(*Layer) = .empty;
var next_id: u32 = 1;

// ---- buffers ------------------------------------------------------------------

fn makeBuffer(w: i32, h: i32, shade: u8) !*wl.Buffer {
    const stride = w * 4;
    const size: usize = @intCast(stride * h);
    const fd = try posix.memfd_create("raywm-chaos", 0);
    defer _ = posix.system.close(fd);
    if (posix.errno(posix.system.ftruncate(fd, @intCast(size))) != .SUCCESS) return error.FtruncateFailed;
    const data = try posix.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
    defer posix.munmap(data);
    @memset(data, shade);
    const pool = try shm.createPool(fd, @intCast(size));
    defer pool.destroy();
    return pool.createBuffer(0, w, h, stride, .argb8888);
}

fn replaceBuffer(slot: *?*wl.Buffer, surface: *wl.Surface, w: i32, h: i32, shade: u8) !void {
    const b = try makeBuffer(w, h, shade);
    surface.attach(b, 0, 0);
    surface.damageBuffer(0, 0, w, h);
    surface.commit();
    if (slot.*) |old| old.destroy();
    slot.* = b;
}

// ---- listeners ----------------------------------------------------------------

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, _: ?*anyopaque) void {
    switch (event) {
        .global => |g| {
            const name = std.mem.span(g.interface);
            if (std.mem.eql(u8, name, std.mem.span(wl.Compositor.interface.name))) {
                compositor = registry.bind(g.name, wl.Compositor, 4) catch return;
            } else if (std.mem.eql(u8, name, std.mem.span(wl.Shm.interface.name))) {
                shm = registry.bind(g.name, wl.Shm, 1) catch return;
            } else if (std.mem.eql(u8, name, std.mem.span(xdg.WmBase.interface.name))) {
                wm_base = registry.bind(g.name, xdg.WmBase, @min(g.version, 6)) catch return;
            } else if (std.mem.eql(u8, name, std.mem.span(wl.Subcompositor.interface.name))) {
                subcompositor = registry.bind(g.name, wl.Subcompositor, 1) catch return;
            } else if (std.mem.eql(u8, name, std.mem.span(zwlr.LayerShellV1.interface.name))) {
                layer_shell = registry.bind(g.name, zwlr.LayerShellV1, @min(g.version, 4)) catch return;
            } else if (std.mem.eql(u8, name, std.mem.span(wl.Output.interface.name))) {
                if (output == null) output = registry.bind(g.name, wl.Output, 2) catch return;
            }
        },
        .global_remove => {},
    }
}

fn wmBaseListener(base: *xdg.WmBase, event: xdg.WmBase.Event, _: ?*anyopaque) void {
    switch (event) {
        .ping => |p| base.pong(p.serial),
    }
}

fn xdgSurfaceListener(_: *xdg.Surface, event: xdg.Surface.Event, w: *Win) void {
    switch (event) {
        .configure => |c| {
            w.serial = c.serial;
            w.pending = true;
            if (verbose) say("serial {d} {d}", .{ w.id, c.serial });
        },
    }
}

fn toplevelListener(_: *xdg.Toplevel, event: xdg.Toplevel.Event, w: *Win) void {
    switch (event) {
        .configure => |c| {
            w.width = c.width;
            w.height = c.height;
            if (verbose) say("configure {d} {d}x{d}", .{ w.id, c.width, c.height });
        },
        .close => w.close_requested = true,
        else => {},
    }
}

fn popupSurfaceListener(_: *xdg.Surface, event: xdg.Surface.Event, p: *Popup) void {
    switch (event) {
        .configure => |c| {
            p.serial = c.serial;
            p.pending = true;
        },
    }
}

fn popupListener(_: *xdg.Popup, event: xdg.Popup.Event, p: *Popup) void {
    switch (event) {
        .popup_done => p.done = true,
        else => {},
    }
}

fn layerListener(_: *zwlr.LayerSurfaceV1, event: zwlr.LayerSurfaceV1.Event, l: *Layer) void {
    switch (event) {
        .configure => |c| {
            l.serial = c.serial;
            l.pending = true;
        },
        .closed => l.closed = true,
    }
}

// ---- operations ---------------------------------------------------------------

/// The master stream gives every operation its own seed, so operation i
/// always draws the same numbers, however many the earlier ones used.
var master: std.Random.DefaultPrng = undefined;
var rng_state: std.Random.DefaultPrng = undefined;
fn rnd() std.Random {
    return rng_state.random();
}
fn chance(percent: u32) bool {
    return rnd().uintLessThan(u32, 100) < percent;
}

fn setTitle(w: *Win, random: bool) void {
    const t = w.toplevel orelse return;
    var buf: [600]u8 = undefined;
    if (!random) {
        const s = std.fmt.bufPrintZ(&buf, "{s}-{d}", .{ tag, w.id }) catch return;
        t.setTitle(s.ptr);
        return;
    }
    // Random lengths and UTF-8 (never invalid UTF-8: the wire is a C string).
    const pieces = [_][]const u8{ "a", "Ω", "日本", "🦀", " ", "\"'", "$(x)", "\\", "%s", "\u{200b}" };
    var n: usize = 0;
    const want = rnd().uintLessThan(usize, 120);
    while (n < want) {
        const p = pieces[rnd().uintLessThan(usize, pieces.len)];
        if (n + p.len >= buf.len - 1) break;
        @memcpy(buf[n..][0..p.len], p);
        n += p.len;
    }
    buf[n] = 0;
    t.setTitle(@ptrCast(&buf));
}

fn newWindow(max: usize) !void {
    if (wins.items.len >= max) return;
    const w = try gpa.create(Win);
    const surface = try compositor.createSurface();
    const xs = try wm_base.getXdgSurface(surface);
    const t = try xs.getToplevel();
    w.* = .{ .id = next_id, .surface = surface, .xs = xs, .toplevel = t };
    next_id += 1;
    xs.setListener(*Win, xdgSurfaceListener, w);
    t.setListener(*Win, toplevelListener, w);
    setTitle(w, false);
    if (chance(50)) t.setAppId(if (chance(50)) "chaos.app" else "org.raywm.Chaos");
    // A dialog of an older window (never a cycle: parents are older).
    if (wins.items.len > 0 and chance(25)) {
        const p = wins.items[rnd().uintLessThan(usize, wins.items.len)];
        if (p.toplevel) |pt| t.setParent(pt);
    }
    if (chance(10)) t.setFullscreen(null);
    if (chance(10)) t.setMaximized();
    if (chance(15)) {
        const mw = rnd().intRangeAtMost(i32, 1, 300);
        const mh = rnd().intRangeAtMost(i32, 1, 300);
        t.setMinSize(mw, mh);
        if (chance(50)) t.setMaxSize(mw + rnd().intRangeAtMost(i32, 0, 500), mh + rnd().intRangeAtMost(i32, 0, 500));
    }
    surface.commit();
    try wins.append(gpa, w);
    if (verbose) say("op new {d}", .{w.id});
}

/// Acks the latest configure and commits a buffer of the requested size.
fn ackWindow(w: *Win) !void {
    if (w.toplevel == null) return;
    if (w.needs_initial) {
        w.needs_initial = false;
        w.surface.commit();
        return;
    }
    if (!w.pending) return;
    w.pending = false;
    w.xs.ackConfigure(w.serial);
    w.configured = true;
    const bw = if (w.width > 0) @min(w.width, 4096) else rnd().intRangeAtMost(i32, 40, 400);
    const bh = if (w.height > 0) @min(w.height, 4096) else rnd().intRangeAtMost(i32, 40, 300);
    // Like toolkits: once a window geometry is set, it follows every buffer
    // (geometry that is set once and kept is tests/shell.sh s15).
    if (w.geometry_set or chance(20)) {
        w.geometry_set = true;
        w.xs.setWindowGeometry(0, 0, bw, bh);
    }
    try replaceBuffer(&w.buffer, w.surface, bw, bh, @truncate(w.id *% 37));
    w.buf_w = bw;
    w.buf_h = bh;
    w.mapped = true;
    if (verbose) say("op ack {d} {d}x{d}", .{ w.id, bw, bh });
}

fn destroyPopups(w: *Win) void {
    // Topmost first (xdg-shell requires it).
    var i: usize = w.popups.len;
    while (i > 0) {
        i -= 1;
        if (w.popups[i]) |p| {
            p.popup.destroy();
            p.xs.destroy();
            p.surface.destroy();
            if (p.buffer) |b| b.destroy();
            gpa.destroy(p);
            w.popups[i] = null;
        }
    }
}

fn destroySub(w: *Win) void {
    if (w.subsurface) |s| s.destroy();
    if (w.sub) |s| s.destroy();
    if (w.sub_buffer) |b| b.destroy();
    w.subsurface = null;
    w.sub = null;
    w.sub_buffer = null;
}

fn destroyWindow(index: usize) void {
    const w = wins.orderedRemove(index);
    if (verbose) say("op destroy {d} pending={}", .{ w.id, w.pending });
    destroyPopups(w);
    destroySub(w);
    if (w.toplevel) |t| t.destroy();
    w.xs.destroy();
    w.surface.destroy();
    if (w.buffer) |b| b.destroy();
    gpa.destroy(w);
}

fn openPopup(w: *Win) !void {
    if (!w.mapped or w.toplevel == null) return;
    const slot: usize = if (w.popups[0] == null) 0 else if (w.popups[1] == null and w.popups[0].?.mapped and !w.popups[0].?.done) 1 else return;
    const parent_xs = if (slot == 0) w.xs else w.popups[0].?.xs;
    const pos = try wm_base.createPositioner();
    pos.setSize(rnd().intRangeAtMost(i32, 1, 300), rnd().intRangeAtMost(i32, 1, 300));
    pos.setAnchorRect(rnd().intRangeAtMost(i32, -50, 300), rnd().intRangeAtMost(i32, -50, 300), rnd().intRangeAtMost(i32, 1, 50), rnd().intRangeAtMost(i32, 1, 50));
    const anchors = [_]xdg.Positioner.Anchor{ .none, .top, .bottom, .left, .right, .top_left, .bottom_left, .top_right, .bottom_right };
    pos.setAnchor(anchors[rnd().uintLessThan(usize, anchors.len)]);
    const gravities = [_]xdg.Positioner.Gravity{ .none, .top, .bottom, .left, .right, .top_left, .bottom_left, .top_right, .bottom_right };
    pos.setGravity(gravities[rnd().uintLessThan(usize, gravities.len)]);
    pos.setConstraintAdjustment(@bitCast(rnd().int(u32) & 0x3f));
    if (chance(30)) pos.setOffset(rnd().intRangeAtMost(i32, -200, 200), rnd().intRangeAtMost(i32, -200, 200));
    const surface = try compositor.createSurface();
    const xs = try wm_base.getXdgSurface(surface);
    const popup = try xs.getPopup(parent_xs, pos);
    pos.destroy();
    const p = try gpa.create(Popup);
    p.* = .{ .surface = surface, .xs = xs, .popup = popup };
    xs.setListener(*Popup, popupSurfaceListener, p);
    popup.setListener(*Popup, popupListener, p);
    surface.commit();
    w.popups[slot] = p;
    if (verbose) say("op popup {d}.{d}", .{ w.id, slot });
}

fn ackPopups(w: *Win) !void {
    for (w.popups) |maybe| if (maybe) |p| if (p.pending and !p.done) {
        p.pending = false;
        p.xs.ackConfigure(p.serial);
        try replaceBuffer(&p.buffer, p.surface, 30, 20, 0x40);
        p.mapped = true;
    };
}

fn addSub(w: *Win) !void {
    const sc = subcompositor orelse return;
    if (w.sub != null or !w.mapped) return;
    const s = try compositor.createSurface();
    const ss = try sc.getSubsurface(s, w.surface);
    ss.setPosition(rnd().intRangeAtMost(i32, -40, 200), rnd().intRangeAtMost(i32, -40, 200));
    if (chance(50)) ss.setDesync();
    w.sub = s;
    w.subsurface = ss;
    // Like toolkits with subsurfaces: the window geometry is the main
    // buffer, not the extents that the subsurface widens.
    w.geometry_set = true;
    w.xs.setWindowGeometry(0, 0, w.buf_w, w.buf_h);
    try replaceBuffer(&w.sub_buffer, s, rnd().intRangeAtMost(i32, 1, 80), rnd().intRangeAtMost(i32, 1, 80), 0xc0);
    w.surface.commit();
    if (verbose) say("op sub {d}", .{w.id});
}

fn unmapWindow(w: *Win) void {
    if (!w.mapped) return;
    destroyPopups(w);
    w.surface.attach(null, 0, 0);
    w.surface.commit();
    w.mapped = false;
    w.configured = false;
    w.needs_initial = true;
    // Configures sent before the compositor saw the unmap are stale: their
    // serials are no longer valid. Drain them before the next initial commit.
    roundtrip() catch {};
    w.pending = false;
    if (verbose) say("op unmap {d}", .{w.id});
}

/// A new toplevel role on the same xdg_surface (allowed once the old role
/// object is destroyed and the surface is unmapped).
fn rerole(w: *Win) !void {
    if (w.toplevel == null) return;
    destroyPopups(w);
    // Unmap while the role still exists (a role-less xdg_surface must not
    // commit, and a mapped surface cannot take a new role).
    if (w.mapped or w.configured) {
        w.surface.attach(null, 0, 0);
        w.surface.commit();
    }
    w.toplevel.?.destroy();
    w.toplevel = null;
    // As after an unmap: drop configures of the old role.
    try roundtrip();
    w.pending = false;
    const t = try w.xs.getToplevel();
    t.setListener(*Win, toplevelListener, w);
    w.toplevel = t;
    w.mapped = false;
    w.configured = false;
    w.pending = false;
    w.needs_initial = false;
    // The xdg_surface keeps its window geometry across roles.
    setTitle(w, false);
    w.surface.commit();
    if (verbose) say("op rerole {d}", .{w.id});
}

fn burst(w: *Win) !void {
    if (!w.mapped or w.buffer == null) return;
    const n = rnd().intRangeAtMost(u32, 2, 40);
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        w.surface.attach(w.buffer, 0, 0);
        w.surface.damageBuffer(rnd().intRangeAtMost(i32, 0, 50), rnd().intRangeAtMost(i32, 0, 50), 10, 10);
        w.surface.commit();
    }
    if (verbose) say("op burst {d} x{d}", .{ w.id, n });
}

fn newLayer() !void {
    const shell = layer_shell orelse return;
    if (layers.items.len >= 3) return;
    const s = try compositor.createSurface();
    const lvl = [_]zwlr.LayerShellV1.Layer{ .background, .bottom, .top, .overlay };
    const ls = try shell.getLayerSurface(s, if (chance(50)) output else null, lvl[rnd().uintLessThan(usize, lvl.len)], "chaos");
    const l = try gpa.create(Layer);
    l.* = .{ .surface = s, .ls = ls };
    ls.setListener(*Layer, layerListener, l);
    const anchor: zwlr.LayerSurfaceV1.Anchor = @bitCast(rnd().int(u32) & 0xf);
    ls.setAnchor(anchor);
    const horiz = anchor.left and anchor.right;
    const vert = anchor.top and anchor.bottom;
    ls.setSize(if (horiz) 0 else rnd().intRangeAtMost(u32, 1, 300), if (vert) 0 else rnd().intRangeAtMost(u32, 1, 200));
    if (chance(50)) ls.setExclusiveZone(rnd().intRangeAtMost(i32, -1, 120));
    // Exclusive keyboard interactivity is left out: it would starve windows of focus forever.
    if (chance(30)) ls.setKeyboardInteractivity(.on_demand);
    s.commit();
    try layers.append(gpa, l);
    if (verbose) say("op layer new", .{});
}

fn ackLayers() !void {
    var i: usize = 0;
    while (i < layers.items.len) {
        const l = layers.items[i];
        if (l.closed) {
            destroyLayer(i);
            continue;
        }
        if (l.pending) {
            l.pending = false;
            l.ls.ackConfigure(l.serial);
            try replaceBuffer(&l.buffer, l.surface, 100, 30, 0x20);
            l.mapped = true;
        }
        i += 1;
    }
}

fn destroyLayer(i: usize) void {
    const l = layers.orderedRemove(i);
    l.ls.destroy();
    l.surface.destroy();
    if (l.buffer) |b| b.destroy();
    gpa.destroy(l);
    if (verbose) say("op layer destroy", .{});
}

fn pick() ?*Win {
    if (wins.items.len == 0) return null;
    return wins.items[rnd().uintLessThan(usize, wins.items.len)];
}

const Op = enum { new, ack, destroy, title, appid, state, popup, unpopup, sub, unsub, unmap, rerole, burst, layer, unlayer, acklayers, close };

/// RAYWM_CHAOS_ONLY=a,b,...: draw operations uniformly from that list.
var only: [32]Op = undefined;
var n_only: usize = 0;

fn pickOp() Op {
    if (n_only > 0) return only[rnd().uintLessThan(usize, n_only)];
    const r = rnd().uintLessThan(u32, 100);
    const table = [_]struct { u32, Op }{
        .{ 14, .new },       .{ 40, .ack },    .{ 48, .destroy }, .{ 54, .title }, .{ 58, .appid },
        .{ 66, .state },     .{ 71, .popup },  .{ 73, .unpopup }, .{ 76, .sub },   .{ 77, .unsub },
        .{ 80, .unmap },     .{ 82, .rerole }, .{ 89, .burst },   .{ 92, .layer }, .{ 94, .unlayer },
        .{ 96, .acklayers },
    };
    for (table) |t| if (r < t[0]) return t[1];
    return .close;
}

fn step(max: usize) !void {
    switch (pickOp()) {
        .new => return newWindow(max),
        // Ack everything that is pending on one window (the common case).
        .ack => if (pick()) |w| {
            try ackWindow(w);
            try ackPopups(w);
        },
        .destroy => if (wins.items.len > 0) destroyWindow(rnd().uintLessThan(usize, wins.items.len)),
        .title => if (pick()) |w| setTitle(w, true),
        .appid => if (pick()) |w| if (w.toplevel) |t| t.setAppId(if (chance(50)) "chaos.other" else "chaos.app"),
        .state => {
            const w = pick() orelse return;
            const t = w.toplevel orelse return;
            switch (rnd().uintLessThan(u32, 5)) {
                0 => t.setFullscreen(if (chance(50)) output else null),
                1 => t.unsetFullscreen(),
                2 => t.setMaximized(),
                3 => t.unsetMaximized(),
                else => t.setMinimized(),
            }
            if (verbose) say("op state {d}", .{w.id});
        },
        .popup => if (pick()) |w| try openPopup(w),
        .unpopup => if (pick()) |w| destroyPopups(w),
        .sub => if (pick()) |w| try addSub(w),
        .unsub => if (pick()) |w| destroySub(w),
        .unmap => if (pick()) |w| unmapWindow(w),
        .rerole => if (pick()) |w| try rerole(w),
        .burst => if (pick()) |w| try burst(w),
        .layer => try newLayer(),
        .unlayer => if (layers.items.len > 0) destroyLayer(rnd().uintLessThan(usize, layers.items.len)),
        .acklayers => try ackLayers(),
        // A close request from the compositor is honoured now and then.
        .close => for (wins.items, 0..) |w, i| if (w.close_requested and chance(50)) {
            destroyWindow(i);
            return;
        },
    }
}

fn dispatchTimeout(ms: i32) !void {
    if (display.dispatchPending() != .SUCCESS) return error.DispatchFailed;
    while (!display.prepareRead()) {
        if (display.dispatchPending() != .SUCCESS) return error.DispatchFailed;
    }
    _ = display.flush();
    var fds = [_]posix.pollfd{.{ .fd = display.getFd(), .events = posix.POLL.IN, .revents = 0 }};
    const n = posix.poll(&fds, ms) catch {
        display.cancelRead();
        return error.PollFailed;
    };
    if (n == 0) return display.cancelRead();
    if (display.readEvents() != .SUCCESS) return error.ReadFailed;
    if (display.dispatchPending() != .SUCCESS) return error.DispatchFailed;
}

fn roundtrip() !void {
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
}

/// Maps every live window: initial commits, configures, acks.
fn settle() !void {
    var round: u32 = 0;
    while (round < 50) : (round += 1) {
        for (wins.items) |w| {
            if (w.close_requested) w.close_requested = false; // ignored: allowed
            if (w.needs_initial) try ackWindow(w);
            try ackWindow(w);
            try ackPopups(w);
        }
        try ackLayers();
        try roundtrip();
        const all = for (wins.items) |w| {
            if (!w.mapped or w.pending or w.needs_initial) break false;
        } else true;
        if (all) break;
    }
    for (wins.items) |w| setTitle(w, false);
    try roundtrip();
    try roundtrip();
}

fn env(name: [*:0]const u8) ?[]const u8 {
    return if (std.c.getenv(name)) |v| std.mem.span(v) else null;
}

fn invalidEnd() !void {
    // One protocol violation; the compositor must disconnect this client.
    const kind = rnd().uintLessThan(u32, 4);
    say("invalid kind={d}", .{kind});
    switch (kind) {
        0 => {
            const s = try compositor.createSurface();
            const xs = try wm_base.getXdgSurface(s);
            _ = try xs.getToplevel();
            xs.ackConfigure(0xdeadbeef); // a serial never sent
            s.commit();
        },
        1 => {
            const s = try compositor.createSurface();
            const xs = try wm_base.getXdgSurface(s);
            _ = try xs.getToplevel();
            const b = try makeBuffer(10, 10, 1);
            s.attach(b, 0, 0); // a buffer before the first configure
            s.commit();
        },
        2 => {
            const s = try compositor.createSurface();
            const xs = try wm_base.getXdgSurface(s);
            _ = try xs.getToplevel();
            xs.destroy(); // before its role object
        },
        else => {
            const s = try compositor.createSurface();
            const xs = try wm_base.getXdgSurface(s);
            _ = try xs.getToplevel();
            xs.setWindowGeometry(0, 0, 0, -5); // invalid size
            s.commit();
        },
    }
    var i: u32 = 0;
    while (i < 100) : (i += 1) {
        if (display.roundtrip() != .SUCCESS) {
            const code = display.getError();
            say("disconnected as expected (error {d})", .{code});
            std.process.exit(3);
        }
    }
    say("NOT disconnected after a protocol violation", .{});
    std.process.exit(4);
}

pub fn main() !void {
    const seed = std.fmt.parseInt(u64, env("RAYWM_CHAOS_SEED") orelse return error.NoSeed, 10) catch return error.BadSeed;
    const ops = std.fmt.parseInt(u32, env("RAYWM_CHAOS_OPS") orelse "500", 10) catch 500;
    const max = std.fmt.parseInt(usize, env("RAYWM_CHAOS_MAX") orelse "6", 10) catch 6;
    tag = env("RAYWM_CHAOS_TAG") orelse "chaos";
    verbose = env("RAYWM_CHAOS_VERBOSE") != null;
    const delay = std.fmt.parseInt(i32, env("RAYWM_CHAOS_DELAY_MS") orelse "0", 10) catch 0;
    master = .init(seed);
    rng_state = .init(seed);
    if (env("RAYWM_CHAOS_ONLY")) |list| {
        var it = std.mem.tokenizeScalar(u8, list, ',');
        while (it.next()) |name| {
            const op = std.meta.stringToEnum(Op, name) orelse return error.UnknownOp;
            if (n_only < only.len) {
                only[n_only] = op;
                n_only += 1;
            }
        }
    }
    say("seed={d} ops={d} max={d} tag={s}", .{ seed, ops, max, tag });

    display = try wl.Display.connect(null);
    const registry = try display.getRegistry();
    registry.setListener(?*anyopaque, registryListener, null);
    try roundtrip();
    wm_base.setListener(?*anyopaque, wmBaseListener, null);

    var i: u32 = 0;
    while (i < ops) : (i += 1) {
        rng_state = .init(master.random().int(u64));
        step(max) catch |e| {
            say("FAIL op {d}: {s} (display error {d})", .{ i, @errorName(e), display.getError() });
            std.process.exit(1);
        };
        // Sometimes wait for the compositor, sometimes race ahead.
        dispatchTimeout(if (chance(30)) rnd().intRangeAtMost(i32, 0, 8) + delay else @divTrunc(delay, 2)) catch |e| {
            say("FAIL disconnected at op {d}: {s} (display error {d})", .{ i, @errorName(e), display.getError() });
            std.process.exit(1);
        };
    }
    if (env("RAYWM_CHAOS_INVALID") != null) try invalidEnd();
    settle() catch |e| {
        say("FAIL settle: {s} (display error {d})", .{ @errorName(e), display.getError() });
        std.process.exit(1);
    };
    for (wins.items) |w| say("mapped {s}-{d}", .{ tag, w.id });
    say("settled windows={d} layers={d}", .{ wins.items.len, layers.items.len });
    if (env("RAYWM_CHAOS_HOLD")) |path| {
        var pz: [512]u8 = undefined;
        const p = std.fmt.bufPrintZ(&pz, "{s}", .{path}) catch return error.PathTooLong;
        while (std.c.access(p.ptr, 0) != 0) {
            dispatchTimeout(50) catch |e| {
                say("FAIL disconnected while holding: {s}", .{@errorName(e)});
                std.process.exit(1);
            };
            for (wins.items) |w| if (w.pending) try ackWindow(w);
        }
    }
    if (env("RAYWM_CHAOS_CRASH") != null) {
        _ = display.flush();
        say("crash exit", .{});
        std.c._exit(0);
    }
    while (wins.items.len > 0) destroyWindow(wins.items.len - 1);
    while (layers.items.len > 0) destroyLayer(layers.items.len - 1);
    try roundtrip();
    display.disconnect();
    say("done", .{});
}
