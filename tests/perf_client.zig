//! Deterministic high-frequency client for tests/perf.sh (test builds only).
//!
//!   raywm-test-perf spin  SECONDS [fullscreen] [translucent] [tearing]
//!       Commits a new full-surface buffer whenever one of four buffers is
//!       free, never waiting for frame callbacks: like a game with vsync
//!       off. The commit rate is limited by buffer releases only.
//!   raywm-test-perf vsync SECONDS [fullscreen]
//!       Commits once per frame callback, like a game with vsync on.
//!   `tearing` sets the tearing-control "async" presentation hint.
//!   raywm-test-perf watch SECONDS
//!       A passive taskbar: counts wlr-foreign-toplevel and ext list events.
//!
//! Every commit asks for presentation feedback. The final line is
//! `perf: key=value ...` (stderr). Fixed storage only; nothing is printed
//! per frame, so the output does not perturb the measurement.
const std = @import("std");
const posix = std.posix;
const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;
const wp = wayland.client.wp;
const zwlr = wayland.client.zwlr;
const ext = wayland.client.ext;

fn nowNs() u64 {
    var ts: posix.timespec = undefined;
    _ = posix.system.clock_gettime(posix.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn say(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("perf: " ++ fmt ++ "\n", args);
}

const Buffer = struct {
    app: *App,
    proxy: *wl.Buffer,
    w: i32,
    h: i32,
    busy: bool = false,
};

const max_intervals = 4096;

const App = struct {
    shm: ?*wl.Shm = null,
    compositor: ?*wl.Compositor = null,
    wm_base: ?*xdg.WmBase = null,
    presentation: ?*wp.Presentation = null,
    foreign: ?*zwlr.ForeignToplevelManagerV1 = null,
    list: ?*ext.ForeignToplevelListV1 = null,
    tearing: ?*wp.TearingControlManagerV1 = null,
    width: i32 = 0,
    height: i32 = 0,
    configured: bool = false,
    closed: bool = false,
    buffers: [4]?Buffer = @splat(null),
    translucent: bool = false,
    // Counters.
    commits: u64 = 0,
    releases: u64 = 0,
    frames: u64 = 0,
    frame_pending: bool = false,
    presented: u64 = 0,
    discarded: u64 = 0,
    zero_copy: u64 = 0,
    vsync_flag: u64 = 0,
    nonmonotonic: u64 = 0,
    future: u64 = 0,
    last_present_ns: u64 = 0,
    intervals: [max_intervals]u64 = undefined,
    n_intervals: usize = 0,
    // watch
    w_title: u64 = 0,
    w_app_id: u64 = 0,
    w_state: u64 = 0,
    w_done: u64 = 0,
    w_output: u64 = 0,
    e_done: u64 = 0,
};

pub fn main(init: std.process.Init) !u8 {
    const argv = init.minimal.args.vector;
    if (argv.len < 3) {
        say("usage: raywm-test-perf spin|vsync|watch SECONDS [fullscreen] [translucent]", .{});
        return 2;
    }
    const mode = std.mem.span(argv[1]);
    const seconds = std.fmt.parseFloat(f64, std.mem.span(argv[2])) catch return 2;
    var fullscreen = false;
    var tearing = false;
    var app: App = .{};
    for (argv[3..]) |a| {
        const s = std.mem.span(a);
        if (std.mem.eql(u8, s, "fullscreen")) fullscreen = true;
        if (std.mem.eql(u8, s, "translucent")) app.translucent = true;
        if (std.mem.eql(u8, s, "tearing")) tearing = true;
    }
    const display = try wl.Display.connect(null);
    defer display.disconnect();
    const registry = try display.getRegistry();
    registry.setListener(*App, registryListener, &app);
    if (display.roundtrip() != .SUCCESS) return 1;
    if (display.roundtrip() != .SUCCESS) return 1;
    const deadline_ns: u64 = @intFromFloat(seconds * std.time.ns_per_s);

    if (std.mem.eql(u8, mode, "watch")) {
        if (app.foreign == null) return 2;
        say("ready", .{});
        const start = nowNs();
        while (nowNs() - start < deadline_ns) {
            if (try dispatchTimeout(display, 20) == false) return 1;
        }
        say("mode=watch title={d} app_id={d} state={d} output={d} done={d} ext_done={d}", .{ app.w_title, app.w_app_id, app.w_state, app.w_output, app.w_done, app.e_done });
        return 0;
    }

    const spin = std.mem.eql(u8, mode, "spin");
    if (!spin and !std.mem.eql(u8, mode, "vsync")) return 2;
    if (app.compositor == null or app.shm == null or app.wm_base == null) return 2;
    const surface = try app.compositor.?.createSurface();
    const xs = try app.wm_base.?.getXdgSurface(surface);
    const top = try xs.getToplevel();
    xs.setListener(*App, xdgSurfaceListener, &app);
    top.setListener(*App, toplevelListener, &app);
    top.setAppId("raywm-test-perf");
    top.setTitle("perf");
    if (fullscreen) top.setFullscreen(null);
    if (tearing) {
        const tc = try (app.tearing orelse return 2).getTearingControl(surface);
        tc.setPresentationHint(.async);
    }
    surface.commit();
    while (!app.configured) if (display.dispatch() != .SUCCESS) return 1;
    // Wait for a fullscreen configure if asked (the first may be the initial one).
    say("ready {d}x{d}", .{ app.width, app.height });

    const start = nowNs();
    var next_frame_needed = true;
    while (!app.closed) {
        const t = nowNs();
        if (t - start >= deadline_ns) break;
        const ready = spin or next_frame_needed or !app.frame_pending;
        if (ready) if (try freeBuffer(&app)) |b| {
            surface.attach(b.proxy, 0, 0);
            surface.damageBuffer(0, 0, b.w, b.h);
            if (app.presentation) |p| {
                const fb = try p.feedback(surface);
                fb.setListener(*App, presentationListener, &app);
            }
            if (!spin) {
                const cb = try surface.frame();
                cb.setListener(*App, frameListener, &app);
                app.frame_pending = true;
            }
            b.busy = true;
            surface.commit();
            app.commits += 1;
            next_frame_needed = false;
            _ = display.flush();
            if (spin) {
                // Read what has arrived without blocking.
                if (display.dispatchPending() != .SUCCESS) return 1;
                if (try dispatchTimeout(display, 0) == false) return 1;
                continue;
            }
        };
        if (try dispatchTimeout(display, 20) == false) return 1;
    }
    const elapsed = nowNs() - start;
    // Collect outstanding feedback before reporting.
    _ = display.roundtrip();
    var p50: u64 = 0;
    var p99: u64 = 0;
    if (app.n_intervals > 0) {
        const s = app.intervals[0..app.n_intervals];
        std.mem.sort(u64, s, {}, std.sort.asc(u64));
        p50 = s[s.len / 2];
        p99 = s[@min(s.len - 1, (s.len * 99) / 100)];
    }
    say("mode={s} size={d}x{d} elapsed_ms={d} commits={d} releases={d} frames={d} presented={d} discarded={d} zero_copy={d} vsync={d} nonmonotonic={d} future={d} present_p50_us={d} present_p99_us={d}", .{
        mode,       app.width,     app.height,    elapsed / std.time.ns_per_ms, app.commits,    app.releases,
        app.frames, app.presented, app.discarded, app.zero_copy,                app.vsync_flag, app.nonmonotonic,
        app.future, p50 / 1000,    p99 / 1000,
    });
    top.destroy();
    xs.destroy();
    surface.destroy();
    _ = display.roundtrip();
    return 0;
}

/// Dispatches events, waiting at most `ms` for new ones. False on error.
fn dispatchTimeout(display: *wl.Display, ms: i32) !bool {
    if (display.dispatchPending() != .SUCCESS) return false;
    while (!display.prepareRead()) if (display.dispatchPending() != .SUCCESS) return false;
    _ = display.flush();
    var fds = [_]posix.pollfd{.{ .fd = display.getFd(), .events = posix.POLL.IN, .revents = 0 }};
    const n = posix.poll(&fds, ms) catch 0;
    if (n > 0) {
        if (display.readEvents() != .SUCCESS) return false;
    } else display.cancelRead();
    return display.dispatchPending() == .SUCCESS;
}

fn makeBuffer(app: *App, w: i32, h: i32) !Buffer {
    const stride = w * 4;
    const size: usize = @intCast(stride * h);
    const fd = try posix.memfd_create("raywm-test-perf", 0);
    defer _ = posix.system.close(fd);
    if (posix.errno(posix.system.ftruncate(fd, @intCast(size))) != .SUCCESS) return error.FtruncateFailed;
    const data = try posix.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
    defer posix.munmap(data);
    @memset(data, if (app.translucent) 0x80 else 0x40);
    const pool = try app.shm.?.createPool(fd, @intCast(size));
    defer pool.destroy();
    const proxy = try pool.createBuffer(0, w, h, stride, if (app.translucent) .argb8888 else .xrgb8888);
    return .{ .app = app, .proxy = proxy, .w = w, .h = h };
}

fn freeBuffer(app: *App) !?*Buffer {
    const w = if (app.width > 0) app.width else 640;
    const h = if (app.height > 0) app.height else 480;
    for (&app.buffers) |*slot| {
        if (slot.*) |*b| {
            if (b.busy) continue;
            if (b.w == w and b.h == h) return b;
            b.proxy.destroy();
            slot.* = null;
        }
    }
    for (&app.buffers) |*slot| if (slot.* == null) {
        slot.* = try makeBuffer(app, w, h);
        const b = &slot.*.?;
        b.proxy.setListener(*Buffer, bufferListener, b);
        return b;
    };
    return null;
}

fn bufferListener(_: *wl.Buffer, event: wl.Buffer.Event, b: *Buffer) void {
    switch (event) {
        .release => {
            b.busy = false;
            b.app.releases += 1;
        },
    }
}

fn frameListener(cb: *wl.Callback, _: wl.Callback.Event, app: *App) void {
    cb.destroy();
    app.frames += 1;
    app.frame_pending = false;
}

fn presentationListener(fb: *wp.PresentationFeedback, event: wp.PresentationFeedback.Event, app: *App) void {
    switch (event) {
        .sync_output => {},
        .presented => |p| {
            fb.destroy();
            app.presented += 1;
            const flags: u32 = @bitCast(p.flags);
            if (flags & 0x8 != 0) app.zero_copy += 1;
            if (flags & 0x1 != 0) app.vsync_flag += 1;
            const sec = (@as(u64, p.tv_sec_hi) << 32) | p.tv_sec_lo;
            const ns = sec * std.time.ns_per_s + p.tv_nsec;
            // Presentation timestamps use the compositor's clock (MONOTONIC
            // here): never later than now, never going backwards.
            if (ns > nowNs()) app.future += 1;
            if (app.last_present_ns != 0) {
                if (ns < app.last_present_ns) app.nonmonotonic += 1 else if (ns > app.last_present_ns and app.n_intervals < max_intervals) {
                    app.intervals[app.n_intervals] = ns - app.last_present_ns;
                    app.n_intervals += 1;
                }
            }
            app.last_present_ns = ns;
        },
        .discarded => {
            fb.destroy();
            app.discarded += 1;
        },
    }
}

fn xdgSurfaceListener(xs: *xdg.Surface, event: xdg.Surface.Event, app: *App) void {
    switch (event) {
        .configure => |c| {
            xs.ackConfigure(c.serial);
            app.configured = true;
        },
    }
}

fn toplevelListener(_: *xdg.Toplevel, event: xdg.Toplevel.Event, app: *App) void {
    switch (event) {
        .configure => |c| {
            if (c.width > 0) app.width = c.width;
            if (c.height > 0) app.height = c.height;
        },
        .close => app.closed = true,
        else => {},
    }
}

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, app: *App) void {
    switch (event) {
        .global => |g| {
            const name = std.mem.span(g.interface);
            if (std.mem.eql(u8, name, std.mem.span(wl.Compositor.interface.name))) {
                app.compositor = registry.bind(g.name, wl.Compositor, 4) catch return;
            } else if (std.mem.eql(u8, name, std.mem.span(wl.Shm.interface.name))) {
                app.shm = registry.bind(g.name, wl.Shm, 1) catch return;
            } else if (std.mem.eql(u8, name, std.mem.span(xdg.WmBase.interface.name))) {
                app.wm_base = registry.bind(g.name, xdg.WmBase, 1) catch return;
                app.wm_base.?.setListener(?*anyopaque, wmBaseListener, null);
            } else if (std.mem.eql(u8, name, std.mem.span(wp.Presentation.interface.name))) {
                app.presentation = registry.bind(g.name, wp.Presentation, 1) catch return;
            } else if (std.mem.eql(u8, name, std.mem.span(wp.TearingControlManagerV1.interface.name))) {
                app.tearing = registry.bind(g.name, wp.TearingControlManagerV1, 1) catch return;
            } else if (std.mem.eql(u8, name, std.mem.span(zwlr.ForeignToplevelManagerV1.interface.name))) {
                app.foreign = registry.bind(g.name, zwlr.ForeignToplevelManagerV1, 3) catch return;
                app.foreign.?.setListener(*App, foreignListener, app);
            } else if (std.mem.eql(u8, name, std.mem.span(ext.ForeignToplevelListV1.interface.name))) {
                app.list = registry.bind(g.name, ext.ForeignToplevelListV1, 1) catch return;
                app.list.?.setListener(*App, listListener, app);
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

fn foreignListener(_: *zwlr.ForeignToplevelManagerV1, event: zwlr.ForeignToplevelManagerV1.Event, app: *App) void {
    switch (event) {
        .toplevel => |e| e.toplevel.setListener(*App, topListener, app),
        .finished => {},
    }
}

fn topListener(proxy: *zwlr.ForeignToplevelHandleV1, event: zwlr.ForeignToplevelHandleV1.Event, app: *App) void {
    switch (event) {
        .title => app.w_title += 1,
        .app_id => app.w_app_id += 1,
        .state => app.w_state += 1,
        .output_enter, .output_leave => app.w_output += 1,
        .done => app.w_done += 1,
        .parent => {},
        .closed => proxy.destroy(),
    }
}

fn listListener(_: *ext.ForeignToplevelListV1, event: ext.ForeignToplevelListV1.Event, app: *App) void {
    switch (event) {
        .toplevel => |e| e.toplevel.setListener(*App, extListener, app),
        .finished => {},
    }
}

fn extListener(proxy: *ext.ForeignToplevelHandleV1, event: ext.ForeignToplevelHandleV1.Event, app: *App) void {
    switch (event) {
        .done => app.e_done += 1,
        .closed => proxy.destroy(),
        else => {},
    }
}
