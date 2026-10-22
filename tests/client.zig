//! Minimal xdg-shell client for the headless smoke test.
//! Per round: create toplevel -> wait configure -> ack -> attach buffer ->
//! wait frame callback (proves the surface was mapped and rendered) ->
//! destroy toplevel. Two rounds reuse one xdg_surface. Each step is printed.
const std = @import("std");
const posix = std.posix;
const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;
const zwlr = wayland.client.zwlr;

const Globals = struct {
    shm: ?*wl.Shm = null,
    compositor: ?*wl.Compositor = null,
    wm_base: ?*xdg.WmBase = null,
    layer_shell: ?*zwlr.LayerShellV1 = null,
    seat: ?*wl.Seat = null,
    /// The seat's capabilities arrive right after binding, before any
    /// SeatUse exists: kept here and applied by SeatUse.listen().
    seat_caps: ?wl.Seat.Capability = null,
    seat_use: ?*SeatUse = null,
};

/// Seat use by a held window or panel:
/// - RAYWM_TEST_CSD_MOVE: a left press asks the compositor to start an
///   interactive move, like a client-side title bar does;
/// - RAYWM_TEST_PTR: log pointer enter and button events (window or popup);
/// - RAYWM_TEST_KBD: log keyboard enter/leave/key events;
/// - panel only: F11 switches keyboard interactivity to none.
const SeatUse = struct {
    seat: *wl.Seat,
    surface: *wl.Surface,
    toplevel: ?*xdg.Toplevel = null,
    layer: ?*zwlr.LayerSurfaceV1 = null,
    pointer: ?*wl.Pointer = null,
    keyboard: ?*wl.Keyboard = null,
    popup: ?*PopupTest = null,
    /// Surface under the pointer, as last reported by wl_pointer.enter.
    ptr_on: ?*wl.Surface = null,

    fn listen(use: *SeatUse, g: *Globals) void {
        g.seat_use = use;
        if (g.seat_caps) |caps| applyCaps(use, caps);
    }
};

const State = struct {
    configured: bool = false,
    serial: u32 = 0,
    width: i32 = 0,
    height: i32 = 0,
    frame_done: bool = false,
    /// xdg_toplevel "activated" state, i.e. whether the window has focus.
    activated: bool = false,
};

fn step(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("client: " ++ fmt ++ "\n", args);
}

