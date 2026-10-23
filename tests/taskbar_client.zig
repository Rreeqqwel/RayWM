//! Real client for foreign-toplevel (wlr + ext) and ext-workspace tests.
//! Fixed storage deliberately bounds the probe. All output goes to stderr.
const std = @import("std");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;
const ext = wayland.client.ext;

const Text = struct {
    buf: [256]u8 = @splat(0),
    len: usize = 0,
    fn set(t: *Text, value: [*:0]const u8) void {
        const s = std.mem.span(value);
        t.len = @min(s.len, t.buf.len);
        @memcpy(t.buf[0..t.len], s[0..t.len]);
    }
    fn text(t: *const Text) []const u8 {
        return t.buf[0..t.len];
    }
};
const Output = struct { proxy: *wl.Output, name: Text = .{} };
const Top = struct {
    app: *App,
    proxy: *zwlr.ForeignToplevelHandleV1,
    title: Text = .{},
    app_id: Text = .{},
    max: bool = false,
    min: bool = false,
    active: bool = false,
    full: bool = false,
    outputs: usize = 0,
    parent: ?*zwlr.ForeignToplevelHandleV1 = null,
    closed: bool = false,
};
const ExtTop = struct {
    proxy: *ext.ForeignToplevelHandleV1,
    title: Text = .{},
    app_id: Text = .{},
    identifier: Text = .{},
    closed: bool = false,
};
const Workspace = struct {
    proxy: *ext.WorkspaceHandleV1,
    name: Text = .{},
    group: ?*ext.WorkspaceGroupHandleV1 = null,
    state: u32 = 0,
    caps: u32 = 0,
    removed: bool = false,
};
const Group = struct {
    app: *App,
    proxy: *ext.WorkspaceGroupHandleV1,
    output: ?*wl.Output = null,
    caps: u32 = 0,
    removed: bool = false,
};
const App = struct {
    seat: ?*wl.Seat = null,
    foreign: ?*zwlr.ForeignToplevelManagerV1 = null,
    list: ?*ext.ForeignToplevelListV1 = null,
    manager: ?*ext.WorkspaceManagerV1 = null,
    outputs: [16]Output = undefined,
    n_outputs: usize = 0,
    tops: [128]Top = undefined,
    n_tops: usize = 0,
    ext_tops: [128]ExtTop = undefined,
    n_ext_tops: usize = 0,
    workspaces: [256]Workspace = undefined,
    n_workspaces: usize = 0,
    groups: [32]Group = undefined,
    n_groups: usize = 0,
    finished: u8 = 0,

    fn outputName(app: *App, output: ?*wl.Output) []const u8 {
        for (app.outputs[0..app.n_outputs]) |*o| if (o.proxy == output) return o.name.text();
        return "none";
    }
    fn groupOutput(app: *App, group: ?*ext.WorkspaceGroupHandleV1) []const u8 {
        for (app.groups[0..app.n_groups]) |g| if (g.proxy == group and !g.removed) return app.outputName(g.output);
        return "none";
    }
    fn snapshots(app: *App) void {
        say("snapshot", .{});
        for (app.tops[0..app.n_tops]) |*t| if (!t.closed) topSnapshot(t);
        for (app.ext_tops[0..app.n_ext_tops]) |*t| if (!t.closed) extSnapshot(t);
        for (app.groups[0..app.n_groups]) |g| if (!g.removed) say("group output={s} caps={d}", .{ app.outputName(g.output), g.caps });
        for (app.workspaces[0..app.n_workspaces]) |w| if (!w.removed) say("ws name={s} output={s} state={d} caps={d}", .{ w.name.text(), app.groupOutput(w.group), w.state, w.caps });
    }
};

fn say(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("taskbar: " ++ fmt ++ "\n", args);
}

