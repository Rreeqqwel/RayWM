//! raywm-update: checks for and installs RayWM releases from GitHub
//! (docs/INSTALL.md, docs/RELEASE-WORKFLOW.md).
//!
//! The subscription (beta or stable) lives in /etc/raywm/update.conf, apart
//! from the installed version and from raywm.conf: installing a Stable
//! release from the beta channel keeps the beta channel.
//!
//! Network input is untrusted. Releases are chosen from the tag scheme of
//! docs/RELEASE-WORKFLOW.md, compared with pacman's `vercmp`, and accepted
//! only if their raywm-release.json agrees with the tag, the GitHub release
//! and the asset list; downloads must match its size and SHA256. Beta
//! releases are built from source as the invoking (non-root) user with the
//! archive's own makepkg packaging; both channels install through
//! `pacman -U`, the only step that runs with privileges (via sudo).
//!
//! External programs: curl and vercmp (both required by pacman), pacman,
//! sudo, tar, and for Beta builds makepkg (base-devel) and python3.
const std = @import("std");
const build_options = @import("build_options");

const usage =
    \\Usage: raywm-update COMMAND [OPTIONS]
    \\Commands:
    \\  --check              show the newest update for your channel (installs nothing)
    \\  --install            download, verify and install that update (asks first)
    \\  --channel            show the subscribed channel
    \\  --set-channel NAME   subscribe to beta or stable (installs nothing)
    \\  --version            show versions of raywm-update and the installed package
    \\  --help               show this help
    \\Options:
    \\  --yes, --noconfirm   do not ask before installing (non-interactive use)
    \\  --dry-run            --install: select, download and verify only, show what
    \\                       would run; --set-channel: show what would be written
    \\  --verbose            also list ignored releases and why
    \\Exit status: --check 0 = update available, 2 = up to date; 1 = error.
    \\
;

pub const repo = "Rreeqqwel/RayWM";
const default_api = "https://api.github.com/repos/" ++ repo ++ "/releases?per_page=100&page={page}";
const download_prefix = "https://github.com/" ++ repo ++ "/releases/download/";
const default_conf = "/etc/raywm/update.conf";
const max_pages = 10;
const per_page = 100;

// ---- tags and versions (same rules as scripts/release-meta.py) ---------------

pub const Channel = enum { beta, stable };

pub const Tag = struct {
    channel: Channel,
    /// X.Y.Z
    version: []const u8,
    /// pacman pkgver: X.Y.Zbeta[.N] or X.Y.Z
    pkgver: [48]u8 = undefined,
    pkgver_len: usize = 0,

    pub fn pkgverSlice(t: *const Tag) []const u8 {
        return t.pkgver[0..t.pkgver_len];
    }
    /// pkgver-1
    pub fn pacmanVersion(t: *const Tag, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}-1", .{t.pkgverSlice()}) catch unreachable;
    }
    /// The asset a channel installs from: the source archive for a Beta,
    /// the Arch package for a Stable release.
    pub fn assetName(t: *const Tag, tag: []const u8, buf: []u8) []const u8 {
        return switch (t.channel) {
            .beta => std.fmt.bufPrint(buf, "raywm-{s}.tar.gz", .{tag}) catch unreachable,
            .stable => std.fmt.bufPrint(buf, "raywm-{s}-1-x86_64.pkg.tar.zst", .{t.pkgverSlice()}) catch unreachable,
        };
    }
    pub fn assetKind(t: *const Tag) []const u8 {
        return switch (t.channel) {
            .beta => "source",
            .stable => "arch-package",
        };
    }
};

/// A number without a leading zero (0 itself is fine), at most 6 digits.
fn number(s: []const u8) bool {
    if (s.len == 0 or s.len > 6) return false;
    for (s) |ch| if (!std.ascii.isDigit(ch)) return false;
    return s.len == 1 or s[0] != '0';
}

/// vX.Y.Z-beta, vX.Y.Z-beta.N (N >= 2), vX.Y.Z-stable. Historical tags
/// (vX.Y.Z) and anything else: null.
pub fn parseTag(tag: []const u8) ?Tag {
    if (tag.len < 2 or tag[0] != 'v') return null;
    const dash = std.mem.indexOfScalar(u8, tag, '-') orelse return null;
    const version = tag[1..dash];
    var parts = std.mem.splitScalar(u8, version, '.');
    var n: usize = 0;
    while (parts.next()) |p| : (n += 1) if (!number(p)) return null;
    if (n != 3) return null;
    const suffix = tag[dash + 1 ..];
    var t: Tag = .{ .channel = .stable, .version = version };
    if (std.mem.eql(u8, suffix, "stable")) {
        t.pkgver_len = (std.fmt.bufPrint(&t.pkgver, "{s}", .{version}) catch return null).len;
    } else if (std.mem.eql(u8, suffix, "beta")) {
        t.channel = .beta;
        t.pkgver_len = (std.fmt.bufPrint(&t.pkgver, "{s}beta", .{version}) catch return null).len;
    } else if (std.mem.startsWith(u8, suffix, "beta.")) {
        const pre = suffix["beta.".len..];
        if (!number(pre) or std.mem.eql(u8, pre, "0") or std.mem.eql(u8, pre, "1")) return null;
        t.channel = .beta;
        t.pkgver_len = (std.fmt.bufPrint(&t.pkgver, "{s}beta.{s}", .{ version, pre }) catch return null).len;
    } else return null;
    return t;
}

/// Beta subscribers get Beta and Stable releases; Stable subscribers only Stable.
pub fn offered(sub: Channel, release: Channel) bool {
    return sub == .beta or release == .stable;
}

// ---- channel file -----------------------------------------------------------

pub const ChannelState = union(enum) {
    ok: Channel,
    missing,
    /// Line number of the problem (0: the file as a whole).
    malformed: u32,
};

/// `channel=beta|stable`; '#' comments and blank lines; nothing else.
pub fn parseChannelFile(text: []const u8) ChannelState {
    var found: ?Channel = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var n: u32 = 0;
    while (lines.next()) |raw| {
        n += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return .{ .malformed = n };
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (!std.mem.eql(u8, key, "channel") or found != null) return .{ .malformed = n };
        found = std.meta.stringToEnum(Channel, value) orelse return .{ .malformed = n };
    }
    return if (found) |c| .{ .ok = c } else .{ .malformed = 0 };
}

/// The channel a package version implies (first install, see raywm.install).
pub fn channelOfVersion(pacman_version: []const u8) Channel {
    return if (std.mem.indexOf(u8, pacman_version, "beta") != null) .beta else .stable;
}

// ---- releases ---------------------------------------------------------------

pub const Asset = struct { name: []const u8, url: []const u8, size: i64 };

pub const Release = struct {
    tag_name: []const u8,
    tag: Tag,
    prerelease: bool,
    asset: Asset,
    meta: Asset,
};

pub const Ignored = struct { tag: []const u8, why: []const u8 };

