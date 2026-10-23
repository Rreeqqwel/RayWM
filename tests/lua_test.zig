//! Unit tests for the Lua plugin host against a fake compositor.
//! Plugins report what they observe through raywm.spawn(), which the fake
//! host records. Fixtures live in tests/lua/ (run from the repo root).
const std = @import("std");
const lua = @import("lua");

const Fake = struct {
    log: std.ArrayList([]u8) = .empty,
    timer_ms: ?u32 = null,
    quit: bool = false,
    /// Set by tests that need nested dispatch, like the real compositor:
    /// focusing a view emits view_focus while Lua is still running.
    rt: ?*RT = null,
    /// Host hooks of v0.2.0: managed-state changes, last view command.
    managed_changes: usize = 0,
    last_cmd: ?std.meta.Tag(lua.ViewCmd) = null,
    fs_outputs: [4]u32 = @splat(99),
    n_fs: usize = 0,
    /// A tiny workspace registry with the core's ownership rules.
    ws: [8]FakeWs = undefined,
    n_ws: usize = 0,
    settles: usize = 0,

    const FakeWs = struct { id: u32, name: [16:0]u8, alive: bool, orphan: bool };

    fn wsById(f: *Fake, id: u32) ?*FakeWs {
        for (f.ws[0..f.n_ws]) |*w| if (w.alive and w.id == id) return w;
        return null;
    }

    pub const Api = struct {
        pub fn views(_: *Fake, buf: []u32) usize {
            buf[0] = 1;
            return 1;
        }
        pub fn view(_: *Fake, id: u32) ?lua.ViewInfo {
            if (id != 1) return null;
            return .{ .box = .{ .x = 0, .y = 0, .w = 640, .h = 480 }, .title = "term", .app_id = "foot", .focused = true, .output = 1 };
        }
        pub fn viewCmd(f: *Fake, id: u32, cmd: lua.ViewCmd) bool {
            if (id != 1) return false;
            f.last_cmd = cmd;
            if (cmd == .fullscreen and f.n_fs < f.fs_outputs.len) {
                f.fs_outputs[f.n_fs] = cmd.fullscreen.output;
                f.n_fs += 1;
            }
            if (cmd == .focus) if (f.rt) |rt| rt.emit(.view_focus, id);
            return true;
        }
        pub fn outputs(_: *Fake, buf: []u32) usize {
            buf[0] = 2; // id 2 vanishes between listing and lookup
            buf[1] = 1;
            return 2;
        }
        pub fn outputsAll(f: *Fake, buf: []u32) usize {
            return outputs(f, buf);
        }
        pub fn outputModes(_: *Fake, id: u32, buf: []lua.ModeInfo) ?[]const lua.ModeInfo {
            if (id != 1) return null;
            buf[0] = .{ .w = 1920, .h = 1080, .refresh = 60000, .preferred = true, .current = true };
            buf[1] = .{ .w = 1280, .h = 720, .refresh = 60000, .preferred = false, .current = false };
            return buf[0..2];
        }
        pub fn outputConfigure(f: *Fake, target: lua.OutputTarget, cfg: lua.OutputConfig) lua.OutputResult {
            var buf: [128]u8 = undefined;
            const name = switch (target) {
                .id => |id| if (id == 1) "FAKE-1" else return .stale,
                .name => |n| if (std.mem.eql(u8, n, "FAKE-1")) n else return .stale,
            };
            if (cfg.enabled == false) return .no_output_left;
            const m = cfg.mode orelse [3]i32{ 0, 0, 0 };
            const line = std.fmt.bufPrint(&buf, "configure:{s}:{d}x{d}@{d}:{d}:{s}:{s}", .{ name, m[0], m[1], m[2], cfg.scale orelse 0, cfg.transform orelse "-", if (cfg.position) |p| switch (p) {
                .auto => "auto",
                .at => "at",
            } else "-" }) catch unreachable;
            f.log.append(std.testing.allocator, std.testing.allocator.dupe(u8, line) catch unreachable) catch unreachable;
            return .ok;
        }
        pub fn output(_: *Fake, id: u32) ?lua.OutputInfo {
            if (id != 1) return null;
            const b: lua.Box = .{ .x = 0, .y = 0, .w = 1920, .h = 1080 };
            return .{ .box = b, .usable = b };
        }
        pub fn parseKey(_: *Fake, spec: [*:0]const u8) ?lua.Key {
            const s = std.mem.span(spec);
            if (std.mem.eql(u8, s, "Super+Return")) return .{ .mods = 64, .sym = 0xff0d };
            if (std.mem.eql(u8, s, "Super+x")) return .{ .mods = 64, .sym = 'x' };
            // "Super+U4E01".. (tests/lua/plugins/bindloop.lua): distinct keys.
            if (std.mem.startsWith(u8, s, "Super+U")) return .{ .mods = 64, .sym = 0x0100_0000 + (std.fmt.parseInt(u32, s[7..], 16) catch return null) };
            return null;
        }
        pub fn spawn(f: *Fake, cmd: [*:0]const u8) void {
            f.log.append(std.testing.allocator, std.testing.allocator.dupe(u8, std.mem.span(cmd)) catch unreachable) catch unreachable;
        }
        pub fn quit(f: *Fake) void {
            f.quit = true;
        }
        pub fn armTimer(f: *Fake, ms: ?u32) void {
            f.timer_ms = ms;
        }
        pub fn locked(_: *Fake) bool {
            return false;
        }
        pub fn inputConfigure(f: *Fake, match: []const u8, st: lua.InputSettings, apply_now: bool) lua.InputResult {
            if (std.mem.eql(u8, match, "bad")) return .bad_match;
            var buf: [160]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "input:{s}:{s}:{d}:{s}:{s}", .{ match, st.xkb_layout orelse "-", st.repeat_rate orelse -1, if (st.natural_scroll) |b| (if (b) "ns" else "nons") else "-", if (apply_now) "now" else "later" }) catch unreachable;
            f.log.append(std.testing.allocator, std.testing.allocator.dupe(u8, line) catch unreachable) catch unreachable;
            return .ok;
        }
        pub fn inputDevices(_: *Fake, buf: []lua.DeviceInfo) []const lua.DeviceInfo {
            buf[0] = .{ .id = 40, .name = "kbd", .kind = "keyboard", .virtual = false, .libinput = true };
            return buf[0..1];
        }
        pub fn keyboardLayout(_: *Fake, names: [][*:0]const u8) ?lua.LayoutInfo {
            names[0] = "English (US)";
            names[1] = "Russian";
            return .{ .active = 2, .names = names[0..2] };
        }
        pub fn keyboardSetLayout(_: *Fake, index: u32) bool {
            return index < 2;
        }
        pub fn managedChanged(f: *Fake, _: u32) void {
            f.managed_changes += 1;
        }
        pub fn workspaces(f: *Fake, buf: []u32) usize {
            var n: usize = 0;
            for (f.ws[0..f.n_ws]) |w| if (w.alive) {
                buf[n] = w.id;
                n += 1;
            };
            return n;
        }
        pub fn workspace(f: *Fake, id: u32) ?lua.WorkspaceInfo {
            const w = f.wsById(id) orelse return null;
            return .{ .name = &w.name, .home = "FAKE-1", .output = 1, .active = false, .urgent = false, .orphan = w.orphan };
        }
        pub fn workspaceCreate(f: *Fake, out: u32, name: []const u8) lua.CreateResult {
            if (out != 1) return .stale;
            if (name.len == 0 or name.len > 15) return .bad_name;
            if (f.n_ws == f.ws.len) return .failed;
            var w: FakeWs = .{ .id = @intCast(100 + f.n_ws), .name = @splat(0), .alive = true, .orphan = false };
            @memcpy(w.name[0..name.len], name);
            f.ws[f.n_ws] = w;
            f.n_ws += 1;
            return .{ .ok = w.id };
        }
        pub fn workspaceAdopt(f: *Fake, id: u32) lua.AdoptResult {
            const w = f.wsById(id) orelse return .stale;
            if (!w.orphan) return .owned;
            w.orphan = false;
            return .ok;
        }
        pub fn workspaceOrphan(f: *Fake, id: u32) void {
            if (f.wsById(id)) |w| w.orphan = true;
        }
        pub fn workspacesSettled(f: *Fake) void {
            f.settles += 1;
            for (f.ws[0..f.n_ws]) |*w| if (w.alive and w.orphan) {
                w.alive = false;
            };
        }
        pub fn workspaceCmd(f: *Fake, id: u32, cmd: lua.WorkspaceCmd) lua.WorkspaceResult {
            const w = f.wsById(id) orelse return .stale;
            if (cmd == .remove) w.alive = false;
            return .ok;
        }
        pub fn pointer(_: *Fake) lua.PointerInfo {
            return .{ .x = 10, .y = 20, .busy = false };
        }
        pub fn pointerWarp(f: *Fake, x: i32, y: i32) lua.WarpResult {
            var buf: [64]u8 = undefined;
            f.log.append(std.testing.allocator, std.testing.allocator.dupe(u8, std.fmt.bufPrint(&buf, "hostwarp:{d},{d}", .{ x, y }) catch unreachable) catch unreachable) catch unreachable;
            return if (x < 0) .outside else .ok;
        }
    };

    fn deinit(f: *Fake) void {
        for (f.log.items) |s| std.testing.allocator.free(s);
        f.log.deinit(std.testing.allocator);
    }

    fn count(f: *Fake, s: []const u8) usize {
        var n: usize = 0;
        for (f.log.items) |l| n += @intFromBool(std.mem.eql(u8, l, s));
        return n;
    }

    fn clear(f: *Fake) void {
        for (f.log.items) |s| std.testing.allocator.free(s);
        f.log.clearRetainingCapacity();
    }
};

