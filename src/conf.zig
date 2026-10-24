//! raywm.conf: the compositor's central settings (docs/CONFIGURATION.md).
//!
//! Format: INI-like. `[section]` headers, `key = value` entries, and
//! comments starting with `#` or `;` on their own line. Values are booleans
//! (true/false, yes/no, on/off, 1/0), integers in a fixed range, strings,
//! `#rrggbb[aa]` colours and a few keywords. Nothing is ever executed.
//!
//! Layers, later ones override earlier ones key by key: built-in defaults,
//! the system file (/usr/share/raywm/config/raywm.conf), the user file
//! (next to init.lua). A file with any error is rejected as a whole, so a
//! broken file never applies half of its settings. Unknown sections and
//! keys are reported as warnings and ignored (a newer file still loads).
//!
//! Every value is fixed-size, so parsing and reloading allocate nothing and
//! cannot leak. Depends only on std and libc: unit-testable without wlroots.
const std = @import("std");

/// An integer setting limited to [lo, hi].
pub fn Int(comptime lo: i32, comptime hi: i32) type {
    return struct {
        value: i32,
        pub const min = lo;
        pub const max = hi;
    };
}

/// A string setting without control characters, at most `cap` bytes.
pub fn Text(comptime cap: usize) type {
    return struct {
        /// Bytes past `len` are always zero, so two equal strings are equal
        /// structs (std.meta.eql) whatever was stored before.
        buf: [cap]u8 = @splat(0),
        len: u16 = 0,
        pub const capacity = cap;
        pub fn slice(t: *const @This()) []const u8 {
            return t.buf[0..t.len];
        }
    };
}

/// "#rrggbbaa" (normalized), or "none" where `optional`.
pub fn ColorT(comptime is_optional: bool) type {
    return struct {
        text: [9]u8 = "#00000000".*,
        none: bool = is_optional,
        pub const optional = is_optional;
        pub fn of(comptime spec: []const u8) @This() {
            var c: @This() = .{ .none = false };
            if (!parseColor(spec, &c.text)) @compileError("bad colour " ++ spec);
            return c;
        }
        pub fn slice(c: *const @This()) []const u8 {
            return if (c.none) "none" else &c.text;
        }
    };
}
pub const Color = ColorT(false);
pub const OptColor = ColorT(true);

/// The modifier for Super+drag (move/resize floating windows).
pub const Modifier = enum {
    super,
    alt,
    ctrl,
    shift,
    pub const aliases = .{ .{ "super", .super }, .{ "logo", .super }, .{ "mod4", .super }, .{ "win", .super }, .{ "alt", .alt }, .{ "mod1", .alt }, .{ "ctrl", .ctrl }, .{ "control", .ctrl }, .{ "shift", .shift } };
};

pub const Settings = struct {
    general: General = .{},
    appearance: Appearance = .{},
    input: Input = .{},

    pub const General = struct {
        /// A new window takes keyboard focus when it appears (unless a
        /// plugin chose focus itself while handling view_map).
        focus_new_windows: bool = true,
        /// Command for Super+Return (core fallback key and binds.lua);
        /// empty: $TERMINAL, else foot. Run through /bin/sh.
        terminal: Text(256) = .{},
        /// Start Xwayland lazily for X11 clients. RAYWM_XWAYLAND=0 also
        /// turns it off. Read at startup only.
        xwayland: bool = true,

        pub const restart_only = .{"xwayland"};
    };

    pub const Appearance = struct {
        /// Pixels between tiled windows (dwindle.lua).
        inner_gaps: Int(0, 500) = .{ .value = 8 },
        /// Pixels between tiled windows and the usable area's edge.
        outer_gaps: Int(0, 500) = .{ .value = 8 },
        /// Border width in pixels; 0: no borders (focus.lua).
        border_width: Int(0, 64) = .{ .value = 2 },
        /// Border colour of the focused window.
        border_active: Color = Color.of("#5294e2"),
        /// Border colour of the other windows; none: no border.
        border_inactive: OptColor = .{},

        pub const restart_only = .{};
    };

    pub const Input = struct {
        /// Modifier for dragging floating windows (button 1 moves,
        /// button 3 resizes).
        mouse_modifier: Modifier = .super,
        /// Focus the window the pointer moves into.
        focus_follows_mouse: bool = false,

        pub const restart_only = .{};
    };
};

