//! Input device configuration: keyboard layouts and key repeat, pointer
//! and touchpad settings (libinput), per device.
//!
//! Settings come in layers; each overrides the one before, field by field:
//!   "*"                    every device
//!   "type:keyboard", "type:pointer", "type:touchpad", "type:touch",
//!   "type:tablet", "type:switch"
//!   a device name          e.g. "SynPS/2 Synaptics TouchPad"
//! A field set in no layer has its default: keyboards use the XKB_DEFAULT_*
//! environment variables and repeat 25 keys/s after 600 ms; pointer
//! devices use libinput's defaults. So a setting removed from the config
//! is undone at the next reload.
//!
//! The layers belong to the configuration: a (re)load starts with none,
//! init.lua sets them, and then every device gets its settings (only what
//! changed is applied; a keymap is compiled only when its names change).
//! Settings given later (e.g. from a key binding) apply at once.
//!
//! Virtual keyboards (wtype, on-screen keyboards) keep the keymap their
//! client gave them; only key repeat applies to them. A layout that does
//! not compile is refused and the keyboard keeps its keymap.
const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const xkb = @import("xkbcommon");
const srv = @import("server.zig");
const Server = srv.Server;
const gpa = srv.gpa;
const log = std.log.scoped(.input);

pub const default_repeat_rate = 25;
pub const default_repeat_delay = 600;

pub const AccelProfile = enum { flat, adaptive };
pub const ScrollMethod = enum { none, two_finger, edge, button };
pub const ClickMethod = enum { none, button_areas, clickfinger };
pub const SendEvents = enum { enabled, disabled, disabled_on_external_mouse };
pub const Kind = enum { keyboard, pointer, touchpad, touch, tablet, tablet_pad, @"switch" };

/// One layer of settings; null fields are not set by this layer.
/// Strings are owned by the store (see Store).
pub const Settings = struct {
    xkb_rules: ?[]const u8 = null,
    xkb_model: ?[]const u8 = null,
    xkb_layout: ?[]const u8 = null,
    xkb_variant: ?[]const u8 = null,
    xkb_options: ?[]const u8 = null,
    repeat_rate: ?i32 = null,
    repeat_delay: ?i32 = null,
    accel_profile: ?AccelProfile = null,
    accel_speed: ?f64 = null,
    natural_scroll: ?bool = null,
    left_handed: ?bool = null,
    tap: ?bool = null,
    tap_drag: ?bool = null,
    drag_lock: ?bool = null,
    dwt: ?bool = null,
    middle_emulation: ?bool = null,
    scroll_method: ?ScrollMethod = null,
    scroll_button: ?u32 = null,
    click_method: ?ClickMethod = null,
    send_events: ?SendEvents = null,

    const string_fields = .{ "xkb_rules", "xkb_model", "xkb_layout", "xkb_variant", "xkb_options" };

    /// `over`'s set fields replace ours (strings are borrowed).
    pub fn merge(base: *Settings, over: Settings) void {
        inline for (std.meta.fields(Settings)) |f| {
            if (@field(over, f.name)) |v| @field(base, f.name) = v;
        }
    }

    fn freeStrings(s: *Settings) void {
        inline for (string_fields) |name| if (@field(s, name)) |v| gpa.free(v);
    }

    /// A copy owning its strings.
    fn dupe(s: Settings) !Settings {
        var r = s;
        inline for (string_fields) |name| @field(r, name) = null;
        errdefer r.freeStrings();
        inline for (string_fields) |name| if (@field(s, name)) |v| {
            @field(r, name) = try gpa.dupe(u8, v);
        };
        return r;
    }

    /// Range checks of the numbers (strings are checked by compiling).
    pub fn validate(s: Settings) error{BadValue}!void {
        if (s.repeat_rate) |r| if (r < 0 or r > 1000) return error.BadValue;
        if (s.repeat_delay) |d| if (d < 0 or d > 10_000) return error.BadValue;
        if (s.accel_speed) |a| if (!(a >= -1 and a <= 1)) return error.BadValue;
        if (s.scroll_button) |b| if (b > 0x2ff) return error.BadValue;
        inline for (string_fields) |name| if (@field(s, name)) |v| {
            if (v.len > 256 or std.mem.indexOfScalar(u8, v, 0) != null) return error.BadValue;
        };
    }
};