const RT = lua.Runtime(Fake);

/// Starts a runtime with clean error/warning counters, so leftovers from a
/// previous test's destroy() never count against this one.
fn start(f: *Fake, path: [:0]const u8, limits: lua.Limits) !*RT {
    error_count = 0;
    warn_count = 0;
    return RT.create(f, path, limits);
}

/// Collected plugin errors ("source: first line"), checked by the tests.
/// Fixed storage, so errors raised during destroy() cannot leak.
var error_lines: [64][256]u8 = undefined;
var error_lens: [64]usize = undefined;
var error_count: usize = 0;
fn report(source: []const u8, msg: []const u8) void {
    if (error_count == error_lines.len) return;
    const line = std.mem.sliceTo(msg, '\n');
    const e = std.fmt.bufPrint(&error_lines[error_count], "{s}: {s}", .{ source, line }) catch error_lines[error_count][0..];
    error_lens[error_count] = e.len;
    error_count += 1;
}
fn takeErrors() usize {
    defer error_count = 0;
    return error_count;
}
fn hasError(needle: []const u8) bool {
    for (0..error_count) |i| if (std.mem.indexOf(u8, error_lines[i][0..error_lens[i]], needle) != null) return true;
    return false;
}
/// Warnings (missing config, ignored reload, dropped events): counted, and
/// the last one kept, without allocating.
var warn_count: usize = 0;
var last_warn_buf: [256]u8 = undefined;
var last_warn: []const u8 = "";
var warn_lines: [16][256]u8 = undefined;
var warn_lens: [16]usize = undefined;
fn warn(msg: []const u8) void {
    const n = @min(msg.len, last_warn_buf.len);
    @memcpy(last_warn_buf[0..n], msg[0..n]);
    last_warn = last_warn_buf[0..n];
    if (warn_count < warn_lines.len) {
        @memcpy(warn_lines[warn_count][0..n], msg[0..n]);
        warn_lens[warn_count] = n;
    }
    warn_count += 1;
}
fn hasWarning(needle: []const u8) bool {
    for (0..@min(warn_count, warn_lines.len)) |i| if (std.mem.indexOf(u8, warn_lines[i][0..warn_lens[i]], needle) != null) return true;
    return false;
}
fn takeWarnings() usize {
    defer warn_count = 0;
    return warn_count;
}
const opts: lua.Limits = .{ .report = report, .warn = warn };
var fake_now: u64 = 1_000_000_000;
fn fakeClock() u64 {
    return fake_now;
}