/// Appends the usable releases of one API page. Returns the number of
/// entries on the page; null if the page is not a JSON array.
pub fn parsePage(arena: std.mem.Allocator, text: []const u8, url_ok: *const fn ([]const u8, []const u8, []const u8) bool, found: *std.ArrayList(Release), ignored: *std.ArrayList(Ignored)) !?usize {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch return null;
    if (root != .array) return null;
    for (root.array.items) |item| {
        if (item != .object) continue;
        const o = item.object;
        const tag_name = str(o, "tag_name") orelse continue;
        if (boolean(o, "draft") orelse true) {
            try ignored.append(arena, .{ .tag = tag_name, .why = "draft or no draft flag" });
            continue;
        }
        const tag = parseTag(tag_name) orelse {
            try ignored.append(arena, .{ .tag = tag_name, .why = "not a beta/stable tag (historical release)" });
            continue;
        };
        const pre = boolean(o, "prerelease") orelse {
            try ignored.append(arena, .{ .tag = tag_name, .why = "no prerelease flag" });
            continue;
        };
        if (pre != (tag.channel == .beta)) {
            try ignored.append(arena, .{ .tag = tag_name, .why = "Pre-release flag does not match the tag's channel" });
            continue;
        }
        var name_buf: [128]u8 = undefined;
        const want = tag.assetName(tag_name, &name_buf);
        const assets = if (o.get("assets")) |a| (if (a == .array) a.array.items else &.{}) else &.{};
        var asset: ?Asset = null;
        var meta: ?Asset = null;
        for (assets) |a| {
            if (a != .object) continue;
            const name = str(a.object, "name") orelse continue;
            const url = str(a.object, "browser_download_url") orelse continue;
            const size = integer(a.object, "size") orelse continue;
            if (std.mem.eql(u8, name, want) and url_ok(url, tag_name, name)) asset = .{ .name = try arena.dupe(u8, name), .url = url, .size = size };
            if (std.mem.eql(u8, name, "raywm-release.json") and url_ok(url, tag_name, name)) meta = .{ .name = name, .url = url, .size = size };
        }
        if (asset == null) {
            try ignored.append(arena, .{ .tag = tag_name, .why = "release asset missing" });
            continue;
        }
        if (meta == null) {
            try ignored.append(arena, .{ .tag = tag_name, .why = "raywm-release.json missing" });
            continue;
        }
        try found.append(arena, .{ .tag_name = tag_name, .tag = tag, .prerelease = pre, .asset = asset.?, .meta = meta.? });
    }
    return root.array.items.len;
}

fn str(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}
fn boolean(o: std.json.ObjectMap, key: []const u8) ?bool {
    const v = o.get(key) orelse return null;
    return if (v == .bool) v.bool else null;
}
fn integer(o: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = o.get(key) orelse return null;
    return if (v == .integer) v.integer else null;
}

/// Checks raywm-release.json (schema 1) against the release. Returns the
/// asset's SHA256 (64 lower-case hex digits) or why it is refused.
pub fn checkMetadata(arena: std.mem.Allocator, text: []const u8, r: *const Release, sub: Channel) union(enum) { ok: []const u8, bad: []const u8 } {
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch return .{ .bad = "metadata is not valid JSON" };
    if (root != .object) return .{ .bad = "metadata is not a JSON object" };
    const o = root.object;
    if ((integer(o, "schema") orelse 0) != 1) return .{ .bad = "unsupported metadata schema" };
    if (!eqlOpt(str(o, "project"), "raywm")) return .{ .bad = "metadata project is not raywm" };
    if (!eqlOpt(str(o, "tag"), r.tag_name)) return .{ .bad = "metadata tag differs from the release tag" };
    if (!eqlOpt(str(o, "channel"), @tagName(r.tag.channel))) return .{ .bad = "metadata channel differs from the tag" };
    if (!eqlOpt(str(o, "version"), r.tag.version)) return .{ .bad = "metadata version differs from the tag" };
    if (!eqlOpt(str(o, "pkgver"), r.tag.pkgverSlice())) return .{ .bad = "metadata pkgver differs from the tag" };
    var pv: [64]u8 = undefined;
    if (!eqlOpt(str(o, "pacman_version"), r.tag.pacmanVersion(&pv))) return .{ .bad = "metadata pacman_version differs from the tag" };
    // channels must be exactly what the tag implies, and offer the subscription.
    const channels = o.get("channels") orelse return .{ .bad = "metadata has no channels" };
    if (channels != .array) return .{ .bad = "metadata channels is not a list" };
    var has_beta = false;
    var has_stable = false;
    for (channels.array.items) |c| {
        if (c != .string) return .{ .bad = "metadata channels has a non-string entry" };
        if (std.mem.eql(u8, c.string, "beta")) has_beta = true else if (std.mem.eql(u8, c.string, "stable")) has_stable = true else return .{ .bad = "metadata lists an unknown channel" };
    }
    const expect_stable = r.tag.channel == .stable;
    if (!has_beta or has_stable != expect_stable) return .{ .bad = "metadata channels do not match the tag" };
    if ((sub == .stable and !has_stable)) return .{ .bad = "release is not offered to the stable channel" };
    const assets = o.get("assets") orelse return .{ .bad = "metadata has no assets" };
    if (assets != .array) return .{ .bad = "metadata assets is not a list" };
    for (assets.array.items) |a| {
        if (a != .object) continue;
        if (!eqlOpt(str(a.object, "name"), r.asset.name)) continue;
        if (!eqlOpt(str(a.object, "kind"), r.tag.assetKind())) return .{ .bad = "metadata asset kind does not match the channel" };
        if ((integer(a.object, "size") orelse -1) != r.asset.size) return .{ .bad = "metadata asset size differs from GitHub's" };
        const sum = str(a.object, "sha256") orelse return .{ .bad = "metadata asset has no sha256" };
        if (sum.len != 64) return .{ .bad = "metadata sha256 is not 64 hex digits" };
        for (sum) |ch| if (!std.ascii.isDigit(ch) and !(ch >= 'a' and ch <= 'f')) return .{ .bad = "metadata sha256 is not lower-case hex" };
        return .{ .ok = sum };
    }
    return .{ .bad = "metadata does not list the release asset" };
}

fn eqlOpt(a: ?[]const u8, b: []const u8) bool {
    return if (a) |x| std.mem.eql(u8, x, b) else false;
}

/// Asset names come from parseTag (no '/'), so this only guards the URL.
fn githubUrl(url: []const u8, tag: []const u8, name: []const u8) bool {
    var buf: [512]u8 = undefined;
    const want = std.fmt.bufPrint(&buf, download_prefix ++ "{s}/{s}", .{ tag, name }) catch return false;
    return std.mem.eql(u8, url, want);
}

/// With RAYWM_UPDATE_API (tests, mirrors): https or file URLs ending in the
/// asset's name.
fn overrideUrl(url: []const u8, _: []const u8, name: []const u8) bool {
    const scheme_ok = std.mem.startsWith(u8, url, "https://") or std.mem.startsWith(u8, url, "file:///");
    if (!scheme_ok or !std.mem.endsWith(u8, url, name)) return false;
    const before = url[0 .. url.len - name.len];
    return before.len > 0 and before[before.len - 1] == '/' and std.mem.indexOf(u8, url, "..") == null;
}

// ---- process environment ---------------------------------------------------

const Ctx = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    verbose: bool = false,
    yes: bool = false,
    dry_run: bool = false,

    fn env(_: *Ctx, name: [*:0]const u8, default: []const u8) []const u8 {
        return if (std.c.getenv(name)) |v| std.mem.span(v) else default;
    }
    fn api(c: *Ctx) []const u8 {
        return c.env("RAYWM_UPDATE_API", default_api);
    }
    fn apiOverridden(_: *Ctx) bool {
        return std.c.getenv("RAYWM_UPDATE_API") != null;
    }
    fn confPath(c: *Ctx) []const u8 {
        return c.env("RAYWM_UPDATE_CONF", default_conf);
    }
    fn pacman(c: *Ctx) []const u8 {
        return c.env("RAYWM_UPDATE_PACMAN", "pacman");
    }
    /// "" runs privileged steps directly (tests, or already root).
    fn sudo(c: *Ctx) []const u8 {
        if (std.c.geteuid() == 0) return "";
        return c.env("RAYWM_UPDATE_SUDO", "sudo");
    }
};