// ---- diagnostics ------------------------------------------------------------

/// Messages from one parse, with line numbers. Bounded: further messages are
/// only counted.
pub const Diag = struct {
    pub const max = 16;
    pub const Item = struct {
        line: u32,
        is_error: bool,
        buf: [200]u8 = undefined,
        len: u8 = 0,
        pub fn text(i: *const Item) []const u8 {
            return i.buf[0..i.len];
        }
    };
    items: [max]Item = undefined,
    n: usize = 0,
    errors: usize = 0,
    warnings: usize = 0,

    fn add(d: *Diag, line: u32, is_error: bool, comptime fmt: []const u8, args: anytype) void {
        if (is_error) d.errors += 1 else d.warnings += 1;
        if (d.n == max) return;
        var item: Item = .{ .line = line, .is_error = is_error };
        const s = std.fmt.bufPrint(&item.buf, fmt, args) catch blk: {
            const tail = "...";
            @memcpy(item.buf[item.buf.len - tail.len ..], tail);
            break :blk item.buf[0..];
        };
        item.len = @intCast(s.len);
        d.items[d.n] = item;
        d.n += 1;
    }

    pub fn slice(d: *const Diag) []const Item {
        return d.items[0..d.n];
    }
};

// ---- parsing ----------------------------------------------------------------

/// Largest accepted file: the shipped one is ~2 KiB.
pub const max_file_size = 64 * 1024;

/// Applies `text` on top of `base`. Returns the result only if the whole
/// text is valid (diag.errors == 0); otherwise null and `base` is unused.
pub fn parse(text: []const u8, base: Settings, diag: *Diag) ?Settings {
    var out = base;
    var section: ?[]const u8 = null;
    var section_known = false;
    var line_no: u32 = 0;
    if (text.len > max_file_size) {
        diag.add(0, true, "file larger than {d} bytes", .{max_file_size});
        return null;
    }
    if (!std.unicode.utf8ValidateSlice(text)) {
        diag.add(0, true, "not valid UTF-8", .{});
        return null;
    }
    var seen: [64]u64 = undefined; // hashes of section.key, for duplicates
    var n_seen: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        line_no += 1;
        const line = std.mem.trim(u8, std.mem.trimEnd(u8, raw, "\r"), " \t");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
        if (hasControl(line)) {
            diag.add(line_no, true, "control character in line", .{});
            continue;
        }
        if (line[0] == '[') {
            if (line[line.len - 1] != ']') {
                diag.add(line_no, true, "section header must end with ']'", .{});
                // Its keys are skipped, not reported once more each.
                section = "";
                section_known = false;
                continue;
            }
            const name = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
            section = name;
            section_known = knownSection(name);
            if (!section_known) diag.add(line_no, false, "unknown section [{s}] ignored", .{name});
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
            diag.add(line_no, true, "expected 'key = value' or '[section]'", .{});
            continue;
        };
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (key.len == 0) {
            diag.add(line_no, true, "missing key before '='", .{});
            continue;
        }
        const sec = section orelse {
            diag.add(line_no, true, "'{s}' outside of a [section]", .{key});
            continue;
        };
        if (!section_known) continue;
        var h = std.hash.Wyhash.init(0);
        h.update(sec);
        h.update("\x00");
        h.update(key);
        const hash = h.final();
        const dup = for (seen[0..n_seen]) |s| {
            if (s == hash) break true;
        } else false;
        if (dup) diag.add(line_no, false, "[{s}] {s} set again; the last value is used", .{ sec, key });
        if (!dup and n_seen < seen.len) {
            seen[n_seen] = hash;
            n_seen += 1;
        }
        setKey(&out, sec, key, value, line_no, diag);
    }
    return if (diag.errors == 0) out else null;
}

fn hasControl(s: []const u8) bool {
    for (s) |ch| if ((ch < 0x20 and ch != '\t') or ch == 0x7f) return true;
    return false;
}

