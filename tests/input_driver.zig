//! TEST-ONLY input driver for tests/input.sh. Needs a raywm built with
//! -Dtest-input. Creates a virtual pointer and keyboard and runs commands
//! given as arguments, with a roundtrip after each one:
//!   move X Y          absolute pointer position in layout pixels
//!   relative DX DY    relative motion (also unaccelerated)
//!   down|up left|right|middle
//!   key NAME down|up  NAME: super, ctrl, alt, shift, f5 .. f12,
//!                     a-z, 0-9, tab, print, escape, space, return,
//!                     left, right, up, down, comma, period
//!   group N           locks keyboard layout group N (0 = first layout), as
//!                     a layout switch key does
//!   sleep MS
//! RAYWM_TEST_EXTENT=WxH: the layout size for absolute motion (default
//! 1280x720, one headless output). The keymap follows XKB_DEFAULT_LAYOUT
//! etc., e.g. XKB_DEFAULT_LAYOUT=us,ru for a two-layout keymap.
const std = @import("std");
const posix = std.posix;
const wayland = @import("wayland");
const wl = wayland.client.wl;
const zwlr = wayland.client.zwlr;
const zwp = wayland.client.zwp;
const xkb = @import("xkbcommon");

const BTN_LEFT = 0x110;
const BTN_RIGHT = 0x111;
const BTN_MIDDLE = 0x112;
const KEY_F12 = 88;
const KEY_F11 = 87;
const KEY_F10 = 68;
const KEY_F9 = 67;
const KEY_H = 35;
const KEY_J = 36;
const KEY_K = 37;
const KEY_L = 38;
const KEY_Q = 16;
const KEY_TAB = 15;
const KEY_R = 19;
const KEY_LEFTCTRL = 29;
const KEY_LEFTALT = 56;
const KEY_LEFTSHIFT = 42;
const KEY_P = 25;
const KEY_SYSRQ = 99; // the Print key
const KEY_ESC = 1;

const Key = struct { name: []const u8, code: u32, mod: ?[*:0]const u8 = null };
const keys = [_]Key{
    .{ .name = "super", .code = KEY_LEFTMETA, .mod = "Mod4" },
    .{ .name = "ctrl", .code = KEY_LEFTCTRL, .mod = "Control" },
    .{ .name = "alt", .code = KEY_LEFTALT, .mod = "Mod1" },
    .{ .name = "shift", .code = KEY_LEFTSHIFT, .mod = "Shift" },
    .{ .name = "p", .code = KEY_P },
    .{ .name = "print", .code = KEY_SYSRQ },
    .{ .name = "escape", .code = KEY_ESC },
    .{ .name = "f5", .code = 63 },
    .{ .name = "f6", .code = 64 },
    .{ .name = "f7", .code = 65 },
    .{ .name = "f8", .code = 66 },
    .{ .name = "f9", .code = KEY_F9 },
    .{ .name = "f10", .code = KEY_F10 },
    .{ .name = "f11", .code = KEY_F11 },
    .{ .name = "f12", .code = KEY_F12 },
    .{ .name = "h", .code = KEY_H },
    .{ .name = "j", .code = KEY_J },
    .{ .name = "k", .code = KEY_K },
    .{ .name = "l", .code = KEY_L },
    .{ .name = "q", .code = KEY_Q },
    .{ .name = "tab", .code = KEY_TAB },
    .{ .name = "r", .code = KEY_R },
    // Evdev codes (linux/input-event-codes.h).
    .{ .name = "space", .code = 57 },
    .{ .name = "return", .code = 28 },
    .{ .name = "left", .code = 105 },
    .{ .name = "right", .code = 106 },
    .{ .name = "up", .code = 103 },
    .{ .name = "down", .code = 108 },
    .{ .name = "comma", .code = 51 },
    .{ .name = "period", .code = 52 },
    .{ .name = "1", .code = 2 },
    .{ .name = "2", .code = 3 },
    .{ .name = "3", .code = 4 },
    .{ .name = "4", .code = 5 },
    .{ .name = "5", .code = 6 },
    .{ .name = "6", .code = 7 },
    .{ .name = "7", .code = 8 },
    .{ .name = "8", .code = 9 },
    .{ .name = "9", .code = 10 },
    .{ .name = "0", .code = 11 },
    .{ .name = "a", .code = 30 },
    .{ .name = "b", .code = 48 },
    .{ .name = "c", .code = 46 },
    .{ .name = "d", .code = 32 },
    .{ .name = "e", .code = 18 },
    .{ .name = "f", .code = 33 },
    .{ .name = "g", .code = 34 },
    .{ .name = "i", .code = 23 },
    .{ .name = "m", .code = 50 },
    .{ .name = "n", .code = 49 },
    .{ .name = "o", .code = 24 },
    .{ .name = "s", .code = 31 },
    .{ .name = "t", .code = 20 },
    .{ .name = "u", .code = 22 },
    .{ .name = "v", .code = 47 },
    .{ .name = "w", .code = 17 },
    .{ .name = "x", .code = 45 },
    .{ .name = "y", .code = 21 },
    .{ .name = "z", .code = 44 },
};
const KEY_LEFTMETA = 125;