pub fn main() !void {
    const display = try wl.Display.connect(null);
    defer display.disconnect();
    const registry = try display.getRegistry();
    defer registry.destroy();

    var globals: Globals = .{};
    registry.setListener(*Globals, registryListener, &globals);
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    const shm = globals.shm orelse return error.NoWlShm;
    const compositor = globals.compositor orelse return error.NoWlCompositor;
    if (std.c.getenv("RAYWM_TEST_LAYER") != null)
        return panel(display, shm, compositor, globals.layer_shell orelse return error.NoLayerShell, &globals);
    const wm_base = globals.wm_base orelse return error.NoXdgWmBase;
    wm_base.setListener(?*anyopaque, wmBaseListener, null);

    const surface = try compositor.createSurface();
    const xdg_surface = try wm_base.getXdgSurface(surface);
    // Two rounds on the same xdg_surface: destroying the toplevel role and
    // creating a new one must work (and must not leak compositor state).
    var state: State = .{};
    xdg_surface.setListener(*State, xdgSurfaceListener, &state);
    const rounds: usize = if (std.c.getenv("RAYWM_TEST_ROUNDS")) |r| std.fmt.parseInt(usize, std.mem.span(r), 10) catch 2 else 2;
    for (0..rounds) |round| {
        state = .{};
        const toplevel = try xdg_surface.getToplevel();
        toplevel.setListener(*State, toplevelListener, &state);
        toplevel.setTitle("raywm-test");
        toplevel.setAppId("raywm-test");
        surface.attach(null, 0, 0);
        surface.commit();

        while (!state.configured) {
            if (display.dispatch() != .SUCCESS) return error.DispatchFailed;
        }
        xdg_surface.ackConfigure(state.serial);
        step("round {d} configured {d}x{d}", .{ round, state.width, state.height });
        const w: i32 = if (state.width > 0) state.width else 200;
        const h: i32 = if (state.height > 0) state.height else 150;
        state.configured = false; // detect the next configure
        state.width = 0;
        const buffer = try windowBuffer(shm, xdg_surface, w, h);
        defer buffer.destroy();

        const frame = try surface.frame();
        frame.setListener(*State, frameListener, &state);
        surface.attach(buffer, 0, 0);
        surface.damageBuffer(0, 0, std.math.maxInt(i32), std.math.maxInt(i32));
        surface.commit();
        while (!state.frame_done) {
            if (display.dispatch() != .SUCCESS) return error.DispatchFailed;
        }
        step("round {d} frame done", .{round});
        if (std.c.getenv("RAYWM_TEST_HOLD") != null) {
            var use: SeatUse = .{ .seat = globals.seat orelse return error.NoSeat, .surface = surface, .toplevel = toplevel };
            var popup_test: PopupTest = .{ .display = display, .wm_base = wm_base, .compositor = compositor, .shm = shm };
            if (std.c.getenv("RAYWM_TEST_POPUP") != null) {
                try popup_test.open(xdg_surface);
                use.popup = &popup_test;
            }
            use.listen(&globals);
            // Keep the window (acking every configure) until the compositor
            // goes away. The previous buffer is released after each commit.
            var prev: ?*wl.Buffer = null;
            defer if (prev) |p| p.destroy();
            while (true) {
                // A configure may already have arrived while waiting above.
                if (!state.configured) {
                    if (display.dispatch() != .SUCCESS) break;
                    continue;
                }
                state.configured = false;
                xdg_surface.ackConfigure(state.serial);
                var next: ?*wl.Buffer = null;
                if (state.width > 0 and state.height > 0) {
                    next = try windowBuffer(shm, xdg_surface, state.width, state.height);
                    surface.attach(next, 0, 0);
                    surface.damageBuffer(0, 0, std.math.maxInt(i32), std.math.maxInt(i32));
                    step("hold resized {d}x{d}", .{ state.width, state.height });
                }
                surface.commit();
                if (next) |n| {
                    if (prev) |p| p.destroy();
                    prev = n;
                }
            }
            return;
        }

        // With a tiling config the compositor resizes the window after map:
        // ack that configure and commit a buffer of the requested size.
        if (std.c.getenv("RAYWM_TEST_RESIZE") != null) {
            while (state.width == 0 or state.serial == 0 or !state.configured) {
                if (display.dispatch() != .SUCCESS) return error.DispatchFailed;
            }
            state.configured = false;
            state.frame_done = false;
            xdg_surface.ackConfigure(state.serial);
            const resized = try windowBuffer(shm, xdg_surface, state.width, state.height);
            defer resized.destroy();
            const cb = try surface.frame();
            cb.setListener(*State, frameListener, &state);
            surface.attach(resized, 0, 0);
            surface.damageBuffer(0, 0, std.math.maxInt(i32), std.math.maxInt(i32));
            surface.commit();
            while (!state.frame_done) {
                if (display.dispatch() != .SUCCESS) return error.DispatchFailed;
            }
            step("round {d} resized {d}x{d}", .{ round, state.width, state.height });
        }
        toplevel.destroy();
        if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
    }
    xdg_surface.destroy();
    surface.destroy();
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
    step("destroyed", .{});
}

