//! Lua 5.4 plugin host, API v1 (see docs/API.md).
//!
//! Plugins are trusted user code. The limits here (pcall isolation, memory
//! cap, instruction budget) contain bugs; they are not a security sandbox.
//! Lua never sees native pointers: windows, outputs and timers are integer
//! ids, and the host validates every id on use.
const std = @import("std");
pub const c = @cImport({
    @cInclude("lua.h");
    @cInclude("lualib.h");
    @cInclude("lauxlib.h");
});

const log = std.log.scoped(.lua);
const gpa = std.heap.c_allocator;

pub const api_version = 1;
pub const Event = enum { view_map, view_unmap, view_focus, view_title, view_resized, output_add, output_remove, layout };
pub const Box = struct { x: i32, y: i32, w: i32, h: i32 };
pub const ViewInfo = struct { box: Box, title: ?[*:0]const u8, app_id: ?[*:0]const u8, focused: bool, output: u32 };
pub const OutputInfo = struct { box: Box, usable: Box };
pub const ViewCmd = union(enum) { move: [2]i32, place: Box, opacity: f32, raise, focus, close, show: bool };
pub const Key = struct { mods: u32, sym: u32 };
pub const Limits = struct {
    memory: usize = 64 << 20,
    instructions: u64 = 200_000_000,
    /// Receives plugin/config errors ("init.lua" for the config itself).
    report: *const fn (source: []const u8, msg: []const u8) void = logError,
};

fn logError(source: []const u8, msg: []const u8) void {
    log.err("[{s}] {s}", .{ source, msg });
}

const max_depth = 8; // nested host->Lua->host->Lua re-entry
const hook_step = 10_000;
const no_ref = c.LUA_NOREF;

/// Lua string at `i`, or `default` if it is not a string or number.
fn str(L: ?*c.lua_State, i: c_int, default: [:0]const u8) [:0]const u8 {
    const p = c.lua_tolstring(L, i, null);
    return if (p == null) default else std.mem.span(p);
}

fn upvalue(i: c_int) c_int {
    return c.LUA_REGISTRYINDEX - i;
}

