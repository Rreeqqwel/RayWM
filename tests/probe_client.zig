//! TEST-ONLY protocol probe for the integration suites: binds a global,
//! makes requests and prints what the compositor answers, one line each
//! ("probe: ..."). Exits 0 when the exchange finished (also on an answer
//! like "failed"), 1 on an error, 2 when the global is missing.
//!   power <output> on|off   wlr-output-power-management: set and confirm
//!   gamma <output>          wlr-gamma-control: the gamma ramp size, or failed
//! <output> is a wl_output name (wl_output v4), e.g. HEADLESS-1.
const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;

const max_outputs = 8;

const Out = struct { output: *wl.Output, name: [64]u8 = @splat(0), len: usize = 0 };

const App = struct {
    outputs: [max_outputs]Out = undefined,
    n_outputs: usize = 0,
    power_mgr: ?*zwlr.OutputPowerManagerV1 = null,
    gamma_mgr: ?*zwlr.GammaControlManagerV1 = null,
    done: bool = false,
    last_mode: ?zwlr.OutputPowerV1.Mode = null,

    fn outputNamed(app: *App, name: []const u8) ?*wl.Output {
        for (app.outputs[0..app.n_outputs]) |o| if (std.mem.eql(u8, o.name[0..o.len], name)) return o.output;
        return null;
    }
};

fn say(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("probe: " ++ fmt ++ "\n", args);
}

pub fn main(init: std.process.Init) !u8 {
    const argv = init.minimal.args.vector;
    if (argv.len < 2) return 1;
    const cmd = std.mem.span(argv[1]);
    const display = try wl.Display.connect(null);
    defer display.disconnect();
    const registry = try display.getRegistry();
    var app: App = .{};
    registry.setListener(*App, registryListener, &app);
    if (display.roundtrip() != .SUCCESS) return 1;
    if (display.roundtrip() != .SUCCESS) return 1; // output names
    if (std.mem.eql(u8, cmd, "power")) {
        const mgr = app.power_mgr orelse return missing("zwlr_output_power_manager_v1");
        const name = if (argv.len > 2) std.mem.span(argv[2]) else "";
        const out = app.outputNamed(name) orelse return noOutput(name);
        const power = try mgr.getOutputPower(out);
        power.setListener(*App, powerListener, &app);
        const on = argv.len > 3 and std.mem.eql(u8, std.mem.span(argv[3]), "on");
        power.setMode(if (on) .on else .off);
        // The current mode comes first, then the new one (or failed).
        var events: usize = 0;
        while (!app.done and events < 50) : (events += 1) {
            if (display.dispatch() != .SUCCESS) return 1;
            if (app.last_mode) |m| if (m == (if (on) zwlr.OutputPowerV1.Mode.on else .off)) break;
        }
        return 0;
    } else if (std.mem.eql(u8, cmd, "gamma")) {
        const mgr = app.gamma_mgr orelse return missing("zwlr_gamma_control_manager_v1");
        const name = if (argv.len > 2) std.mem.span(argv[2]) else "";
        const out = app.outputNamed(name) orelse return noOutput(name);
        const gamma = try mgr.getGammaControl(out);
        gamma.setListener(*App, gammaListener, &app);
        while (!app.done) if (display.dispatch() != .SUCCESS) return 1;
        return 0;
    }
    say("unknown command {s}", .{cmd});
    return 1;
}

fn missing(global: []const u8) u8 {
    say("no global {s}", .{global});
    return 2;
}

fn noOutput(name: []const u8) u8 {
    say("no output {s}", .{name});
    return 1;
}

fn powerListener(_: *zwlr.OutputPowerV1, event: zwlr.OutputPowerV1.Event, app: *App) void {
    switch (event) {
        .mode => |m| {
            say("power mode {s}", .{@tagName(m.mode)});
            app.last_mode = m.mode;
        },
        .failed => {
            say("power failed", .{});
            app.done = true;
        },
    }
}

fn gammaListener(_: *zwlr.GammaControlV1, event: zwlr.GammaControlV1.Event, app: *App) void {
    switch (event) {
        .gamma_size => |g| say("gamma size {d}", .{g.size}),
        .failed => say("gamma failed", .{}),
    }
    app.done = true;
}

fn outputListener(_: *wl.Output, event: wl.Output.Event, o: *Out) void {
    switch (event) {
        .name => |n| {
            const s = std.mem.span(n.name);
            const len = @min(s.len, o.name.len);
            @memcpy(o.name[0..len], s[0..len]);
            o.len = len;
        },
        else => {},
    }
}

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, app: *App) void {
    switch (event) {
        .global => |g| {
            const name = std.mem.span(g.interface);
            if (std.mem.eql(u8, name, std.mem.span(wl.Output.interface.name))) {
                if (app.n_outputs == max_outputs or g.version < 4) return;
                const o = registry.bind(g.name, wl.Output, 4) catch return;
                app.outputs[app.n_outputs] = .{ .output = o };
                o.setListener(*Out, outputListener, &app.outputs[app.n_outputs]);
                app.n_outputs += 1;
            } else if (std.mem.eql(u8, name, std.mem.span(zwlr.OutputPowerManagerV1.interface.name))) {
                app.power_mgr = registry.bind(g.name, zwlr.OutputPowerManagerV1, 1) catch return;
            } else if (std.mem.eql(u8, name, std.mem.span(zwlr.GammaControlManagerV1.interface.name))) {
                app.gamma_mgr = registry.bind(g.name, zwlr.GammaControlManagerV1, 1) catch return;
            }
        },
        .global_remove => {},
    }
}