test "plugin contract, dispatch and error isolation" {
    var f: Fake = .{};
    defer f.deinit();
    const rt = try start(&f, "tests/lua/basic.lua", opts);
    defer rt.destroy();
    const t = std.testing;

    try t.expect(rt.configured());
    try t.expectEqual(1, f.count("setup:probe"));
    // Wrong api version: rejected, setup never ran.
    try t.expectEqual(1, f.count("badapi:nil"));
    try t.expectEqual(0, f.count("badapi-setup-ran"));

    // crashy errors in its view_map handler: probe (earlier) still ran,
    // crashy is torn down and never called again.
    rt.emit(.view_map, 7);
    try t.expectEqual(1, f.count("map:7"));
    try t.expectEqual(1, f.count("teardown:crashy"));
    rt.emit(.view_map, 8);
    try t.expectEqual(1, f.count("map:8"));
    try t.expectEqual(1, f.count("teardown:crashy"));

    // Bindings: probe's still works; crashy's Super+x was released.
    try t.expect(rt.key(64, 0xff0d));
    try t.expectEqual(1, f.count("bind"));
    try t.expect(!rt.key(64, 'x'));
    try t.expect(rt.hasBindings());

    // Cancelling a handler later in the same dispatch: it does not run.
    rt.emit(.view_unmap, 1);
    try t.expectEqual(1, f.count("first"));
    try t.expectEqual(1, f.count("cancel:true"));
    try t.expectEqual(0, f.count("second"));
    rt.emit(.view_unmap, 1);
    try t.expectEqual(1, f.count("cancel:nil"));
    try t.expectEqual(0, f.count("second"));

    // Stale ids return nil, "stale"; live ids return data.
    rt.emit(.layout, 0);
    try t.expectEqual(1, f.count("stale:nil:stale:nil:stale"));
    try t.expectEqual(1, f.count("view1:term:640:true"));

    // A vanished output is skipped without leaving a hole in the array.
    try t.expectEqual(1, f.count("outputs:1:1"));

    // raywm.load outside init.lua is an error -> lateload is unloaded.
    rt.emit(.view_title, 1);
    try t.expectEqual(1, f.count("teardown:lateload"));

    try t.expect(hasError("badapi: plugin 'badapi' requires api = 1"));
    try t.expect(hasError("crashy: tests/lua/plugins/crashy.lua:4: boom"));
    try t.expect(hasError("lateload: tests/lua/plugins/lateload.lua:4: raywm.load is only allowed"));
    try t.expectEqual(3, takeErrors());
}