fn out(comptime fmt: []const u8, args: anytype) void {
    write(1, fmt, args);
}
fn err(comptime fmt: []const u8, args: anytype) void {
    write(2, "raywm-update: " ++ fmt, args);
}
fn write(fd: c_int, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch blk: {
        const tail = "...\n";
        @memcpy(buf[buf.len - tail.len ..], tail);
        break :blk buf[0..];
    };
    var off: usize = 0;
    while (off < s.len) {
        const n = std.c.write(fd, s[off..].ptr, s.len - off);
        if (n <= 0) return;
        off += @intCast(n);
    }
}

const RunResult = struct { ok: bool, code: u8, stdout: []const u8 };

/// Runs argv, capturing stdout (bounded); stderr is passed through.
fn capture(c: *Ctx, argv: []const []const u8) RunResult {
    const r = std.process.run(c.arena, c.io, .{ .argv = argv, .stdout_limit = .limited(1 << 20), .stderr_limit = .limited(1 << 20) }) catch |e| {
        err("cannot run {s}: {s}\n", .{ argv[0], @errorName(e) });
        return .{ .ok = false, .code = 127, .stdout = "" };
    };
    if (r.stderr.len > 0) write(2, "{s}", .{r.stderr});
    const code: u8 = switch (r.term) {
        .exited => |e| e,
        else => 128,
    };
    return .{ .ok = code == 0, .code = code, .stdout = r.stdout };
}

/// Runs argv with inherited stdio (pacman's own prompts reach the user).
fn interactive(c: *Ctx, argv: []const []const u8) bool {
    var child = std.process.spawn(c.io, .{ .argv = argv }) catch |e| {
        err("cannot run {s}: {s}\n", .{ argv[0], @errorName(e) });
        return false;
    };
    const term = child.wait(c.io) catch return false;
    return term == .exited and term.exited == 0;
}

/// pacman's version order (vercmp): <0, 0, >0.
fn vercmp(c: *Ctx, a: []const u8, b: []const u8) !i32 {
    const r = capture(c, &.{ "vercmp", a, b });
    if (!r.ok) return error.VercmpFailed;
    const s = std.mem.trim(u8, r.stdout, " \n");
    return std.fmt.parseInt(i32, s, 10) catch error.VercmpFailed;
}

fn installedVersion(c: *Ctx) ?[]const u8 {
    const r = std.process.run(c.arena, c.io, .{ .argv = &.{ c.pacman(), "-Q", "raywm" }, .stdout_limit = .limited(4096), .stderr_limit = .limited(4096) }) catch return null;
    if (r.term != .exited or r.term.exited != 0) return null;
    var it = std.mem.tokenizeAny(u8, r.stdout, " \n");
    const name = it.next() orelse return null;
    const version = it.next() orelse return null;
    if (!std.mem.eql(u8, name, "raywm")) return null;
    return version;
}

fn readFile(c: *Ctx, path: []const u8, limit: usize) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(c.io, path, c.arena, .limited(limit));
}

// ---- channel state ----------------------------------------------------------

const Subscription = struct { channel: Channel, source: enum { file, installed_version, default } };

/// The subscription, or null (reported) when update.conf is malformed or
/// unreadable: never guess then, a wrong guess could install a Beta.
fn subscription(c: *Ctx) ?Subscription {
    const path = c.confPath();
    const text = readFile(c, path, 4096) catch |e| switch (e) {
        error.FileNotFound => {
            const v = installedVersion(c);
            const ch = if (v) |x| channelOfVersion(x) else .stable;
            return .{ .channel = ch, .source = if (v != null) .installed_version else .default };
        },
        else => {
            err("cannot read {s}: {s}\n", .{ path, @errorName(e) });
            err("fix it with: sudo raywm-update --set-channel beta|stable\n", .{});
            return null;
        },
    };
    switch (parseChannelFile(text)) {
        .ok => |ch| return .{ .channel = ch, .source = .file },
        .missing => unreachable,
        .malformed => |line| {
            if (line == 0) err("{s}: no 'channel=beta' or 'channel=stable' line\n", .{path}) else err("{s}:{d}: expected 'channel=beta' or 'channel=stable'\n", .{ path, line });
            err("fix it with: sudo raywm-update --set-channel beta|stable\n", .{});
            return null;
        },
    }
}

fn describeSubscription(c: *Ctx, s: Subscription) void {
    switch (s.source) {
        .file => out("Channel: {s} ({s})\n", .{ @tagName(s.channel), c.confPath() }),
        .installed_version => out("Channel: {s} (no {s}; assumed from the installed version, set it with --set-channel)\n", .{ @tagName(s.channel), c.confPath() }),
        .default => out("Channel: {s} (no {s} and no installed package; the default)\n", .{ @tagName(s.channel), c.confPath() }),
    }
}

/// Writes update.conf atomically (temporary file, fsync, rename), with sudo
/// when the directory is not writable.
fn setChannel(c: *Ctx, ch: Channel) u8 {
    const path = c.confPath();
    const dir = std.fs.path.dirname(path) orelse ".";
    if (c.dry_run) {
        out("Would write {s}: channel={s}\n", .{ path, @tagName(ch) });
        return 0;
    }
    var dir_z: [std.fs.max_path_bytes]u8 = undefined;
    const dz = std.fmt.bufPrintZ(&dir_z, "{s}", .{dir}) catch return 1;
    const writable = std.c.access(dz.ptr, std.c.W_OK) == 0;
    const exists = std.c.access(dz.ptr, std.c.F_OK) == 0;
    if (!writable and !(exists == false and std.c.geteuid() == 0)) {
        const sudo = c.sudo();
        if (sudo.len == 0) {
            err("{s} is not writable\n", .{dir});
            return 1;
        }
        var self_buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = std.c.readlink("/proc/self/exe", &self_buf, self_buf.len);
        if (n <= 0) return 1;
        const self = self_buf[0..@intCast(n)];
        out("Writing {s} needs root; running sudo.\n", .{path});
        // sudo resets the environment: the path is passed on explicitly.
        const conf_env = std.fmt.allocPrint(c.arena, "RAYWM_UPDATE_CONF={s}", .{path}) catch return 1;
        return if (interactive(c, &.{ sudo, "env", conf_env, self, "--set-channel", @tagName(ch) })) 0 else 1;
    }
    const previous = subscriptionQuiet(c);
    writeChannel(path, dir, ch) catch |e| {
        err("cannot write {s}: {s}\n", .{ path, @errorName(e) });
        return 1;
    };
    if (previous) |p| {
        if (p != ch) out("Channel: {s} (was {s}). Nothing was installed; see raywm-update --check.\n", .{ @tagName(ch), @tagName(p) }) else out("Channel: {s} (unchanged).\n", .{@tagName(ch)});
    } else out("Channel: {s}. Nothing was installed; see raywm-update --check.\n", .{@tagName(ch)});
    return 0;
}