fn knownSection(name: []const u8) bool {
    inline for (std.meta.fields(Settings)) |f| if (std.mem.eql(u8, f.name, name)) return true;
    return false;
}

fn setKey(out: *Settings, sec: []const u8, key: []const u8, value: []const u8, line: u32, diag: *Diag) void {
    inline for (std.meta.fields(Settings)) |sf| if (std.mem.eql(u8, sf.name, sec)) {
        const s = &@field(out, sf.name);
        inline for (std.meta.fields(sf.type)) |kf| if (std.mem.eql(u8, kf.name, key)) {
            parseValue(kf.type, &@field(s, kf.name), value) catch |err| {
                diag.add(line, true, "[{s}] {s} = {s}: {s}", .{ sec, key, value, explain(kf.type, err) });
            };
            return;
        };
        diag.add(line, false, "unknown key '{s}' in [{s}] ignored", .{ key, sec });
        return;
    };
}

fn hasDecl(comptime T: type, comptime name: []const u8) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => @hasDecl(T, name),
        else => false,
    };
}

const ValueError = error{ NotBool, NotInt, OutOfRange, TooLong, BadText, NotColor, NotKeyword };

fn explain(comptime T: type, err: ValueError) []const u8 {
    return switch (err) {
        error.NotBool => "expected true or false",
        error.NotInt => "expected a whole number",
        error.OutOfRange => if (comptime hasDecl(T, "min")) std.fmt.comptimePrint("expected {d}..{d}", .{ T.min, T.max }) else "out of range",
        error.TooLong => "value too long",
        error.BadText => "quotes must enclose the whole value",
        error.NotColor => if (comptime hasDecl(T, "optional") and T.optional) "expected #rrggbb, #rrggbbaa or none" else "expected #rrggbb or #rrggbbaa",
        error.NotKeyword => if (T == Modifier) "expected super, alt, ctrl or shift" else "unknown keyword",
    };
}

fn parseValue(comptime T: type, dst: *T, value: []const u8) ValueError!void {
    if (T == bool) {
        dst.* = parseBool(value) orelse return error.NotBool;
    } else if (T == Modifier) {
        inline for (Modifier.aliases) |a| if (std.ascii.eqlIgnoreCase(value, a[0])) {
            dst.* = a[1];
            return;
        };
        return error.NotKeyword;
    } else if (comptime hasDecl(T, "min")) {
        const v = std.fmt.parseInt(i32, value, 10) catch |err| return switch (err) {
            error.Overflow => error.OutOfRange,
            error.InvalidCharacter => error.NotInt,
        };
        if (v < T.min or v > T.max) return error.OutOfRange;
        dst.value = v;
    } else if (comptime hasDecl(T, "capacity")) {
        var s = value;
        if (s.len > 0 and (s[0] == '"' or s[0] == '\'')) {
            if (s.len < 2 or s[s.len - 1] != s[0]) return error.BadText;
            s = s[1 .. s.len - 1];
        }
        if (s.len > T.capacity) return error.TooLong;
        if (hasControl(s)) return error.BadText;
        @memcpy(dst.buf[0..s.len], s);
        @memset(dst.buf[s.len..], 0);
        dst.len = @intCast(s.len);
    } else if (comptime hasDecl(T, "optional")) {
        if (T.optional and std.ascii.eqlIgnoreCase(value, "none")) {
            dst.none = true;
            return;
        }
        if (!parseColor(value, &dst.text)) return error.NotColor;
        dst.none = false;
    } else @compileError("unsupported setting type " ++ @typeName(T));
}

fn parseBool(v: []const u8) ?bool {
    for ([_][]const u8{ "true", "yes", "on", "1" }) |t| if (std.ascii.eqlIgnoreCase(v, t)) return true;
    for ([_][]const u8{ "false", "no", "off", "0" }) |f| if (std.ascii.eqlIgnoreCase(v, f)) return false;
    return null;
}

/// "#rgb"-style shorthands are not accepted: only #rrggbb and #rrggbbaa.
/// Writes the normalized lower-case "#rrggbbaa".
fn parseColor(spec: []const u8, out: *[9]u8) bool {
    if ((spec.len != 7 and spec.len != 9) or spec[0] != '#') return false;
    for (spec[1..]) |ch| if (!std.ascii.isHex(ch)) return false;
    out[0] = '#';
    for (spec[1..], 1..) |ch, i| out[i] = std.ascii.toLower(ch);
    if (spec.len == 7) {
        out[7] = 'f';
        out[8] = 'f';
    }
    return true;
}

