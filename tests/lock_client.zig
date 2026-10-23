//! TEST-ONLY screen locker for tests/session.sh (ext-session-lock-v1).
//! Locks the session, draws a solid colour on every output (also outputs
//! added later) and logs what it receives:
//!   "locked", "finished", "surface configured WxH", "kbd enter",
//!   "kbd key N pressed|released", "ptr enter", "ptr button N pressed".
//! F12 (keycode 88) unlocks (unlock_and_destroy) and exits.
//!   RAYWM_TEST_LOCK_COLOR=0xAARRGGBB   colour (default opaque green)
//!   RAYWM_TEST_LOCK_CRASH=1            exit right after "locked", without unlocking
const std = @import("std");
const posix = std.posix;
const wayland = @import("wayland");
const wl = wayland.client.wl;
const ext = wayland.client.ext;

const max_outputs = 8;

const Surface = struct {
    app: *App,
    output: *wl.Output,
    surface: ?*wl.Surface = null,
    lock_surface: ?*ext.SessionLockSurfaceV1 = null,
    buffer: ?*wl.Buffer = null,

    fn create(s: *Surface) !void {
        const app = s.app;
        const surface = try app.compositor.?.createSurface();
        const ls = try app.lock.?.getLockSurface(surface, s.output);
        ls.setListener(*Surface, lockSurfaceListener, s);
        s.surface = surface;
        s.lock_surface = ls;
    }
};

const App = struct {
    compositor: ?*wl.Compositor = null,
    shm: ?*wl.Shm = null,
    seat: ?*wl.Seat = null,
    manager: ?*ext.SessionLockManagerV1 = null,
    lock: ?*ext.SessionLockV1 = null,
    surfaces: [max_outputs]Surface = undefined,
    n_surfaces: usize = 0,
    keyboard: ?*wl.Keyboard = null,
    pointer: ?*wl.Pointer = null,
    color: u32 = 0xff00ff00,
    done: bool = false,
    unlock_now: bool = false,

    fn addOutput(app: *App, output: *wl.Output) void {
        if (app.n_surfaces == max_outputs) return;
        app.surfaces[app.n_surfaces] = .{ .app = app, .output = output };
        app.n_surfaces += 1;
        if (app.lock != null) app.surfaces[app.n_surfaces - 1].create() catch {};
    }
};

fn step(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("lock: " ++ fmt ++ "\n", args);
}

pub fn main() !void {
    const display = try wl.Display.connect(null);
    defer display.disconnect();
    const registry = try display.getRegistry();
    var app: App = .{};
    if (std.c.getenv("RAYWM_TEST_LOCK_COLOR")) |c| app.color = std.fmt.parseUnsigned(u32, std.mem.trimStart(u8, std.mem.span(c), "0x"), 16) catch app.color;
    registry.setListener(*App, registryListener, &app);
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
    const manager = app.manager orelse return error.NoSessionLock;
    const lock = try manager.lock();
    lock.setListener(*App, lockListener, &app);
    app.lock = lock;
    for (app.surfaces[0..app.n_surfaces]) |*s| try s.create();
    while (!app.done) {
        if (display.dispatch() != .SUCCESS) break;
        if (app.unlock_now) {
            lock.unlockAndDestroy();
            _ = display.roundtrip();
            step("unlocked", .{});
            return;
        }
    }
}

fn lockListener(_: *ext.SessionLockV1, event: ext.SessionLockV1.Event, app: *App) void {
    switch (event) {
        .locked => {
            step("locked", .{});
            if (std.c.getenv("RAYWM_TEST_LOCK_CRASH") != null) {
                step("crashing", .{});
                std.c._exit(3);
            }
        },
        .finished => {
            step("finished", .{});
            app.done = true;
        },
    }
}

fn lockSurfaceListener(ls: *ext.SessionLockSurfaceV1, event: ext.SessionLockSurfaceV1.Event, s: *Surface) void {
    switch (event) {
        .configure => |c| {
            ls.ackConfigure(c.serial);
            const w: i32 = @intCast(c.width);
            const h: i32 = @intCast(c.height);
            const buffer = makeBuffer(s.app.shm.?, w, h, s.app.color) catch return;
            if (s.buffer) |b| b.destroy();
            s.buffer = buffer;
            s.surface.?.attach(buffer, 0, 0);
            s.surface.?.damageBuffer(0, 0, w, h);
            s.surface.?.commit();
            step("surface configured {d}x{d}", .{ w, h });
        },
    }
}

fn makeBuffer(shm: *wl.Shm, w: i32, h: i32, color: u32) !*wl.Buffer {
    const stride = w * 4;
    const size: usize = @intCast(stride * h);
    const fd = try posix.memfd_create("raywm-test-lock", 0);
    defer _ = posix.system.close(fd);
    if (posix.errno(posix.system.ftruncate(fd, @intCast(size))) != .SUCCESS) return error.FtruncateFailed;
    const data = try posix.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
    defer posix.munmap(data);
    @memset(std.mem.bytesAsSlice(u32, data), color);
    const pool = try shm.createPool(fd, @intCast(size));
    defer pool.destroy();
    return pool.createBuffer(0, w, h, stride, .argb8888);
}

fn seatListener(seat: *wl.Seat, event: wl.Seat.Event, app: *App) void {
    switch (event) {
        .capabilities => |c| {
            if (c.capabilities.keyboard and app.keyboard == null) {
                app.keyboard = seat.getKeyboard() catch return;
                app.keyboard.?.setListener(*App, keyboardListener, app);
            }
            if (!c.capabilities.keyboard) if (app.keyboard) |k| {
                k.destroy();
                app.keyboard = null;
            };
            if (c.capabilities.pointer and app.pointer == null) {
                app.pointer = seat.getPointer() catch return;
                app.pointer.?.setListener(*App, pointerListener, app);
            }
        },
        else => {},
    }
}

fn keyboardListener(_: *wl.Keyboard, event: wl.Keyboard.Event, app: *App) void {
    switch (event) {
        .keymap => |k| _ = posix.system.close(k.fd),
        .enter => step("kbd enter", .{}),
        .leave => step("kbd leave", .{}),
        .key => |k| {
            step("kbd key {d} {s}", .{ k.key, @tagName(k.state) });
            if (k.key == 88 and k.state == .pressed) app.unlock_now = true;
        },
        else => {},
    }
}

fn pointerListener(_: *wl.Pointer, event: wl.Pointer.Event, _: *App) void {
    switch (event) {
        .enter => step("ptr enter", .{}),
        .button => |b| step("ptr button {d} {s}", .{ b.button, @tagName(b.state) }),
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
            } else if (std.mem.eql(u8, name, std.mem.span(wl.Seat.interface.name))) {
                app.seat = registry.bind(g.name, wl.Seat, 1) catch return;
                app.seat.?.setListener(*App, seatListener, app);
            } else if (std.mem.eql(u8, name, std.mem.span(wl.Output.interface.name))) {
                const o = registry.bind(g.name, wl.Output, 1) catch return;
                app.addOutput(o);
            } else if (std.mem.eql(u8, name, std.mem.span(ext.SessionLockManagerV1.interface.name))) {
                app.manager = registry.bind(g.name, ext.SessionLockManagerV1, 1) catch return;
            }
        },
        .global_remove => {},
    }
}