fn subscriptionQuiet(c: *Ctx) ?Channel {
    const text = readFile(c, c.confPath(), 4096) catch return null;
    return switch (parseChannelFile(text)) {
        .ok => |ch| ch,
        else => null,
    };
}

fn writeChannel(path: []const u8, dir: []const u8, ch: Channel) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dz = try std.fmt.bufPrintZ(&buf, "{s}", .{dir});
    if (std.c.mkdir(dz.ptr, 0o755) != 0 and std.c._errno().* != @intFromEnum(std.posix.E.EXIST)) return error.CannotCreateDirectory;
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = try std.fmt.bufPrintZ(&tmp_buf, "{s}/.update.conf.{d}", .{ dir, std.c.getpid() });
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const pz = try std.fmt.bufPrintZ(&path_buf, "{s}", .{path});
    const fd = std.c.open(tmp.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) return error.CannotCreateFile;
    var ok = false;
    defer if (!ok) {
        _ = std.c.unlink(tmp.ptr);
    };
    var text_buf: [256]u8 = undefined;
    const text = try std.fmt.bufPrint(&text_buf, "# RayWM update channel (raywm-update --set-channel beta|stable).\n# Kept across package upgrades; not part of raywm.conf.\nchannel={s}\n", .{@tagName(ch)});
    const written = std.c.write(fd, text.ptr, text.len);
    const synced = std.c.fsync(fd) == 0;
    _ = std.c.fchmod(fd, 0o644);
    _ = std.c.close(fd);
    if (written != text.len or !synced) return error.WriteFailed;
    if (std.c.rename(tmp.ptr, pz.ptr) != 0) return error.RenameFailed;
    ok = true;
}

// ---- downloads --------------------------------------------------------------

const Fetch = union(enum) { ok, failed: []const u8 };

/// curl to `dest`, https only (file:// too when the API is overridden).
fn fetch(c: *Ctx, url: []const u8, dest: []const u8, max_bytes: u64, headers: ?[]const u8) Fetch {
    const proto = if (c.apiOverridden()) "=https,file" else "=https";
    var max_buf: [32]u8 = undefined;
    const max = std.fmt.bufPrint(&max_buf, "{d}", .{max_bytes}) catch unreachable;
    var argv: std.ArrayList([]const u8) = .empty;
    // A server that accepts and then stalls must not hang raywm-update:
    // fewer than 1 byte/s for 30 s ends a transfer, and lists and metadata
    // (small) get 2 minutes in all. Before, only --max-time 1800 applied,
    // three times with --retry (found by tests/stress update, case stall).
    const max_time = if (max_bytes <= 16 << 20) "120" else "1800";
    argv.appendSlice(c.arena, &.{ "curl", "--silent", "--show-error", "--fail", "--location", "--proto", proto, "--proto-redir", "=https", "--connect-timeout", "20", "--speed-limit", "1", "--speed-time", "30", "--max-time", max_time, "--retry", "2", "--max-filesize", max, "--user-agent", "raywm-update/" ++ build_options.version, "--output", dest }) catch return .{ .failed = "out of memory" };
    if (headers) |h| argv.appendSlice(c.arena, &.{ "--dump-header", h, "--header", "Accept: application/vnd.github+json", "--header", "X-GitHub-Api-Version: 2022-11-28" }) catch return .{ .failed = "out of memory" };
    argv.append(c.arena, url) catch return .{ .failed = "out of memory" };
    const r = capture(c, argv.items);
    // HTTP errors: the status says more than curl's exit code (rate limits).
    if (headers) |h| if (httpStatus(c, h)) |status| if (status >= 400) return .{ .failed = switch (status) {
        403, 429 => "GitHub API rate limit reached or access denied (unauthenticated: 60 requests/hour); try again later",
        404 => "not found (HTTP 404)",
        else => "server error",
    } };
    if (!r.ok) return .{ .failed = switch (r.code) {
        6, 7, 28 => "network unavailable (cannot reach the server)",
        22 => "HTTP error",
        37 => "file not found",
        63 => "download larger than allowed",
        127 => "curl is not installed",
        else => "download failed",
    } };
    return .ok;
}

/// Status of the last response in a curl --dump-header file.
fn httpStatus(c: *Ctx, path: []const u8) ?u16 {
    const text = readFile(c, path, 1 << 16) catch return null;
    var status: ?u16 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| if (std.mem.startsWith(u8, line, "HTTP/")) {
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        _ = it.next();
        status = std.fmt.parseInt(u16, std.mem.trim(u8, it.next() orelse "", "\r"), 10) catch null;
    };
    return status;
}

const Digest = struct { hex: [64]u8, size: i64 };