// ---- files ------------------------------------------------------------------

pub const FileResult = enum { applied, missing, rejected };

/// Applies the file at `path` on top of `settings` if it is valid. A
/// missing file changes nothing. `buf` holds the file while it is parsed.
pub fn applyFile(path: [*:0]const u8, settings: *Settings, diag: *Diag, buf: *[max_file_size + 1]u8) FileResult {
    const fd = std.posix.openatZ(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return .missing,
        else => {
            diag.add(0, true, "cannot open: {s}", .{@errorName(err)});
            return .rejected;
        },
    };
    defer _ = std.c.close(fd);
    var len: usize = 0;
    while (len < buf.len) {
        const n = std.posix.read(fd, buf[len..]) catch |err| {
            diag.add(0, true, "cannot read: {s}", .{@errorName(err)});
            return .rejected;
        };
        if (n == 0) break;
        len += n;
    }
    const result = parse(buf[0..len], settings.*, diag) orelse return .rejected;
    settings.* = result;
    return .applied;
}

/// Default system file; RAYWM_SYSTEM_CONF overrides it (empty: none), for
/// tests and for running from a build tree.
pub const system_path = "/usr/share/raywm/config/raywm.conf";

/// Names the restart-only settings that differ between `a` and `b`.
pub fn restartOnlyChanged(a: *const Settings, b: *const Settings, out: *[8][]const u8) [][]const u8 {
    var n: usize = 0;
    inline for (std.meta.fields(Settings)) |sf| {
        const S = sf.type;
        inline for (S.restart_only) |name| {
            const x = @field(@field(a, sf.name), name);
            const y = @field(@field(b, sf.name), name);
            if (!std.meta.eql(x, y) and n < out.len) {
                out[n] = sf.name ++ "." ++ name;
                n += 1;
            }
        }
    }
    return out[0..n];
}

/// Calls `f(ctx, section, key, value_text)` for every setting, in
/// declaration order. Used to export the settings to Lua and to print them.
pub fn each(s: *const Settings, ctx: anytype, comptime f: fn (@TypeOf(ctx), []const u8, []const u8, Value) void) void {
    inline for (std.meta.fields(Settings)) |sf| {
        const sec = &@field(s, sf.name);
        inline for (std.meta.fields(sf.type)) |kf| {
            const v = &@field(sec, kf.name);
            const T = kf.type;
            const value: Value = if (T == bool)
                .{ .boolean = v.* }
            else if (T == Modifier)
                .{ .string = @tagName(v.*) }
            else if (comptime hasDecl(T, "min"))
                .{ .integer = v.value }
            else
                .{ .string = v.slice() };
            f(ctx, sf.name, kf.name, value);
        }
    }
}

pub const Value = union(enum) { boolean: bool, integer: i32, string: []const u8 };

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

test "defaults match the behaviour before raywm.conf" {
    const s: Settings = .{};
    try testing.expect(s.general.focus_new_windows);
    try testing.expect(s.general.xwayland);
    try testing.expectEqualStrings("", s.general.terminal.slice());
    try testing.expectEqual(@as(i32, 8), s.appearance.inner_gaps.value);
    try testing.expectEqual(@as(i32, 8), s.appearance.outer_gaps.value);
    try testing.expectEqual(@as(i32, 2), s.appearance.border_width.value);
    try testing.expectEqualStrings("#5294e2ff", s.appearance.border_active.slice());
    try testing.expectEqualStrings("none", s.appearance.border_inactive.slice());
    try testing.expectEqual(Modifier.super, s.input.mouse_modifier);
    try testing.expect(!s.input.focus_follows_mouse);
}