test "timers are one-shot and use the injected clock" {
    var f: Fake = .{};
    defer f.deinit();
    const rt = try start(&f, "tests/lua/basic.lua", opts);
    defer rt.destroy();
    rt.clock = fakeClock;
    rt.emit(.output_add, 1); // probe schedules a 10 ms timer
    try std.testing.expectEqual(10, f.timer_ms.?);
    fake_now += 5 * std.time.ns_per_ms;
    rt.runTimers();
    try std.testing.expectEqual(0, f.count("timer"));
    try std.testing.expectEqual(5, f.timer_ms.?);
    fake_now += 5 * std.time.ns_per_ms;
    rt.runTimers();
    try std.testing.expectEqual(1, f.count("timer"));
    try std.testing.expectEqual(null, f.timer_ms);
    rt.runTimers();
    try std.testing.expectEqual(1, f.count("timer"));
    try std.testing.expectEqual(1, takeErrors()); // badapi
}

test "memory and instruction limits unload only the offender" {
    var f: Fake = .{};
    defer f.deinit();
    const rt = try start(&f, "tests/lua/limits.lua", .{ .memory = 16 << 20, .instructions = 5_000_000, .report = report, .warn = warn });
    defer rt.destroy();
    try std.testing.expect(rt.configured());
    try std.testing.expectEqual(1, f.count("hog:nil"));
    rt.emit(.view_map, 3); // spin loops forever -> budget error
    try std.testing.expectEqual(1, f.count("map:3"));
    try std.testing.expectEqual(1, f.count("teardown:spin"));
    rt.emit(.view_map, 4);
    try std.testing.expectEqual(1, f.count("map:4"));
    try std.testing.expect(hasError("hog: not enough memory"));
    try std.testing.expect(hasError("spin: instruction budget exceeded"));
    try std.testing.expectEqual(2, takeErrors());
}

test "reload tears everything down and runs the config again" {
    var f: Fake = .{};
    defer f.deinit();
    const rt = try start(&f, "tests/lua/basic.lua", opts);
    defer rt.destroy();
    f.clear();
    rt.requestReload();
    try std.testing.expectEqual(1, f.count("teardown:probe"));
    try std.testing.expectEqual(1, f.count("teardown:lateload"));
    try std.testing.expectEqual(1, f.count("setup:probe"));
    rt.emit(.view_map, 9);
    try std.testing.expectEqual(1, f.count("map:9"));
    try std.testing.expectEqual(3, takeErrors()); // badapi twice, crashy once
}

test "broken config falls back and still cleans up its plugins" {
    var f: Fake = .{};
    defer f.deinit();
    const rt = try start(&f, "tests/lua/broken.lua", opts);
    try std.testing.expect(!rt.configured());
    try std.testing.expectEqual(1, f.count("setup:probe"));
    rt.destroy();
    try std.testing.expectEqual(1, f.count("teardown:probe"));
    try std.testing.expect(hasError("init.lua: tests/lua/broken.lua:2: bad config"));
    try std.testing.expectEqual(1, takeErrors());
}

test "v0.1.2 additions: pointer, pointer_warp, view_border, visible" {
    var f: Fake = .{};
    defer f.deinit();
    const rt = try start(&f, "tests/lua/api012.lua", opts);
    defer rt.destroy();
    const t = std.testing;
    try t.expectEqual(0, takeErrors());
    try t.expectEqual(1, f.count("pointer:10,20,false"));
    try t.expectEqual(1, f.count("hostwarp:5,6"));
    try t.expectEqual(1, f.count("warp:true"));
    try t.expectEqual(1, f.count("hostwarp:-1,0"));
    try t.expectEqual(1, f.count("warpfail:nil:outside"));
    try t.expectEqual(1, f.count("visible:true"));
    try t.expectEqual(1, f.count("border:true"));
    try t.expectEqual(1, f.count("noborder:true"));
    try t.expectEqual(1, f.count("staleborder:nil"));
    try t.expectEqual(6, f.count("bad:false"));
    try t.expectEqual(1, f.count("badwarp:false"));
}