pub const Match = union(enum) { all, kind: Kind, name: []const u8 };

pub fn parseMatch(spec: []const u8) ?Match {
    if (std.mem.eql(u8, spec, "*")) return .all;
    if (std.mem.startsWith(u8, spec, "type:")) {
        return .{ .kind = std.meta.stringToEnum(Kind, spec["type:".len..]) orelse return null };
    }
    if (spec.len == 0 or spec.len > 256) return null;
    return .{ .name = spec };
}

/// The configured layers.
pub const Store = struct {
    all: Settings = .{},
    kinds: [std.meta.fields(Kind).len]Settings = @splat(.{}),
    names: std.StringHashMapUnmanaged(Settings) = .empty,

    pub fn clear(st: *Store) void {
        st.all.freeStrings();
        st.all = .{};
        for (&st.kinds) |*k| {
            k.freeStrings();
            k.* = .{};
        }
        var it = st.names.iterator();
        while (it.next()) |e| {
            e.value_ptr.freeStrings();
            gpa.free(e.key_ptr.*);
        }
        st.names.clearRetainingCapacity();
    }

    pub fn deinit(st: *Store) void {
        st.clear();
        st.names.deinit(gpa);
    }

    /// Merges `s` into the layer `m` (copying strings).
    pub fn set(st: *Store, m: Match, s: Settings) !void {
        try s.validate();
        const layer: *Settings = switch (m) {
            .all => &st.all,
            .kind => |k| &st.kinds[@intFromEnum(k)],
            .name => |n| blk: {
                const gop = try st.names.getOrPut(gpa, n);
                if (!gop.found_existing) {
                    gop.key_ptr.* = gpa.dupe(u8, n) catch |err| {
                        st.names.removeByPtr(gop.key_ptr);
                        return err;
                    };
                    gop.value_ptr.* = .{};
                }
                break :blk gop.value_ptr;
            },
        };
        const owned = try s.dupe();
        // Replace the strings this layer had for the fields `s` sets.
        inline for (Settings.string_fields) |name| if (@field(owned, name) != null) if (@field(layer.*, name)) |old| gpa.free(old);
        layer.merge(owned);
    }

    /// The settings of a device (strings borrowed from the store).
    pub fn effective(st: *const Store, kind: Kind, name: []const u8) Settings {
        var r: Settings = .{};
        r.merge(st.all);
        // A touchpad is a pointer too.
        if (kind == .touchpad) r.merge(st.kinds[@intFromEnum(Kind.pointer)]);
        r.merge(st.kinds[@intFromEnum(kind)]);
        if (st.names.get(name)) |s| r.merge(s);
        return r;
    }
};

// ---- devices ------------------------------------------------------------------