const Globals = struct {
    seat: ?*wl.Seat = null,
    pointer_mgr: ?*zwlr.VirtualPointerManagerV1 = null,
    keyboard_mgr: ?*zwp.VirtualKeyboardManagerV1 = null,
};

pub fn main(init: std.process.Init) !void {
    const argv = init.minimal.args.vector;
    const display = try wl.Display.connect(null);
    defer display.disconnect();
    const registry = try display.getRegistry();
    var g: Globals = .{};
    registry.setListener(*Globals, registryListener, &g);
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
    const seat = g.seat orelse return error.NoSeat;
    const pointer = try (g.pointer_mgr orelse return error.NoVirtualPointer).createVirtualPointer(seat);
    const keyboard = try (g.keyboard_mgr orelse return error.NoVirtualKeyboard).createVirtualKeyboard(seat);
    // wlroots does not derive modifiers from virtual key events, so the
    // driver sends them explicitly, like real virtual-keyboard clients.
    const keymap = try uploadKeymap(keyboard);
    defer keymap.unref();
    var depressed: u32 = 0;
    var group: u32 = 0;
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    // Matches the single default headless output (WLR_HEADLESS_OUTPUTS=1).
    var extent_w: u32 = 1280;
    var extent_h: u32 = 720;
    if (std.c.getenv("RAYWM_TEST_EXTENT")) |e| {
        var it = std.mem.splitScalar(u8, std.mem.span(e), 'x');
        extent_w = try std.fmt.parseInt(u32, it.next() orelse "", 10);
        extent_h = try std.fmt.parseInt(u32, it.next() orelse "", 10);
    }

    var time: u32 = 1;
    var i: usize = 1;
    while (i < argv.len) : (time += 10) {
        const cmd = std.mem.span(argv[i]);
        const a = if (i + 1 < argv.len) std.mem.span(argv[i + 1]) else "";
        const b = if (i + 2 < argv.len) std.mem.span(argv[i + 2]) else "";
        if (std.mem.eql(u8, cmd, "move")) {
            const x = try std.fmt.parseInt(u32, a, 10);
            const y = try std.fmt.parseInt(u32, b, 10);
            pointer.motionAbsolute(time, x, y, extent_w, extent_h);
            pointer.frame();
            i += 3;
        } else if (std.mem.eql(u8, cmd, "relative")) {
            const dx = try std.fmt.parseFloat(f64, a);
            const dy = try std.fmt.parseFloat(f64, b);
            pointer.motion(time, wl.Fixed.fromDouble(dx), wl.Fixed.fromDouble(dy));
            pointer.frame();
            i += 3;
        } else if (std.mem.eql(u8, cmd, "down") or std.mem.eql(u8, cmd, "up")) {
            const button: u32 = if (std.mem.eql(u8, a, "right")) BTN_RIGHT else if (std.mem.eql(u8, a, "middle")) BTN_MIDDLE else BTN_LEFT;
            pointer.button(time, button, if (cmd[0] == 'd') .pressed else .released);
            pointer.frame();
            i += 2;
        } else if (std.mem.eql(u8, cmd, "key")) {
            const k = for (keys) |k| {
                if (std.mem.eql(u8, k.name, a)) break k;
            } else return error.UnknownKey;
            const down = std.mem.eql(u8, b, "down");
            keyboard.key(time, k.code, if (down) 1 else 0);
            if (k.mod) |m| {
                const index = keymap.modGetIndex(m);
                if (index >= 32) return error.UnknownModifier;
                const bit = @as(u32, 1) << @intCast(index);
                depressed = if (down) depressed | bit else depressed & ~bit;
                keyboard.modifiers(depressed, 0, 0, group);
            }
            i += 3;
        } else if (std.mem.eql(u8, cmd, "group")) {
            group = try std.fmt.parseInt(u32, a, 10);
            keyboard.modifiers(depressed, 0, 0, group);
            i += 2;
        } else if (std.mem.eql(u8, cmd, "sleep")) {
            const ms = try std.fmt.parseInt(u32, a, 10);
            var ts: posix.timespec = .{ .sec = ms / 1000, .nsec = @as(isize, ms % 1000) * std.time.ns_per_ms };
            _ = posix.system.nanosleep(&ts, &ts);
            i += 2;
        } else {
            std.debug.print("unknown command '{s}'\n", .{cmd});
            return error.UnknownCommand;
        }
        if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
    }
    pointer.destroy();
    keyboard.destroy();
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
    std.debug.print("driver: done\n", .{});
}

