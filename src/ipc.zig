//! Version 1 NDJSON desktop IPC. Same-uid peers, a private runtime socket,
//! bounded messages/queues/clients, and a fixed action vocabulary. No eval.
const std = @import("std");
const wl = @import("wayland").server.wl;
const lua = @import("lua");
const srv = @import("server.zig");
const host = @import("host.zig");
const c = @cImport({
    // Zig 0.16 translate-c diagnoses glibc's fortified error stubs while
    // importing fcntl.h at -OReleaseSafe. Import the plain declarations;
    // the socket code below supplies explicit fixed-buffer bounds.
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
    @cInclude("sys/stat.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("errno.h");
});
const Value = std.json.Value;
const Allocator = std.mem.Allocator;
const event_count = @typeInfo(lua.Event).@"enum".fields.len;
const max_request = 65536;
const max_queue = 131072;
const max_clients = 32;
const log = std.log.scoped(.ipc);

pub const Ipc = struct {
    server: *srv.Server = undefined,
    fd: c_int = -1,
    source: ?*wl.EventSource = null,
    ready: bool = false,
    path: [108:0]u8 = @splat(0),
    inode: u64 = 0,
    clients: wl.list.Head(Client, .link) = undefined,
    count: usize = 0,
    depth: usize = 0,
    seq: u64 = 0,

    pub fn init(ipc: *Ipc, server: *srv.Server, display: [:0]const u8) !void {
        const runtime = std.c.getenv("XDG_RUNTIME_DIR") orelse return error.NoRuntimeDirectory;
        const dir = c.open(runtime, c.O_RDONLY | c.O_DIRECTORY | c.O_NOFOLLOW | c.O_CLOEXEC);
        if (dir < 0) return error.BadRuntimeDirectory;
        defer _ = c.close(dir);
        var stat: c.struct_stat = undefined;
        if (c.fstat(dir, &stat) != 0 or stat.st_uid != c.getuid() or stat.st_mode & 0o077 != 0) return error.InsecureRuntimeDirectory;
        ipc.* = .{ .server = server };
        ipc.clients.init();
        const name = try std.fmt.bufPrintZ(&ipc.path, "{s}/raywm-{s}.sock", .{ std.mem.span(runtime), display });
        var addr: c.struct_sockaddr_un = std.mem.zeroes(c.struct_sockaddr_un);
        if (name.len >= addr.sun_path.len) return error.SocketPathTooLong;
        addr.sun_family = c.AF_UNIX;
        @memcpy(addr.sun_path[0..name.len], name);
        const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_NONBLOCK | c.SOCK_CLOEXEC, 0);
        if (fd < 0) return error.SocketFailed;
        errdefer _ = c.close(fd);
        if (c.bind(fd, .{ .__sockaddr_un__ = &addr }, @sizeOf(@TypeOf(addr))) != 0) return error.BindFailed;
        errdefer _ = c.unlink(&ipc.path);
        if (c.chmod(&ipc.path, 0o600) != 0 or c.listen(fd, 16) != 0 or c.lstat(&ipc.path, &stat) != 0) return error.ListenFailed;
        ipc.inode = stat.st_ino;
        ipc.fd = fd;
        ipc.source = try server.wl_server.getEventLoop().addFd(*Ipc, fd, .{ .readable = true }, accept, ipc);
        ipc.ready = true;
        log.info("v1 socket {s}", .{name});
    }

    pub fn deinit(ipc: *Ipc) void {
        if (!ipc.ready) return;
        ipc.ready = false;
        var it = ipc.clients.safeIterator(.forward);
        while (it.next()) |client| client.destroy();
        if (ipc.source) |source| source.remove();
        ipc.source = null;
        _ = c.close(ipc.fd);
        ipc.fd = -1;
        var stat: c.struct_stat = undefined;
        if (c.lstat(&ipc.path, &stat) == 0 and stat.st_ino == ipc.inode and stat.st_mode & c.S_IFMT == c.S_IFSOCK) _ = c.unlink(&ipc.path);
    }

    fn accept(_: c_int, _: wl.EventMask, ipc: *Ipc) c_int {
        for (0..8) |_| {
            const fd = c.accept4(ipc.fd, .{ .__sockaddr__ = null }, null, c.SOCK_NONBLOCK | c.SOCK_CLOEXEC);
            if (fd < 0) break;
            var peer: c.struct_ucred = undefined;
            var size: c.socklen_t = @sizeOf(@TypeOf(peer));
            if (ipc.count >= max_clients or c.getsockopt(fd, c.SOL_SOCKET, c.SO_PEERCRED, &peer, &size) != 0 or peer.uid != c.getuid()) {
                _ = c.close(fd);
                continue;
            }
            const client = srv.gpa.create(Client) catch {
                _ = c.close(fd);
                continue;
            };
            client.* = .{ .ipc = ipc, .fd = fd };
            const loop = ipc.server.wl_server.getEventLoop();
            client.source = loop.addFd(*Client, fd, .{ .readable = true }, Client.io, client) catch {
                _ = c.close(fd);
                srv.gpa.destroy(client);
                continue;
            };
            client.timer = loop.addTimer(*Client, Client.timeout, client) catch {
                client.source.?.remove();
                _ = c.close(fd);
                srv.gpa.destroy(client);
                continue;
            };
            ipc.clients.append(client);
            ipc.count += 1;
        }
        return 0;
    }

    fn sweep(ipc: *Ipc) void {
        if (ipc.depth != 0) return;
        var it = ipc.clients.safeIterator(.forward);
        while (it.next()) |client| if (client.dead) client.destroy();
    }

    pub fn notify(ipc: *Ipc, event: lua.Event, id: u32, args: []const lua.Arg) void {
        if (!ipc.ready or ipc.count == 0) return;
        ipc.seq +%= 1;
        var values: [8]Value = undefined;
        const n = @min(args.len, values.len);
        for (args[0..n], values[0..n]) |arg, *value| value.* = switch (arg) {
            .int => |i| .{ .integer = i },
            .boolean => |b| .{ .bool = b },
            .nil => .null,
        };
        var it = ipc.clients.iterator(.forward);
        while (it.next()) |client| {
            if (client.dead or !client.events.isSet(@intFromEnum(event))) continue;
            client.send(.{ .v = 1, .event = @tagName(event), .subject = id, .args = values[0..n], .seq = ipc.seq });
        }
        ipc.sweep();
    }
};

