//! Unit tests for the Lua plugin host against a fake compositor.
//! Plugins report what they observe through raywm.spawn(), which the fake
//! host records. Fixtures live in tests/lua/ (run from the repo root).
const std = @import("std");
const lua = @import("lua");

const Fake = struct {
    log: std.ArrayList([]u8) = .empty,
    timer_ms: ?u32 = null,
    quit: bool = false,

    pub const Api = struct {
        pub fn views(_: *Fake, buf: []u32) usize {
            buf[0] = 1;
            return 1;
        }
        pub fn view(_: *Fake, id: u32) ?lua.ViewInfo {
            if (id != 1) return null;
            return .{ .box = .{ .x = 0, .y = 0, .w = 640, .h = 480 }, .title = "term", .app_id = "foot", .focused = true, .output = 1 };
        }
        pub fn viewCmd(_: *Fake, id: u32, _: lua.ViewCmd) bool {
            return id == 1;
        }
        pub fn outputs(_: *Fake, buf: []u32) usize {
            buf[0] = 2; // id 2 vanishes between listing and lookup
            buf[1] = 1;
            return 2;
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

/// Collected plugin errors ("source: first line"), checked by the tests.
var errors: std.ArrayList([]u8) = .empty;
fn report(source: []const u8, msg: []const u8) void {
    const line = std.mem.sliceTo(msg, '\n');
    const e = std.fmt.allocPrint(std.testing.allocator, "{s}: {s}", .{ source, line }) catch unreachable;
    errors.append(std.testing.allocator, e) catch unreachable;
}
fn takeErrors() usize {
    defer {
        for (errors.items) |e| std.testing.allocator.free(e);
        errors.clearAndFree(std.testing.allocator);
    }
    return errors.items.len;
}
fn hasError(needle: []const u8) bool {
    for (errors.items) |e| if (std.mem.indexOf(u8, e, needle) != null) return true;
    return false;
}
const opts: lua.Limits = .{ .report = report };
var fake_now: u64 = 1_000_000_000;
fn fakeClock() u64 {
    return fake_now;
}

test "plugin contract, dispatch and error isolation" {
    var f: Fake = .{};
    defer f.deinit();
    const rt = try RT.create(&f, "tests/lua/basic.lua", opts);
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
    const rt = try RT.create(&f, "tests/lua/basic.lua", opts);
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
    const rt = try RT.create(&f, "tests/lua/limits.lua", .{ .memory = 16 << 20, .instructions = 5_000_000, .report = report });
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
    const rt = try RT.create(&f, "tests/lua/basic.lua", opts);
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
    const rt = try RT.create(&f, "tests/lua/broken.lua", opts);
    try std.testing.expect(!rt.configured());
    try std.testing.expectEqual(1, f.count("setup:probe"));
    rt.destroy();
    try std.testing.expectEqual(1, f.count("teardown:probe"));
    try std.testing.expect(hasError("init.lua: tests/lua/broken.lua:2: bad config"));
    try std.testing.expectEqual(1, takeErrors());
}

test "missing config is not fatal" {
    var f: Fake = .{};
    defer f.deinit();
    const rt = try RT.create(&f, "tests/lua/does-not-exist.lua", opts);
    defer rt.destroy();
    try std.testing.expect(!rt.configured());
    try std.testing.expect(!rt.hasBindings());
}

test "reload requested from init.lua or teardown is ignored, not recursive" {
    var f: Fake = .{};
    defer f.deinit();
    const rt = try RT.create(&f, "tests/lua/reload_in_config.lua", opts);
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
    const rt = try RT.create(&f, "tests/lua/basic.lua", opts);
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
    const rt = try RT.create(&f, "tests/lua/budget.lua", .{ .instructions = 1_000_000, .report = report });
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
    const rt = try RT.create(&f, "tests/lua/manage.lua", opts);
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