test "bindings in a loop: one duplicate warning, bounded native work" {
    var f: Fake = .{};
    defer f.deinit();
    const start_ns = lua.monotonicNs();
    const rt = try start(&f, "tests/lua/bindloop.lua", opts);
    defer rt.destroy();
    try std.testing.expectEqual(0, takeErrors());
    try std.testing.expectEqual(1, takeWarnings());
    try std.testing.expect(rt.hasBindings());
    // 23000 registrations; a quadratic scan would take seconds.
    try std.testing.expect(lua.monotonicNs() - start_ns < 2 * std.time.ns_per_s);
}

test "colors parse to premultiplied RGBA" {
    const t = std.testing;
    try t.expectEqual([4]f32{ 1, 0, 0, 1 }, lua.parseColor("#ff0000").?);
    const half = lua.parseColor("#ffffff80").?;
    try t.expectApproxEqAbs(@as(f32, 128.0 / 255.0), half[0], 1e-6);
    try t.expectApproxEqAbs(@as(f32, 128.0 / 255.0), half[3], 1e-6);
    try t.expectEqual([4]f32{ 0, 0, 0, 0 }, lua.parseColor("#12345600").?);
    for ([_][]const u8{ "", "#", "ff0000", "#ff00", "#ff00000", "#gg0000", "#ff0000ff0" }) |bad| try t.expect(lua.parseColor(bad) == null);
}

test "missing config is not fatal" {
    var f: Fake = .{};
    defer f.deinit();
    const rt = try start(&f, "tests/lua/does-not-exist.lua", opts);
    defer rt.destroy();
    try std.testing.expect(!rt.configured());
    try std.testing.expect(!rt.hasBindings());
    // Says why plugin keys do nothing.
    try std.testing.expect(hasWarning("no plugin registered key bindings"));
}

test "reload requested from init.lua or teardown is ignored, not recursive" {
    var f: Fake = .{};
    defer f.deinit();
    const rt = try start(&f, "tests/lua/reload_in_config.lua", opts);
    defer rt.destroy();
    try std.testing.expectEqual(1, f.count("setup:probe"));
    rt.requestReload(); // reloader's teardown asks for another reload
    try std.testing.expectEqual(2, f.count("setup:probe"));
    try std.testing.expectEqual(1, f.count("teardown:probe"));
    rt.emit(.view_map, 5);
    try std.testing.expectEqual(1, f.count("map:5"));
    try std.testing.expectEqual(0, takeErrors());
}

test "failed reload disables Lua safely until the next reload" {
    var f: Fake = .{};
    defer f.deinit();
    const rt = try start(&f, "tests/lua/basic.lua", opts);
    defer rt.destroy();
    const saved = rt.limits.memory;
    rt.limits.memory = 1; // lua_newstate cannot allocate
    rt.requestReload();
    try std.testing.expect(hasError("raywm: reload failed"));
    rt.emit(.view_map, 6); // must not touch the closed state
    try std.testing.expect(!rt.key(64, 0xff0d));
    rt.runTimers();
    try std.testing.expectEqual(0, f.count("map:6"));
    rt.limits.memory = saved;
    rt.requestReload();
    rt.emit(.view_map, 7);
    try std.testing.expectEqual(1, f.count("map:7"));
    _ = takeErrors();
}

test "instruction budget is per callback" {
    var f: Fake = .{};
    defer f.deinit();
    const rt = try start(&f, "tests/lua/budget.lua", .{ .instructions = 1_000_000, .report = report, .warn = warn });
    defer rt.destroy();
    rt.emit(.view_map, 1);
    rt.emit(.view_map, 2);
    try std.testing.expectEqual(2, f.count("slow_a"));
    try std.testing.expectEqual(2, f.count("slow_b"));
    try std.testing.expectEqual(0, takeErrors());
}