const Client = struct {
    ipc: *Ipc,
    fd: c_int,
    source: ?*wl.EventSource = null,
    timer: ?*wl.EventSource = null,
    link: wl.list.Link = undefined,
    dead: bool = false,
    eof: bool = false,
    input: [max_request]u8 = undefined,
    used: usize = 0,
    output: [max_queue]u8 = undefined,
    end: usize = 0,
    sent: usize = 0,
    events: std.StaticBitSet(event_count) = .initEmpty(),

    fn destroy(client: *Client) void {
        client.link.remove();
        if (client.source) |source| source.remove();
        if (client.timer) |timer| timer.remove();
        _ = c.close(client.fd);
        client.ipc.count -= 1;
        srv.gpa.destroy(client);
    }

    fn timeout(client: *Client) c_int {
        client.dead = true;
        client.ipc.sweep();
        return 0;
    }

    fn send(client: *Client, value: anytype) void {
        if (client.dead) return;
        const bytes = std.json.Stringify.valueAlloc(srv.gpa, value, .{}) catch {
            client.dead = true;
            return;
        };
        defer srv.gpa.free(bytes);
        const remaining = client.end - client.sent;
        if (bytes.len + 1 > max_queue - remaining) {
            client.dead = true; // slow consumers cannot grow compositor memory
            return;
        }
        std.mem.copyForwards(u8, client.output[0..remaining], client.output[client.sent..client.end]);
        client.sent = 0;
        client.end = remaining;
        @memcpy(client.output[client.end..][0..bytes.len], bytes);
        client.end += bytes.len;
        client.output[client.end] = '\n';
        client.end += 1;
        client.source.?.fdUpdate(.{ .readable = !client.eof, .writable = true }) catch {
            client.dead = true;
        };
    }

    fn err(client: *Client, id: Value, message: []const u8) void {
        client.send(.{ .v = 1, .id = id, .ok = false, .err = message });
    }

    fn io(_: c_int, mask: wl.EventMask, client: *Client) c_int {
        const ipc = client.ipc;
        ipc.depth += 1;
        defer {
            ipc.depth -= 1;
            ipc.sweep();
        }
        if (mask.@"error" or mask.hangup) {
            client.dead = true;
            return 0;
        }
        if (mask.readable and !client.eof) {
            var budget: usize = 64;
            while (!client.dead) {
                if (client.used == max_request) {
                    client.dead = true;
                    break;
                }
                const n = c.read(client.fd, client.input[client.used..].ptr, max_request - client.used);
                if (n == 0) {
                    client.eof = true;
                    break;
                }
                if (n < 0) {
                    if (std.c._errno().* != c.EAGAIN and std.c._errno().* != c.EINTR) client.dead = true;
                    break;
                }
                if (client.used == 0) client.timer.?.timerUpdate(5000) catch {};
                client.used += @intCast(n);
                while (std.mem.indexOfScalar(u8, client.input[0..client.used], '\n')) |end| {
                    if (budget == 0) {
                        client.dead = true;
                        break;
                    }
                    budget -= 1;
                    client.request(client.input[0..end]);
                    std.mem.copyForwards(u8, client.input[0 .. client.used - end - 1], client.input[end + 1 .. client.used]);
                    client.used -= end + 1;
                    if (client.used == 0) client.timer.?.timerUpdate(0) catch {};
                    if (client.dead) break;
                }
            }
        }
        if (!client.dead) while (client.sent < client.end) {
            const n = c.send(client.fd, client.output[client.sent..client.end].ptr, client.end - client.sent, c.MSG_NOSIGNAL);
            if (n < 0) {
                if (std.c._errno().* != c.EAGAIN and std.c._errno().* != c.EINTR) client.dead = true;
                break;
            }
            if (n == 0) break;
            client.sent += @intCast(n);
        };
        if (!client.dead and client.sent == client.end) {
            if (client.eof) {
                client.dead = true;
                return 0;
            }
            client.sent = 0;
            client.end = 0;
            client.source.?.fdUpdate(.{ .readable = true }) catch {
                client.dead = true;
            };
        }
        return 0;
    }

    fn request(client: *Client, bytes: []const u8) void {
        var arena = std.heap.ArenaAllocator.init(srv.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        if (!boundedJson(bytes)) return client.err(.null, "invalid_json");
        const parsed = std.json.parseFromSlice(Value, a, bytes, .{ .allocate = .alloc_always, .max_value_len = max_request }) catch return client.err(.null, "invalid_json");
        const root = parsed.value;
        if (root != .object) return client.err(.null, "invalid_request");
        const id = root.object.get("id") orelse Value.null;
        if (id != .integer or id.integer < 0 or id.integer > (1 << 53) - 1) return client.err(.null, "invalid_id");
        const version = root.object.get("v") orelse Value.null;
        if (version != .integer or version.integer != 1) return client.err(id, "unsupported_version");
        const method = root.object.get("method") orelse Value.null;
        if (method != .string) return client.err(id, "invalid_method");
        for (root.object.keys()) |key| if (!oneOf(key, &.{ "id", "v", "method", "params" })) return client.err(id, "invalid_request");
        const params = root.object.get("params") orelse Value{ .object = .empty };
        if (params != .object) return client.err(id, "invalid_params");
        const result = client.execute(a, method.string, params.object) catch |e| return client.err(id, @errorName(e));
        client.send(.{ .v = 1, .id = id, .ok = true, .result = result });
    }

    fn execute(client: *Client, a: Allocator, method: []const u8, params: std.json.ObjectMap) !Value {
        const server = client.ipc.server;
        if (oneOf(method, &.{ "windows", "outputs", "workspaces" })) {
            try allowed(params, &.{ "offset", "limit" });
            const offset = try unsigned(params.get("offset") orelse .{ .integer = 0 });
            const limit = try unsigned(params.get("limit") orelse .{ .integer = 64 });
            if (offset > lua.max_list or limit == 0 or limit > 64) return error.invalid_params;
            var ids: [lua.max_list]u32 = undefined;
            const total = if (std.mem.eql(u8, method, "windows")) host.views(server, &ids) else if (std.mem.eql(u8, method, "outputs")) host.outputsAll(server, &ids) else host.workspaces(server, &ids);
            var items: std.array_list.Managed(Value) = .init(a);
            const end = @min(total, @as(usize, offset) + limit);
            for (ids[@min(offset, total)..end]) |id| {
                const value: Value = if (std.mem.eql(u8, method, "windows")) blk: {
                    const v = host.view(server, id) orelse continue;
                    break :blk try obj(a, &.{ .{ "id", num(id) }, .{ "x", num(v.box.x) }, .{ "y", num(v.box.y) }, .{ "w", num(v.box.w) }, .{ "h", num(v.box.h) }, .{ "title", text(v.title) }, .{ "app_id", text(v.app_id) }, .{ "workspace", num(v.workspace) }, .{ "output", num(v.output) }, .{ "focused", boolean(v.focused) }, .{ "visible", boolean(v.visible) }, .{ "floating", boolean(v.floating) }, .{ "fullscreen", boolean(v.fullscreen) }, .{ "maximized", boolean(v.maximized) }, .{ "minimized", boolean(v.minimized) }, .{ "urgent", boolean(v.urgent) }, .{ "xwayland", boolean(v.xwayland) }, .{ "pid", num(v.pid) } });
                } else if (std.mem.eql(u8, method, "outputs")) blk: {
                    const o = host.output(server, id) orelse continue;
                    break :blk try obj(a, &.{ .{ "id", num(id) }, .{ "name", text(o.name) }, .{ "x", num(o.box.x) }, .{ "y", num(o.box.y) }, .{ "w", num(o.box.w) }, .{ "h", num(o.box.h) }, .{ "scale", .{ .float = o.scale } }, .{ "transform", text(o.transform) }, .{ "enabled", boolean(o.enabled) }, .{ "power", boolean(o.power) }, .{ "workspace", num(o.workspace) } });
                } else blk: {
                    const w = host.workspace(server, id) orelse continue;
                    break :blk try obj(a, &.{ .{ "id", num(id) }, .{ "name", text(w.name) }, .{ "output", num(w.output) }, .{ "active", boolean(w.active) }, .{ "urgent", boolean(w.urgent) } });
                };
                try items.append(value);
            }
            return obj(a, &.{ .{ "items", .{ .array = items } }, .{ "next", if (end < total) num(end) else .null } });
        }
        if (std.mem.eql(u8, method, "subscribe")) {
            try allowed(params, &.{"events"});
            const events = params.get("events") orelse return error.invalid_params;
            if (events != .array or events.array.items.len > event_count) return error.invalid_params;
            var selected: @TypeOf(client.events) = .initEmpty();
            for (events.array.items) |name| {
                if (name != .string) return error.invalid_params;
                const event = std.meta.stringToEnum(lua.Event, name.string) orelse return error.invalid_event;
                selected.set(@intFromEnum(event));
            }
            client.events = selected;
            return .null;
        }
        if (server.session_lock.locked()) return error.locked;
        if (std.mem.eql(u8, method, "focus")) {
            try allowed(params, &.{"window"});
            const id = try unsigned(params.get("window") orelse return error.invalid_params);
            const v = server.viewById(id) orelse return error.stale;
            if (!server.focusable(v)) return error.hidden;
            _ = host.viewCmd(server, id, .focus);
        } else if (std.mem.eql(u8, method, "workspace_activate")) {
            try allowed(params, &.{"workspace"});
            const id = try unsigned(params.get("workspace") orelse return error.invalid_params);
            const result = host.workspaceCmd(server, id, .activate);
            if (result != .ok) return error.stale;
        } else if (std.mem.eql(u8, method, "window_workspace")) {
            try allowed(params, &.{ "window", "workspace" });
            const id = try unsigned(params.get("window") orelse return error.invalid_params);
            const ws = try unsigned(params.get("workspace") orelse return error.invalid_params);
            if (!host.viewCmd(server, id, .{ .workspace = ws })) return error.stale;
        } else return error.unknown_method;
        return .null;
    }
};

fn oneOf(s: []const u8, names: []const []const u8) bool {
    for (names) |name| if (std.mem.eql(u8, s, name)) return true;
    return false;
}
fn allowed(params: std.json.ObjectMap, names: []const []const u8) !void {
    for (params.keys()) |key| if (!oneOf(key, names)) return error.invalid_params;
}
fn unsigned(value: Value) !u32 {
    if (value != .integer or value.integer < 0 or value.integer > std.math.maxInt(u32)) return error.invalid_params;
    return @intCast(value.integer);
}
fn num(value: anytype) Value {
    return .{ .integer = @intCast(value) };
}
fn boolean(value: bool) Value {
    return .{ .bool = value };
}
fn text(value: ?[*:0]const u8) Value {
    const bytes = if (value) |s| std.mem.span(s) else "";
    var len = @min(bytes.len, 512);
    while (len != 0 and len < bytes.len and bytes[len] & 0xc0 == 0x80) : (len -= 1) {}
    if (!std.unicode.utf8ValidateSlice(bytes[0..len])) return .{ .string = "<invalid UTF-8>" };
    return .{ .string = bytes[0..len] };
}
fn obj(a: Allocator, pairs: []const struct { []const u8, Value }) !Value {
    var map: std.json.ObjectMap = .empty;
    for (pairs) |pair| try map.put(a, pair[0], pair[1]);
    return .{ .object = map };
}

/// Bound structural depth before the recursive JSON parser runs.
pub fn boundedJson(bytes: []const u8) bool {
    var depth: usize = 0;
    var string = false;
    var escape = false;
    for (bytes) |byte| {
        if (byte == 0) return false;
        if (string) {
            if (escape) escape = false else if (byte == '\\') escape = true else if (byte == '"') string = false;
        } else switch (byte) {
            '"' => string = true,
            '{', '[' => {
                depth += 1;
                if (depth > 32) return false;
            },
            '}', ']' => {
                if (depth == 0) return false;
                depth -= 1;
            },
            else => {},
        }
    }
    return depth == 0 and !string;
}