/// RAYWM_TEST_LAYER=1: a 30 px top panel with an exclusive zone. Stays mapped until the
/// compositor goes away.
fn panel(display: *wl.Display, shm: *wl.Shm, compositor: *wl.Compositor, layer_shell: *zwlr.LayerShellV1, globals: *Globals) !void {
    var state: State = .{};
    const surface = try compositor.createSurface();
    // RAYWM_TEST_LAYER_LEVEL=overlay: a 30 px bar at the bottom of the
    // overlay layer instead, without an exclusive zone.
    const overlay = if (std.c.getenv("RAYWM_TEST_LAYER_LEVEL")) |l| std.mem.eql(u8, std.mem.span(l), "overlay") else false;
    const layer = try layer_shell.getLayerSurface(surface, null, if (overlay) .overlay else .top, "raywm-test-panel");
    layer.setListener(*State, layerListener, &state);
    layer.setAnchor(.{ .top = !overlay, .bottom = overlay, .left = true, .right = true });
    layer.setSize(0, 30);
    if (!overlay) layer.setExclusiveZone(30);
    // RAYWM_TEST_LAYER_KBD: a launcher-like panel that grabs the keyboard
    // (=on_demand: one that takes it only when chosen).
    if (std.c.getenv("RAYWM_TEST_LAYER_KBD")) |k|
        layer.setKeyboardInteractivity(if (std.mem.eql(u8, std.mem.span(k), "on_demand")) .on_demand else .exclusive);
    var use: SeatUse = .{ .seat = globals.seat orelse return error.NoSeat, .surface = surface, .layer = layer };
    use.listen(globals);
    surface.commit();
    while (!state.configured) {
        if (display.dispatch() != .SUCCESS) return error.DispatchFailed;
    }
    layer.ackConfigure(state.serial);
    step("layer configured {d}x{d}", .{ state.width, state.height });
    const buffer = try makeBuffer(shm, state.width, state.height);
    const frame = try surface.frame();
    frame.setListener(*State, frameListener, &state);
    surface.attach(buffer, 0, 0);
    surface.commit();
    while (!state.frame_done) {
        if (display.dispatch() != .SUCCESS) return error.DispatchFailed;
    }
    step("layer frame done", .{});
    while (display.dispatch() == .SUCCESS) {}
}

fn layerListener(_: *zwlr.LayerSurfaceV1, event: zwlr.LayerSurfaceV1.Event, state: *State) void {
    switch (event) {
        .configure => |c| {
            state.serial = c.serial;
            state.width = @intCast(c.width);
            state.height = @intCast(c.height);
            state.configured = true;
        },
        .closed => {},
    }
}

fn seatListener(_: *wl.Seat, event: wl.Seat.Event, g: *Globals) void {
    switch (event) {
        .capabilities => |c| {
            g.seat_caps = c.capabilities;
            if (g.seat_use) |use| applyCaps(use, c.capabilities);
        },
        else => {},
    }
}

/// Devices may only be requested once the seat has them.
fn applyCaps(use: *SeatUse, caps: wl.Seat.Capability) void {
    const seat = use.seat;
    const wants_pointer = std.c.getenv("RAYWM_TEST_CSD_MOVE") != null or std.c.getenv("RAYWM_TEST_PTR") != null or use.popup != null;
    if (caps.pointer and use.pointer == null and use.toplevel != null and wants_pointer) {
        use.pointer = seat.getPointer() catch return;
        use.pointer.?.setListener(*SeatUse, pointerListener, use);
    }
    // wlroots makes a wl_keyboard inert when the seat loses its
    // keyboard (the test driver exits): drop it, ask again later.
    if (!caps.keyboard) if (use.keyboard) |k| {
        k.destroy();
        use.keyboard = null;
    };
    if (caps.keyboard and use.keyboard == null and std.c.getenv("RAYWM_TEST_KBD") != null) {
        use.keyboard = seat.getKeyboard() catch return;
        use.keyboard.?.setListener(*SeatUse, keyboardListener, use);
    }
}

fn pointerListener(_: *wl.Pointer, event: wl.Pointer.Event, use: *SeatUse) void {
    switch (event) {
        .enter => |e| {
            use.ptr_on = e.surface;
            const on_popup = use.popup != null and e.surface == use.popup.?.surface;
            if (std.c.getenv("RAYWM_TEST_PTR") != null) step("ptr enter {s}", .{if (on_popup) "popup" else "window"});
            if (on_popup) if (use.toplevel) |t| {
                use.popup.?.race(t);
                use.toplevel = null; // destroyed by race()
            };
        },
        .leave => use.ptr_on = null,
        .button => |b| {
            const on_popup = use.popup != null and use.ptr_on != null and use.ptr_on == use.popup.?.surface;
            if (std.c.getenv("RAYWM_TEST_PTR") != null)
                step("ptr button {d} {s} {s}", .{ b.button, @tagName(b.state), if (on_popup) "popup" else "window" });
            if (b.button == 0x110 and b.state == .pressed and std.c.getenv("RAYWM_TEST_CSD_MOVE") != null) if (use.toplevel) |t| {
                t.move(use.seat, b.serial);
                step("csd move requested", .{});
            };
        },
        else => {},
    }
}