test "ctx.manage: owned by the plugin, released on request, unmap, reload and unload" {
    var f: Fake = .{};
    defer f.deinit();
    const rt = try start(&f, "tests/lua/manage.lua", opts);
    defer rt.destroy();
    const t = std.testing;
    try t.expectEqual(1, f.count("manage999:nil:stale"));
    try t.expect(!rt.managed(1));

    rt.emit(.layout, 0); // tiled: managed
    try t.expectEqual(1, f.count("manage1:true"));
    try t.expect(rt.managed(1));
    try t.expect(!rt.managed(2)); // floating: never managed
    rt.emit(.layout, 0); // managing twice is harmless
    try t.expect(rt.managed(1));

    rt.emit(.view_title, 1); // explicit release
    try t.expect(!rt.managed(1));

    rt.emit(.layout, 0);
    rt.emit(.view_unmap, 1); // the window is gone
    try t.expect(!rt.managed(1));

    rt.emit(.layout, 0);
    rt.requestReload(); // fresh state: nothing managed until the plugin says so
    try t.expect(!rt.managed(1));

    rt.emit(.layout, 0);
    try t.expect(rt.managed(1));
    rt.emit(.view_resized, 1); // the plugin errors and is unloaded
    try t.expect(!rt.managed(1));
    try t.expectEqual(1, takeErrors());
}

test "edge cases: no debug library, coroutines, invalid ids, nesting, duplicates" {
    var f: Fake = .{};
    defer f.deinit();
    const rt = try start(&f, "tests/lua/edge.lua", opts);
    defer rt.destroy();
    f.rt = rt;
    const t = std.testing;

    // Plugins never get the debug library (it can reach host internals).
    try t.expectEqual(1, f.count("debug:nil:nil"));
    try t.expectEqual(1, f.count("native:nil:2:false"));
    // A failing setup rejects the plugin; its teardown still runs; its
    // binding is released.
    try t.expectEqual(1, f.count("teardown:badsetup"));
    try t.expect(hasError("badsetup: tests/lua/plugins/badsetup.lua:6: setup failed"));

    // Same key bound twice: the registration made first wins, and the
    // later ones are reported.
    try t.expect(hasWarning("plugin edge2: key Super+Return is already bound by plugin edge, whose binding is used"));
    try t.expect(hasWarning("plugin badsetup: key Super+Return is already bound by plugin edge"));
    try t.expect(rt.key(64, 0xff0d));
    try t.expectEqual(1, f.count("bind:edge"));
    try t.expectEqual(0, f.count("bind:edge2"));
    try t.expectEqual(0, f.count("bind:badsetup")); // released with its plugin

    // Coroutines may call the host; invalid ids are stale, not errors.
    rt.emit(.layout, 0);
    try t.expectEqual(1, f.count("co:true:true"));
    try t.expectEqual(3, f.count("id:nil:stale"));

    // Nested dispatch stops at the depth limit with a warning, no crash.
    // (The coroutine's view_focus above already ran this chain from depth 2:
    // 7 handlers before the limit.)
    try t.expectEqual(7, f.count("focus:1"));
    f.clear();
    _ = takeWarnings();
    rt.emit(.view_focus, 1);
    try t.expectEqual(8, f.count("focus:1"));
    try t.expectEqual(1, takeWarnings());

    // Toggling ctx.manage 200k times reuses one registration.
    const before = rt.regs.items.len;
    rt.emit(.view_title, 1);
    try t.expectEqual(1, f.count("toggled"));
    try t.expect(rt.managed(1));
    try t.expect(rt.regs.items.len <= before + 1);

    // A wrong argument type or a non-string error unloads only this plugin.
    rt.emit(.output_remove, 3);
    try t.expect(hasError("edge: (non-string error)"));
    try t.expectEqual(1, f.count("teardown:edge"));
    try t.expect(!rt.managed(1)); // its managed view is released
    try t.expect(rt.key(64, 0xff0d)); // edge2's binding takes over
    try t.expectEqual(1, f.count("bind:edge2"));
    _ = takeErrors();
}

test "reload from a binding callback is deferred, then runs once" {
    var f: Fake = .{};
    defer f.deinit();
    const rt = try start(&f, "tests/lua/edge.lua", opts);
    defer rt.destroy();
    f.clear();
    try std.testing.expect(rt.key(64, 'x')); // edge binds Super+x to raywm.reload
    try std.testing.expectEqual(1, f.count("teardown:edge"));
    try std.testing.expectEqual(1, f.count("debug:nil:nil")); // setup ran again
    // edge2's teardown error is reported, not fatal.
    try std.testing.expect(hasError("edge2: tests/lua/plugins/edge2.lua:7: teardown failed"));
    _ = takeErrors();
}

test "repeated reload keeps Lua memory flat" {
    var f: Fake = .{};
    defer f.deinit();
    const rt = try start(&f, "tests/lua/basic.lua", opts);
    defer rt.destroy();
    rt.requestReload();
    const first = rt.mem_used;
    for (0..25) |_| rt.requestReload();
    try std.testing.expectEqual(26 + 1, f.count("setup:probe"));
    // Same config, same state size (allow small allocator noise).
    try std.testing.expect(rt.mem_used <= first + 4096);
    try std.testing.expect(rt.regs.items.len < 32);
    _ = takeErrors();
    _ = takeWarnings();
}

