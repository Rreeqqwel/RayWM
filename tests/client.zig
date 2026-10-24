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
const zwp = wayland.client.zwp;
const wp = wayland.client.wp;
const zxdg = wayland.client.zxdg;
const captures = @import("support/captures.zig");

/// Optional protocols (bound when the compositor has them), used by the
/// RAYWM_TEST_SINGLE_PIXEL, _FRACTIONAL, _PRESENTATION, _CURSOR_SHAPE,
/// _DECORATION and activation modes.
const Extras = struct {
    viewporter: ?*wp.Viewporter = null,
    single_pixel: ?*wp.SinglePixelBufferManagerV1 = null,
    fractional: ?*wp.FractionalScaleManagerV1 = null,
    presentation: ?*wp.Presentation = null,
    cursor_shape: ?*wp.CursorShapeManagerV1 = null,
    decoration: ?*zxdg.DecorationManagerV1 = null,
    activation: ?*xdg.ActivationV1 = null,
    /// Viewport of the window's surface (single-pixel mode).
    viewport: ?*wp.Viewport = null,
};
var extras: Extras = .{};

const Globals = struct {
    shm: ?*wl.Shm = null,
    compositor: ?*wl.Compositor = null,
    wm_base: ?*xdg.WmBase = null,
    subcompositor: ?*wl.Subcompositor = null,
    layer_shell: ?*zwlr.LayerShellV1 = null,
    seat: ?*wl.Seat = null,
    /// The seat's capabilities arrive right after binding, before any
    /// SeatUse exists: kept here and applied by SeatUse.listen().
    seat_caps: ?wl.Seat.Capability = null,
    seat_use: ?*SeatUse = null,
    idle_inhibit: ?*zwp.IdleInhibitManagerV1 = null,
    /// wl_outputs in the order they were announced.
    outputs: [8]?*wl.Output = @splat(null),
    n_outputs: usize = 0,
};