/// RAYWM_TEST_POPUP: a 60x60 popup at (190,140) of the held window, i.e.
/// partly outside a 200x150 window. When the
/// pointer enters it, the client destroys the toplevel while the popup is
/// still open and, before it can have seen popup_done, opens a nested popup
/// on that popup (a legal race: the client did not know the parent died).
const PopupTest = struct {
    display: *wl.Display,
    wm_base: *xdg.WmBase,
    compositor: *wl.Compositor,
    shm: *wl.Shm,
    surface: ?*wl.Surface = null,
    xdg_surface: ?*xdg.Surface = null,
    state: State = .{},

    fn positioner(pt: *PopupTest) !*xdg.Positioner {
        const pos = try pt.wm_base.createPositioner();
        pos.setSize(60, 60);
        pos.setAnchorRect(190, 140, 1, 1);
        pos.setAnchor(.top_left);
        pos.setGravity(.bottom_right);
        return pos;
    }

    fn open(pt: *PopupTest, parent: *xdg.Surface) !void {
        const surface = try pt.compositor.createSurface();
        const xs = try pt.wm_base.getXdgSurface(surface);
        pt.surface = surface;
        pt.xdg_surface = xs;
        xs.setListener(*State, xdgSurfaceListener, &pt.state);
        const pos = try pt.positioner();
        const popup = try xs.getPopup(parent, pos);
        pos.destroy();
        popup.setListener(?*anyopaque, popupListener, null);
        surface.commit();
        while (!pt.state.configured) {
            if (pt.display.dispatch() != .SUCCESS) return error.DispatchFailed;
        }
        xs.ackConfigure(pt.state.serial);
        const buffer = try makeBuffer(pt.shm, 60, 60);
        const frame = try surface.frame();
        frame.setListener(*State, frameListener, &pt.state);
        surface.attach(buffer, 0, 0);
        surface.damageBuffer(0, 0, 60, 60);
        surface.commit();
        while (!pt.state.frame_done) {
            if (pt.display.dispatch() != .SUCCESS) return error.DispatchFailed;
        }
        step("popup mapped", .{});
    }

    fn race(pt: *PopupTest, toplevel: *xdg.Toplevel) void {
        toplevel.destroy();
        const s = pt.compositor.createSurface() catch return;
        const xs = pt.wm_base.getXdgSurface(s) catch return;
        const pos = pt.positioner() catch return;
        const nested = xs.getPopup(pt.xdg_surface.?, pos) catch return;
        pos.destroy();
        nested.setListener(?*anyopaque, popupListener, null);
        s.commit();
        _ = pt.display.flush();
        step("popup race sent", .{});
    }
};

fn popupListener(_: *xdg.Popup, event: xdg.Popup.Event, _: ?*anyopaque) void {
    switch (event) {
        .popup_done => step("popup done", .{}),
        else => {},
    }
}

fn keyboardListener(_: *wl.Keyboard, event: wl.Keyboard.Event, use: *SeatUse) void {
    switch (event) {
        .keymap => |k| {
            _ = posix.system.close(k.fd);
            step("kbd keymap", .{});
        },
        .enter => |e| {
            var buf: [256]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            for (e.keys.slice(u32)) |k| w.print(" {d}", .{k}) catch {};
            step("kbd enter{s}", .{w.buffered()});
        },
        .leave => step("kbd leave", .{}),
        .key => |k| {
            step("kbd key {d} {s}", .{ k.key, @tagName(k.state) });
            if (use.layer) |layer| if (k.key == 87 and k.state == .pressed) {
                layer.setKeyboardInteractivity(.none);
                use.surface.commit();
                step("layer kbd none", .{});
            };
        },
        else => {},
    }
}

/// A window's content of w x h. RAYWM_TEST_SHADOW=N adds an N pixel
/// magenta margin around it, outside the window geometry, like client-side
/// shadows (the window geometry is set to the content).
fn windowBuffer(shm: *wl.Shm, xdg_surface: *xdg.Surface, w: i32, h: i32) !*wl.Buffer {
    const m: i32 = if (std.c.getenv("RAYWM_TEST_SHADOW")) |v| std.fmt.parseInt(i32, std.mem.span(v), 10) catch 0 else 0;
    if (m > 0) xdg_surface.setWindowGeometry(m, m, w, h);
    return makeBufferMargin(shm, w, h, m);
}

