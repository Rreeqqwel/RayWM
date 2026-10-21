//! Minimal xdg-shell client for the headless smoke test.
//! Steps: create toplevel -> wait configure -> ack -> attach buffer ->
//! wait frame callback (proves the surface was mapped and rendered) ->
//! destroy toplevel -> roundtrip -> exit 0. Each step is printed.
const std = @import("std");
const posix = std.posix;
const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;

const Globals = struct {
    shm: ?*wl.Shm = null,
    compositor: ?*wl.Compositor = null,
    wm_base: ?*xdg.WmBase = null,
};

const State = struct {
    configured: bool = false,
    serial: u32 = 0,
    width: i32 = 0,
    height: i32 = 0,
    frame_done: bool = false,
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
    const wm_base = globals.wm_base orelse return error.NoXdgWmBase;
    wm_base.setListener(?*anyopaque, wmBaseListener, null);

    var state: State = .{};
    const surface = try compositor.createSurface();
    const xdg_surface = try wm_base.getXdgSurface(surface);
    const toplevel = try xdg_surface.getToplevel();
    xdg_surface.setListener(*State, xdgSurfaceListener, &state);
    toplevel.setListener(*State, toplevelListener, &state);
    toplevel.setTitle("raywm-test");
    toplevel.setAppId("raywm-test");
    surface.commit();

    while (!state.configured) {
        if (display.dispatch() != .SUCCESS) return error.DispatchFailed;
    }
    xdg_surface.ackConfigure(state.serial);
    step("configured {d}x{d}", .{ state.width, state.height });

    const w: i32 = if (state.width > 0) state.width else 200;
    const h: i32 = if (state.height > 0) state.height else 150;
    const buffer = try makeBuffer(shm, w, h);
    defer buffer.destroy();

    const frame = try surface.frame();
    frame.setListener(*State, frameListener, &state);
    surface.attach(buffer, 0, 0);
    surface.damageBuffer(0, 0, w, h);
    surface.commit();
    step("committed buffer", .{});

    while (!state.frame_done) {
        if (display.dispatch() != .SUCCESS) return error.DispatchFailed;
    }
    step("frame done", .{});

    toplevel.destroy();
    xdg_surface.destroy();
    surface.destroy();
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
    step("destroyed", .{});
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
