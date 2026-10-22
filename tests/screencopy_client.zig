//! TEST-ONLY wlr-screencopy client for tests/screenshot.sh. Requests a
//! capture of one output and prints how each frame ends:
//!   raywm-test-screencopy <output-name> now
//!       copies as soon as the buffer parameters arrive;
//!   raywm-test-screencopy <output-name> wait <file>
//!       prints "frame buffer", waits until <file> exists (the test
//!       unplugs the output meanwhile), then copies; afterwards it asks
//!       for a second frame of the same, now removed, output.
//! Each frame ends with "frame ready" or "frame failed" (exit status 0);
//! the protocol guarantees one of the two.
const std = @import("std");
const posix = std.posix;
const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

const Output = struct { wl_output: *wl.Output = undefined, name: [32]u8 = @splat(0) };

const Globals = struct {
    shm: ?*wl.Shm = null,
    manager: ?*zwlr.ScreencopyManagerV1 = null,
    outputs: [8]Output = @splat(.{}),
    n: usize = 0,
};

const Frame = struct {
    format: wl.Shm.Format = .argb8888,
    width: u32 = 0,
    height: u32 = 0,
    stride: u32 = 0,
    shm_offered: bool = false,
    buffer_done: bool = false,
    result: enum { pending, ready, failed } = .pending,
};

pub fn main(init: std.process.Init) !void {
    const argv = init.minimal.args.vector;
    if (argv.len < 3) return error.Usage;
    const want = std.mem.span(argv[1]);
    const wait = std.mem.eql(u8, std.mem.span(argv[2]), "wait");
    const ctl: ?[*:0]const u8 = if (!wait) null else if (argv.len > 3) argv[3] else return error.Usage;

    const display = try wl.Display.connect(null);
    defer display.disconnect();
    const registry = try display.getRegistry();
    var g: Globals = .{};
    registry.setListener(*Globals, registryListener, &g);
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed; // wl_output.name
    const shm = g.shm orelse return error.NoShm;
    const manager = g.manager orelse return error.NoScreencopy;
    const output = for (g.outputs[0..g.n]) |o| {
        if (std.mem.eql(u8, std.mem.sliceTo(&o.name, 0), want)) break o.wl_output;
    } else return error.NoSuchOutput;

    try capture(display, shm, manager, output, ctl, "frame");
    // The output is gone by now (wait mode): a new request must fail, and
    // the compositor must not touch the destroyed output for it.
    if (wait) try capture(display, shm, manager, output, null, "second frame");
}

fn capture(display: *wl.Display, shm: *wl.Shm, manager: *zwlr.ScreencopyManagerV1, output: *wl.Output, ctl: ?[*:0]const u8, label: []const u8) !void {
    var f: Frame = .{};
    const frame = try manager.captureOutput(0, output);
    defer frame.destroy();
    frame.setListener(*Frame, frameListener, &f);
    while (!f.buffer_done and f.result == .pending) {
        if (display.dispatch() != .SUCCESS) return error.DispatchFailed;
    }
    if (f.result == .pending) {
        if (!f.shm_offered) return error.NoShmBuffer;
        std.debug.print("{s} buffer {d}x{d}\n", .{ label, f.width, f.height });
        if (ctl) |path| while (std.c.access(path, 0) != 0) {
            var ts: posix.timespec = .{ .sec = 0, .nsec = 10 * std.time.ns_per_ms };
            _ = posix.system.nanosleep(&ts, &ts);
        };
        const buffer = try makeBuffer(shm, &f);
        defer buffer.destroy();
        frame.copy(buffer);
        while (f.result == .pending) {
            if (display.dispatch() != .SUCCESS) return error.DispatchFailed;
        }
    }
    std.debug.print("{s} {s}\n", .{ label, @tagName(f.result) });
}

fn makeBuffer(shm: *wl.Shm, f: *const Frame) !*wl.Buffer {
    const size: usize = @as(usize, f.stride) * f.height;
    const fd = try posix.memfd_create("raywm-test-screencopy", 0);
    defer _ = posix.system.close(fd);
    if (posix.errno(posix.system.ftruncate(fd, @intCast(size))) != .SUCCESS) return error.FtruncateFailed;
    const pool = try shm.createPool(fd, @intCast(size));
    defer pool.destroy();
    return pool.createBuffer(0, @intCast(f.width), @intCast(f.height), @intCast(f.stride), f.format);
}

fn frameListener(_: *zwlr.ScreencopyFrameV1, event: zwlr.ScreencopyFrameV1.Event, f: *Frame) void {
    switch (event) {
        .buffer => |b| {
            f.format = b.format;
            f.width = b.width;
            f.height = b.height;
            f.stride = b.stride;
            f.shm_offered = true;
        },
        .buffer_done => f.buffer_done = true,
        .ready => f.result = .ready,
        .failed => f.result = .failed,
        else => {},
    }
}

fn outputListener(_: *wl.Output, event: wl.Output.Event, o: *Output) void {
    switch (event) {
        .name => |n| {
            const src = std.mem.span(n.name);
            const len = @min(src.len, o.name.len - 1);
            @memcpy(o.name[0..len], src[0..len]);
        },
        else => {},
    }
}

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, g: *Globals) void {
    switch (event) {
        .global => |global| {
            const name = std.mem.span(global.interface);
            if (std.mem.eql(u8, name, std.mem.span(wl.Shm.interface.name))) {
                g.shm = registry.bind(global.name, wl.Shm, 1) catch return;
            } else if (std.mem.eql(u8, name, std.mem.span(zwlr.ScreencopyManagerV1.interface.name))) {
                g.manager = registry.bind(global.name, zwlr.ScreencopyManagerV1, 3) catch return;
            } else if (std.mem.eql(u8, name, std.mem.span(wl.Output.interface.name)) and g.n < g.outputs.len and global.version >= 4) {
                const o = &g.outputs[g.n];
                o.wl_output = registry.bind(global.name, wl.Output, 4) catch return;
                o.wl_output.setListener(*Output, outputListener, o);
                g.n += 1;
            }
        },
        .global_remove => {},
    }
}