fn sha256File(path: []const u8) !Digest {
    var pz_buf: [std.fs.max_path_bytes]u8 = undefined;
    const pz = try std.fmt.bufPrintZ(&pz_buf, "{s}", .{path});
    const fd = std.c.open(pz.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.CannotOpen;
    defer _ = std.c.close(fd);
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [1 << 16]u8 = undefined;
    var size: i64 = 0;
    while (true) {
        const n = std.c.read(fd, &buf, buf.len);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        h.update(buf[0..@intCast(n)]);
        size += n;
    }
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return .{ .hex = std.fmt.bytesToHex(digest, .lower), .size = size };
}

// ---- selection --------------------------------------------------------------

const Choice = struct { release: Release, sha256: []const u8 };

const Selection = union(enum) { update: Choice, up_to_date, failed };

/// Working directories of runs that were killed (Ctrl+C, a timeout, a
/// crash) never got cleaned: run-<pid>-<random> of processes that no longer
/// exist are removed. Only that name pattern, only the user's own cache.
fn removeStale(c: *Ctx, base: []const u8) void {
    var dir = std.Io.Dir.cwd().openDir(c.io, base, .{ .iterate = true }) catch return;
    defer dir.close(c.io);
    var it = dir.iterate();
    while (it.next(c.io) catch return) |entry| {
        if (entry.kind != .directory or !std.mem.startsWith(u8, entry.name, "run-")) continue;
        const rest = entry.name["run-".len..];
        const dash = std.mem.indexOfScalar(u8, rest, '-') orelse continue;
        const pid = std.fmt.parseInt(std.c.pid_t, rest[0..dash], 10) catch continue;
        if (pid == std.c.getpid()) continue;
        if (std.c.kill(pid, @enumFromInt(0)) == 0 or std.c._errno().* != @intFromEnum(std.posix.E.SRCH)) continue;
        dir.deleteTree(c.io, entry.name) catch |e| err("could not remove stale {s}/{s}: {s}\n", .{ base, entry.name, @errorName(e) });
    }
}

fn workDir(c: *Ctx) ![]const u8 {
    const base = if (std.c.getenv("RAYWM_UPDATE_CACHE")) |v|
        try c.arena.dupe(u8, std.mem.span(v))
    else if (std.c.getenv("XDG_CACHE_HOME")) |v|
        try std.fmt.allocPrint(c.arena, "{s}/raywm-update", .{std.mem.span(v)})
    else if (std.c.getenv("HOME")) |v|
        try std.fmt.allocPrint(c.arena, "{s}/.cache/raywm-update", .{std.mem.span(v)})
    else
        return error.NoCacheDirectory;
    std.Io.Dir.cwd().createDirPath(c.io, base) catch return error.CannotCreateCache;
    removeStale(c, base);
    // A fresh private directory per run (mode 0700; mkdir fails if it exists).
    var tries: u32 = 0;
    while (tries < 16) : (tries += 1) {
        var rnd: [8]u8 = undefined;
        c.io.random(&rnd);
        const path = try std.fmt.allocPrint(c.arena, "{s}/run-{d}-{x}", .{ base, std.c.getpid(), std.mem.readInt(u64, &rnd, .little) });
        const pz = try c.arena.dupeZ(u8, path);
        if (std.c.mkdir(pz.ptr, 0o700) == 0) return path;
    }
    return error.CannotCreateWorkDir;
}

fn select(c: *Ctx, sub: Channel, installed: ?[]const u8, work: []const u8) Selection {
    var releases: std.ArrayList(Release) = .empty;
    var ignored: std.ArrayList(Ignored) = .empty;
    const url_ok: *const fn ([]const u8, []const u8, []const u8) bool = if (c.apiOverridden()) overrideUrl else githubUrl;
    var page: u32 = 1;
    while (page <= max_pages) : (page += 1) {
        const api = c.api();
        const url = std.mem.replaceOwned(u8, c.arena, api, "{page}", std.fmt.allocPrint(c.arena, "{d}", .{page}) catch return .failed) catch return .failed;
        const dest = std.fmt.allocPrint(c.arena, "{s}/releases-{d}.json", .{ work, page }) catch return .failed;
        const hdr = std.fmt.allocPrint(c.arena, "{s}/releases-{d}.headers", .{ work, page }) catch return .failed;
        switch (fetch(c, url, dest, 16 << 20, hdr)) {
            .ok => {},
            .failed => |why| {
                // A missing later page of a file:// fixture ends the list.
                if (page > 1 and c.apiOverridden() and std.mem.eql(u8, why, "file not found")) break;
                err("cannot list releases: {s}\n", .{why});
                return .failed;
            },
        }
        const text = readFile(c, dest, 16 << 20) catch {
            err("cannot read the release list\n", .{});
            return .failed;
        };
        const n = (parsePage(c.arena, text, url_ok, &releases, &ignored) catch return .failed) orelse {
            err("the release list from {s} is not valid JSON\n", .{url});
            return .failed;
        };
        if (n < per_page or std.mem.indexOf(u8, api, "{page}") == null) break;
    }
    if (c.verbose) for (ignored.items) |i| out("  ignored {s}: {s}\n", .{ i.tag, i.why });

    // Eligible and newer than the installed version, newest first.
    var candidates: std.ArrayList(Release) = .empty;
    var pv: [64]u8 = undefined;
    for (releases.items) |r| {
        if (!offered(sub, r.tag.channel)) {
            if (c.verbose) out("  skipped {s}: a Beta, not offered to the stable channel\n", .{r.tag_name});
            continue;
        }
        if (installed) |v| {
            const cmp = vercmp(c, r.tag.pacmanVersion(&pv), v) catch {
                err("vercmp failed (is pacman installed?)\n", .{});
                return .failed;
            };
            if (cmp <= 0) continue;
        }
        candidates.append(c.arena, r) catch return .failed;
    }
    // Insertion sort, newest first (few releases; vercmp is a process).
    var i: usize = 1;
    while (i < candidates.items.len) : (i += 1) {
        var j = i;
        while (j > 0) : (j -= 1) {
            var a: [64]u8 = undefined;
            var b: [64]u8 = undefined;
            const cmp = vercmp(c, candidates.items[j].tag.pacmanVersion(&a), candidates.items[j - 1].tag.pacmanVersion(&b)) catch return .failed;
            if (cmp <= 0) break;
            std.mem.swap(Release, &candidates.items[j], &candidates.items[j - 1]);
        }
    }
    for (candidates.items) |*r| {
        const dest = std.fmt.allocPrint(c.arena, "{s}/{s}.raywm-release.json", .{ work, r.tag_name }) catch return .failed;
        switch (fetch(c, r.meta.url, dest, 1 << 20, null)) {
            .ok => {},
            .failed => |why| {
                err("{s}: cannot download raywm-release.json ({s}); trying an older release\n", .{ r.tag_name, why });
                continue;
            },
        }
        const text = readFile(c, dest, 1 << 20) catch continue;
        switch (checkMetadata(c.arena, text, r, sub)) {
            .ok => |sum| return .{ .update = .{ .release = r.*, .sha256 = sum } },
            .bad => |why| err("{s}: ignored, {s}\n", .{ r.tag_name, why }),
        }
    }
    return .up_to_date;
}

// ---- commands ---------------------------------------------------------------

fn kindName(ch: Channel) []const u8 {
    return switch (ch) {
        .beta => "source archive, built locally with makepkg",
        .stable => "Arch Linux package",
    };
}

fn cmdCheck(c: *Ctx) u8 {
    const s = subscription(c) orelse return 1;
    describeSubscription(c, s);
    const installed = installedVersion(c);
    out("Installed: {s}\n", .{installed orelse "(raywm is not installed with pacman)"});
    const work = workDir(c) catch |e| {
        err("{s}\n", .{@errorName(e)});
        return 1;
    };
    defer cleanup(c, work);
    switch (select(c, s.channel, installed, work)) {
        .failed => return 1,
        .up_to_date => {
            out("Up to date: no newer {s} release.\n", .{if (s.channel == .beta) "Beta or Stable" else "Stable"});
            return 2;
        },
        .update => |u| {
            var pv: [64]u8 = undefined;
            out("Update available: {s} (pacman {s}, {s} release, {s}, {d} bytes)\n", .{ u.release.tag_name, u.release.tag.pacmanVersion(&pv), @tagName(u.release.tag.channel), kindName(u.release.tag.channel), u.release.asset.size });
            out("Install it with: raywm-update --install\n", .{});
            return 0;
        },
    }
}

fn cleanup(c: *Ctx, work: []const u8) void {
    std.Io.Dir.cwd().deleteTree(c.io, work) catch |e| err("could not remove {s}: {s}\n", .{ work, @errorName(e) });
}

fn confirm(c: *Ctx) bool {
    if (c.yes) return true;
    if (std.c.isatty(0) == 0) {
        err("not a terminal: pass --yes to install without asking\n", .{});
        return false;
    }
    out("Install it? [y/N] ", .{});
    var buf: [16]u8 = undefined;
    const n = std.c.read(0, &buf, buf.len);
    if (n <= 0) return false;
    const answer = std.mem.trim(u8, buf[0..@intCast(n)], " \t\r\n");
    return std.ascii.eqlIgnoreCase(answer, "y") or std.ascii.eqlIgnoreCase(answer, "yes");
}

fn cmdInstall(c: *Ctx) u8 {
    const s = subscription(c) orelse return 1;
    describeSubscription(c, s);
    const installed = installedVersion(c);
    out("Installed: {s}\n", .{installed orelse "(raywm is not installed with pacman)"});
    const work = workDir(c) catch |e| {
        err("{s}\n", .{@errorName(e)});
        return 1;
    };
    // The working directory goes in every case: the installed RayWM is
    // only touched by the final pacman -U.
    defer cleanup(c, work);
    const u = switch (select(c, s.channel, installed, work)) {
        .failed => return 1,
        .up_to_date => {
            out("Up to date: nothing to install.\n", .{});
            return 0;
        },
        .update => |u| u,
    };
    const r = u.release;
    var pv: [64]u8 = undefined;
    const pacman_version = r.tag.pacmanVersion(&pv);
    out("\nUpdate:   {s} -> {s}\n", .{ installed orelse "(none)", pacman_version });
    out("Release:  {s} ({s} channel{s})\n", .{ r.tag_name, @tagName(r.tag.channel), if (s.channel != r.tag.channel) "; your subscription stays " ++ "as it is" else "" });
    out("Type:     {s}\n", .{kindName(r.tag.channel)});
    out("Asset:    {s} ({d} bytes)\n", .{ r.asset.name, r.asset.size });
    out("SHA256:   {s}\n", .{u.sha256});
    if (r.tag.channel == .beta) {
        if (std.c.geteuid() == 0) {
            err("Beta releases are built from source, which never runs as root: run raywm-update as your user (sudo is used only for pacman)\n", .{});
            return 1;
        }
        out("Build:    makepkg as {s} in {s} (needs base-devel, wayland-protocols, pkgconf; downloads Zig {s})\n", .{ c.env("USER", "you"), work, "0.16.0" });
    }
    if (!c.dry_run and !confirm(c)) {
        out("Nothing was installed.\n", .{});
        return 1;
    }

    const asset = std.fmt.allocPrint(c.arena, "{s}/{s}", .{ work, r.asset.name }) catch return 1;
    out("Downloading {s} ...\n", .{r.asset.name});
    switch (fetch(c, r.asset.url, asset, @intCast(@max(r.asset.size, 0)), null)) {
        .ok => {},
        .failed => |why| {
            err("download failed: {s}. Nothing was installed.\n", .{why});
            return 1;
        },
    }
    const got = sha256File(asset) catch {
        err("cannot read the download. Nothing was installed.\n", .{});
        return 1;
    };
    if (got.size != r.asset.size) {
        err("downloaded {d} bytes, the release lists {d}. Nothing was installed.\n", .{ got.size, r.asset.size });
        return 1;
    }
    if (!std.mem.eql(u8, &got.hex, u.sha256)) {
        err("SHA256 mismatch (expected {s}, got {s}): corrupted or tampered download. Nothing was installed.\n", .{ u.sha256, &got.hex });
        return 1;
    }
    out("SHA256 verified.\n", .{});

    const pkg = switch (r.tag.channel) {
        .stable => asset,
        .beta => buildBeta(c, r, asset, work) orelse return 1,
    };
    if (!checkPackage(c, pkg, pacman_version)) return 1;

    const sudo = c.sudo();
    var argv: std.ArrayList([]const u8) = .empty;
    if (sudo.len > 0) argv.append(c.arena, sudo) catch return 1;
    argv.appendSlice(c.arena, &.{ c.pacman(), "-U" }) catch return 1;
    if (c.yes) argv.append(c.arena, "--noconfirm") catch return 1;
    argv.append(c.arena, pkg) catch return 1;
    if (c.dry_run) {
        out("Dry run: would run:", .{});
        for (argv.items) |a| out(" {s}", .{a});
        out("\nNothing was installed.\n", .{});
        return 0;
    }
    out("Installing with pacman ...\n", .{});
    if (!interactive(c, argv.items)) {
        err("pacman -U failed or was cancelled; the previous installation is unchanged.\n", .{});
        return 1;
    }
    const now = installedVersion(c) orelse "?";
    if (!std.mem.eql(u8, now, pacman_version)) {
        err("pacman reports raywm {s}, expected {s}\n", .{ now, pacman_version });
        return 1;
    }
    out("Installed raywm {s} ({s}). Channel: {s} (unchanged). Restart RayWM to use it.\n", .{ pacman_version, r.tag_name, @tagName(s.channel) });
    return 0;
}

/// Extracts the verified archive as the invoking user and runs its own
/// packaging (scripts/arch-package.sh: makepkg). Returns the package path.
fn buildBeta(c: *Ctx, r: Release, archive: []const u8, work: []const u8) ?[]const u8 {
    const top = std.fmt.allocPrint(c.arena, "raywm-{s}/", .{r.tag_name}) catch return null;
    // Every member must lie inside raywm-<tag>/ (no absolute paths, no ..).
    const list = capture(c, &.{ "tar", "-tzf", archive });
    if (!list.ok) {
        err("the source archive cannot be read. Nothing was installed.\n", .{});
        return null;
    }
    var lines = std.mem.splitScalar(u8, list.stdout, '\n');
    while (lines.next()) |name| {
        if (name.len == 0) continue;
        const bad = !std.mem.startsWith(u8, name, top) or std.mem.indexOf(u8, name, "/../") != null or std.mem.endsWith(u8, name, "/..");
        if (bad) {
            err("unexpected path in the source archive: {s}. Nothing was installed.\n", .{name});
            return null;
        }
    }
    // Only regular files and directories (the release archives have
    // nothing else): no symlinks, hard links or device nodes, whatever tar
    // itself would make of them.
    const verbose = capture(c, &.{ "tar", "-tvzf", archive });
    if (!verbose.ok) return null;
    var vlines = std.mem.splitScalar(u8, verbose.stdout, '\n');
    while (vlines.next()) |line| {
        if (line.len == 0) continue;
        if (line[0] != '-' and line[0] != 'd') {
            err("the source archive contains a link or special file: {s}. Nothing was installed.\n", .{line});
            return null;
        }
    }
    const src = std.fmt.allocPrint(c.arena, "{s}/src", .{work}) catch return null;
    std.Io.Dir.cwd().createDirPath(c.io, src) catch return null;
    if (!capture(c, &.{ "tar", "-xzf", archive, "-C", src, "--no-same-owner", "--no-same-permissions" }).ok) {
        err("cannot extract the source archive. Nothing was installed.\n", .{});
        return null;
    }
    const script = std.fmt.allocPrint(c.arena, "{s}/{s}scripts/arch-package.sh", .{ src, top }) catch return null;
    const pkgdir = std.fmt.allocPrint(c.arena, "{s}/pkg", .{work}) catch return null;
    if (c.dry_run) {
        out("Dry run: would build with: sh {s} {s} {s} {s}\n", .{ script, r.tag_name, archive, pkgdir });
        return std.fmt.allocPrint(c.arena, "{s}/raywm-{s}-1-x86_64.pkg.tar.zst", .{ pkgdir, r.tag.pkgverSlice() }) catch null;
    }
    out("Building {s} with makepkg (this takes a few minutes) ...\n", .{r.tag_name});
    if (!interactive(c, &.{ "sh", script, r.tag_name, archive, pkgdir })) {
        err("the Beta build failed (see above). Nothing was installed; the current RayWM is unchanged.\n", .{});
        return null;
    }
    return std.fmt.allocPrint(c.arena, "{s}/raywm-{s}-1-x86_64.pkg.tar.zst", .{ pkgdir, r.tag.pkgverSlice() }) catch null;
}

/// The package is raywm, the expected version, x86_64, and only installs
/// below the paths a RayWM package owns.
fn checkPackage(c: *Ctx, pkg: []const u8, pacman_version: []const u8) bool {
    if (c.dry_run and std.c.access((c.arena.dupeZ(u8, pkg) catch return false).ptr, std.c.F_OK) != 0) {
        out("Dry run: would check the package with pacman -Qip / -Qlp\n", .{});
        return true;
    }
    const info = capture(c, &.{ c.pacman(), "-Qip", pkg });
    if (!info.ok) {
        err("{s} is not a valid pacman package. Nothing was installed.\n", .{pkg});
        return false;
    }
    var name_ok = false;
    var version_ok = false;
    var arch_ok = false;
    var lines = std.mem.splitScalar(u8, info.stdout, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " ");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \r");
        if (std.mem.eql(u8, key, "Name")) name_ok = std.mem.eql(u8, value, "raywm");
        if (std.mem.eql(u8, key, "Version")) version_ok = std.mem.eql(u8, value, pacman_version);
        if (std.mem.eql(u8, key, "Architecture")) arch_ok = std.mem.eql(u8, value, "x86_64");
    }
    if (!name_ok or !version_ok or !arch_ok) {
        err("package metadata is not raywm {s} x86_64. Nothing was installed.\n", .{pacman_version});
        return false;
    }
    const files = capture(c, &.{ c.pacman(), "-Qlp", pkg });
    if (!files.ok) return false;
    const allowed = [_][]const u8{ "/usr/bin/raywm", "/usr/bin/raywmctl", "/usr/bin/raywm-update", "/usr/share/raywm/", "/usr/share/doc/raywm/", "/usr/share/licenses/raywm/", "/usr/share/wayland-sessions/raywm.desktop" };
    const dirs = [_][]const u8{ "/usr/", "/usr/bin/", "/usr/share/", "/usr/share/doc/", "/usr/share/licenses/", "/usr/share/wayland-sessions/" };
    var it = std.mem.splitScalar(u8, files.stdout, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse return false;
        const path = line[sp + 1 ..];
        const ok = for (allowed) |a| {
            if (std.mem.eql(u8, path, a) or (a[a.len - 1] == '/' and std.mem.startsWith(u8, path, a))) break true;
        } else for (dirs) |d| {
            if (std.mem.eql(u8, path, d)) break true;
        } else false;
        if (!ok or std.mem.indexOf(u8, path, "..") != null) {
            err("package contains an unexpected path: {s}. Nothing was installed.\n", .{path});
            return false;
        }
    }
    out("Package checked: raywm {s} x86_64.\n", .{pacman_version});
    return true;
}