test "the instruction budget cannot be swallowed by pcall or coroutines" {
    var f: Fake = .{};
    defer f.deinit();
    const rt = try start(&f, "tests/lua/bypass.lua", .{ .instructions = 1_000_000, .report = report, .warn = warn });
    defer rt.destroy();
    rt.emit(.view_map, 1); // returns instead of hanging
    try std.testing.expect(hasError("bypass:"));
    try std.testing.expectEqual(1, takeErrors());
}

test "the coroutine variant of a budget bypass also ends" {
    var f: Fake = .{};
    defer f.deinit();
    const rt = try start(&f, "tests/lua/bypass.lua", .{ .instructions = 1_000_000, .report = report, .warn = warn });
    defer rt.destroy();
    rt.emit(.view_unmap, 1);
    try std.testing.expectEqual(1, takeErrors());
    // The runtime is still usable afterwards (budget and hook restored).
    rt.requestReload();
    try std.testing.expectEqual(0, takeErrors());
}

test "registrations are capped" {
    var f: Fake = .{};
    defer f.deinit();
    const rt = try start(&f, "tests/lua/regcap.lua", .{ .max_registrations = 1000, .report = report, .warn = warn });
    defer rt.destroy();
    rt.emit(.view_map, 1);
    try std.testing.expect(hasError("regcap: tests/lua/plugins/regcap.lua:6: too many registrations"));
    try std.testing.expect(rt.regs.items.len == 0); // swept with the plugin
    try std.testing.expectEqual(1, takeErrors());
}

test "a coroutine created before the budget ran out cannot swallow it either" {
    var f: Fake = .{};
    defer f.deinit();
    const rt = try start(&f, "tests/lua/bypass.lua", .{ .instructions = 1_000_000, .report = report, .warn = warn });
    defer rt.destroy();
    rt.emit(.view_title, 1); // resumes the coroutine created in setup
    try std.testing.expectEqual(1, takeErrors());
}

test "v0.2.0 foundation: version, view metadata, event arguments, managed hook" {
    var f: Fake = .{};
    defer f.deinit();
    const rt = try start(&f, "tests/lua/v020.lua", opts);
    defer rt.destroy();
    const t = std.testing;
    try t.expectEqual(0, takeErrors());
    try t.expectEqual(1, f.count("version:" ++ lua.version));
    try t.expectEqual(1, f.count("meta:false:false:0:0:false:false:0"));
    try t.expectEqual(1, f.count("floating:true"));
    try t.expectEqual(1, f.count("floatingstale:nil"));
    // view_fullscreen(id, on, output?) and view_maximize(id, on).
    try t.expectEqual(1, f.count("fs:true"));
    try t.expectEqual(1, f.count("fsdefault:true"));
    try t.expectEqual(1, f.count("max:true"));
    try t.expectEqual(1, f.count("badfs:false")); // the output must be an id
    try t.expectEqual(2, f.n_fs);
    try t.expectEqual(@as(u32, 7), f.fs_outputs[0]);
    try t.expectEqual(@as(u32, 0), f.fs_outputs[1]); // 0: the window's output
    try t.expectEqual(.maximize, f.last_cmd.?);
    // raywm.output_configure: mode strings with decimals, tables, positions.
    try t.expectEqual(1, f.count("configure:FAKE-1:2560x1440@143970:1.5:90:at"));
    try t.expectEqual(1, f.count("configure:FAKE-1:1920x1080@60000:0:-:auto"));
    try t.expectEqual(1, f.count("configure:FAKE-1:1280x720@0:0:-:-"));
    try t.expectEqual(1, f.count("outstale:nil:stale"));
    try t.expectEqual(1, f.count("outlast:nil:no_output_left"));
    try t.expectEqual(1, f.count("badmode:false"));
    try t.expectEqual(1, f.count("badpos:false"));
    try t.expectEqual(1, f.count("modes:2:1920x1080@60000:true"));
    try t.expectEqual(1, f.count("modesstale:nil"));
    try t.expectEqual(1, f.count("outputs:1::true"));
    // raywm.input_configure: deferred while init.lua runs, typos are errors.
    try t.expectEqual(1, f.count("input:type:keyboard:us,ru:40:-:later"));
    try t.expectEqual(1, f.count("input:type:touchpad:-:-1:ns:later"));
    try t.expectEqual(1, f.count("inputtypo:false"));
    try t.expectEqual(1, f.count("inputtype:false"));
    try t.expectEqual(1, f.count("inputmatch:nil:bad_match"));
    try t.expectEqual(1, f.count("devices:1:kbd:keyboard"));
    try t.expectEqual(1, f.count("layout:2:English (US),Russian"));
    try t.expectEqual(1, f.count("setlayout:true:nil"));
    rt.emitArgs(.keyboard_layout, 0, &.{.{ .int = 2 }});
    try t.expectEqual(1, f.count("layoutevent:2"));
    rt.emit(.input_add, 40);
    try t.expectEqual(1, f.count("input:*:-:-1:nons:now"));

    // Extra handler arguments arrive after the id, in order.
    rt.emitArgs(.view_state, 1, &.{ .{ .int = 5 }, .{ .boolean = true }, .nil });
    try t.expectEqual(1, f.count("state:1:5:true:nil"));

    // ctx.manage on and off tell the host at once...
    const before = f.managed_changes;
    rt.emit(.view_new, 1);
    try t.expect(rt.managed(1));
    try t.expectEqual(before + 1, f.managed_changes);
    rt.emit(.view_app_id, 1);
    try t.expect(!rt.managed(1));
    try t.expect(f.managed_changes >= before + 2);
    // ...and so does a managed view released by an unload (reload here).
    rt.emit(.view_new, 1);
    try t.expect(rt.managed(1));
    const mid = f.managed_changes;
    rt.requestReload();
    try t.expect(f.managed_changes > mid);
    try t.expect(!rt.managed(1));
    try t.expectEqual(0, takeErrors());
}