/// The virtual keyboard needs a keymap before any key event. Returns the
/// keymap (caller unrefs) to look up modifier masks.
fn uploadKeymap(keyboard: *zwp.VirtualKeyboardV1) !*xkb.Keymap {
    const ctx = xkb.Context.new(.no_flags) orelse return error.XkbContext;
    defer ctx.unref();
    const keymap = xkb.Keymap.newFromNames(ctx, null, .no_flags) orelse return error.XkbKeymap;
    errdefer keymap.unref();
    const text: [*:0]u8 = keymap.getAsString(.text_v1) orelse return error.XkbKeymapString;
    defer std.c.free(text);
    const bytes = std.mem.span(text);
    const size = bytes.len + 1;
    const fd = try posix.memfd_create("raywm-test-keymap", 0);
    defer _ = posix.system.close(fd);
    if (posix.errno(posix.system.ftruncate(fd, @intCast(size))) != .SUCCESS) return error.Ftruncate;
    const map = try posix.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
    defer posix.munmap(map);
    @memcpy(map[0..bytes.len], bytes);
    map[bytes.len] = 0;
    keyboard.keymap(@intFromEnum(wl.Keyboard.KeymapFormat.xkb_v1), fd, @intCast(size));
    return keymap;
}

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, g: *Globals) void {
    switch (event) {
        .global => |global| {
            const name = std.mem.span(global.interface);
            if (std.mem.eql(u8, name, std.mem.span(wl.Seat.interface.name))) {
                g.seat = registry.bind(global.name, wl.Seat, 1) catch return;
            } else if (std.mem.eql(u8, name, std.mem.span(zwlr.VirtualPointerManagerV1.interface.name))) {
                g.pointer_mgr = registry.bind(global.name, zwlr.VirtualPointerManagerV1, 1) catch return;
            } else if (std.mem.eql(u8, name, std.mem.span(zwp.VirtualKeyboardManagerV1.interface.name))) {
                g.keyboard_mgr = registry.bind(global.name, zwp.VirtualKeyboardManagerV1, 1) catch return;
            }
        },
        .global_remove => {},
    }
}