pub fn main(init: std.process.Init) u8 {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    var c: Ctx = .{ .io = init.io, .gpa = init.gpa, .arena = arena_state.allocator() };
    const argv = init.minimal.args.vector;
    var command: ?[]const u8 = null;
    var channel_arg: ?[]const u8 = null;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = std.mem.span(argv[i]);
        if (std.mem.eql(u8, a, "--yes") or std.mem.eql(u8, a, "--noconfirm")) {
            c.yes = true;
        } else if (std.mem.eql(u8, a, "--dry-run")) {
            c.dry_run = true;
        } else if (std.mem.eql(u8, a, "--verbose") or std.mem.eql(u8, a, "-v")) {
            c.verbose = true;
        } else if (std.mem.eql(u8, a, "--set-channel")) {
            if (command != null or i + 1 >= argv.len) return badUsage();
            command = a;
            i += 1;
            channel_arg = std.mem.span(argv[i]);
        } else if (for ([_][]const u8{ "--check", "--install", "--channel", "--version", "--help", "-h" }) |known| {
            if (std.mem.eql(u8, a, known)) break true;
        } else false) {
            if (command != null) return badUsage();
            command = a;
        } else return badUsage();
    }
    const cmd = command orelse return badUsage();
    if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        out(usage, .{});
        return 0;
    }
    if (std.mem.eql(u8, cmd, "--version")) {
        out("raywm-update {s}\n", .{build_options.version});
        out("raywm package: {s}\n", .{installedVersion(&c) orelse "not installed with pacman"});
        return 0;
    }
    if (std.mem.eql(u8, cmd, "--channel")) {
        const s = subscription(&c) orelse return 1;
        describeSubscription(&c, s);
        return 0;
    }
    if (std.mem.eql(u8, cmd, "--set-channel")) {
        const ch = std.meta.stringToEnum(Channel, channel_arg.?) orelse {
            err("unknown channel '{s}': use beta or stable\n", .{channel_arg.?});
            return 1;
        };
        return setChannel(&c, ch);
    }
    if (std.mem.eql(u8, cmd, "--check")) return cmdCheck(&c);
    if (std.mem.eql(u8, cmd, "--install")) return cmdInstall(&c);
    return badUsage();
}