/// Seat use by a held window or panel:
/// - RAYWM_TEST_CSD_MOVE: a left press asks the compositor to start an
///   interactive move, like a client-side title bar does;
/// - RAYWM_TEST_CSD_RESIZE: a right press asks for an interactive resize
///   from the bottom-right corner;
/// - RAYWM_TEST_PTR: log every pointer event (enter, leave, motion with
///   surface-local coordinates, button) and the surface it is for: window,
///   sub (RAYWM_TEST_SUB), popup or layer;
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
    /// RAYWM_TEST_SUB: a 60x60 subsurface at (20,20) of the window.
    sub: ?*wl.Surface = null,
    /// RAYWM_TEST_POPUP_GRAB: serial of the right press that asked for a
    /// grabbing popup; opened by the main loop (not inside a listener).
    popup_request: ?u32 = null,
    /// Surface under the pointer, as last reported by wl_pointer.enter.
    ptr_on: ?*wl.Surface = null,
    /// The window's state, for RAYWM_TEST_REQUEST_KEYS (F9/F10 toggle
    /// fullscreen/maximized requests, F8 asks to be minimized).
    state: ?*State = null,
    /// RAYWM_TEST_TOKEN_TO: serial of the F7 press that asks for an
    /// activation token; requested by the main loop.
    token_request: ?u32 = null,
    token_enter_serial: u32 = 0,
    token_press_serial: u32 = 0,
    capture: ?*captures.Capture = null,

    /// What a pointer event's surface is, for the log.
    fn kind(use: *SeatUse, surface: ?*wl.Surface) []const u8 {
        const s = surface orelse return "gone";
        if (use.popup) |p| if (p.surface == s) return "popup";
        if (use.sub == s) return "sub";
        if (use.layer == null and s != use.surface) return "dialog";
        return if (use.layer != null) "layer" else "window";
    }

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
    /// Last fullscreen/maximized states received (logged on change).
    fullscreen: bool = false,
    maximized: bool = false,
    /// xdg-shell v6/v2/v7 states (logged on change).
    suspended: bool = false,
    tiled: bool = false,
    constrained: bool = false,
    /// Prefix of logged state changes ("" for the window, "child " ...).
    who: []const u8 = "",
    /// The compositor asked to close the window (RAYWM_TEST_CLOSE honours it).
    close_requested: bool = false,
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
    // wl_surface.enter arrives when the window is first shown on an output.
    surface.setListener(?*anyopaque, surfaceListener, null);
    // RAYWM_TEST_SINGLE_PIXEL=RRGGBB: the window is a single-pixel buffer
    // scaled to its size by a viewport.
    if (std.c.getenv("RAYWM_TEST_SINGLE_PIXEL") != null) {
        if (extras.viewporter == null or extras.single_pixel == null) return error.NoSinglePixel;
        extras.viewport = try extras.viewporter.?.getViewport(surface);
    }
    // RAYWM_TEST_FRACTIONAL: log the preferred fractional scale.
    if (std.c.getenv("RAYWM_TEST_FRACTIONAL") != null) {
        const fs = try (extras.fractional orelse return error.NoFractionalScale).getFractionalScale(surface);
        fs.setListener(?*anyopaque, fractionalListener, null);
    }
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
        toplevel.setTitle(if (std.c.getenv("RAYWM_TEST_TITLE")) |v| v else "raywm-test");
        toplevel.setAppId(if (std.c.getenv("RAYWM_TEST_APP_ID")) |v| v else "raywm-test");
        // Requests made before the initial commit (answered by the initial
        // configure), and size limits.
        if (std.c.getenv("RAYWM_TEST_FULLSCREEN_OUTPUT")) |v| {
            const i = std.fmt.parseInt(usize, std.mem.span(v), 10) catch 0;
            toplevel.setFullscreen(if (i < globals.n_outputs) globals.outputs[i] else null);
        } else if (std.c.getenv("RAYWM_TEST_FULLSCREEN") != null) toplevel.setFullscreen(null);
        if (std.c.getenv("RAYWM_TEST_MAXIMIZED") != null) toplevel.setMaximized();
        if (sizeEnv("RAYWM_TEST_MIN")) |m| toplevel.setMinSize(m[0], m[1]);
        if (sizeEnv("RAYWM_TEST_MAX")) |m| toplevel.setMaxSize(m[0], m[1]);
        // RAYWM_TEST_DECORATION=server|client|unset: an xdg-decoration
        // object asking for that mode (unset: no preference).
        var decoration: ?*zxdg.ToplevelDecorationV1 = null;
        defer if (decoration) |d| d.destroy();
        if (std.c.getenv("RAYWM_TEST_DECORATION")) |v| {
            const d = try (extras.decoration orelse return error.NoDecorationManager).getToplevelDecoration(toplevel);
            d.setListener(?*anyopaque, decorationListener, null);
            const mode = std.mem.span(v);
            if (std.mem.eql(u8, mode, "server")) d.setMode(.server_side) else if (std.mem.eql(u8, mode, "client")) d.setMode(.client_side);
            decoration = d;
        }
        surface.attach(null, 0, 0);
        surface.commit();

        while (!state.configured) {
            if (display.dispatch() != .SUCCESS) return error.DispatchFailed;
        }
        xdg_surface.ackConfigure(state.serial);
        step("round {d} configured {d}x{d}", .{ round, state.width, state.height });
        const natural = sizeEnv("RAYWM_TEST_SIZE") orelse .{ 200, 150 };
        const w: i32 = if (state.width > 0) state.width else natural[0];
        const h: i32 = if (state.height > 0) state.height else natural[1];
        state.configured = false; // detect the next configure
        state.width = 0;
        const buffer = try windowBuffer(shm, xdg_surface, w, h);
        defer buffer.destroy();

        const frame = try surface.frame();
        frame.setListener(*State, frameListener, &state);
        // RAYWM_TEST_PRESENTATION: feedback for the first content update.
        if (round == 0 and std.c.getenv("RAYWM_TEST_PRESENTATION") != null) {
            const fb = try (extras.presentation orelse return error.NoPresentation).feedback(surface);
            fb.setListener(?*anyopaque, presentationListener, null);
        }
        surface.attach(buffer, 0, 0);
        surface.damageBuffer(0, 0, std.math.maxInt(i32), std.math.maxInt(i32));
        surface.commit();
        while (!state.frame_done) {
            if (display.dispatch() != .SUCCESS) return error.DispatchFailed;
        }
        step("round {d} frame done", .{round});
        if (std.c.getenv("RAYWM_TEST_HOLD") != null) {
            var use: SeatUse = .{ .seat = globals.seat orelse return error.NoSeat, .surface = surface, .toplevel = toplevel, .state = &state };
            var popup_test: PopupTest = .{ .display = display, .wm_base = wm_base, .compositor = compositor, .shm = shm };
            if (std.c.getenv("RAYWM_TEST_POPUP") != null) {
                try popup_test.open(xdg_surface);
                use.popup = &popup_test;
            }
            if (std.c.getenv("RAYWM_TEST_SUB") != null) {
                const sub_surface = try compositor.createSurface();
                const sub = try (globals.subcompositor orelse return error.NoSubcompositor).getSubsurface(sub_surface, surface);
                sub.setPosition(20, 20);
                const sub_buffer = try makeBuffer(shm, 60, 60);
                sub_surface.attach(sub_buffer, 0, 0);
                sub_surface.damageBuffer(0, 0, 60, 60);
                sub_surface.commit();
                surface.commit(); // a synchronized subsurface appears with its parent's commit
                use.sub = sub_surface;
                step("subsurface mapped", .{});
            }
            use.listen(&globals);
            var capture: captures.Capture = undefined;
            try capture.init(compositor, surface, use.seat, use.pointer);
            use.capture = &capture;
            // RAYWM_TEST_IDLE_INHIBIT: keeps the session from going idle
            // while this window is visible.
            if (std.c.getenv("RAYWM_TEST_IDLE_INHIBIT") != null) {
                _ = try (globals.idle_inhibit orelse return error.NoIdleInhibit).createInhibitor(surface);
                _ = display.flush();
                step("idle inhibitor created", .{});
            }
            // RAYWM_TEST_CHILD: a second toplevel, a dialog of this one.
            var child: Child = .{ .shm = shm };
            if (std.c.getenv("RAYWM_TEST_CHILD") != null) try child.open(display, compositor, wm_base, toplevel);
            var grandchild: Child = .{ .shm = shm, .state = .{ .who = "grandchild " } };
            if (std.c.getenv("RAYWM_TEST_REPARENT") != null) {
                try grandchild.open(display, compositor, wm_base, child.toplevel orelse return error.NoParent);
            }
            // Keep the window (acking every configure) until the compositor
            // goes away. The previous buffer is released after each commit.
            var prev: ?*wl.Buffer = null;
            defer if (prev) |p| p.destroy();
            while (true) {
                if (child.toplevel != null and child.state.configured) try child.ackAndDraw();
                if (grandchild.toplevel != null and grandchild.state.configured) try grandchild.ackAndDraw();
                if (std.c.getenv("RAYWM_TEST_REPARENT")) |path| {
                    if (std.c.access(path, 0) == 0) {
                        _ = std.c.unlink(path);
                        child.toplevel.?.setParent(null);
                        step("child detached", .{});
                    }
                }
                if (use.popup_request) |serial| {
                    use.popup_request = null;
                    try popup_test.openWith(xdg_surface, .{ .seat = use.seat, .serial = serial });
                    use.popup = &popup_test;
                    step("grabbing popup mapped", .{});
                }
                if (use.token_request) |serial| {
                    const go = std.c.getenv("RAYWM_TEST_TOKEN_GO");
                    if (go == null or std.c.access(go.?, 0) == 0) {
                        if (go) |path| _ = std.c.unlink(path);
                        use.token_request = null;
                        try requestToken(surface, .{ .seat = use.seat, .serial = serial }, .{ .write_to = std.c.getenv("RAYWM_TEST_TOKEN_TO").? });
                    }
                }
                try pollActivation(surface);
                if (state.close_requested and std.c.getenv("RAYWM_TEST_CLOSE") != null) {
                    step("closing", .{});
                    return;
                }
                // A configure may already have arrived while waiting above.
                if (!state.configured and !(child.toplevel != null and child.state.configured)) {
                    if (activationFiles() or std.c.getenv("RAYWM_TEST_REPARENT") != null) {
                        dispatchTimeout(display, 50) catch break;
                    } else if (display.dispatch() != .SUCCESS) break;
                    continue;
                }
                if (!state.configured) continue;
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
        // RAYWM_TEST_CLOSE_WHEN=<path>: stay mapped (dispatching) until the
        // test creates that file, at most 10 s, so a test can close this
        // window only after another client reached an observable state.
        if (std.c.getenv("RAYWM_TEST_CLOSE_WHEN")) |path| {
            var waited: u32 = 0;
            while (std.c.access(path, 0) != 0) : (waited += 1) {
                if (waited == 200) return error.CloseSignalTimeout;
                try dispatchTimeout(display, 50);
            }
            step("round {d} close signalled", .{round});
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
    if (std.c.getenv("RAYWM_TEST_LAYER_EDGE") != null) {
        // A 30x200 panel in the top-left corner whose exclusive zone is on
        // the left edge (layer-shell v5: a corner alone names no edge).
        if (layer_shell.getVersion() < 5) return error.NoLayerShellV5;
        layer.setAnchor(.{ .top = true, .left = true });
        layer.setSize(30, 200);
        layer.setExclusiveZone(30);
        layer.setExclusiveEdge(.{ .left = true });
    } else {
        layer.setAnchor(.{ .top = !overlay, .bottom = overlay, .left = true, .right = true });
        layer.setSize(0, 30);
        if (!overlay) layer.setExclusiveZone(30);
    }
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
    if (caps.pointer and use.pointer == null and (use.toplevel != null or use.layer != null) and wants_pointer) {
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

fn pointerListener(pointer: *wl.Pointer, event: wl.Pointer.Event, use: *SeatUse) void {
    const log_ptr = std.c.getenv("RAYWM_TEST_PTR") != null;
    switch (event) {
        .enter => |e| {
            use.token_enter_serial = e.serial;
            use.ptr_on = e.surface;
            // RAYWM_TEST_CURSOR_SHAPE: a named cursor (wp_cursor_shape_v1).
            if (std.c.getenv("RAYWM_TEST_CURSOR_SHAPE") != null) if (extras.cursor_shape) |m| {
                if (m.getPointer(pointer)) |dev| {
                    dev.setShape(e.serial, .grab);
                    step("cursor shape set", .{});
                } else |_| {}
            };
            const on_popup = use.popup != null and e.surface == use.popup.?.surface;
            if (log_ptr) step("ptr enter {s} at {d},{d}", .{ use.kind(e.surface), e.surface_x.toInt(), e.surface_y.toInt() });
            if (on_popup and std.c.getenv("RAYWM_TEST_POPUP") != null and std.c.getenv("RAYWM_TEST_POPUP_KILL") == null) if (use.toplevel) |t| {
                use.popup.?.race(t);
                use.toplevel = null; // destroyed by race()
            };
        },
        .leave => |e| {
            if (log_ptr) step("ptr leave {s}", .{use.kind(e.surface)});
            use.ptr_on = null;
        },
        .motion => |m| if (log_ptr) step("ptr motion {d},{d}", .{ m.surface_x.toInt(), m.surface_y.toInt() }),
        .button => |b| {
            const on_popup = use.popup != null and use.ptr_on != null and use.ptr_on == use.popup.?.surface;
            if (log_ptr) step("ptr button {d} {s} {s}", .{ b.button, @tagName(b.state), use.kind(use.ptr_on) });
            if (b.button == 0x112 and b.state == .pressed and tokenMode("pointer") and std.c.getenv("RAYWM_TEST_TOKEN_TO") != null)
                use.token_request = b.serial;
            if (b.button == 0x110 and b.state == .pressed and std.c.getenv("RAYWM_TEST_CSD_MOVE") != null) if (use.toplevel) |t| {
                t.move(use.seat, b.serial);
                step("csd move requested", .{});
            };
            if (b.button == 0x111 and b.state == .pressed and std.c.getenv("RAYWM_TEST_CSD_RESIZE") != null) if (use.toplevel) |t| {
                t.resize(use.seat, b.serial, .bottom_right);
                step("csd resize requested", .{});
            };
            if (b.button == 0x111 and b.state == .pressed and use.popup == null and std.c.getenv("RAYWM_TEST_POPUP_GRAB") != null)
                use.popup_request = b.serial;
            // RAYWM_TEST_POPUP_KILL: the popup goes away while the button
            // that was pressed on it is still held.
            if (on_popup and b.state == .pressed and std.c.getenv("RAYWM_TEST_POPUP_KILL") != null) {
                use.ptr_on = null;
                use.popup.?.kill();
            }
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
    popup: ?*xdg.Popup = null,
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
        return pt.openWith(parent, null);
    }

    /// With `grab`, the popup takes an xdg_popup grab (wlroots routes the
    /// pointer to this client's surfaces until the popup is dismissed).
    fn openWith(pt: *PopupTest, parent: *xdg.Surface, grab: ?struct { seat: *wl.Seat, serial: u32 }) !void {
        const surface = try pt.compositor.createSurface();
        const xs = try pt.wm_base.getXdgSurface(surface);
        pt.surface = surface;
        pt.xdg_surface = xs;
        xs.setListener(*State, xdgSurfaceListener, &pt.state);
        const pos = try pt.positioner();
        const popup = try xs.getPopup(parent, pos);
        pos.destroy();
        popup.setListener(?*anyopaque, popupListener, null);
        pt.popup = popup;
        if (grab) |g| popup.grab(g.seat, g.serial);
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

    /// Destroys the popup (role, xdg_surface, surface).
    fn kill(pt: *PopupTest) void {
        if (pt.popup) |p| p.destroy();
        if (pt.xdg_surface) |x| x.destroy();
        if (pt.surface) |s| s.destroy();
        pt.popup = null;
        pt.xdg_surface = null;
        pt.surface = null;
        _ = pt.display.flush();
        step("popup destroyed", .{});
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
            use.token_enter_serial = e.serial;
            var buf: [256]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            for (e.keys.slice(u32)) |k| w.print(" {d}", .{k}) catch {};
            step("kbd enter{s}", .{w.buffered()});
        },
        .leave => step("kbd leave", .{}),
        .repeat_info => |r| step("kbd repeat {d} {d}", .{ r.rate, r.delay }),
        .key => |k| {
            if (k.state == .pressed) if (use.capture) |capture| capture.key(k.key);
            step("kbd key {d} {s}", .{ k.key, @tagName(k.state) });
            if (k.state == .pressed and k.key == 63 and std.c.getenv("RAYWM_TEST_METADATA_KEYS") != null) if (use.toplevel) |t| {
                t.setTitle("Changed title");
                t.setAppId("changed-app");
                step("metadata changed", .{});
            };
            // RAYWM_TEST_REQUEST_KEYS: F9 toggles a fullscreen request, F10
            // a maximize request.
            if (k.state == .pressed and std.c.getenv("RAYWM_TEST_REQUEST_KEYS") != null) if (use.toplevel) |t| if (use.state) |st| {
                if (k.key == 67) {
                    if (st.fullscreen) t.unsetFullscreen() else t.setFullscreen(null);
                    step("fullscreen requested {s}", .{if (st.fullscreen) "off" else "on"});
                } else if (k.key == 68) {
                    if (st.maximized) t.unsetMaximized() else t.setMaximized();
                    step("maximize requested {s}", .{if (st.maximized) "off" else "on"});
                } else if (k.key == 66) {
                    t.setMinimized();
                    step("minimize requested", .{});
                }
            };
            // RAYWM_TEST_TOKEN_TO: F7 asks for an activation token for this
            // key press (as a terminal does when a link is clicked).
            if (k.state == .pressed and std.c.getenv("RAYWM_TEST_TOKEN_TO") != null) {
                if (k.key == 65) {
                    use.token_press_serial = k.serial;
                    use.token_request = if (tokenMode("enter")) use.token_enter_serial else k.serial;
                    step("input token queued", .{});
                } else if (k.key == 66 and tokenMode("reuse")) {
                    // F8 deliberately reuses the F7 serial, rather than
                    // the new key's serial: one input grants one token.
                    use.token_request = use.token_press_serial;
                }
            }
            if (use.layer) |layer| if (k.key == 87 and k.state == .pressed) {
                layer.setKeyboardInteractivity(.none);
                use.surface.commit();
                step("layer kbd none", .{});
            };
        },
        else => {},
    }
}

/// RAYWM_TEST_GEOMETRY_ONCE: the bad geometry is set with the first buffer only.
var bad_geometry_set = false;

/// A window's content of w x h. RAYWM_TEST_SHADOW=N adds an N pixel
/// magenta margin around it, outside the window geometry, like client-side
/// shadows (the window geometry is set to the content).
fn windowBuffer(shm: *wl.Shm, xdg_surface: *xdg.Surface, w: i32, h: i32) !*wl.Buffer {
    if (extras.viewport) |vp| {
        const hex = std.mem.span(std.c.getenv("RAYWM_TEST_SINGLE_PIXEL").?);
        const rgb = std.fmt.parseUnsigned(u32, hex, 16) catch 0xff0000;
        const ch = struct {
            fn f(v: u32) u32 {
                return (v & 0xff) * 0x01010101;
            }
        }.f;
        vp.setDestination(w, h);
        return extras.single_pixel.?.createU32RgbaBuffer(ch(rgb >> 16), ch(rgb >> 8), ch(rgb), 0xffffffff);
    }
    const m: i32 = if (std.c.getenv("RAYWM_TEST_SHADOW")) |v| std.fmt.parseInt(i32, std.mem.span(v), 10) catch 0 else 0;
    if (m > 0) xdg_surface.setWindowGeometry(m, m, w, h);
    // RAYWM_TEST_BAD_GEOMETRY=X,Y,W,H: a window geometry that does not fit
    // the buffer (xdg-shell clamps it to the surface's extents).
    if (std.c.getenv("RAYWM_TEST_BAD_GEOMETRY")) |v| if (!(std.c.getenv("RAYWM_TEST_GEOMETRY_ONCE") != null and bad_geometry_set)) {
        bad_geometry_set = true;
        var it = std.mem.splitScalar(u8, std.mem.span(v), ',');
        var n: [4]i32 = .{ 0, 0, 1, 1 };
        for (&n) |*x| x.* = std.fmt.parseInt(i32, it.next() orelse "1", 10) catch 1;
        xdg_surface.setWindowGeometry(n[0], n[1], n[2], n[3]);
    };
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
            captures.bind(registry, global.name, std.mem.span(global.interface));
            const name = std.mem.span(global.interface);
            if (std.mem.eql(u8, name, std.mem.span(wl.Compositor.interface.name))) {
                g.compositor = registry.bind(global.name, wl.Compositor, 4) catch return;
            } else if (std.mem.eql(u8, name, std.mem.span(wl.Shm.interface.name))) {
                g.shm = registry.bind(global.name, wl.Shm, 1) catch return;
            } else if (std.mem.eql(u8, name, std.mem.span(xdg.WmBase.interface.name))) {
                // RAYWM_TEST_XDG_VERSION=N: bind version N (default 2).
                const want: u32 = if (std.c.getenv("RAYWM_TEST_XDG_VERSION")) |v| std.fmt.parseInt(u32, std.mem.span(v), 10) catch 2 else 2;
                g.wm_base = registry.bind(global.name, xdg.WmBase, @min(global.version, want)) catch return;
            } else if (std.mem.eql(u8, name, std.mem.span(zxdg.DecorationManagerV1.interface.name))) {
                extras.decoration = registry.bind(global.name, zxdg.DecorationManagerV1, 1) catch return;
            } else if (std.mem.eql(u8, name, std.mem.span(xdg.ActivationV1.interface.name))) {
                extras.activation = registry.bind(global.name, xdg.ActivationV1, 1) catch return;
            } else if (std.mem.eql(u8, name, std.mem.span(wl.Subcompositor.interface.name))) {
                g.subcompositor = registry.bind(global.name, wl.Subcompositor, 1) catch return;
            } else if (std.mem.eql(u8, name, std.mem.span(wl.Seat.interface.name))) {
                // v4: wl_keyboard.repeat_info.
                const seat = registry.bind(global.name, wl.Seat, @min(global.version, 4)) catch return;
                seat.setListener(*Globals, seatListener, g);
                g.seat = seat;
            } else if (std.mem.eql(u8, name, std.mem.span(zwlr.LayerShellV1.interface.name))) {
                // RAYWM_TEST_LAYER_EDGE needs v5 (set_exclusive_edge).
                const want: u32 = if (std.c.getenv("RAYWM_TEST_LAYER_EDGE") != null) 5 else 4;
                g.layer_shell = registry.bind(global.name, zwlr.LayerShellV1, @min(global.version, want)) catch return;
            } else if (std.mem.eql(u8, name, std.mem.span(wp.Viewporter.interface.name))) {
                extras.viewporter = registry.bind(global.name, wp.Viewporter, 1) catch return;
            } else if (std.mem.eql(u8, name, std.mem.span(wp.SinglePixelBufferManagerV1.interface.name))) {
                extras.single_pixel = registry.bind(global.name, wp.SinglePixelBufferManagerV1, 1) catch return;
            } else if (std.mem.eql(u8, name, std.mem.span(wp.FractionalScaleManagerV1.interface.name))) {
                extras.fractional = registry.bind(global.name, wp.FractionalScaleManagerV1, 1) catch return;
            } else if (std.mem.eql(u8, name, std.mem.span(wp.Presentation.interface.name))) {
                extras.presentation = registry.bind(global.name, wp.Presentation, 1) catch return;
            } else if (std.mem.eql(u8, name, std.mem.span(wp.CursorShapeManagerV1.interface.name))) {
                extras.cursor_shape = registry.bind(global.name, wp.CursorShapeManagerV1, 1) catch return;
            } else if (std.mem.eql(u8, name, std.mem.span(zwp.IdleInhibitManagerV1.interface.name))) {
                g.idle_inhibit = registry.bind(global.name, zwp.IdleInhibitManagerV1, 1) catch return;
            } else if (std.mem.eql(u8, name, std.mem.span(wl.Output.interface.name))) {
                // Bound so that wl_surface.enter can name the output, and
                // for fullscreen requests on a given output.
                const o = registry.bind(global.name, wl.Output, @min(global.version, 2)) catch return;
                o.setListener(?*anyopaque, outputListener, null);
                if (g.n_outputs < g.outputs.len) {
                    g.outputs[g.n_outputs] = o;
                    g.n_outputs += 1;
                }
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
            var fullscreen = false;
            var maximized = false;
            var suspended = false;
            var tiled = false;
            var constrained = false;
            const S = xdg.Toplevel.State;
            for (c.states.slice(u32)) |st| {
                active = active or st == @intFromEnum(S.activated);
                fullscreen = fullscreen or st == @intFromEnum(S.fullscreen);
                maximized = maximized or st == @intFromEnum(S.maximized);
                suspended = suspended or st == @intFromEnum(S.suspended);
                tiled = tiled or (st >= @intFromEnum(S.tiled_left) and st <= @intFromEnum(S.tiled_bottom));
                constrained = constrained or (st >= @intFromEnum(S.constrained_left) and st <= @intFromEnum(S.constrained_bottom));
            }
            if (active != state.activated) step("{s}{s}", .{ state.who, if (active) "activated" else "deactivated" });
            if (fullscreen != state.fullscreen) step("{s}fullscreen {s} {d}x{d}", .{ state.who, if (fullscreen) "on" else "off", c.width, c.height });
            if (maximized != state.maximized) step("{s}maximized {s} {d}x{d}", .{ state.who, if (maximized) "on" else "off", c.width, c.height });
            if (suspended != state.suspended) step("{s}suspended {s}", .{ state.who, if (suspended) "on" else "off" });
            if (tiled != state.tiled) step("{s}tiled {s}", .{ state.who, if (tiled) "on" else "off" });
            if (constrained != state.constrained) step("{s}constrained {s}", .{ state.who, if (constrained) "on" else "off" });
            state.activated = active;
            state.fullscreen = fullscreen;
            state.maximized = maximized;
            state.suspended = suspended;
            state.tiled = tiled;
            state.constrained = constrained;
        },
        .configure_bounds => |b| step("{s}bounds {d}x{d}", .{ state.who, b.width, b.height }),
        .wm_capabilities => |c| {
            var buf: [128]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            for (c.capabilities.slice(u32)) |cap| {
                const name = std.enums.tagName(xdg.Toplevel.WmCapabilities, @enumFromInt(cap)) orelse "?";
                w.print(" {s}", .{name}) catch {};
            }
            step("{s}capabilities{s}", .{ state.who, w.buffered() });
        },
        .close => {
            step("close requested", .{});
            state.close_requested = true;
        },
    }
}

/// "WxH" from an environment variable.
fn sizeEnv(name: [*:0]const u8) ?[2]i32 {
    const v = std.mem.span(std.c.getenv(name) orelse return null);
    const x = std.mem.indexOfScalar(u8, v, 'x') orelse return null;
    const w = std.fmt.parseInt(i32, v[0..x], 10) catch return null;
    const h = std.fmt.parseInt(i32, v[x + 1 ..], 10) catch return null;
    return .{ w, h };
}

/// RAYWM_TEST_CHILD: a dialog (xdg_toplevel.set_parent) of the window,
/// 120x90 unless configured otherwise. Logs its state as "child ...".
const Child = struct {
    shm: *wl.Shm,
    surface: ?*wl.Surface = null,
    xdg_surface: ?*xdg.Surface = null,
    toplevel: ?*xdg.Toplevel = null,
    state: State = .{ .who = "child " },
    buffer: ?*wl.Buffer = null,

    fn open(c: *Child, display: *wl.Display, compositor: *wl.Compositor, wm_base: *xdg.WmBase, parent: *xdg.Toplevel) !void {
        const surface = try compositor.createSurface();
        const xs = try wm_base.getXdgSurface(surface);
        xs.setListener(*State, xdgSurfaceListener, &c.state);
        const t = try xs.getToplevel();
        t.setListener(*State, toplevelListener, &c.state);
        t.setTitle("raywm-test-child");
        t.setAppId("raywm-test-child");
        t.setParent(parent);
        c.surface = surface;
        c.xdg_surface = xs;
        c.toplevel = t;
        surface.commit();
        while (!c.state.configured) {
            if (display.dispatch() != .SUCCESS) return error.DispatchFailed;
        }
        try c.ackAndDraw();
        step("child mapped", .{});
    }

    fn ackAndDraw(c: *Child) !void {
        c.state.configured = false;
        c.xdg_surface.?.ackConfigure(c.state.serial);
        const w: i32 = if (c.state.width > 0) c.state.width else 120;
        const h: i32 = if (c.state.height > 0) c.state.height else 90;
        const next = try makeBuffer(c.shm, w, h);
        c.surface.?.attach(next, 0, 0);
        c.surface.?.damageBuffer(0, 0, w, h);
        c.surface.?.commit();
        if (c.buffer) |b| b.destroy();
        c.buffer = next;
    }
};

fn decorationListener(_: *zxdg.ToplevelDecorationV1, event: zxdg.ToplevelDecorationV1.Event, _: ?*anyopaque) void {
    switch (event) {
        .configure => |c| step("decoration {s}", .{@tagName(c.mode)}),
    }
}

// ---- xdg-activation --------------------------------------------------------
//
// RAYWM_TEST_TOKEN_TO=<file>: F7 (keyboard, with RAYWM_TEST_KBD) gets a
//   token for that key press and this surface, and writes it to <file>.
// RAYWM_TEST_ACTIVATE_FROM=<file>: once <file> exists, reads a token from it
//   (and deletes it) and asks to activate this window with it.
// RAYWM_TEST_ACTIVATE_SELF=<file>: once <file> exists (and is deleted),
//   gets a token without any input event and activates this window with it.
// RAYWM_TEST_TOKEN_MODE=enter|no-surface|reuse: deliberately weaken the
//   request, or let F8 request a second token from the previous F7 serial.
// RAYWM_TEST_TOKEN_GO=<file>: defer a queued request until this file exists.
// RAYWM_TEST_TOKEN_BACKUP=<file>: save the same token to test wire replay.

const TokenUse = union(enum) { write_to: [*:0]const u8, activate: *wl.Surface };
var token_use: TokenUse = undefined;
var token_pending = false;

fn tokenMode(mode: []const u8) bool {
    const value = std.c.getenv("RAYWM_TEST_TOKEN_MODE") orelse return false;
    return std.mem.eql(u8, std.mem.span(value), mode);
}

fn requestToken(surface: *wl.Surface, input: ?struct { seat: *wl.Seat, serial: u32 }, use: TokenUse) !void {
    const act = extras.activation orelse return error.NoActivation;
    const token = try act.getActivationToken();
    token.setListener(?*anyopaque, tokenListener, null);
    if (input) |i| {
        token.setSerial(i.serial, i.seat);
        if (!tokenMode("no-surface")) token.setSurface(surface);
    }
    token.commit();
    token_use = use;
    token_pending = true;
    step("token requested{s}", .{if (input != null) " (input)" else ""});
}

fn tokenListener(token: *xdg.ActivationTokenV1, event: xdg.ActivationTokenV1.Event, _: ?*anyopaque) void {
    switch (event) {
        .done => |d| {
            token_pending = false;
            token.destroy();
            const name = std.mem.span(d.token);
            switch (token_use) {
                .write_to => |path| {
                    writeFile(path, name) catch return step("token not written", .{});
                    if (std.c.getenv("RAYWM_TEST_TOKEN_BACKUP")) |backup| writeFile(backup, name) catch return step("token backup failed", .{});
                    step("token written", .{});
                },
                .activate => |surface| {
                    extras.activation.?.activate(d.token, surface);
                    step("activate sent", .{});
                },
            }
        },
    }
}

/// Whether the hold loop must wake up to look for activation files.
fn activationFiles() bool {
    return std.c.getenv("RAYWM_TEST_ACTIVATE_FROM") != null or std.c.getenv("RAYWM_TEST_ACTIVATE_SELF") != null or std.c.getenv("RAYWM_TEST_TOKEN_GO") != null;
}

fn pollActivation(surface: *wl.Surface) !void {
    if (token_pending) return;
    if (std.c.getenv("RAYWM_TEST_ACTIVATE_FROM")) |path| {
        var buf: [256]u8 = undefined;
        if (readFile(path, &buf)) |name| {
            _ = std.c.unlink(path);
            var z: [257]u8 = undefined;
            @memcpy(z[0..name.len], name);
            z[name.len] = 0;
            (extras.activation orelse return error.NoActivation).activate(z[0..name.len :0], surface);
            step("activate sent", .{});
        }
    }
    if (std.c.getenv("RAYWM_TEST_ACTIVATE_SELF")) |path| {
        if (std.c.access(path, 0) == 0) {
            _ = std.c.unlink(path);
            try requestToken(surface, null, .{ .activate = surface });
        }
    }
}

fn readFile(path: [*:0]const u8, buf: []u8) ?[]const u8 {
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY });
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    const n = std.c.read(fd, buf.ptr, buf.len);
    if (n <= 0) return null;
    return std.mem.trimEnd(u8, buf[0..@intCast(n)], "\n");
}

/// Written to <path>.tmp and renamed, so a reader never sees half a token.
fn writeFile(path: [*:0]const u8, data: []const u8) !void {
    var tmp_buf: [512]u8 = undefined;
    const tmp = try std.fmt.bufPrintZ(&tmp_buf, "{s}.tmp", .{std.mem.span(path)});
    const fd = std.c.open(tmp, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.OpenFailed;
    defer _ = std.c.close(fd);
    if (std.c.write(fd, data.ptr, data.len) != @as(isize, @intCast(data.len))) return error.WriteFailed;
    if (std.c.rename(tmp, path) != 0) return error.RenameFailed;
}

/// One dispatch that gives up after `ms` without events.
fn dispatchTimeout(display: *wl.Display, ms: i32) !void {
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

fn fractionalListener(_: *wp.FractionalScaleV1, event: wp.FractionalScaleV1.Event, _: ?*anyopaque) void {
    switch (event) {
        .preferred_scale => |p| step("fractional scale {d}", .{p.scale}),
    }
}

fn presentationListener(fb: *wp.PresentationFeedback, event: wp.PresentationFeedback.Event, _: ?*anyopaque) void {
    switch (event) {
        .sync_output => {},
        .presented => |p| {
            step("presented refresh {d}", .{p.refresh});
            fb.destroy();
        },
        .discarded => {
            step("presentation discarded", .{});
            fb.destroy();
        },
    }
}

fn outputListener(_: *wl.Output, event: wl.Output.Event, _: ?*anyopaque) void {
    switch (event) {
        .scale => |sc| step("output scale {d}", .{sc.factor}),
        else => {},
    }
}

fn surfaceListener(_: *wl.Surface, event: wl.Surface.Event, _: ?*anyopaque) void {
    switch (event) {
        .enter => step("surface enter", .{}),
        .leave => step("surface leave", .{}),
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