test "valid file with comments, sections and every value type" {
    var d: Diag = .{};
    const s = parse(
        \\# RayWM
        \\; also a comment
        \\[general]
        \\focus_new_windows = no
        \\terminal = "kitty -1"
        \\
        \\[appearance]
        \\  inner_gaps=4
        \\outer_gaps = 0
        \\border_active = #FF0000
        \\border_inactive = #20202080
        \\[input]
        \\mouse_modifier = ALT
        \\focus_follows_mouse = on
    , .{}, &d) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 0), d.n);
    try testing.expect(!s.general.focus_new_windows);
    try testing.expectEqualStrings("kitty -1", s.general.terminal.slice());
    try testing.expectEqual(@as(i32, 4), s.appearance.inner_gaps.value);
    try testing.expectEqual(@as(i32, 0), s.appearance.outer_gaps.value);
    try testing.expectEqualStrings("#ff0000ff", s.appearance.border_active.slice());
    try testing.expectEqualStrings("#20202080", s.appearance.border_inactive.slice());
    try testing.expectEqual(Modifier.alt, s.input.mouse_modifier);
    try testing.expect(s.input.focus_follows_mouse);
}

test "empty file keeps the base" {
    var d: Diag = .{};
    var base: Settings = .{};
    base.appearance.inner_gaps.value = 3;
    const s = parse("", base, &d).?;
    try testing.expectEqual(@as(i32, 3), s.appearance.inner_gaps.value);
}