test "workspaces: owned by their plugin, orphaned on unload, adopted or released after a reload" {
    var f: Fake = .{};
    defer f.deinit();
    const rt = try start(&f, "tests/lua/ws.lua", opts);
    defer rt.destroy();
    const t = std.testing;
    try t.expectEqual(0, takeErrors());
    try t.expectEqual(1, f.count("adopted:0"));
    try t.expectEqual(1, f.count("created:100:101"));
    try t.expectEqual(1, f.count("stale:nil"));
    try t.expectEqual(1, f.count("badname:nil:bad_name"));
    try t.expectEqual(1, f.count("owned:nil:owned")); // owned by a live plugin
    try t.expectEqual(1, f.settles); // after the first config run

    // Reload: both become orphans; "one" is adopted, "two" is released
    // once init.lua has run.
    rt.requestReload();
    try t.expectEqual(1, f.count("adopted:1"));
    try t.expectEqual(2, f.settles);
    rt.emit(.layout, 0);
    try t.expectEqual(1, f.count("list:one"));

    // A plugin error orphans its workspace but releases nothing: the
    // windows stay where they are until the next (re)load.
    rt.emit(.view_title, 1);
    try t.expect(hasError("wsowner:"));
    try t.expect(f.wsById(100).?.orphan);
    try t.expectEqual(2, f.settles);
    rt.requestReload();
    try t.expectEqual(2, f.count("adopted:1"));
    try t.expect(!f.wsById(100).?.orphan);
    _ = takeErrors();
}

test "raywm.startup runs once after init.lua, in order; spawn_once survives reloads" {
    var f: Fake = .{};
    defer f.deinit();
    const rt = try start(&f, "tests/lua/startup.lua", opts);
    defer rt.destroy();
    const t = std.testing;
    try t.expectEqual(1, f.count("startup-returned:true"));
    try t.expectEqual(1, f.count("once-first:true"));
    try t.expectEqual(1, f.count("once-second:false"));
    try t.expectEqual(1, f.count("once-cmd"));
    // In registration order, after init.lua (so after "plain"); an error in
    // one is reported as "startup" and does not stop the others.
    var order: [5]usize = undefined;
    for ([_][]const u8{ "plain", "startup:1", "startup:2", "startup:3", "startup:after-error" }, 0..) |want, i| {
        order[i] = for (f.log.items, 0..) |l, j| {
            if (std.mem.eql(u8, l, want)) break j;
        } else return error.TestMissing;
    }
    for (1..order.len) |i| try t.expect(order[i - 1] < order[i]);
    try t.expect(hasError("startup: tests/lua/startup.lua:8: startup boom"));
    try t.expectEqual(1, takeErrors());

    // Reload: the config runs again, startup functions and once-commands do not.
    rt.requestReload();
    try t.expectEqual(2, f.count("plain"));
    try t.expectEqual(1, f.count("startup:1"));
    try t.expectEqual(1, f.count("startup-returned:false"));
    try t.expectEqual(1, f.count("once-cmd"));
    try t.expectEqual(2, f.count("once-second:false"));
    // Outside init.lua it is an error.
    rt.emit(.layout, 0);
    try t.expectEqual(1, f.count("late:false"));
    try t.expectEqual(0, takeErrors());
}