/// Every input device (keyboards also have an input.Keyboard).
pub const Device = struct {
    server: *Server,
    wlr_device: *wlr.InputDevice,
    id: u32,
    kind: Kind,
    /// In server.devices.
    link: wl.list.Link = undefined,
    /// xkb names of the keymap it has (keyboards), to compile only on change.
    keymap_key: ?[]u8 = null,
    destroy: wl.Listener(*wlr.InputDevice) = .init(handleDestroy),

    pub fn create(server: *Server, wlr_device: *wlr.InputDevice) !*Device {
        const dev = try gpa.create(Device);
        // Own id space: devices come and go (virtual ones often), and
        // their ids are only used with the input functions.
        server.next_device_id +%= 1;
        if (server.next_device_id == 0) server.next_device_id = 1;
        dev.* = .{ .server = server, .wlr_device = wlr_device, .id = server.next_device_id, .kind = kindOf(wlr_device) };
        server.devices.append(dev);
        wlr_device.events.destroy.add(&dev.destroy);
        return dev;
    }

    pub fn name(dev: *Device) []const u8 {
        return if (dev.wlr_device.name) |n| std.mem.span(n) else "";
    }

    pub fn isVirtual(dev: *Device) bool {
        return dev.wlr_device.type == .keyboard and dev.wlr_device.getVirtualKeyboard() != null;
    }

    fn handleDestroy(listener: *wl.Listener(*wlr.InputDevice), _: *wlr.InputDevice) void {
        const dev: *Device = @fieldParentPtr("destroy", listener);
        const server = dev.server;
        const id = dev.id;
        dev.destroy.link.remove();
        dev.link.remove();
        if (dev.keymap_key) |k| gpa.free(k);
        gpa.destroy(dev);
        server.emit(.input_remove, id);
    }

    /// Applies the effective settings. Keymap errors are returned (the
    /// keyboard keeps its keymap); libinput settings a device does not
    /// support are skipped.
    pub fn apply(dev: *Device) error{BadKeymap}!void {
        const s = dev.server.input_store.effective(dev.kind, dev.name());
        switch (dev.wlr_device.type) {
            .keyboard => try dev.applyKeyboard(s),
            .pointer => dev.applyLibinput(s),
            else => {},
        }
    }

    fn applyKeyboard(dev: *Device, s: Settings) error{BadKeymap}!void {
        const kb = dev.wlr_device.toKeyboard();
        if (!dev.isVirtual()) {
            var buf: [1400]u8 = undefined;
            const key = std.fmt.bufPrint(&buf, "{s}\x00{s}\x00{s}\x00{s}\x00{s}", .{
                s.xkb_rules orelse "", s.xkb_model orelse "", s.xkb_layout orelse "", s.xkb_variant orelse "", s.xkb_options orelse "",
            }) catch return error.BadKeymap;
            if (dev.keymap_key == null or !std.mem.eql(u8, dev.keymap_key.?, key)) {
                const keymap = compileKeymap(s) orelse {
                    log.err("keyboard {s}: layout \"{s}\" (variant \"{s}\", options \"{s}\") does not compile; keeping the current keymap", .{ dev.name(), s.xkb_layout orelse "", s.xkb_variant orelse "", s.xkb_options orelse "" });
                    return error.BadKeymap;
                };
                defer keymap.unref();
                if (!kb.setKeymap(keymap)) return error.BadKeymap;
                if (dev.keymap_key) |k| gpa.free(k);
                dev.keymap_key = gpa.dupe(u8, key) catch null;
            }
        }
        kb.setRepeatInfo(s.repeat_rate orelse default_repeat_rate, s.repeat_delay orelse default_repeat_delay);
    }

    fn applyLibinput(dev: *Device, s: Settings) void {
        const d: *li.Handle = @ptrCast(dev.wlr_device.getLibinputDevice() orelse return);
        const on = struct {
            fn f(b: bool) c_int {
                return @intFromBool(b);
            }
        }.f;
        if (li.libinput_device_config_accel_is_available(d) != 0) {
            _ = li.libinput_device_config_accel_set_profile(d, if (s.accel_profile) |p| switch (p) {
                .flat => li.accel_flat,
                .adaptive => li.accel_adaptive,
            } else li.libinput_device_config_accel_get_default_profile(d));
            _ = li.libinput_device_config_accel_set_speed(d, s.accel_speed orelse li.libinput_device_config_accel_get_default_speed(d));
        }
        if (li.libinput_device_config_scroll_has_natural_scroll(d) != 0)
            _ = li.libinput_device_config_scroll_set_natural_scroll_enabled(d, if (s.natural_scroll) |b| on(b) else li.libinput_device_config_scroll_get_default_natural_scroll_enabled(d));
        if (li.libinput_device_config_left_handed_is_available(d) != 0)
            _ = li.libinput_device_config_left_handed_set(d, if (s.left_handed) |b| on(b) else li.libinput_device_config_left_handed_get_default(d));
        if (li.libinput_device_config_tap_get_finger_count(d) > 0) {
            _ = li.libinput_device_config_tap_set_enabled(d, if (s.tap) |b| on(b) else li.libinput_device_config_tap_get_default_enabled(d));
            _ = li.libinput_device_config_tap_set_drag_enabled(d, if (s.tap_drag) |b| on(b) else li.libinput_device_config_tap_get_default_drag_enabled(d));
            _ = li.libinput_device_config_tap_set_drag_lock_enabled(d, if (s.drag_lock) |b| on(b) else li.libinput_device_config_tap_get_default_drag_lock_enabled(d));
        }
        if (li.libinput_device_config_dwt_is_available(d) != 0)
            _ = li.libinput_device_config_dwt_set_enabled(d, if (s.dwt) |b| on(b) else li.libinput_device_config_dwt_get_default_enabled(d));
        if (li.libinput_device_config_middle_emulation_is_available(d) != 0)
            _ = li.libinput_device_config_middle_emulation_set_enabled(d, if (s.middle_emulation) |b| on(b) else li.libinput_device_config_middle_emulation_get_default_enabled(d));
        const methods = li.libinput_device_config_scroll_get_methods(d);
        if (methods != 0) {
            const want: u32 = if (s.scroll_method) |m| switch (m) {
                .none => li.scroll_none,
                .two_finger => li.scroll_2fg,
                .edge => li.scroll_edge,
                .button => li.scroll_button,
            } else li.libinput_device_config_scroll_get_default_method(d);
            if (want == 0 or methods & want != 0) _ = li.libinput_device_config_scroll_set_method(d, want);
            if (want == li.scroll_button) _ = li.libinput_device_config_scroll_set_button(d, s.scroll_button orelse li.libinput_device_config_scroll_get_default_button(d));
        }
        const clicks = li.libinput_device_config_click_get_methods(d);
        if (clicks != 0) {
            const want: u32 = if (s.click_method) |m| switch (m) {
                .none => li.click_none,
                .button_areas => li.click_button_areas,
                .clickfinger => li.click_clickfinger,
            } else li.libinput_device_config_click_get_default_method(d);
            if (want == 0 or clicks & want != 0) _ = li.libinput_device_config_click_set_method(d, want);
        }
        _ = li.libinput_device_config_send_events_set_mode(d, if (s.send_events) |m| switch (m) {
            .enabled => li.send_enabled,
            .disabled => li.send_disabled,
            .disabled_on_external_mouse => li.send_disabled_on_external_mouse,
        } else li.libinput_device_config_send_events_get_default_mode(d));
    }
};