fn badUsage() u8 {
    write(2, usage, .{});
    return 1;
}

// ---- tests ------------------------------------------------------------------

const testing = std.testing;

test "tags follow the release scheme" {
    var buf: [64]u8 = undefined;
    const b = parseTag("v0.2.1-beta").?;
    try testing.expectEqual(Channel.beta, b.channel);
    try testing.expectEqualStrings("0.2.1beta-1", b.pacmanVersion(&buf));
    try testing.expectEqualStrings("0.2.1beta.2-1", parseTag("v0.2.1-beta.2").?.pacmanVersion(&buf));
    try testing.expectEqualStrings("0.2.1-1", parseTag("v0.2.1-stable").?.pacmanVersion(&buf));
    try testing.expectEqualStrings("10.0.12beta.17-1", parseTag("v10.0.12-beta.17").?.pacmanVersion(&buf));
    for ([_][]const u8{ "v0.2.1", "v0.2.0", "0.2.1-beta", "v0.2-beta", "v0.2.1-beta.1", "v0.2.1-beta.0", "v0.2.1-beta.02", "v00.2.1-beta", "v0.2.1-rc", "v0.2.1-stable.2", "v0.2.1-beta/../x", "v0.2.1.4-beta", "" }) |t| {
        if (parseTag(t) != null) {
            std.debug.print("accepted {s}\n", .{t});
            return error.TestUnexpectedResult;
        }
    }
}

test "asset names per channel" {
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("raywm-v0.2.2-beta.tar.gz", parseTag("v0.2.2-beta").?.assetName("v0.2.2-beta", &buf));
    try testing.expectEqualStrings("raywm-0.2.2-1-x86_64.pkg.tar.zst", parseTag("v0.2.2-stable").?.assetName("v0.2.2-stable", &buf));
}

test "channel rules: beta gets both, stable never a beta" {
    try testing.expect(offered(.beta, .beta));
    try testing.expect(offered(.beta, .stable));
    try testing.expect(offered(.stable, .stable));
    try testing.expect(!offered(.stable, .beta));
}

test "channel file" {
    try testing.expectEqual(ChannelState{ .ok = .beta }, parseChannelFile("channel=beta\n"));
    try testing.expectEqual(ChannelState{ .ok = .stable }, parseChannelFile("# c\n\n channel = stable \r\n"));
    try testing.expectEqual(ChannelState{ .malformed = 1 }, parseChannelFile("channel=nightly\n"));
    try testing.expectEqual(ChannelState{ .malformed = 2 }, parseChannelFile("channel=beta\nchannel=stable\n"));
    try testing.expectEqual(ChannelState{ .malformed = 1 }, parseChannelFile("chanel=beta\n"));
    try testing.expectEqual(ChannelState{ .malformed = 1 }, parseChannelFile("beta\n"));
    try testing.expectEqual(ChannelState{ .malformed = 0 }, parseChannelFile(""));
    try testing.expectEqual(ChannelState{ .malformed = 0 }, parseChannelFile("# only a comment\n"));
}

test "channel of a package version" {
    try testing.expectEqual(Channel.beta, channelOfVersion("0.2.2beta-1"));
    try testing.expectEqual(Channel.beta, channelOfVersion("0.2.1beta.2-1"));
    try testing.expectEqual(Channel.stable, channelOfVersion("0.2.1-1"));
}