pub fn main(init: std.process.Init) !u8 {
    const argv = init.minimal.args.vector;
    const command = if (argv.len > 1) std.mem.span(argv[1]) else "snapshot";
    const display = try wl.Display.connect(null);
    defer display.disconnect();
    const registry = try display.getRegistry();
    var app: App = .{};
    registry.setListener(*App, registryListener, &app);
    for (0..4) |_| if (display.roundtrip() != .SUCCESS) return 1;
    if (app.foreign == null or app.list == null or app.manager == null or app.seat == null) {
        say("missing required global", .{});
        return 2;
    }
    if (std.mem.eql(u8, command, "watch")) {
        app.snapshots();
        say("ready", .{});
        while (display.dispatch() == .SUCCESS) {}
        return 1;
    }
    if (std.mem.eql(u8, command, "stop")) {
        app.foreign.?.stop();
        app.list.?.stop();
        app.manager.?.stop();
        for (0..3) |_| if (display.roundtrip() != .SUCCESS) return 1;
        say("finished {d}", .{app.finished});
        return if (app.finished == 3) 0 else 1;
    }
    if (!std.mem.eql(u8, command, "snapshot")) {
        const target = if (argv.len > 2) std.mem.span(argv[2]) else "";
        var found = false;
        if (std.mem.eql(u8, command, "workspace") or std.mem.eql(u8, command, "unsupported")) {
            for (app.workspaces[0..app.n_workspaces]) |w| {
                if (!std.mem.eql(u8, w.name.text(), target)) continue;
                if (argv.len > 3 and !std.mem.eql(u8, app.groupOutput(w.group), std.mem.span(argv[3]))) continue;
                if (std.mem.eql(u8, command, "workspace")) w.proxy.activate() else {
                    w.proxy.deactivate();
                    w.proxy.remove();
                    if (w.group) |group| {
                        w.proxy.assign(group);
                        group.createWorkspace("unsupported-create");
                    }
                }
                app.manager.?.commit();
                found = true;
                break;
            }
        } else for (app.tops[0..app.n_tops]) |t| {
            if (!std.mem.eql(u8, t.app_id.text(), target)) continue;
            if (std.mem.eql(u8, command, "activate")) t.proxy.activate(app.seat.?) else if (std.mem.eql(u8, command, "minimize")) t.proxy.setMinimized() else if (std.mem.eql(u8, command, "restore")) t.proxy.unsetMinimized() else if (std.mem.eql(u8, command, "maximize")) t.proxy.setMaximized() else if (std.mem.eql(u8, command, "unmaximize")) t.proxy.unsetMaximized() else if (std.mem.eql(u8, command, "fullscreen")) {
                var output: ?*wl.Output = null;
                if (argv.len > 3) for (app.outputs[0..app.n_outputs]) |*o| {
                    if (std.mem.eql(u8, o.name.text(), std.mem.span(argv[3]))) output = o.proxy;
                };
                t.proxy.setFullscreen(output);
            } else if (std.mem.eql(u8, command, "unfullscreen")) t.proxy.unsetFullscreen() else if (std.mem.eql(u8, command, "close")) t.proxy.close() else return 2;
            found = true;
            break;
        }
        if (!found) {
            say("target missing {s}", .{target});
            return 2;
        }
        for (0..4) |_| if (display.roundtrip() != .SUCCESS) return 1;
        say("request complete", .{});
    }
    app.snapshots();
    return 0;
}

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, app: *App) void {
    switch (event) {
        .global => |g| {
            if (std.mem.orderZ(u8, g.interface, wl.Output.interface.name) == .eq) {
                if (app.n_outputs == app.outputs.len) return;
                const o = &app.outputs[app.n_outputs];
                app.n_outputs += 1;
                o.* = .{ .proxy = registry.bind(g.name, wl.Output, 4) catch return };
                o.proxy.setListener(*Output, outputListener, o);
            } else if (std.mem.orderZ(u8, g.interface, wl.Seat.interface.name) == .eq) {
                app.seat = registry.bind(g.name, wl.Seat, 1) catch return;
                app.seat.?.setListener(*App, seatListener, app);
            } else if (std.mem.orderZ(u8, g.interface, zwlr.ForeignToplevelManagerV1.interface.name) == .eq) {
                app.foreign = registry.bind(g.name, zwlr.ForeignToplevelManagerV1, 3) catch return;
                app.foreign.?.setListener(*App, foreignListener, app);
            } else if (std.mem.orderZ(u8, g.interface, ext.ForeignToplevelListV1.interface.name) == .eq) {
                app.list = registry.bind(g.name, ext.ForeignToplevelListV1, 1) catch return;
                app.list.?.setListener(*App, listListener, app);
            } else if (std.mem.orderZ(u8, g.interface, ext.WorkspaceManagerV1.interface.name) == .eq) {
                app.manager = registry.bind(g.name, ext.WorkspaceManagerV1, 1) catch return;
                app.manager.?.setListener(*App, managerListener, app);
            }
        },
        .global_remove => {},
    }
}
fn outputListener(_: *wl.Output, event: wl.Output.Event, output: *Output) void {
    switch (event) {
        .name => |n| output.name.set(n.name),
        else => {},
    }
}
fn seatListener(_: *wl.Seat, _: wl.Seat.Event, _: *App) void {}
fn foreignListener(_: *zwlr.ForeignToplevelManagerV1, event: zwlr.ForeignToplevelManagerV1.Event, app: *App) void {
    switch (event) {
        .toplevel => |e| {
            if (app.n_tops == app.tops.len) return;
            const t = &app.tops[app.n_tops];
            app.n_tops += 1;
            t.* = .{ .app = app, .proxy = e.toplevel };
            e.toplevel.setListener(*Top, topListener, t);
        },
        .finished => app.finished += 1,
    }
}
fn topSnapshot(t: *Top) void {
    var parent: []const u8 = "none";
    for (t.app.tops[0..t.app.n_tops]) |*other| if (other.proxy == t.parent) {
        parent = other.app_id.text();
    };
    say("wlr app={s} title={s} max={} min={} active={} full={} outputs={d} parent={s}", .{ t.app_id.text(), t.title.text(), t.max, t.min, t.active, t.full, t.outputs, parent });
}
fn topListener(proxy: *zwlr.ForeignToplevelHandleV1, event: zwlr.ForeignToplevelHandleV1.Event, t: *Top) void {
    switch (event) {
        .title => |e| t.title.set(e.title),
        .app_id => |e| t.app_id.set(e.app_id),
        .parent => |e| t.parent = e.parent,
        .output_enter => t.outputs += 1,
        .output_leave => t.outputs -|= 1,
        .state => |e| {
            t.max = false;
            t.min = false;
            t.active = false;
            t.full = false;
            for (e.state.slice(u32)) |state| switch (state) {
                0 => t.max = true,
                1 => t.min = true,
                2 => t.active = true,
                3 => t.full = true,
                else => {},
            };
        },
        .done => topSnapshot(t),
        .closed => {
            t.closed = true;
            say("wlr closed {s}", .{t.app_id.text()});
            // Inert handles must safely ignore all these after window destroy.
            proxy.setMaximized();
            proxy.setMinimized();
            proxy.activate(t.app.seat.?);
            proxy.setFullscreen(null);
            proxy.close();
            proxy.destroy();
            say("wlr stale requests sent", .{});
        },
    }
}
fn listListener(_: *ext.ForeignToplevelListV1, event: ext.ForeignToplevelListV1.Event, app: *App) void {
    switch (event) {
        .toplevel => |e| {
            if (app.n_ext_tops == app.ext_tops.len) return;
            const t = &app.ext_tops[app.n_ext_tops];
            app.n_ext_tops += 1;
            t.* = .{ .proxy = e.toplevel };
            e.toplevel.setListener(*ExtTop, extListener, t);
        },
        .finished => app.finished += 1,
    }
}
fn extSnapshot(t: *ExtTop) void {
    say("ext app={s} title={s} identifier={s}", .{ t.app_id.text(), t.title.text(), t.identifier.text() });
}
fn extListener(proxy: *ext.ForeignToplevelHandleV1, event: ext.ForeignToplevelHandleV1.Event, t: *ExtTop) void {
    switch (event) {
        .title => |e| t.title.set(e.title),
        .app_id => |e| t.app_id.set(e.app_id),
        .identifier => |e| t.identifier.set(e.identifier),
        .done => extSnapshot(t),
        .closed => {
            t.closed = true;
            say("ext closed {s}", .{t.app_id.text()});
            proxy.destroy();
        },
    }
}
fn managerListener(_: *ext.WorkspaceManagerV1, event: ext.WorkspaceManagerV1.Event, app: *App) void {
    switch (event) {
        .workspace_group => |e| {
            if (app.n_groups == app.groups.len) return;
            const g = &app.groups[app.n_groups];
            app.n_groups += 1;
            g.* = .{ .app = app, .proxy = e.workspace_group };
            g.proxy.setListener(*Group, groupListener, g);
        },
        .workspace => |e| {
            if (app.n_workspaces == app.workspaces.len) return;
            const w = &app.workspaces[app.n_workspaces];
            app.n_workspaces += 1;
            w.* = .{ .proxy = e.workspace };
            w.proxy.setListener(*Workspace, workspaceListener, w);
        },
        .done => {
            say("workspace done", .{});
            for (app.workspaces[0..app.n_workspaces]) |w| if (!w.removed) say("ws name={s} output={s} state={d} caps={d}", .{ w.name.text(), app.groupOutput(w.group), w.state, w.caps });
        },
        .finished => app.finished += 1,
    }
}
fn groupListener(proxy: *ext.WorkspaceGroupHandleV1, event: ext.WorkspaceGroupHandleV1.Event, g: *Group) void {
    switch (event) {
        .capabilities => |e| g.caps = @bitCast(e.capabilities),
        .output_enter => |e| g.output = e.output,
        .output_leave => g.output = null,
        .workspace_enter => |e| {
            for (g.app.workspaces[0..g.app.n_workspaces]) |*w| if (w.proxy == e.workspace) {
                w.group = proxy;
            };
        },
        .workspace_leave => |e| {
            for (g.app.workspaces[0..g.app.n_workspaces]) |*w| if (w.proxy == e.workspace) {
                w.group = null;
            };
        },
        .removed => {
            g.removed = true;
            say("group removed", .{});
            proxy.destroy();
        },
    }
}
fn workspaceListener(proxy: *ext.WorkspaceHandleV1, event: ext.WorkspaceHandleV1.Event, w: *Workspace) void {
    switch (event) {
        .name => |e| w.name.set(e.name),
        .state => |e| w.state = @bitCast(e.state),
        .capabilities => |e| w.caps = @bitCast(e.capabilities),
        .removed => {
            w.removed = true;
            say("ws removed {s}", .{w.name.text()});
            proxy.activate(); // inert workspace must ignore this too
            proxy.destroy();
        },
        .id, .coordinates => {},
    }
}