fn kindOf(d: *wlr.InputDevice) Kind {
    return switch (d.type) {
        .keyboard => .keyboard,
        .pointer => blk: {
            const h: *li.Handle = @ptrCast(d.getLibinputDevice() orelse break :blk .pointer);
            break :blk if (li.libinput_device_config_tap_get_finger_count(h) > 0) .touchpad else .pointer;
        },
        .touch => .touch,
        .tablet => .tablet,
        .tablet_pad => .tablet_pad,
        .@"switch" => .@"switch",
    };
}

/// A keymap from the settings' names; null fields come from the
/// XKB_DEFAULT_* environment variables (libxkbcommon's rule).
pub fn compileKeymap(s: Settings) ?*xkb.Keymap {
    const context = xkb.Context.new(.no_flags) orelse return null;
    defer context.unref();
    var bufs: [5][257]u8 = undefined;
    const fields = [_]?[]const u8{ s.xkb_rules, s.xkb_model, s.xkb_layout, s.xkb_variant, s.xkb_options };
    var z: [5]?[*:0]const u8 = @splat(null);
    for (fields, 0..) |f, i| if (f) |v| {
        z[i] = std.fmt.bufPrintZ(&bufs[i], "{s}", .{v}) catch return null;
    };
    const names: xkb.RuleNames = .{ .rules = z[0], .model = z[1], .layout = z[2], .variant = z[3], .options = z[4] };
    return xkb.Keymap.newFromNames(context, &names, .no_flags);
}

/// Every device gets its effective settings (after a (re)load, or after a
/// change that may concern several devices).
pub fn applyAll(server: *Server) void {
    var it = server.devices.iterator(.forward);
    while (it.next()) |d| d.apply() catch {};
}