fn makeBuffer(shm: *wl.Shm, w: i32, h: i32) !*wl.Buffer {
    return makeBufferMargin(shm, w, h, 0);
}

fn makeBufferMargin(shm: *wl.Shm, content_w: i32, content_h: i32, m: i32) !*wl.Buffer {
    const w = content_w + 2 * m;
    const h = content_h + 2 * m;
    const stride = w * 4;
    const size: usize = @intCast(stride * h);
    const fd = try posix.memfd_create("raywm-test", 0);
    defer _ = posix.system.close(fd);
    if (posix.errno(posix.system.ftruncate(fd, @intCast(size))) != .SUCCESS) return error.FtruncateFailed;
    const data = try posix.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
    defer posix.munmap(data);
    // RAYWM_TEST_PATTERN: opaque quadrants, top-left red, top-right green,
    // bottom-left blue, bottom-right white (checked in screenshots).
    if (std.c.getenv("RAYWM_TEST_PATTERN") != null) {
        const px = std.mem.bytesAsSlice(u32, data);
        const uw: usize = @intCast(w);
        for (px, 0..) |*p, i| {
            const x: i32 = @intCast(i % uw);
            const y: i32 = @intCast(i / uw);
            if (x < m or y < m or x >= w - m or y >= h - m) {
                p.* = 0xffff00ff; // shadow
                continue;
            }
            const right = x - m >= @divTrunc(content_w, 2);
            const bottom = y - m >= @divTrunc(content_h, 2);
            p.* = if (bottom) (if (right) 0xffffffff else 0xff0000ff) else if (right) 0xff00ff00 else 0xffff0000;
        }
    } else @memset(data, 0x80);
    const pool = try shm.createPool(fd, @intCast(size));
    defer pool.destroy();
    return pool.createBuffer(0, w, h, stride, .argb8888);
}

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, g: *Globals) void {
    switch (event) {
        .global => |global| {
            const name = std.mem.span(global.interface);
            if (std.mem.eql(u8, name, std.mem.span(wl.Compositor.interface.name))) {
                g.compositor = registry.bind(global.name, wl.Compositor, 4) catch return;
            } else if (std.mem.eql(u8, name, std.mem.span(wl.Shm.interface.name))) {
                g.shm = registry.bind(global.name, wl.Shm, 1) catch return;
            } else if (std.mem.eql(u8, name, std.mem.span(xdg.WmBase.interface.name))) {
                g.wm_base = registry.bind(global.name, xdg.WmBase, 2) catch return;
            } else if (std.mem.eql(u8, name, std.mem.span(wl.Seat.interface.name))) {
                const seat = registry.bind(global.name, wl.Seat, 1) catch return;
                seat.setListener(*Globals, seatListener, g);
                g.seat = seat;
            } else if (std.mem.eql(u8, name, std.mem.span(zwlr.LayerShellV1.interface.name))) {
                g.layer_shell = registry.bind(global.name, zwlr.LayerShellV1, 4) catch return;
            }
        },
        .global_remove => {},
    }
}

fn wmBaseListener(wm_base: *xdg.WmBase, event: xdg.WmBase.Event, _: ?*anyopaque) void {
    switch (event) {
        .ping => |ping| wm_base.pong(ping.serial),
    }
}

fn xdgSurfaceListener(_: *xdg.Surface, event: xdg.Surface.Event, state: *State) void {
    switch (event) {
        .configure => |c| {
            state.serial = c.serial;
            state.configured = true;
        },
    }
}

fn toplevelListener(_: *xdg.Toplevel, event: xdg.Toplevel.Event, state: *State) void {
    switch (event) {
        .configure => |c| {
            state.width = c.width;
            state.height = c.height;
            var active = false;
            for (c.states.slice(u32)) |s| active = active or s == @intFromEnum(xdg.Toplevel.State.activated);
            if (active != state.activated) step("{s}", .{if (active) "activated" else "deactivated"});
            state.activated = active;
        },
        .close => {},
    }
}

fn frameListener(cb: *wl.Callback, event: wl.Callback.Event, state: *State) void {
    switch (event) {
        .done => {
            cb.destroy();
            state.frame_done = true;
        },
    }
}