test "download URLs" {
    try testing.expect(githubUrl("https://github.com/Rreeqqwel/RayWM/releases/download/v0.2.2-beta/raywm-v0.2.2-beta.tar.gz", "v0.2.2-beta", "raywm-v0.2.2-beta.tar.gz"));
    try testing.expect(!githubUrl("https://evil.example/releases/download/v0.2.2-beta/raywm-v0.2.2-beta.tar.gz", "v0.2.2-beta", "raywm-v0.2.2-beta.tar.gz"));
    try testing.expect(!githubUrl("https://github.com/Rreeqqwel/RayWM/releases/download/v0.2.1-beta/raywm-v0.2.2-beta.tar.gz", "v0.2.2-beta", "raywm-v0.2.2-beta.tar.gz"));
    try testing.expect(overrideUrl("file:///tmp/x/raywm-release.json", "", "raywm-release.json"));
    try testing.expect(!overrideUrl("file:///tmp/../x/raywm-release.json", "", "raywm-release.json"));
    try testing.expect(!overrideUrl("http://x/raywm-release.json", "", "raywm-release.json"));
    try testing.expect(!overrideUrl("file:///tmp/xraywm-release.json", "", "raywm-release.json"));
}

const page_fixture =
    \\[
    \\ {"tag_name": "v0.2.2-beta", "draft": false, "prerelease": true, "assets": [
    \\   {"name": "raywm-v0.2.2-beta.tar.gz", "size": 10, "browser_download_url": "https://github.com/Rreeqqwel/RayWM/releases/download/v0.2.2-beta/raywm-v0.2.2-beta.tar.gz"},
    \\   {"name": "raywm-release.json", "size": 5, "browser_download_url": "https://github.com/Rreeqqwel/RayWM/releases/download/v0.2.2-beta/raywm-release.json"}]},
    \\ {"tag_name": "v0.2.1", "draft": false, "prerelease": false, "assets": []},
    \\ {"tag_name": "v0.2.3-beta", "draft": true, "prerelease": true, "assets": []},
    \\ {"tag_name": "v0.2.4-beta", "draft": false, "prerelease": false, "assets": []},
    \\ {"tag_name": "v0.2.5-stable", "draft": false, "prerelease": false, "assets": [
    \\   {"name": "raywm-release.json", "size": 5, "browser_download_url": "https://github.com/Rreeqqwel/RayWM/releases/download/v0.2.5-stable/raywm-release.json"}]},
    \\ {"tag_name": "v0.2.6-stable", "draft": false, "prerelease": false, "assets": [
    \\   {"name": "raywm-0.2.6-1-x86_64.pkg.tar.zst", "size": 10, "browser_download_url": "https://elsewhere.example/raywm-0.2.6-1-x86_64.pkg.tar.zst"},
    \\   {"name": "raywm-release.json", "size": 5, "browser_download_url": "https://github.com/Rreeqqwel/RayWM/releases/download/v0.2.6-stable/raywm-release.json"}]},
    \\ "garbage", 42
    \\]
;

test "release list: only well-formed releases survive" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var releases: std.ArrayList(Release) = .empty;
    var ignored: std.ArrayList(Ignored) = .empty;
    const n = (try parsePage(arena, page_fixture, githubUrl, &releases, &ignored)).?;
    try testing.expectEqual(@as(usize, 8), n);
    try testing.expectEqual(@as(usize, 1), releases.items.len);
    try testing.expectEqualStrings("v0.2.2-beta", releases.items[0].tag_name);
    try testing.expectEqual(@as(usize, 5), ignored.items.len);
    try testing.expect((try parsePage(arena, "{\"message\": \"API rate limit exceeded\"}", githubUrl, &releases, &ignored)) == null);
    try testing.expect((try parsePage(arena, "not json", githubUrl, &releases, &ignored)) == null);
}

fn metaFor(arena: std.mem.Allocator, tag: []const u8, edit: []const u8) ![]const u8 {
    const t = parseTag(tag).?;
    var pv: [64]u8 = undefined;
    var nb: [128]u8 = undefined;
    const channels = if (t.channel == .stable) "[\"beta\", \"stable\"]" else "[\"beta\"]";
    const text = try std.fmt.allocPrint(arena,
        \\{{"schema": 1, "project": "raywm", "tag": "{s}", "commit": "x", "channel": "{s}", "channels": {s},
        \\ "version": "{s}", "prerelease": null, "pkgver": "{s}", "pacman_version": "{s}", "compare": "vercmp(pacman_version)",
        \\ "assets": [{{"name": "{s}", "kind": "{s}", "size": 10, "sha256": "{s}"}}]}}
    , .{ tag, @tagName(t.channel), channels, t.version, t.pkgverSlice(), t.pacmanVersion(&pv), t.assetName(tag, &nb), t.assetKind(), "0123456789abcdef" ** 4 });
    if (edit.len == 0) return text;
    var it = std.mem.splitSequence(u8, edit, "=>");
    const from = it.next().?;
    const to = it.next().?;
    return std.mem.replaceOwned(u8, arena, text, from, to);
}

fn releaseFor(tag: []const u8, buf: []u8) Release {
    const t = parseTag(tag).?;
    return .{ .tag_name = tag, .tag = t, .prerelease = t.channel == .beta, .asset = .{ .name = t.assetName(tag, buf), .url = "", .size = 10 }, .meta = .{ .name = "raywm-release.json", .url = "", .size = 1 } };
}

test "metadata must agree with the release" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var nb: [128]u8 = undefined;
    const beta = releaseFor("v0.2.2-beta", &nb);
    try testing.expect(checkMetadata(arena, try metaFor(arena, "v0.2.2-beta", ""), &beta, .beta) == .ok);
    var nb2: [128]u8 = undefined;
    const stable = releaseFor("v0.2.2-stable", &nb2);
    try testing.expect(checkMetadata(arena, try metaFor(arena, "v0.2.2-stable", ""), &stable, .stable) == .ok);
    try testing.expect(checkMetadata(arena, try metaFor(arena, "v0.2.2-stable", ""), &stable, .beta) == .ok);
    const bad_edits = [_][]const u8{
        "\"schema\": 1=>\"schema\": 2",
        "\"project\": \"raywm\"=>\"project\": \"other\"",
        "\"tag\": \"v0.2.2-beta\"=>\"tag\": \"v0.2.3-beta\"",
        "\"pacman_version\": \"0.2.2beta-1\"=>\"pacman_version\": \"9.9.9-1\"",
        "\"channels\": [\"beta\"]=>\"channels\": [\"beta\", \"stable\"]",
        "\"channels\": [\"beta\"]=>\"channels\": [\"nightly\"]",
        "\"kind\": \"source\"=>\"kind\": \"arch-package\"",
        "\"size\": 10=>\"size\": 11",
        "0123456789abcdef0123=>0123456789ABCDEF0123",
        "0123456789abcdef0123=>0123",
        "\"name\": \"raywm-v0.2.2-beta.tar.gz\"=>\"name\": \"other.tar.gz\"",
        "{\"schema\"=>[{\"schema\"",
    };
    for (bad_edits) |e| {
        const text = try metaFor(arena, "v0.2.2-beta", e);
        if (checkMetadata(arena, text, &beta, .beta) != .bad) {
            std.debug.print("accepted edit {s}\n", .{e});
            return error.TestUnexpectedResult;
        }
    }
    // A Beta is never offered to the stable channel, whatever it claims.
    try testing.expect(checkMetadata(arena, try metaFor(arena, "v0.2.2-beta", ""), &beta, .stable) == .bad);
}