/// libinput, only what RayWM uses (values from libinput.h 1.x).
const li = struct {
    const Handle = opaque {};
    const accel_flat: c_int = 1 << 0;
    const accel_adaptive: c_int = 1 << 1;
    const scroll_none: u32 = 0;
    const scroll_2fg: u32 = 1 << 0;
    const scroll_edge: u32 = 1 << 1;
    const scroll_button: u32 = 1 << 2;
    const click_none: u32 = 0;
    const click_button_areas: u32 = 1 << 0;
    const click_clickfinger: u32 = 1 << 1;
    const send_enabled: u32 = 0;
    const send_disabled: u32 = 1 << 0;
    const send_disabled_on_external_mouse: u32 = 1 << 1;

    extern fn libinput_device_config_tap_get_finger_count(d: *Handle) c_int;
    extern fn libinput_device_config_tap_set_enabled(d: *Handle, enable: c_int) c_int;
    extern fn libinput_device_config_tap_get_default_enabled(d: *Handle) c_int;
    extern fn libinput_device_config_tap_set_drag_enabled(d: *Handle, enable: c_int) c_int;
    extern fn libinput_device_config_tap_get_default_drag_enabled(d: *Handle) c_int;
    extern fn libinput_device_config_tap_set_drag_lock_enabled(d: *Handle, enable: c_int) c_int;
    extern fn libinput_device_config_tap_get_default_drag_lock_enabled(d: *Handle) c_int;
    extern fn libinput_device_config_accel_is_available(d: *Handle) c_int;
    extern fn libinput_device_config_accel_set_speed(d: *Handle, speed: f64) c_int;
    extern fn libinput_device_config_accel_get_default_speed(d: *Handle) f64;
    extern fn libinput_device_config_accel_set_profile(d: *Handle, profile: c_int) c_int;
    extern fn libinput_device_config_accel_get_default_profile(d: *Handle) c_int;
    extern fn libinput_device_config_scroll_has_natural_scroll(d: *Handle) c_int;
    extern fn libinput_device_config_scroll_set_natural_scroll_enabled(d: *Handle, enable: c_int) c_int;
    extern fn libinput_device_config_scroll_get_default_natural_scroll_enabled(d: *Handle) c_int;
    extern fn libinput_device_config_left_handed_is_available(d: *Handle) c_int;
    extern fn libinput_device_config_left_handed_set(d: *Handle, left: c_int) c_int;
    extern fn libinput_device_config_left_handed_get_default(d: *Handle) c_int;
    extern fn libinput_device_config_middle_emulation_is_available(d: *Handle) c_int;
    extern fn libinput_device_config_middle_emulation_set_enabled(d: *Handle, enable: c_int) c_int;
    extern fn libinput_device_config_middle_emulation_get_default_enabled(d: *Handle) c_int;
    extern fn libinput_device_config_dwt_is_available(d: *Handle) c_int;
    extern fn libinput_device_config_dwt_set_enabled(d: *Handle, enable: c_int) c_int;
    extern fn libinput_device_config_dwt_get_default_enabled(d: *Handle) c_int;
    extern fn libinput_device_config_scroll_get_methods(d: *Handle) u32;
    extern fn libinput_device_config_scroll_set_method(d: *Handle, method: u32) c_int;
    extern fn libinput_device_config_scroll_get_default_method(d: *Handle) u32;
    extern fn libinput_device_config_scroll_set_button(d: *Handle, button: u32) c_int;
    extern fn libinput_device_config_scroll_get_default_button(d: *Handle) u32;
    extern fn libinput_device_config_click_get_methods(d: *Handle) u32;
    extern fn libinput_device_config_click_set_method(d: *Handle, method: u32) c_int;
    extern fn libinput_device_config_click_get_default_method(d: *Handle) u32;
    extern fn libinput_device_config_send_events_set_mode(d: *Handle, mode: u32) c_int;
    extern fn libinput_device_config_send_events_get_default_mode(d: *Handle) u32;
};