pub fn monotonicNs() u64 {
    var ts: std.posix.timespec = undefined;
    _ = std.posix.system.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// `H.Api` must provide the host functions called below (see host.zig).
pub fn Runtime(comptime H: type) type {
    return struct {
        const Self = @This();
        const Api = H.Api;

        const Plugin = struct { name: [:0]u8, teardown: c_int, dead: bool = false, torn_down: bool = false };
        /// `manage`: the plugin lays out this view (no free move/resize).
        const Kind = union(enum) { event: Event, bind: Key, timer: u64, manage: u32 };
        /// Every resource a plugin registers. Removed only by sweep(), never
        /// while a dispatch loop may be iterating.
        const Reg = struct { id: u32, plugin: u32, ref: c_int, kind: Kind, dead: bool = false };

        L: *c.lua_State = undefined,
        host: *H,
        config_path: [:0]const u8,
        limits: Limits,
        clock: *const fn () u64 = monotonicNs,
        mem_used: usize = 0,
        budget: u64 = 0,
        depth: u32 = 0,
        in_config: bool = false,
        config_ok: bool = false,
        sweeping: bool = false,
        sweep_needed: bool = false,
        reload_requested: bool = false,
        /// False when no Lua state exists (only after a failed reload).
        alive: bool = false,
        plugins: std.ArrayList(Plugin) = .empty,
        regs: std.ArrayList(Reg) = .empty,
        next_id: u32 = 1,

        pub fn create(host: *H, config_path: [:0]const u8, limits: Limits) !*Self {
            const self = try gpa.create(Self);
            errdefer gpa.destroy(self);
            self.* = .{ .host = host, .config_path = try gpa.dupeZ(u8, config_path), .limits = limits };
            errdefer gpa.free(self.config_path);
            try self.start();
            return self;
        }

        pub fn destroy(self: *Self) void {
            self.stop();
            self.plugins.deinit(gpa);
            self.regs.deinit(gpa);
            gpa.free(self.config_path);
            gpa.destroy(self);
        }

        /// True when a live plugin manages the layout of view `id`.
        pub fn managed(self: *Self, id: u32) bool {
            if (!self.alive) return false;
            for (self.regs.items) |r| if (self.live(r) and r.kind == .manage and r.kind.manage == id) return true;
            return false;
        }

        /// True when some live plugin registered a key binding; otherwise the
        /// core keeps its fallback bindings active.
        pub fn hasBindings(self: *Self) bool {
            for (self.regs.items) |r| if (self.live(r) and r.kind == .bind) return true;
            return false;
        }

        pub fn configured(self: *Self) bool {
            return self.config_ok;
        }

        /// Also the way to recover after a failed reload.
        pub fn requestReload(self: *Self) void {
            self.reload_requested = true;
            if (self.depth == 0) self.leaveOuter();
        }

        fn start(self: *Self) !void {
            const L = c.lua_newstate(alloc, self) orelse return error.OutOfMemory;
            // Library setup can raise memory errors, so it runs protected.
            c.lua_pushcclosure(L, initState, 0);
            c.lua_pushlightuserdata(L, self);
            if (c.lua_pcallk(L, 1, 0, 0, 0, null) != c.LUA_OK) {
                c.lua_close(L);
                return error.OutOfMemory;
            }
            c.lua_sethook(L, hook, c.LUA_MASKCOUNT, hook_step);
            self.L = L;
            self.alive = true;

            if (!self.enter()) unreachable;
            self.in_config = true;
            const rc = c.luaL_loadfilex(L, self.config_path.ptr, null);
            if (rc != c.LUA_OK) {
                const msg = str(L, -1, "?");
                // A missing config is normal on first start: fallback bindings apply.
                if (rc == c.LUA_ERRFILE) log.warn("{s}; using fallback bindings", .{msg}) else self.limits.report("init.lua", msg);
                c.lua_settop(L, 0);
            } else self.config_ok = self.pcall(null, 0, 0);
            self.in_config = false;
            self.leave();
        }

        fn initState(L: ?*c.lua_State) callconv(.c) c_int {
            const self: *Self = @ptrCast(@alignCast(c.lua_touserdata(L, 1)));
            c.luaL_openlibs(L);
            c.lua_createtable(L, 0, globals.len + 1);
            c.lua_pushinteger(L, api_version);
            c.lua_setfield(L, -2, "api_version");
            inline for (globals) |g| {
                c.lua_pushlightuserdata(L, self);
                c.lua_pushcclosure(L, g[1], 1);
                c.lua_setfield(L, -2, g[0]);
            }
            c.lua_setglobal(L, "raywm");
            return 0;
        }

        /// Tears down every plugin (teardown + resource release), then the VM.
        fn stop(self: *Self) void {
            if (!self.alive) return;
            for (self.plugins.items) |*p| p.dead = true;
            self.sweep_needed = true;
            self.sweep();
            c.lua_close(self.L);
            self.alive = false;
            for (self.plugins.items) |p| gpa.free(p.name);
            self.plugins.clearRetainingCapacity();
            self.regs.clearRetainingCapacity();
            self.mem_used = 0;
            self.config_ok = false;
            Api.armTimer(self.host, null);
        }

        // ---- entry/exit bookkeeping -------------------------------------

        fn enter(self: *Self) bool {
            if (self.depth >= max_depth) {
                log.warn("event dropped: re-entry depth {d}", .{self.depth});
                return false;
            }
            if (self.depth == 0) self.budget = self.limits.instructions;
            self.depth += 1;
            return true;
        }

        fn leave(self: *Self) void {
            self.depth -= 1;
            if (self.depth == 0) self.leaveOuter();
        }

        /// Deferred work, run only when no Lua code is on the stack.
        fn leaveOuter(self: *Self) void {
            if (self.sweeping) return;
            if (self.sweep_needed) self.sweep();
            if (self.reload_requested) {
                self.reload_requested = false;
                log.info("reloading {s}", .{self.config_path});
                self.stop();
                self.start() catch self.limits.report("raywm", "reload failed: out of memory; Lua is disabled until the next reload");
                self.reload_requested = false;
            }
        }

        fn live(self: *Self, r: Reg) bool {
            return !r.dead and !self.plugins.items[r.plugin].dead;
        }

        fn kill(self: *Self, plugin: u32) void {
            self.plugins.items[plugin].dead = true;
            self.sweep_needed = true;
        }

        fn sweep(self: *Self) void {
            self.sweeping = true;
            defer self.sweeping = false;
            while (self.sweep_needed) {
                self.sweep_needed = false;
                for (0..self.plugins.items.len) |i| {
                    const p = &self.plugins.items[i];
                    if (!p.dead or p.torn_down) continue;
                    p.torn_down = true;
                    if (p.teardown == no_ref) continue;
                    _ = c.lua_rawgeti(self.L, c.LUA_REGISTRYINDEX, p.teardown);
                    self.depth += 1;
                    if (self.depth == 1) self.budget = self.limits.instructions;
                    _ = self.pcall(@intCast(i), 0, 0);
                    self.depth -= 1;
                }
                var j: usize = 0;
                for (self.regs.items) |r| {
                    if (self.live(r)) {
                        self.regs.items[j] = r;
                        j += 1;
                    } else {
                        if (r.ref != no_ref) c.luaL_unref(self.L, c.LUA_REGISTRYINDEX, r.ref);
                    }
                }
                self.regs.shrinkRetainingCapacity(j);
            }
            self.armTimer();
        }

        /// Calls the function below `nargs` arguments on the stack. On error
        /// logs a traceback and unloads the plugin (null = the config file).
        fn pcall(self: *Self, plugin: ?u32, nargs: c_int, nres: c_int) bool {
            const L = self.L;
            // Each top-level callback gets the full budget, so a slow handler
            // cannot get a later, innocent one killed.
            if (self.depth <= 1) self.budget = self.limits.instructions;
            const base = c.lua_gettop(L) - nargs;
            c.lua_pushcclosure(L, traceback, 0);
            c.lua_rotate(L, base, 1);
            const rc = c.lua_pcallk(L, nargs, nres, base, 0, null);
            c.lua_rotate(L, base, -1);
            c.lua_settop(L, -2);
            if (rc == c.LUA_OK) return true;
            const name = if (plugin) |p| self.plugins.items[p].name else "init.lua";
            self.limits.report(name, str(L, -1, "error"));
            c.lua_settop(L, -2);
            if (plugin) |p| self.kill(p);
            return false;
        }

        // ---- calls from the compositor -----------------------------------

        pub fn emit(self: *Self, ev: Event, id: u32) void {
            // While init.lua runs, events are not delivered (same as on the
            // first start, before the runtime is attached to the compositor).
            if (!self.alive or self.in_config) return;
            // A window that is gone is no longer managed by anyone.
            if (ev == .view_unmap) for (self.regs.items) |*r| if (r.kind == .manage and r.kind.manage == id) {
                r.dead = true;
                self.sweep_needed = true;
            };
            if (!self.enter()) return;
            defer self.leave();
            const n = self.regs.items.len; // later registrations wait for the next event
            for (0..n) |i| {
                const r = self.regs.items[i];
                if (!self.live(r) or r.kind != .event or r.kind.event != ev) continue;
                _ = c.lua_rawgeti(self.L, c.LUA_REGISTRYINDEX, r.ref);
                c.lua_pushinteger(self.L, id);
                _ = self.pcall(r.plugin, 1, 0);
            }
        }

        pub fn key(self: *Self, mods: u32, sym: u32) bool {
            if (!self.alive) return false;
            for (0..self.regs.items.len) |i| {
                const r = self.regs.items[i];
                if (!self.live(r) or r.kind != .bind or r.kind.bind.mods != mods or r.kind.bind.sym != sym) continue;
                if (!self.enter()) return true;
                defer self.leave();
                _ = c.lua_rawgeti(self.L, c.LUA_REGISTRYINDEX, r.ref);
                _ = self.pcall(r.plugin, 0, 0);
                return true;
            }
            return false;
        }

        /// Fired by the host's single event-loop timer.
        pub fn runTimers(self: *Self) void {
            if (!self.alive) return;
            const now = self.clock();
            if (!self.enter()) return;
            const n = self.regs.items.len;
            for (0..n) |i| {
                const r = self.regs.items[i];
                if (!self.live(r) or r.kind != .timer or r.kind.timer > now) continue;
                self.regs.items[i].dead = true; // one-shot
                self.sweep_needed = true;
                _ = c.lua_rawgeti(self.L, c.LUA_REGISTRYINDEX, r.ref);
                _ = self.pcall(r.plugin, 0, 0);
            }
            self.leave();
            self.armTimer();
        }

        fn armTimer(self: *Self) void {
            var next: ?u64 = null;
            for (self.regs.items) |r| if (self.live(r) and r.kind == .timer) {
                next = @min(next orelse r.kind.timer, r.kind.timer);
            };
            const deadline = next orelse return Api.armTimer(self.host, null);
            const left = deadline -| self.clock();
            Api.armTimer(self.host, @intCast(@max(1, std.math.divCeil(u64, left, std.time.ns_per_ms) catch 1)));
        }

        // ---- Lua side ------------------------------------------------------

        fn alloc(ud: ?*anyopaque, ptr: ?*anyopaque, osize: usize, nsize: usize) callconv(.c) ?*anyopaque {
            const self: *Self = @ptrCast(@alignCast(ud.?));
            const old = if (ptr == null) 0 else osize; // osize is a type tag when ptr is null
            if (nsize == 0) {
                self.mem_used -= old;
                std.c.free(ptr);
                return null;
            }
            if (nsize > old and self.mem_used + (nsize - old) > self.limits.memory) return null;
            const p = std.c.realloc(ptr, nsize) orelse return null;
            self.mem_used = self.mem_used - old + nsize;
            return p;
        }

        fn hook(L: ?*c.lua_State, _: ?*c.lua_Debug) callconv(.c) void {
            var self: *Self = undefined;
            _ = c.lua_getallocf(L, @ptrCast(&self));
            if (self.budget > hook_step) {
                self.budget -= hook_step;
            } else _ = c.luaL_error(L, "instruction budget exceeded (runaway loop?)");
        }

        fn traceback(L: ?*c.lua_State) callconv(.c) c_int {
            const msg = str(L, 1, "(non-string error)");
            c.luaL_traceback(L, L, msg.ptr, 1);
            return 1;
        }

        fn get(L: ?*c.lua_State) *Self {
            return @ptrCast(@alignCast(c.lua_touserdata(L, upvalue(1))));
        }

        fn int(L: ?*c.lua_State, i: c_int) i32 {
            const v = c.luaL_checkinteger(L, i);
            if (v < std.math.minInt(i32) or v > std.math.maxInt(i32)) _ = c.luaL_argerror(L, i, "out of range");
            return @intCast(v);
        }

        fn checkId(L: ?*c.lua_State, i: c_int) u32 {
            const v = c.luaL_checkinteger(L, i);
            return if (v > 0 and v <= std.math.maxInt(u32)) @intCast(v) else 0;
        }

        fn stale(L: ?*c.lua_State) c_int {
            c.lua_pushnil(L);
            _ = c.lua_pushstring(L, "stale");
            return 2;
        }

        fn setInt(L: ?*c.lua_State, name: [*:0]const u8, v: i64) void {
            c.lua_pushinteger(L, v);
            c.lua_setfield(L, -2, name);
        }

        fn pushBox(L: ?*c.lua_State, b: Box) void {
            c.lua_createtable(L, 0, 4);
            setInt(L, "x", b.x);
            setInt(L, "y", b.y);
            setInt(L, "w", b.w);
            setInt(L, "h", b.h);
        }

        fn pushIds(L: ?*c.lua_State, ids: []const u32) c_int {
            c.lua_createtable(L, @intCast(ids.len), 0);
            for (ids, 1..) |v, i| {
                c.lua_pushinteger(L, v);
                c.lua_rawseti(L, -2, @intCast(i));
            }
            return 1;
        }

        const globals = .{
            .{ "load", lLoad },                 .{ "views", lViews },
            .{ "view", lView },                 .{ "focused", lFocused },
            .{ "outputs", lOutputs },           .{ "view_move", viewCmd(.move) },
            .{ "view_place", viewCmd(.place) }, .{ "view_opacity", viewCmd(.opacity) },
            .{ "view_raise", viewCmd(.raise) }, .{ "view_focus", viewCmd(.focus) },
            .{ "view_close", viewCmd(.close) }, .{ "view_show", viewCmd(.show) },
            .{ "spawn", lSpawn },               .{ "quit", lQuit },
            .{ "reload", lReload },             .{ "log", lLog },
        };

        const ctx_fns = .{
            .{ "on", ctxOn },         .{ "bind", ctxBind },
            .{ "timer", ctxTimer },   .{ "cancel", ctxCancel },
            .{ "manage", ctxManage },
        };

        /// raywm.load(name): loads plugins/<name>.lua next to the config.
        /// Contract: the chunk returns { api = 1, setup = fn(ctx), teardown = fn? }.
        fn lLoad(L: ?*c.lua_State) callconv(.c) c_int {
            const self = get(L);
            const name = std.mem.span(c.luaL_checklstring(L, 1, null));
            if (!self.in_config) return c.luaL_error(L, "raywm.load is only allowed while init.lua runs");
            if (name.len == 0 or name.len > 64) return c.luaL_argerror(L, 1, "bad plugin name");
            for (name) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-')
                return c.luaL_argerror(L, 1, "plugin names use [A-Za-z0-9_-]");
            for (self.plugins.items) |p| if (std.mem.eql(u8, p.name, name))
                return c.luaL_error(L, "plugin '%s' already loaded", name.ptr);

            const dir = std.fs.path.dirname(self.config_path) orelse ".";
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const path = std.fmt.bufPrintZ(&buf, "{s}/plugins/{s}.lua", .{ dir, name }) catch
                return c.luaL_error(L, "plugin path too long");
            if (c.luaL_loadfilex(L, path.ptr, null) != c.LUA_OK) return fail(L, name);
            if (c.lua_pcallk(L, 0, 1, 0, 0, null) != c.LUA_OK) return fail(L, name);
            if (c.lua_type(L, -1) != c.LUA_TTABLE) return failMsg(L, name, "must return a table");
            _ = c.lua_getfield(L, -1, "api");
            if (c.lua_tointegerx(L, -1, null) != api_version) return failMsg(L, name, "requires api = 1");
            if (c.lua_getfield(L, -2, "setup") != c.LUA_TFUNCTION) return failMsg(L, name, "has no setup function");
            const td = c.lua_getfield(L, -3, "teardown");
            if (td != c.LUA_TFUNCTION and td != c.LUA_TNIL) return failMsg(L, name, "teardown must be a function");

            self.plugins.ensureUnusedCapacity(gpa, 1) catch return c.luaL_error(L, "out of memory");
            const index: u32 = @intCast(self.plugins.items.len);
            // luaL_ref may raise; take it before allocating the name.
            const teardown = if (td == c.LUA_TFUNCTION) c.luaL_ref(L, c.LUA_REGISTRYINDEX) else blk: {
                c.lua_settop(L, -2);
                break :blk no_ref;
            };
            const owned = gpa.dupeZ(u8, name) catch {
                c.luaL_unref(L, c.LUA_REGISTRYINDEX, teardown);
                return c.luaL_error(L, "out of memory");
            };
            self.plugins.appendAssumeCapacity(.{ .name = owned, .teardown = teardown });

            // Stack: ..., module, api, setup. Build ctx and call setup(ctx).
            c.lua_createtable(L, 0, ctx_fns.len);
            inline for (ctx_fns) |f| {
                c.lua_pushlightuserdata(L, self);
                c.lua_pushinteger(L, index);
                c.lua_pushcclosure(L, f[1], 2);
                c.lua_setfield(L, -2, f[0]);
            }
            if (!self.pcall(index, 1, 0)) {
                c.lua_pushnil(L);
                _ = c.lua_pushfstring(L, "plugin '%s' failed in setup", name.ptr);
                return 2;
            }
            log.info("loaded plugin {s}", .{name});
            c.lua_pushboolean(L, 1);
            return 1;
        }

        fn fail(L: ?*c.lua_State, name: []const u8) c_int {
            get(L).limits.report(name, str(L, -1, "load error"));
            c.lua_pushnil(L);
            c.lua_rotate(L, -2, 1);
            return 2;
        }

        fn failMsg(L: ?*c.lua_State, name: []const u8, msg: [*:0]const u8) c_int {
            _ = c.lua_pushfstring(L, "plugin '%s' %s", name.ptr, msg);
            return fail(L, name);
        }

        fn lViews(L: ?*c.lua_State) callconv(.c) c_int {
            var buf: [256]u32 = undefined;
            return pushIds(L, buf[0..Api.views(get(L).host, &buf)]);
        }

        fn lOutputs(L: ?*c.lua_State) callconv(.c) c_int {
            const self = get(L);
            var buf: [16]u32 = undefined;
            const ids = buf[0..Api.outputs(self.host, &buf)];
            c.lua_createtable(L, @intCast(ids.len), 0);
            var n: c.lua_Integer = 0;
            for (ids) |oid| {
                const info = Api.output(self.host, oid) orelse continue;
                pushBox(L, info.box);
                setInt(L, "id", oid);
                pushBox(L, info.usable);
                c.lua_setfield(L, -2, "usable");
                n += 1;
                c.lua_rawseti(L, -2, n);
            }
            return 1;
        }

        fn lView(L: ?*c.lua_State) callconv(.c) c_int {
            const vid = checkId(L, 1);
            const info = Api.view(get(L).host, vid) orelse return stale(L);
            pushBox(L, info.box);
            setInt(L, "id", vid);
            setInt(L, "output", info.output);
            _ = c.lua_pushstring(L, info.title orelse "");
            c.lua_setfield(L, -2, "title");
            _ = c.lua_pushstring(L, info.app_id orelse "");
            c.lua_setfield(L, -2, "app_id");
            c.lua_pushboolean(L, @intFromBool(info.focused));
            c.lua_setfield(L, -2, "focused");
            return 1;
        }

        fn lFocused(L: ?*c.lua_State) callconv(.c) c_int {
            var buf: [256]u32 = undefined;
            const self = get(L);
            for (buf[0..Api.views(self.host, &buf)]) |vid| {
                if ((Api.view(self.host, vid) orelse continue).focused) {
                    c.lua_pushinteger(L, vid);
                    return 1;
                }
            }
            c.lua_pushnil(L);
            return 1;
        }

        fn viewCmd(comptime tag: std.meta.Tag(ViewCmd)) c.lua_CFunction {
            return struct {
                fn f(L: ?*c.lua_State) callconv(.c) c_int {
                    const vid = checkId(L, 1);
                    const cmd: ViewCmd = switch (tag) {
                        .move => .{ .move = .{ int(L, 2), int(L, 3) } },
                        .place => .{ .place = .{ .x = int(L, 2), .y = int(L, 3), .w = int(L, 4), .h = int(L, 5) } },
                        .opacity => .{ .opacity = @floatCast(c.luaL_checknumber(L, 2)) },
                        .show => .{ .show = c.lua_toboolean(L, 2) != 0 },
                        inline else => |t| t,
                    };
                    if (!Api.viewCmd(get(L).host, vid, cmd)) return stale(L);
                    c.lua_pushboolean(L, 1);
                    return 1;
                }
            }.f;
        }

        fn lSpawn(L: ?*c.lua_State) callconv(.c) c_int {
            Api.spawn(get(L).host, c.luaL_checklstring(L, 1, null));
            return 0;
        }

        fn lQuit(L: ?*c.lua_State) callconv(.c) c_int {
            Api.quit(get(L).host);
            return 0;
        }

        fn lReload(L: ?*c.lua_State) callconv(.c) c_int {
            const self = get(L);
            // Reloading from init.lua or a teardown would loop forever.
            if (self.in_config or self.sweeping) {
                log.warn("raywm.reload() ignored during init.lua/teardown", .{});
                return 0;
            }
            self.reload_requested = true; // performed once Lua has returned
            return 0;
        }

        fn lLog(L: ?*c.lua_State) callconv(.c) c_int {
            log.info("{s}", .{std.mem.span(c.luaL_tolstring(L, 1, null))});
            return 0;
        }

        // ---- ctx: registrations owned by one plugin -------------------------

        fn owner(L: ?*c.lua_State) u32 {
            return @intCast(c.lua_tointegerx(L, upvalue(2), null));
        }

        /// Stores the function at stack index `fn_index` as a registration.
        /// `fn_index` 0 registers a resource without a callback.
        fn register(L: ?*c.lua_State, fn_index: c_int, kind: Kind) c_int {
            const self = get(L);
            const plugin = owner(L);
            if (self.plugins.items[plugin].dead) return c.luaL_error(L, "plugin is unloaded");
            if (fn_index != 0) c.luaL_checktype(L, fn_index, c.LUA_TFUNCTION);
            self.regs.ensureUnusedCapacity(gpa, 1) catch return c.luaL_error(L, "out of memory");
            const ref = if (fn_index == 0) no_ref else blk: {
                c.lua_pushvalue(L, fn_index);
                break :blk c.luaL_ref(L, c.LUA_REGISTRYINDEX);
            };
            const rid = self.next_id;
            self.next_id = if (self.next_id == std.math.maxInt(u32)) 1 else self.next_id + 1;
            self.regs.appendAssumeCapacity(.{ .id = rid, .plugin = plugin, .ref = ref, .kind = kind });
            c.lua_pushinteger(L, rid);
            return 1;
        }

        fn ctxOn(L: ?*c.lua_State) callconv(.c) c_int {
            const name = std.mem.span(c.luaL_checklstring(L, 1, null));
            const ev = std.meta.stringToEnum(Event, name) orelse return c.luaL_argerror(L, 1, "unknown event");
            return register(L, 2, .{ .event = ev });
        }

        fn ctxBind(L: ?*c.lua_State) callconv(.c) c_int {
            const spec = c.luaL_checklstring(L, 1, null);
            const k = Api.parseKey(get(L).host, spec) orelse return c.luaL_argerror(L, 1, "bad key, e.g. \"Super+Shift+Return\"");
            return register(L, 2, .{ .bind = k });
        }

        fn ctxTimer(L: ?*c.lua_State) callconv(.c) c_int {
            const ms = c.luaL_checkinteger(L, 1);
            if (ms < 0 or ms > 1 << 31) return c.luaL_argerror(L, 1, "ms out of range");
            const self = get(L);
            const rc = register(L, 2, .{ .timer = self.clock() + @as(u64, @intCast(ms)) * std.time.ns_per_ms });
            self.armTimer();
            return rc;
        }

        /// ctx.manage(view, on = true): while on, this plugin lays out the view
        /// and the core refuses free interactive move/resize for it. Released
        /// with ctx.manage(view, false), on unmap, unload and reload.
        fn ctxManage(L: ?*c.lua_State) callconv(.c) c_int {
            const self = get(L);
            const vid = checkId(L, 1);
            const on = c.lua_type(L, 2) <= c.LUA_TNIL or c.lua_toboolean(L, 2) != 0;
            if (Api.view(self.host, vid) == null) return stale(L);
            for (self.regs.items) |*r| if (r.kind == .manage and r.kind.manage == vid and r.plugin == owner(L) and !r.dead) {
                if (!on) {
                    r.dead = true;
                    self.sweep_needed = true;
                }
                c.lua_pushboolean(L, 1);
                return 1;
            };
            if (on) {
                _ = register(L, 0, .{ .manage = vid });
                c.lua_settop(L, -2);
            }
            c.lua_pushboolean(L, 1);
            return 1;
        }

        /// ctx.cancel(id): drops a timer, event handler or binding.
        fn ctxCancel(L: ?*c.lua_State) callconv(.c) c_int {
            const self = get(L);
            const rid = checkId(L, 1);
            for (self.regs.items) |*r| if (r.id == rid and r.plugin == owner(L) and !r.dead) {
                r.dead = true;
                self.sweep_needed = true;
                c.lua_pushboolean(L, 1);
                return 1;
            };
            return stale(L);
        }
    };
}
