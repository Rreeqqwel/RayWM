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
        return panel(display, shm, compositor, globals.layer_shell orelse return error.NoLayerShell);
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
        const buffer = try makeBuffer(shm, w, h);
        defer buffer.destroy();

        const frame = try surface.frame();
        frame.setListener(*State, frameListener, &state);
        surface.attach(buffer, 0, 0);
        surface.damageBuffer(0, 0, w, h);
        surface.commit();
        while (!state.frame_done) {
            if (display.dispatch() != .SUCCESS) return error.DispatchFailed;
        }
        step("round {d} frame done", .{round});
        if (std.c.getenv("RAYWM_TEST_HOLD") != null) {
            // Keep the window (acking every configure) until the compositor
            // goes away. Buffers are intentionally kept alive until exit.
            while (display.dispatch() == .SUCCESS) {
                if (!state.configured) continue;
                state.configured = false;
                xdg_surface.ackConfigure(state.serial);
                if (state.width > 0 and state.height > 0) {
                    surface.attach(try makeBuffer(shm, state.width, state.height), 0, 0);
                    surface.damageBuffer(0, 0, state.width, state.height);
                    step("hold resized {d}x{d}", .{ state.width, state.height });
                }
                surface.commit();
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
            const resized = try makeBuffer(shm, state.width, state.height);
            defer resized.destroy();
            const cb = try surface.frame();
            cb.setListener(*State, frameListener, &state);
            surface.attach(resized, 0, 0);
            surface.damageBuffer(0, 0, state.width, state.height);
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
fn panel(display: *wl.Display, shm: *wl.Shm, compositor: *wl.Compositor, layer_shell: *zwlr.LayerShellV1) !void {
    var state: State = .{};
    const surface = try compositor.createSurface();
    const layer = try layer_shell.getLayerSurface(surface, null, .top, "raywm-test-panel");
    layer.setListener(*State, layerListener, &state);
    layer.setAnchor(.{ .top = true, .left = true, .right = true });
    layer.setSize(0, 30);
    layer.setExclusiveZone(30);
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

fn makeBuffer(shm: *wl.Shm, w: i32, h: i32) !*wl.Buffer {
    const stride = w * 4;
    const size: usize = @intCast(stride * h);
    const fd = try posix.memfd_create("raywm-test", 0);
    defer _ = posix.system.close(fd);
    if (posix.errno(posix.system.ftruncate(fd, @intCast(size))) != .SUCCESS) return error.FtruncateFailed;
    const data = try posix.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
    defer posix.munmap(data);
    @memset(data, 0x80);
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