test "syntax errors carry line numbers and reject the whole file" {
    var d: Diag = .{};
    try testing.expect(parse(
        \\[appearance]
        \\inner_gaps = 3
        \\this is not a setting
        \\[general
        \\outer = 1
    , .{}, &d) == null);
    try testing.expectEqual(@as(usize, 2), d.errors);
    try testing.expectEqual(@as(u32, 3), d.slice()[0].line);
    try testing.expectEqual(@as(u32, 4), d.slice()[1].line);
}

test "key outside a section is an error" {
    var d: Diag = .{};
    try testing.expect(parse("inner_gaps = 3\n", .{}, &d) == null);
    try testing.expectEqual(@as(u32, 1), d.slice()[0].line);
}

test "unknown keys and sections are warnings; the rest applies" {
    var d: Diag = .{};
    const s = parse(
        \\[general]
        \\layout = dwindle
        \\[future]
        \\anything = 1
        \\[appearance]
        \\inner_gaps = 12
    , .{}, &d).?;
    try testing.expectEqual(@as(usize, 0), d.errors);
    try testing.expectEqual(@as(usize, 2), d.warnings);
    try testing.expectEqual(@as(u32, 2), d.slice()[0].line);
    try testing.expectEqual(@as(u32, 3), d.slice()[1].line);
    try testing.expectEqual(@as(i32, 12), s.appearance.inner_gaps.value);
}

test "invalid values are rejected" {
    const cases = [_][]const u8{
        "[general]\nfocus_new_windows = maybe",
        "[appearance]\ninner_gaps = -1",
        "[appearance]\ninner_gaps = 501",
        "[appearance]\ninner_gaps = 99999999999",
        "[appearance]\ninner_gaps = 8px",
        "[appearance]\nborder_width = ",
        "[appearance]\nborder_active = none",
        "[appearance]\nborder_active = #12345",
        "[appearance]\nborder_active = #gggggg",
        "[appearance]\nborder_inactive = red",
        "[input]\nmouse_modifier = hyper",
        "[general]\nterminal = \"foot",
        "[general]\nterminal = a\x01b",
        "[general]\nxwayland = \x00",
    };
    for (cases) |c| {
        var d: Diag = .{};
        if (parse(c, .{}, &d) != null) {
            std.debug.print("accepted: {s}\n", .{c});
            return error.TestUnexpectedResult;
        }
        try testing.expect(d.errors > 0);
        try testing.expectEqual(@as(u32, 2), d.slice()[0].line);
    }
}

test "error messages name the expectation" {
    var d: Diag = .{};
    _ = parse("[appearance]\nborder_width = 65\n", .{}, &d);
    try testing.expectEqualStrings("[appearance] border_width = 65: expected 0..64", d.slice()[0].text());
}

test "string length limit" {
    var d: Diag = .{};
    var long: [300]u8 = undefined;
    @memset(&long, 'a');
    var text: [400]u8 = undefined;
    const t = try std.fmt.bufPrint(&text, "[general]\nterminal = {s}\n", .{long});
    try testing.expect(parse(t, .{}, &d) == null);
}

test "a shorter string replacing a longer one compares equal to it set alone (fuzz regression)" {
    var d: Diag = .{};
    const a = parse("[general]\nterminal=500\nterminal = 0\n", .{}, &d).?;
    const b = parse("[general]\nterminal = 0\n", .{}, &d).?;
    try testing.expect(std.meta.eql(a, b));
}

test "duplicate keys warn and the last value wins" {
    var d: Diag = .{};
    const s = parse("[appearance]\ninner_gaps = 1\ninner_gaps = 2\n", .{}, &d).?;
    try testing.expectEqual(@as(i32, 2), s.appearance.inner_gaps.value);
    try testing.expectEqual(@as(usize, 1), d.warnings);
}

test "CRLF line endings and invalid UTF-8" {
    var d: Diag = .{};
    const s = parse("[appearance]\r\nouter_gaps = 5\r\n", .{}, &d).?;
    try testing.expectEqual(@as(i32, 5), s.appearance.outer_gaps.value);
    try testing.expect(parse("[general]\nterminal = \xff\n", .{}, &d) == null);
}

test "diagnostics are bounded" {
    var d: Diag = .{};
    var text: [2000]u8 = undefined;
    var n: usize = 0;
    for (0..40) |_| {
        @memcpy(text[n..][0..4], "bad\n");
        n += 4;
    }
    try testing.expect(parse(text[0..n], .{}, &d) == null);
    try testing.expectEqual(@as(usize, 40), d.errors);
    try testing.expectEqual(@as(usize, Diag.max), d.n);
}

test "layers: a later file overrides key by key, a broken one changes nothing" {
    var d: Diag = .{};
    var s: Settings = .{};
    s = parse("[appearance]\ninner_gaps = 1\nouter_gaps = 2\n", s, &d).?;
    s = parse("[appearance]\nouter_gaps = 3\n", s, &d).?;
    try testing.expectEqual(@as(i32, 1), s.appearance.inner_gaps.value);
    try testing.expectEqual(@as(i32, 3), s.appearance.outer_gaps.value);
    try testing.expect(parse("[appearance]\ninner_gaps = 9\nouter_gaps = x\n", s, &d) == null);
    try testing.expectEqual(@as(i32, 1), s.appearance.inner_gaps.value);
}

test "restart-only settings are detected" {
    var a: Settings = .{};
    var b: Settings = .{};
    var buf: [8][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 0), restartOnlyChanged(&a, &b, &buf).len);
    b.general.xwayland = false;
    b.appearance.inner_gaps.value = 1;
    const changed = restartOnlyChanged(&a, &b, &buf);
    try testing.expectEqual(@as(usize, 1), changed.len);
    try testing.expectEqualStrings("general.xwayland", changed[0]);
    a = b;
}

test "the shipped config/raywm.conf is valid and equals the defaults" {
    var d: Diag = .{};
    var buf: [max_file_size + 1]u8 = undefined;
    var s: Settings = .{};
    try testing.expectEqual(FileResult.applied, applyFile("config/raywm.conf", &s, &d, &buf));
    try testing.expectEqual(@as(usize, 0), d.n);
    try testing.expect(std.meta.eql(s, Settings{}));
}

test "missing file" {
    var d: Diag = .{};
    var buf: [max_file_size + 1]u8 = undefined;
    var s: Settings = .{};
    try testing.expectEqual(FileResult.missing, applyFile("tests/config/does-not-exist.conf", &s, &d, &buf));
    try testing.expectEqual(FileResult.missing, applyFile("config/init.lua/raywm.conf", &s, &d, &buf));
    try testing.expectEqual(@as(usize, 0), d.n);
}

test "each visits every setting" {
    const Counter = struct {
        n: usize = 0,
        fn visit(c: *@This(), _: []const u8, _: []const u8, _: Value) void {
            c.n += 1;
        }
    };
    var c: Counter = .{};
    const s: Settings = .{};
    each(&s, &c, Counter.visit);
    try testing.expectEqual(@as(usize, 10), c.n);
}
