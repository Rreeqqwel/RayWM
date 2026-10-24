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
/// RayWM release this host belongs to (raywm.version).
pub const version = "0.2.0";
pub const Event = enum {
    view_map,
    view_unmap,
    view_focus,
    view_title,
    view_resized,
    output_add,
    output_remove,
    layout,
    // v0.2.0
    /// A window was mapped; fired before view_map, for window rules.
    view_new,
    /// floating, fullscreen, maximized or urgent changed (after view_map).
    view_state,
    view_app_id,
    /// The client asks for fullscreen: (id, on, output id or 0).
    view_request_fullscreen,
    /// The client asks to be maximized: (id, on).
    view_request_maximize,
    /// A workspace was created (id) or removed (id; already stale).
    workspace_add,
    workspace_remove,
    /// A workspace is shown on its output: (id, previously shown id or 0).
    workspace_activate,
    /// Renamed, moved to another output, or its urgency changed.
    workspace_change,
    /// A window moved to another workspace: (view, workspace or 0, old or 0).
    view_workspace,
    /// The session was locked / unlocked (ext-session-lock-v1); id 0.
    session_lock,
    session_unlock,
    /// An input device was plugged in / removed (id of the device).
    input_add,
    input_remove,
    /// The active keyboard layout changed: (0, index from 1).
    keyboard_layout,
    /// The client asks to be minimized: (id). Granted unless a handler
    /// changes the window's state.
    view_request_minimize,
    /// The client asks for focus (xdg-activation): (id, user). `user` means
    /// a token exchanged from a recent forwarded key/button press and a
    /// supplied source surface still focused when the token was committed.
    /// Default: focus it when it can be seen, else mark it urgent.
    view_request_activate,
    /// Before unmap state is cleared, for native buffer snapshots.
    view_will_unmap,
    /// Before switching visibility: (new workspace, old workspace or 0).
    workspace_will_activate,
};
/// Extra handler arguments after the id (most events have none).
pub const Arg = union(enum) { int: i64, boolean: bool, nil };
pub const Box = struct { x: i32, y: i32, w: i32, h: i32 };
pub const ViewInfo = struct {
    box: Box,
    title: ?[*:0]const u8,
    app_id: ?[*:0]const u8,
    focused: bool,
    output: u32,
    visible: bool = true,
    // v0.2.0. Sizes are 0 when the client sets no limit.
    parent: u32 = 0,
    min_w: i32 = 0,
    min_h: i32 = 0,
    max_w: i32 = 0,
    max_h: i32 = 0,
    floating: bool = false,
    fullscreen: bool = false,
    fullscreen_output: u32 = 0,
    maximized: bool = false,
    workspace: u32 = 0,
    urgent: bool = false,
    minimized: bool = false,
    /// "server" or "client" (xdg-decoration); null: the client did not
    /// ask (it draws its own, or none).
    decoration: ?[*:0]const u8 = null,
    /// A live plugin manages its geometry (ctx.manage).
    managed: bool = false,
    xwayland: bool = false,
    /// Process id of the client, 0 if unknown.
    pid: i32 = 0,
};
pub const OutputInfo = struct {
    box: Box,
    usable: Box,
    name: ?[*:0]const u8 = null,
    /// The workspace shown there, 0 if none.
    workspace: u32 = 0,
    // v0.2.0 (output configuration)
    description: ?[*:0]const u8 = null,
    make: ?[*:0]const u8 = null,
    model: ?[*:0]const u8 = null,
    serial: ?[*:0]const u8 = null,
    /// In the layout (usable). False only in raywm.outputs({ all = true }).
    enabled: bool = true,
    /// Not powered off (DPMS).
    power: bool = true,
    scale: f64 = 1,
    transform: [*:0]const u8 = "normal",
    /// Current mode: pixels and refresh in mHz.
    mode: [3]i32 = .{ 0, 0, 0 },
    physical: [2]i32 = .{ 0, 0 },
    adaptive_sync: bool = false,
    /// raywm.output_configure { allow_tearing } (RayWM 0.2.1).
    allow_tearing: bool = false,
};
pub const ModeInfo = struct { w: i32, h: i32, refresh: i32, preferred: bool, current: bool };
/// raywm.output_configure options; null: unchanged.
pub const OutputConfig = struct {
    enabled: ?bool = null,
    /// refresh in mHz, 0: the highest of that size.
    mode: ?[3]i32 = null,
    scale: ?f64 = null,
    transform: ?[]const u8 = null,
    /// null: unchanged; auto: next to the other outputs.
    position: ?union(enum) { auto, at: [2]i32 } = null,
    adaptive_sync: ?bool = null,
    /// Tearing page flips for fullscreen windows that ask for them.
    allow_tearing: ?bool = null,
};
pub const OutputTarget = union(enum) { id: u32, name: []const u8 };
/// raywm.input_configure settings (see src/inputconfig.zig); strings are
/// borrowed for the duration of the call.
pub const InputSettings = struct {
    xkb_rules: ?[]const u8 = null,
    xkb_model: ?[]const u8 = null,
    xkb_layout: ?[]const u8 = null,
    xkb_variant: ?[]const u8 = null,
    xkb_options: ?[]const u8 = null,
    repeat_rate: ?i32 = null,
    repeat_delay: ?i32 = null,
    accel_profile: ?[]const u8 = null,
    accel_speed: ?f64 = null,
    natural_scroll: ?bool = null,
    left_handed: ?bool = null,
    tap: ?bool = null,
    tap_drag: ?bool = null,
    drag_lock: ?bool = null,
    dwt: ?bool = null,
    middle_emulation: ?bool = null,
    scroll_method: ?[]const u8 = null,
    scroll_button: ?i32 = null,
    click_method: ?[]const u8 = null,
    send_events: ?[]const u8 = null,
};
pub const InputResult = enum { ok, bad_match, bad_value, bad_keymap, failed };
pub const DeviceInfo = struct { id: u32, name: [*:0]const u8, kind: [*:0]const u8, virtual: bool, libinput: bool };
pub const LayoutInfo = struct { active: u32, names: []const [*:0]const u8 };
pub const WorkspaceInfo = struct {
    name: [*:0]const u8,
    /// Name of the output it was created on.
    home: [*:0]const u8,
    output: u32,
    active: bool,
    urgent: bool,
    orphan: bool,
};
pub const WorkspaceCmd = union(enum) { activate, rename: []const u8, set_output: u32, remove };
pub const WorkspaceResult = enum { ok, stale, no_output, bad_name };
pub const AdoptResult = enum { ok, stale, owned };
pub const OutputResult = enum { ok, stale, no_output_left, bad_mode, bad_scale, bad_transform, rejected, failed };
pub const CreateResult = union(enum) { ok: u32, stale, bad_name, failed };
/// Border drawn outside a window: width in pixels (0 removes it) and a
/// premultiplied RGBA color.
pub const Border = struct { width: i32, color: [4]f32 };
pub const max_border = 64;
pub const ViewCmd = union(enum) {
    move: [2]i32,
    place: Box,
    opacity: f32,
    raise,
    focus,
    close,
    show: bool,
    border: Border,
    floating: bool,
    /// `output` 0: the output the window is on.
    fullscreen: struct { on: bool, output: u32 },
    maximize: bool,
    /// 0: no workspace (always shown on its output).
    workspace: u32,
    minimize: bool,
    urgent: bool,
    decoration: Decoration,
};
/// raywm.view_decoration: who draws title bars and borders. RayWM draws
/// none itself, so "server" means the window has no title bar.
pub const Decoration = enum { auto, server, client };
/// `busy`: a pointer grab is active (compositor move/resize, a held button
/// or a client's popup grab); warping is refused then.
pub const PointerInfo = struct { x: i32, y: i32, busy: bool };
pub const WarpResult = enum { ok, busy, exclusive, outside, locked };
pub const Key = struct { mods: u32, sym: u32 };
pub const Easing = enum { linear, in_quad, out_quad, in_out_cubic };
pub const AnimationOptions = struct {
    x: f64 = 0,
    y: f64 = 0,
    opacity: f64 = 1,
    from_x: ?f64 = null,
    from_y: ?f64 = null,
    from_opacity: ?f64 = null,
    duration: u32 = 180,
    easing: Easing = .out_quad,
    snapshot: bool = false,
};
pub const RectOptions = struct {
    view: u32 = 0,
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 1,
    h: i32 = 1,
    color: [4]f32 = .{ 1, 1, 1, 1 },
    background: bool = false,
    visible: bool = true,
};
pub const ResourceResult = union(enum) { ok: u32, stale, hidden, failed, limit };
pub const Limits = struct {
    memory: usize = 64 << 20,
    instructions: u64 = 200_000_000,
    /// Receives plugin/config errors ("init.lua" for the config itself).
    report: *const fn (source: []const u8, msg: []const u8) void = logError,
    /// Receives non-fatal warnings (missing config, ignored reload, ...).
    warn: *const fn (msg: []const u8) void = logWarn,
    /// Most registrations (handlers, bindings, timers, managed views) alive
    /// at once, for all plugins together.
    max_registrations: usize = 1 << 16,
};

fn logError(source: []const u8, msg: []const u8) void {
    log.err("[{s}] {s}", .{ source, msg });
}

fn logWarn(msg: []const u8) void {
    log.warn("{s}", .{msg});
}

const max_depth = 8; // nested host->Lua->host->Lua re-entry
const hook_step = 10_000;
const no_ref = c.LUA_NOREF;
/// Most ids returned by raywm.views() / raywm.outputs().
pub const max_list = 4096;
/// Duplicate key bindings are only looked for up to this many registrations.
const dup_check_limit = 4096;

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

/// "#rrggbb" or "#rrggbbaa" to premultiplied RGBA (what wlr_scene wants).
pub fn parseColor(spec: []const u8) ?[4]f32 {
    if (spec.len != 7 and spec.len != 9) return null;
    if (spec[0] != '#') return null;
    var v: [4]f32 = .{ 0, 0, 0, 1 };
    var i: usize = 0;
    while (i * 2 + 1 < spec.len) : (i += 1) {
        const byte = std.fmt.parseInt(u8, spec[1 + i * 2 ..][0..2], 16) catch return null;
        v[i] = @as(f32, @floatFromInt(byte)) / 255.0;
    }
    return .{ v[0] * v[3], v[1] * v[3], v[2] * v[3], v[3] };
}

/// `H.Api` must provide the host functions called below (see host.zig).
pub fn Runtime(comptime H: type) type {
    return struct {
        const Self = @This();
        const Api = H.Api;

        /// `warned_dup`: a duplicate binding of this plugin was reported.
        const Plugin = struct { name: [:0]u8, teardown: c_int, dead: bool = false, torn_down: bool = false, warned_dup: bool = false };
        /// `manage`: the plugin lays out this view (no free move/resize).
        /// `workspace`: the plugin owns this workspace (see workspace.zig).
        const Kind = union(enum) { event: Event, bind: Key, timer: u64, manage: u32, workspace: u32, animation: u32, visual: u32 };
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
        /// Instruction budget used up; the hook fires on every instruction.
        exhausted: bool = false,
        /// False when no Lua state exists (only after a failed reload).
        alive: bool = false,
        /// The first configuration load of this compositor is running (or
        /// has not finished): raywm.startup() functions run after it.
        first_load: bool = true,
        /// raywm.startup() functions queued during the first load.
        startup_fns: std.ArrayList(c_int) = .empty,
        /// Commands raywm.spawn_once() started; kept across reloads.
        spawned_once: std.StringHashMapUnmanaged(void) = .empty,
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
            self.startup_fns.deinit(gpa);
            var keys = self.spawned_once.keyIterator();
            while (keys.next()) |k| gpa.free(k.*);
            self.spawned_once.deinit(gpa);
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
            // Settings that belong to the configuration start afresh.
            if (@hasDecl(Api, "configBegin")) Api.configBegin(self.host);
            const rc = c.luaL_loadfilex(L, self.config_path.ptr, null);
            if (rc != c.LUA_OK) {
                const msg = str(L, -1, "?");
                // A missing config is normal on first start: fallback bindings apply.
                if (rc == c.LUA_ERRFILE) self.limits.warn(msg) else self.limits.report("init.lua", msg);
                c.lua_settop(L, 0);
            } else self.config_ok = self.pcall(null, 0, 0);
            self.in_config = false;
            self.leave();
            if (@hasDecl(Api, "configEnd")) Api.configEnd(self.host);
            // Workspaces whose plugin did not come back are released.
            self.settleWorkspaces();
            if (self.first_load) self.runStartup();
            // The most common reason for "my keys do nothing".
            if (!self.hasBindings()) self.limits.warn("no plugin registered key bindings: only the built-in Super+Return, Super+Shift+E and Super+Shift+R work");
        }

        /// raywm.startup() functions, in the order they were given, once.
        fn runStartup(self: *Self) void {
            self.first_load = false;
            const fns = self.startup_fns;
            self.startup_fns = .empty;
            defer {
                var list = fns;
                list.deinit(gpa);
            }
            for (fns.items) |ref| {
                if (!self.alive) break;
                if (!self.enter()) break;
                _ = c.lua_rawgeti(self.L, c.LUA_REGISTRYINDEX, ref);
                c.luaL_unref(self.L, c.LUA_REGISTRYINDEX, ref);
                _ = self.pcallAs("startup", 0, 0);
                self.leave();
            }
        }

        fn settleWorkspaces(self: *Self) void {
            if (@hasDecl(Api, "workspacesSettled")) Api.workspacesSettled(self.host);
        }

        fn initState(L: ?*c.lua_State) callconv(.c) c_int {
            const self: *Self = @ptrCast(@alignCast(c.lua_touserdata(L, 1)));
            c.luaL_openlibs(L);
            // `debug` can rewrite C-closure upvalues and the registry, i.e.
            // reach host internals; plugins do not get it.
            c.lua_pushnil(L);
            c.lua_setglobal(L, "debug");
            _ = c.lua_getglobal(L, "package");
            _ = c.lua_getfield(L, -1, "loaded");
            c.lua_pushnil(L);
            c.lua_setfield(L, -2, "debug");
            c.lua_settop(L, -2);
            // No native modules either: package.loadlib or a C searcher could
            // load luaopen_debug (or anything else) from a shared library.
            c.lua_pushnil(L);
            c.lua_setfield(L, -2, "loadlib");
            _ = c.lua_getfield(L, -1, "searchers");
            c.lua_pushnil(L);
            c.lua_rawseti(L, -2, 4);
            c.lua_pushnil(L);
            c.lua_rawseti(L, -2, 3);
            c.lua_settop(L, -3);
            c.lua_createtable(L, 0, globals.len + 3);
            c.lua_pushinteger(L, api_version);
            c.lua_setfield(L, -2, "api_version");
            _ = c.lua_pushstring(L, version);
            c.lua_setfield(L, -2, "version");
            // Directory of init.lua (plugins/ is in it): for plugins' own files.
            const dir = std.fs.path.dirname(self.config_path) orelse ".";
            _ = c.lua_pushlstring(L, dir.ptr, dir.len);
            c.lua_setfield(L, -2, "config_dir");
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
                self.limits.warn("event dropped: plugin re-entry depth limit reached");
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
                self.start() catch {
                    self.limits.report("raywm", "reload failed: out of memory; Lua is disabled until the next reload");
                    self.settleWorkspaces(); // no plugin can own them now
                };
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
                var released_manage = false;
                for (self.regs.items) |r| {
                    if (self.live(r)) {
                        self.regs.items[j] = r;
                        j += 1;
                    } else {
                        if (r.ref != no_ref) c.luaL_unref(self.L, c.LUA_REGISTRYINDEX, r.ref);
                        if (r.kind == .manage) released_manage = true;
                        if (r.kind == .workspace) if (@hasDecl(Api, "workspaceOrphan")) Api.workspaceOrphan(self.host, r.kind.workspace);
                        if (r.kind == .animation) if (@hasDecl(Api, "animationCancel")) Api.animationCancel(self.host, r.kind.animation);
                        if (r.kind == .visual) if (@hasDecl(Api, "visualRemove")) Api.visualRemove(self.host, r.kind.visual);
                    }
                }
                self.regs.shrinkRetainingCapacity(j);
                // After compaction, so the host sees a consistent list.
                if (released_manage) self.managedChanged(0);
            }
            self.armTimer();
        }

        /// Like pcall, for code that belongs to no plugin: errors are
        /// reported as `source` and unload nothing.
        fn pcallAs(self: *Self, source: []const u8, nargs: c_int, nres: c_int) bool {
            const L = self.L;
            if (self.depth <= 1) {
                self.budget = self.limits.instructions;
                if (self.exhausted) {
                    self.exhausted = false;
                    c.lua_sethook(L, hook, c.LUA_MASKCOUNT, hook_step);
                }
            }
            const base = c.lua_gettop(L) - nargs;
            c.lua_pushcclosure(L, traceback, 0);
            c.lua_rotate(L, base, 1);
            const rc = c.lua_pcallk(L, nargs, nres, base, 0, null);
            c.lua_rotate(L, base, -1);
            c.lua_settop(L, -2);
            if (rc == c.LUA_OK) return true;
            self.limits.report(source, str(L, -1, "error"));
            c.lua_settop(L, -2);
            return false;
        }

        /// Calls the function below `nargs` arguments on the stack. On error
        /// logs a traceback and unloads the plugin (null = the config file).
        fn pcall(self: *Self, plugin: ?u32, nargs: c_int, nres: c_int) bool {
            const L = self.L;
            // Each top-level callback gets the full budget, so a slow handler
            // cannot get a later, innocent one killed.
            if (self.depth <= 1) {
                self.budget = self.limits.instructions;
                if (self.exhausted) {
                    self.exhausted = false;
                    c.lua_sethook(L, hook, c.LUA_MASKCOUNT, hook_step);
                }
            }
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
            self.emitArgs(ev, id, &.{});
        }

        /// Calls every handler of `ev` as fn(id, args...).
        pub fn emitArgs(self: *Self, ev: Event, id: u32, args: []const Arg) void {
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
                for (args) |a| switch (a) {
                    .int => |v| c.lua_pushinteger(self.L, v),
                    .boolean => |v| c.lua_pushboolean(self.L, @intFromBool(v)),
                    .nil => c.lua_pushnil(self.L),
                };
                _ = self.pcall(r.plugin, @intCast(1 + args.len), 0);
            }
        }

        /// Tells the host that view `id` (0: any view) may have gained or
        /// lost its last managing plugin. Never calls back into Lua.
        fn managedChanged(self: *Self, id: u32) void {
            if (@hasDecl(Api, "managedChanged")) Api.managedChanged(self.host, id);
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

        /// Native resource retirement; no Lua callbacks and at most one
        /// registration sweep after a frame or a view's teardown.
        pub fn collectResources(self: *Self) void {
            if (!self.alive or self.sweeping) return;
            for (self.regs.items) |*reg| {
                const gone = switch (reg.kind) {
                    .animation => |id| if (@hasDecl(Api, "animationAlive")) !Api.animationAlive(self.host, id) else false,
                    .visual => |id| if (@hasDecl(Api, "visualAlive")) !Api.visualAlive(self.host, id) else false,
                    else => false,
                };
                if (gone) {
                    reg.dead = true;
                    self.sweep_needed = true;
                }
            }
            if (self.depth == 0 and !self.in_config and self.sweep_needed) self.sweep();
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
            // A coroutine armed while exhausted keeps a step of 1: reset it
            // instead of charging a full step per instruction.
            if (!self.exhausted and c.lua_gethookcount(L) == 1) {
                c.lua_sethook(L, hook, c.LUA_MASKCOUNT, hook_step);
                return;
            }
            // Exhausted: every thread that runs gets a step of 1 too, also
            // coroutines created before the budget ran out.
            if (self.exhausted) {
                if (c.lua_gethookcount(L) != 1) c.lua_sethook(L, hook, c.LUA_MASKCOUNT, 1);
                _ = c.luaL_error(L, "instruction budget exceeded (runaway loop?)");
                return;
            }
            if (self.budget > hook_step) {
                self.budget -= hook_step;
                return;
            }
            // Plugin code may catch this error with pcall and loop on; from
            // now on the hook fires on every instruction until RayWM regains
            // control (pcall() restores the normal step).
            if (!self.exhausted) {
                self.exhausted = true;
                c.lua_sethook(self.L, hook, c.LUA_MASKCOUNT, 1);
                if (L != self.L) c.lua_sethook(L, hook, c.LUA_MASKCOUNT, 1);
            }
            _ = c.luaL_error(L, "instruction budget exceeded (runaway loop?)");
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

        /// Reject NaN/infinity before float-to-int conversion, narrowing,
        /// or wlroots setters: a plugin error must stay inside Lua.
        fn number(L: ?*c.lua_State, i: c_int) f64 {
            const value = c.luaL_checknumber(L, i);
            if (!std.math.isFinite(value)) _ = c.luaL_argerror(L, i, "number must be finite");
            return value;
        }

        /// A string naming a field of enum `E`; raises an argument error
        /// listing the names otherwise.
        fn checkEnum(comptime E: type, L: ?*c.lua_State, i: c_int) E {
            const name = std.mem.span(c.luaL_checklstring(L, i, null));
            return std.meta.stringToEnum(E, name) orelse {
                const names = comptime blk: {
                    var list: []const u8 = "";
                    for (std.meta.fieldNames(E), 0..) |f, k| list = list ++ (if (k == 0) "" else ", ") ++ "\"" ++ f ++ "\"";
                    break :blk list;
                };
                _ = c.luaL_argerror(L, i, "expected one of " ++ names); // does not return
                unreachable;
            };
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
            .{ "load", lLoad },                   .{ "views", lViews },
            .{ "view", lView },                   .{ "focused", lFocused },
            .{ "outputs", lOutputs },             .{ "view_move", viewCmd(.move) },
            .{ "view_place", viewCmd(.place) },   .{ "view_opacity", viewCmd(.opacity) },
            .{ "view_raise", viewCmd(.raise) },   .{ "view_focus", viewCmd(.focus) },
            .{ "view_close", viewCmd(.close) },   .{ "view_show", viewCmd(.show) },
            .{ "view_border", viewCmd(.border) }, .{ "pointer", lPointer },
            .{ "pointer_warp", lPointerWarp },    .{ "spawn", lSpawn },
            .{ "quit", lQuit },                   .{ "reload", lReload },
            .{ "log", lLog },
        } ++ globals_v020;

        /// Added in v0.2.0 (api = 1 still: additions only).
        const globals_v020 = .{
            .{ "view_floating", viewCmd(.floating) },
            .{ "view_fullscreen", viewCmd(.fullscreen) },
            .{ "view_maximize", viewCmd(.maximize) },
            .{ "view_workspace", viewCmd(.workspace) },
            .{ "view_minimize", viewCmd(.minimize) },
            .{ "view_urgent", viewCmd(.urgent) },
            .{ "view_decoration", viewCmd(.decoration) },
            .{ "workspaces", lWorkspaces },
            .{ "workspace", lWorkspace },
            .{ "workspace_activate", wsCmd(.activate) },
            .{ "workspace_rename", wsCmd(.rename) },
            .{ "workspace_set_output", wsCmd(.set_output) },
            .{ "workspace_remove", wsCmd(.remove) },
            .{ "locked", lLocked },
            .{ "startup", lStartup },
            .{ "spawn_once", lSpawnOnce },
            .{ "output_modes", lOutputModes },
            .{ "output_configure", lOutputConfigure },
            .{ "input_configure", lInputConfigure },
            .{ "input_devices", lInputDevices },
            .{ "keyboard_layout", lKeyboardLayout },
            .{ "keyboard_set_layout", lKeyboardSetLayout },
        };

        const ctx_fns = .{
            .{ "on", ctxOn },         .{ "bind", ctxBind },
            .{ "timer", ctxTimer },   .{ "cancel", ctxCancel },
            .{ "manage", ctxManage },
        } ++ ctx_fns_v020;

        const ctx_fns_v020 = .{
            .{ "workspace_create", ctxWorkspaceCreate },
            .{ "workspace_adopt", ctxWorkspaceAdopt },
            .{ "animate", ctxAnimate },
            .{ "rect", ctxRect },
            .{ "rect_update", ctxRectUpdate },
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
            var binds: usize = 0;
            for (self.regs.items) |r| binds += @intFromBool(r.plugin == index and self.live(r) and r.kind == .bind);
            log.info("loaded plugin {s} ({d} key bindings)", .{ name, binds });
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
            var buf: [max_list]u32 = undefined;
            return pushIds(L, buf[0..Api.views(get(L).host, &buf)]);
        }

        fn setStr(L: ?*c.lua_State, name: [*:0]const u8, v: ?[*:0]const u8) void {
            _ = c.lua_pushstring(L, v orelse "");
            c.lua_setfield(L, -2, name);
        }

        /// raywm.outputs([{ all = true }]): outputs in the layout (with
        /// `all`, also disabled ones).
        fn lOutputs(L: ?*c.lua_State) callconv(.c) c_int {
            const self = get(L);
            var all = false;
            if (c.lua_type(L, 1) == c.LUA_TTABLE) {
                _ = c.lua_getfield(L, 1, "all");
                all = c.lua_toboolean(L, -1) != 0;
                c.lua_settop(L, -2);
            }
            var buf: [max_list]u32 = undefined;
            const ids = buf[0..if (all and @hasDecl(Api, "outputsAll")) Api.outputsAll(self.host, &buf) else Api.outputs(self.host, &buf)];
            c.lua_createtable(L, @intCast(ids.len), 0);
            var n: c.lua_Integer = 0;
            for (ids) |oid| {
                const info = Api.output(self.host, oid) orelse continue;
                pushBox(L, info.box);
                setInt(L, "id", oid);
                pushBox(L, info.usable);
                c.lua_setfield(L, -2, "usable");
                setStr(L, "name", info.name);
                setInt(L, "workspace", info.workspace);
                setStr(L, "description", info.description);
                setStr(L, "make", info.make);
                setStr(L, "model", info.model);
                setStr(L, "serial", info.serial);
                setBool(L, "enabled", info.enabled);
                setBool(L, "power", info.power);
                c.lua_pushnumber(L, info.scale);
                c.lua_setfield(L, -2, "scale");
                setStr(L, "transform", info.transform);
                c.lua_createtable(L, 0, 3);
                setInt(L, "w", info.mode[0]);
                setInt(L, "h", info.mode[1]);
                setInt(L, "refresh", info.mode[2]);
                c.lua_setfield(L, -2, "mode");
                c.lua_createtable(L, 0, 2);
                setInt(L, "w", info.physical[0]);
                setInt(L, "h", info.physical[1]);
                c.lua_setfield(L, -2, "physical");
                setBool(L, "adaptive_sync", info.adaptive_sync);
                setBool(L, "allow_tearing", info.allow_tearing);
                n += 1;
                c.lua_rawseti(L, -2, n);
            }
            return 1;
        }

        /// raywm.output_modes(id) -> { {w, h, refresh, preferred, current}, ... }
        fn lOutputModes(L: ?*c.lua_State) callconv(.c) c_int {
            const oid = checkId(L, 1);
            var buf: [256]ModeInfo = undefined;
            const modes = Api.outputModes(get(L).host, oid, &buf) orelse return stale(L);
            c.lua_createtable(L, @intCast(modes.len), 0);
            for (modes, 1..) |m, i| {
                c.lua_createtable(L, 0, 5);
                setInt(L, "w", m.w);
                setInt(L, "h", m.h);
                setInt(L, "refresh", m.refresh);
                setBool(L, "preferred", m.preferred);
                setBool(L, "current", m.current);
                c.lua_rawseti(L, -2, @intCast(i));
            }
            return 1;
        }

        /// raywm.input_configure(match, settings) -> true, or nil + reason.
        /// match: "*", "type:keyboard" (pointer, touchpad, touch, tablet,
        /// switch) or a device name. Unknown setting names are errors.
        fn lInputConfigure(L: ?*c.lua_State) callconv(.c) c_int {
            const self = get(L);
            const match = std.mem.span(c.luaL_checklstring(L, 1, null));
            c.luaL_checktype(L, 2, c.LUA_TTABLE);
            var st: InputSettings = .{};
            c.lua_pushnil(L);
            while (c.lua_next(L, 2) != 0) {
                defer c.lua_settop(L, -2); // keep the key for lua_next
                if (c.lua_type(L, -2) != c.LUA_TSTRING) return c.luaL_error(L, "input settings are named");
                const field = std.mem.span(c.lua_tolstring(L, -2, null));
                var known = false;
                inline for (std.meta.fields(InputSettings)) |f| if (std.mem.eql(u8, field, f.name)) {
                    known = true;
                    const T = @typeInfo(f.type).optional.child;
                    @field(st, f.name) = switch (T) {
                        []const u8 => if (c.lua_type(L, -1) == c.LUA_TSTRING) std.mem.span(c.lua_tolstring(L, -1, null)) else return c.luaL_error(L, "%s must be a string", f.name.ptr),
                        bool => c.lua_toboolean(L, -1) != 0,
                        i32 => if (c.lua_isinteger(L, -1) != 0) @intCast(std.math.clamp(c.lua_tointegerx(L, -1, null), -1, 1 << 20)) else return c.luaL_error(L, "%s must be an integer", f.name.ptr),
                        f64 => if (c.lua_type(L, -1) == c.LUA_TNUMBER) number(L, -1) else return c.luaL_error(L, "%s must be a number", f.name.ptr),
                        else => unreachable,
                    };
                };
                if (!known) return c.luaL_error(L, "unknown input setting '%s'", field.ptr);
            }
            // While init.lua runs, the settings are applied once it is done.
            const r = Api.inputConfigure(self.host, match, st, !self.in_config);
            if (r == .ok) {
                c.lua_pushboolean(L, 1);
                return 1;
            }
            c.lua_pushnil(L);
            _ = c.lua_pushstring(L, @tagName(r));
            return 2;
        }

        /// raywm.input_devices() -> { {id, name, type, virtual, libinput}, ... }
        fn lInputDevices(L: ?*c.lua_State) callconv(.c) c_int {
            var buf: [256]DeviceInfo = undefined;
            const devs = Api.inputDevices(get(L).host, &buf);
            c.lua_createtable(L, @intCast(devs.len), 0);
            for (devs, 1..) |d, i| {
                c.lua_createtable(L, 0, 5);
                setInt(L, "id", d.id);
                setStr(L, "name", d.name);
                setStr(L, "type", d.kind);
                setBool(L, "virtual", d.virtual);
                setBool(L, "libinput", d.libinput);
                c.lua_rawseti(L, -2, @intCast(i));
            }
            return 1;
        }

        /// raywm.keyboard_layout() -> { active = n, names = {...} } (from 1),
        /// or nil when there is no keyboard.
        fn lKeyboardLayout(L: ?*c.lua_State) callconv(.c) c_int {
            var names: [32][*:0]const u8 = undefined;
            const info = Api.keyboardLayout(get(L).host, &names) orelse {
                c.lua_pushnil(L);
                return 1;
            };
            c.lua_createtable(L, 0, 2);
            setInt(L, "active", info.active);
            c.lua_createtable(L, @intCast(info.names.len), 0);
            for (info.names, 1..) |n, i| {
                _ = c.lua_pushstring(L, n);
                c.lua_rawseti(L, -2, @intCast(i));
            }
            c.lua_setfield(L, -2, "names");
            return 1;
        }

        /// raywm.keyboard_set_layout(n): makes layout n (from 1) active on
        /// every keyboard. Returns true, or nil + "no_layout".
        fn lKeyboardSetLayout(L: ?*c.lua_State) callconv(.c) c_int {
            const n = c.luaL_checkinteger(L, 1);
            if (n < 1 or n > 32 or !Api.keyboardSetLayout(get(L).host, @intCast(n - 1))) {
                c.lua_pushnil(L);
                _ = c.lua_pushstring(L, "no_layout");
                return 2;
            }
            c.lua_pushboolean(L, 1);
            return 1;
        }

        /// "2560x1440@143.97", "1920x1080" -> width, height, refresh (mHz).
        fn parseMode(text: []const u8) ?[3]i32 {
            const x = std.mem.indexOfScalar(u8, text, 'x') orelse return null;
            const at = std.mem.indexOfScalarPos(u8, text, x + 1, '@');
            const w = std.fmt.parseUnsigned(u16, text[0..x], 10) catch return null;
            const h = std.fmt.parseUnsigned(u16, text[x + 1 .. at orelse text.len], 10) catch return null;
            var hz: f64 = 0;
            if (at) |a| {
                const t = std.mem.trimEnd(u8, text[a + 1 ..], "Hz");
                hz = std.fmt.parseFloat(f64, t) catch return null;
                if (!(hz >= 1 and hz <= 1000)) return null;
            }
            if (w == 0 or h == 0) return null;
            return .{ w, h, @intFromFloat(@round(hz * 1000)) };
        }

        /// raywm.output_configure(name or id, { enabled, mode, scale,
        /// transform, position, adaptive_sync, allow_tearing }) -> true,
        /// or nil + reason.
        /// Tested before it is applied; refuses to disable the last output.
        fn lOutputConfigure(L: ?*c.lua_State) callconv(.c) c_int {
            const self = get(L);
            const target: OutputTarget = if (c.lua_type(L, 1) == c.LUA_TNUMBER)
                .{ .id = checkId(L, 1) }
            else
                .{ .name = std.mem.span(c.luaL_checklstring(L, 1, null)) };
            c.luaL_checktype(L, 2, c.LUA_TTABLE);
            var cfg: OutputConfig = .{};
            if (c.lua_getfield(L, 2, "enabled") != c.LUA_TNIL) cfg.enabled = c.lua_toboolean(L, -1) != 0;
            c.lua_settop(L, -2);
            switch (c.lua_getfield(L, 2, "mode")) {
                c.LUA_TNIL => {},
                c.LUA_TSTRING => cfg.mode = parseMode(std.mem.span(c.lua_tolstring(L, -1, null))) orelse
                    return c.luaL_error(L, "mode must look like \"1920x1080\" or \"1920x1080@60\""),
                c.LUA_TTABLE => {
                    var v: [3]i32 = .{ 0, 0, 0 };
                    inline for (.{ "w", "h" }, 0..) |k, i| {
                        _ = c.lua_getfield(L, -1, k);
                        v[i] = @intCast(std.math.clamp(c.lua_tointegerx(L, -1, null), 0, 16384));
                        c.lua_settop(L, -2);
                    }
                    const refresh_type = c.lua_getfield(L, -1, "refresh"); // Hz
                    const refresh = if (refresh_type == c.LUA_TNIL) 0 else number(L, -1);
                    v[2] = @intFromFloat(@round(std.math.clamp(refresh, 0, 1000) * 1000));
                    c.lua_settop(L, -2);
                    cfg.mode = v;
                },
                else => return c.luaL_error(L, "mode must be a string or { w, h, refresh }"),
            }
            c.lua_settop(L, -2);
            if (c.lua_getfield(L, 2, "scale") != c.LUA_TNIL) cfg.scale = number(L, -1);
            c.lua_settop(L, -2);
            if (c.lua_getfield(L, 2, "transform") != c.LUA_TNIL) cfg.transform = std.mem.span(c.luaL_checklstring(L, -1, null));
            c.lua_settop(L, -2);
            switch (c.lua_getfield(L, 2, "position")) {
                c.LUA_TNIL => {},
                c.LUA_TSTRING => {
                    if (!std.mem.eql(u8, std.mem.span(c.lua_tolstring(L, -1, null)), "auto")) return c.luaL_error(L, "position must be \"auto\" or { x, y }");
                    cfg.position = .auto;
                },
                c.LUA_TTABLE => {
                    var xy: [2]i32 = undefined;
                    inline for (.{ 1, 2 }, 0..) |k, i| {
                        _ = c.lua_rawgeti(L, -1, k);
                        xy[i] = @intCast(std.math.clamp(c.luaL_checkinteger(L, -1), -(1 << 24), 1 << 24));
                        c.lua_settop(L, -2);
                    }
                    cfg.position = .{ .at = xy };
                },
                else => return c.luaL_error(L, "position must be \"auto\" or { x, y }"),
            }
            c.lua_settop(L, -2);
            if (c.lua_getfield(L, 2, "adaptive_sync") != c.LUA_TNIL) cfg.adaptive_sync = c.lua_toboolean(L, -1) != 0;
            c.lua_settop(L, -2);
            if (c.lua_getfield(L, 2, "allow_tearing") != c.LUA_TNIL) cfg.allow_tearing = c.lua_toboolean(L, -1) != 0;
            c.lua_settop(L, -2);
            const r = Api.outputConfigure(self.host, target, cfg);
            if (r == .ok) {
                c.lua_pushboolean(L, 1);
                return 1;
            }
            c.lua_pushnil(L);
            _ = c.lua_pushstring(L, @tagName(r));
            return 2;
        }

        fn setBool(L: ?*c.lua_State, name: [*:0]const u8, v: bool) void {
            c.lua_pushboolean(L, @intFromBool(v));
            c.lua_setfield(L, -2, name);
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
            setBool(L, "focused", info.focused);
            setBool(L, "visible", info.visible);
            // v0.2.0
            setInt(L, "parent", info.parent);
            setInt(L, "min_w", info.min_w);
            setInt(L, "min_h", info.min_h);
            setInt(L, "max_w", info.max_w);
            setInt(L, "max_h", info.max_h);
            setBool(L, "floating", info.floating);
            setBool(L, "fullscreen", info.fullscreen);
            setInt(L, "fullscreen_output", info.fullscreen_output);
            setBool(L, "maximized", info.maximized);
            setInt(L, "workspace", info.workspace);
            setBool(L, "urgent", info.urgent);
            setBool(L, "minimized", info.minimized);
            if (info.decoration) |d| {
                _ = c.lua_pushstring(L, d);
                c.lua_setfield(L, -2, "decoration");
            }
            setBool(L, "managed", info.managed);
            setBool(L, "xwayland", info.xwayland);
            setInt(L, "pid", info.pid);
            return 1;
        }

        fn pushWorkspace(L: ?*c.lua_State, id: u32, w: WorkspaceInfo) void {
            c.lua_createtable(L, 0, 7);
            setInt(L, "id", id);
            _ = c.lua_pushstring(L, w.name);
            c.lua_setfield(L, -2, "name");
            _ = c.lua_pushstring(L, w.home);
            c.lua_setfield(L, -2, "home");
            setInt(L, "output", w.output);
            setBool(L, "active", w.active);
            setBool(L, "urgent", w.urgent);
            setBool(L, "orphan", w.orphan);
        }

        /// raywm.workspaces() -> { {id, name, home, output, active, urgent, orphan}, ... }
        fn lWorkspaces(L: ?*c.lua_State) callconv(.c) c_int {
            const self = get(L);
            var buf: [max_list]u32 = undefined;
            const ids = buf[0..Api.workspaces(self.host, &buf)];
            c.lua_createtable(L, @intCast(ids.len), 0);
            var n: c.lua_Integer = 0;
            for (ids) |wid| {
                const info = Api.workspace(self.host, wid) orelse continue;
                pushWorkspace(L, wid, info);
                n += 1;
                c.lua_rawseti(L, -2, n);
            }
            return 1;
        }

        fn lWorkspace(L: ?*c.lua_State) callconv(.c) c_int {
            const wid = checkId(L, 1);
            const info = Api.workspace(get(L).host, wid) orelse return stale(L);
            pushWorkspace(L, wid, info);
            return 1;
        }

        fn wsCmd(comptime tag: std.meta.Tag(WorkspaceCmd)) c.lua_CFunction {
            return struct {
                fn f(L: ?*c.lua_State) callconv(.c) c_int {
                    const self = get(L);
                    const wid = checkId(L, 1);
                    const cmd: WorkspaceCmd = switch (tag) {
                        .rename => .{ .rename = std.mem.span(c.luaL_checklstring(L, 2, null)) },
                        .set_output => .{ .set_output = checkId(L, 2) },
                        inline else => |t| t,
                    };
                    const r = Api.workspaceCmd(self.host, wid, cmd);
                    if (r != .ok) {
                        c.lua_pushnil(L);
                        _ = c.lua_pushstring(L, @tagName(r));
                        return 2;
                    }
                    // A removed workspace is no registration of anybody any more.
                    if (tag == .remove) for (self.regs.items) |*reg| if (reg.kind == .workspace and reg.kind.workspace == wid) {
                        reg.dead = true;
                        self.sweep_needed = true;
                    };
                    c.lua_pushboolean(L, 1);
                    return 1;
                }
            }.f;
        }

        /// raywm.pointer() -> { x, y, busy }
        fn lPointer(L: ?*c.lua_State) callconv(.c) c_int {
            const p = Api.pointer(get(L).host);
            c.lua_createtable(L, 0, 3);
            setInt(L, "x", p.x);
            setInt(L, "y", p.y);
            c.lua_pushboolean(L, @intFromBool(p.busy));
            c.lua_setfield(L, -2, "busy");
            return 1;
        }

        /// raywm.pointer_warp(x, y) -> true, or nil + "busy" | "exclusive" | "outside"
        fn lPointerWarp(L: ?*c.lua_State) callconv(.c) c_int {
            const x = int(L, 1);
            const y = int(L, 2);
            const r = Api.pointerWarp(get(L).host, x, y);
            if (r == .ok) {
                c.lua_pushboolean(L, 1);
                return 1;
            }
            c.lua_pushnil(L);
            _ = c.lua_pushstring(L, @tagName(r));
            return 2;
        }

        fn lFocused(L: ?*c.lua_State) callconv(.c) c_int {
            var buf: [max_list]u32 = undefined;
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
                        .opacity => .{ .opacity = @floatCast(std.math.clamp(number(L, 2), 0, 1)) },
                        .show => .{ .show = c.lua_toboolean(L, 2) != 0 },
                        .floating => .{ .floating = c.lua_toboolean(L, 2) != 0 },
                        .fullscreen => .{ .fullscreen = .{
                            .on = c.lua_toboolean(L, 2) != 0,
                            .output = if (c.lua_type(L, 3) <= c.LUA_TNIL) 0 else checkId(L, 3),
                        } },
                        .maximize => .{ .maximize = c.lua_toboolean(L, 2) != 0 },
                        .workspace => .{ .workspace = if (c.lua_type(L, 2) <= c.LUA_TNIL) 0 else checkId(L, 2) },
                        .border => .{ .border = border(L) },
                        .minimize => .{ .minimize = c.lua_toboolean(L, 2) != 0 },
                        .urgent => .{ .urgent = c.lua_toboolean(L, 2) != 0 },
                        .decoration => .{ .decoration = checkEnum(Decoration, L, 2) },
                        inline else => |t| t,
                    };
                    if (!Api.viewCmd(get(L).host, vid, cmd)) return stale(L);
                    c.lua_pushboolean(L, 1);
                    return 1;
                }
            }.f;
        }

        /// view_border(id, width, color): width 0..max_border (0 removes the
        /// border, color may then be omitted), color "#rrggbb" or "#rrggbbaa".
        fn border(L: ?*c.lua_State) Border {
            const w = c.luaL_checkinteger(L, 2);
            if (w < 0 or w > max_border) _ = c.luaL_argerror(L, 2, "width out of range (0..64)");
            if (w == 0 and c.lua_type(L, 3) <= c.LUA_TNIL) return .{ .width = 0, .color = @splat(0) };
            const spec = std.mem.span(c.luaL_checklstring(L, 3, null));
            const color = parseColor(spec) orelse {
                _ = c.luaL_argerror(L, 3, "color must be \"#rrggbb\" or \"#rrggbbaa\""); // does not return
                return .{ .width = 0, .color = @splat(0) };
            };
            return .{ .width = @intCast(w), .color = color };
        }

        fn lSpawn(L: ?*c.lua_State) callconv(.c) c_int {
            Api.spawn(get(L).host, c.luaL_checklstring(L, 1, null));
            return 0;
        }

        fn lLocked(L: ?*c.lua_State) callconv(.c) c_int {
            c.lua_pushboolean(L, @intFromBool(Api.locked(get(L).host)));
            return 1;
        }

        /// raywm.startup(fn) -> true if fn will run: once per compositor
        /// start, after init.lua, in order; not again on reload. Only while
        /// init.lua runs (plugin setup included).
        fn lStartup(L: ?*c.lua_State) callconv(.c) c_int {
            const self = get(L);
            c.luaL_checktype(L, 1, c.LUA_TFUNCTION);
            if (!self.in_config) return c.luaL_error(L, "raywm.startup is only allowed while init.lua runs");
            if (!self.first_load) {
                c.lua_pushboolean(L, 0);
                return 1;
            }
            self.startup_fns.ensureUnusedCapacity(gpa, 1) catch return c.luaL_error(L, "out of memory");
            c.lua_pushvalue(L, 1);
            self.startup_fns.appendAssumeCapacity(c.luaL_ref(L, c.LUA_REGISTRYINDEX));
            c.lua_pushboolean(L, 1);
            return 1;
        }

        /// raywm.spawn_once(cmd) -> true if started: like raywm.spawn, but a
        /// command already started this way by this compositor (before a
        /// reload, say) is not started again.
        fn lSpawnOnce(L: ?*c.lua_State) callconv(.c) c_int {
            const self = get(L);
            const cmd = c.luaL_checklstring(L, 1, null);
            const text = std.mem.span(cmd);
            if (self.spawned_once.contains(text)) {
                c.lua_pushboolean(L, 0);
                return 1;
            }
            const owned = gpa.dupe(u8, text) catch return c.luaL_error(L, "out of memory");
            self.spawned_once.put(gpa, owned, {}) catch {
                gpa.free(owned);
                return c.luaL_error(L, "out of memory");
            };
            Api.spawn(self.host, cmd);
            c.lua_pushboolean(L, 1);
            return 1;
        }

        fn lQuit(L: ?*c.lua_State) callconv(.c) c_int {
            Api.quit(get(L).host);
            return 0;
        }

        fn lReload(L: ?*c.lua_State) callconv(.c) c_int {
            const self = get(L);
            // Reloading from init.lua or a teardown would loop forever.
            if (self.in_config or self.sweeping) {
                self.limits.warn("raywm.reload() ignored during init.lua/teardown");
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
            const v = c.lua_tointegerx(L, upvalue(2), null);
            if (v < 0 or v >= get(L).plugins.items.len) _ = c.luaL_error(L, "invalid plugin context");
            return @intCast(v);
        }

        /// Stores the function at stack index `fn_index` as a registration.
        /// `fn_index` 0 registers a resource without a callback.
        fn register(L: ?*c.lua_State, fn_index: c_int, kind: Kind) c_int {
            const self = get(L);
            const plugin = owner(L);
            if (self.plugins.items[plugin].dead) return c.luaL_error(L, "plugin is unloaded");
            if (fn_index != 0) c.luaL_checktype(L, fn_index, c.LUA_TFUNCTION);
            if (self.regs.items.len >= self.limits.max_registrations) return c.luaL_error(L, "too many registrations");
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
            const self = get(L);
            const spec = c.luaL_checklstring(L, 1, null);
            const k = Api.parseKey(self.host, spec) orelse return c.luaL_argerror(L, 1, "bad key, e.g. \"Super+Shift+Return\"");
            // Allowed (the first registration wins, see key()), but almost
            // always a configuration mistake. Reported once per plugin, and
            // only checked while the list is small: this native scan is not
            // covered by the instruction budget.
            const me = &self.plugins.items[owner(L)];
            if (!me.warned_dup and self.regs.items.len <= dup_check_limit) for (self.regs.items) |r| {
                if (!self.live(r) or r.kind != .bind or !std.meta.eql(r.kind.bind, k)) continue;
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "plugin {s}: key {s} is already bound by plugin {s}, whose binding is used", .{ me.name, std.mem.span(spec), self.plugins.items[r.plugin].name }) catch "a key is bound twice";
                self.limits.warn(msg);
                me.warned_dup = true;
                break;
            };
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
            // Reuse this plugin's entry (also one released earlier in this
            // callback and not yet swept), so toggling does not grow the list.
            for (self.regs.items) |*r| if (r.kind == .manage and r.kind.manage == vid and r.plugin == owner(L)) {
                r.dead = !on;
                if (!on) self.sweep_needed = true;
                self.managedChanged(vid);
                c.lua_pushboolean(L, 1);
                return 1;
            };
            if (on) {
                _ = register(L, 0, .{ .manage = vid });
                c.lua_settop(L, -2);
                self.managedChanged(vid);
            }
            c.lua_pushboolean(L, 1);
            return 1;
        }

        /// Errors that would make a registration fail, checked before the
        /// host creates anything that would then have no owner.
        fn checkRegister(L: ?*c.lua_State) void {
            const self = get(L);
            if (self.plugins.items[owner(L)].dead) _ = c.luaL_error(L, "plugin is unloaded");
            if (self.regs.items.len >= self.limits.max_registrations) _ = c.luaL_error(L, "too many registrations");
            self.regs.ensureUnusedCapacity(gpa, 1) catch {
                _ = c.luaL_error(L, "out of memory");
            };
        }

        fn resourceResult(L: ?*c.lua_State, result: ResourceResult, animation: bool) c_int {
            return switch (result) {
                .ok => |id| register(L, 0, if (animation) .{ .animation = id } else .{ .visual = id }),
                inline else => |_, tag| failWith(L, @tagName(tag)),
            };
        }

        fn ctxAnimate(L: ?*c.lua_State) callconv(.c) c_int {
            const self = get(L);
            const vid = checkId(L, 1);
            c.luaL_checktype(L, 2, c.LUA_TTABLE);
            checkRegister(L);
            var options: AnimationOptions = .{};
            inline for (.{ "x", "y", "opacity", "from_x", "from_y", "from_opacity" }) |field| {
                if (c.lua_getfield(L, 2, field) != c.LUA_TNIL) {
                    const value = number(L, -1);
                    @field(options, field) = if (comptime std.mem.endsWith(u8, field, "opacity")) std.math.clamp(value, 0, 1) else std.math.clamp(value, -65536, 65536);
                }
                c.lua_settop(L, -2);
            }
            if (c.lua_getfield(L, 2, "duration") != c.LUA_TNIL) {
                const ms = c.luaL_checkinteger(L, -1);
                if (ms < 0 or ms > 10000) return c.luaL_error(L, "duration must be 0..10000 milliseconds");
                options.duration = @intCast(ms);
            }
            c.lua_settop(L, -2);
            if (c.lua_getfield(L, 2, "easing") != c.LUA_TNIL) options.easing = checkEnum(Easing, L, -1);
            c.lua_settop(L, -2);
            if (c.lua_getfield(L, 2, "snapshot") != c.LUA_TNIL) options.snapshot = c.lua_toboolean(L, -1) != 0;
            c.lua_settop(L, -2);
            if (@hasDecl(Api, "animationCreate")) {
                const result = Api.animationCreate(self.host, vid, options);
                self.collectResources(); // interrupted jobs no longer own registrations
                return resourceResult(L, result, true);
            }
            return failWith(L, "unsupported");
        }

        fn rectOptions(L: ?*c.lua_State, index: c_int) RectOptions {
            c.luaL_checktype(L, index, c.LUA_TTABLE);
            var options: RectOptions = .{};
            inline for (.{ "x", "y", "w", "h" }) |field| {
                if (c.lua_getfield(L, index, field) != c.LUA_TNIL) @field(options, field) = @intCast(std.math.clamp(c.luaL_checkinteger(L, -1), if (comptime field[0] == 'w' or field[0] == 'h') 1 else -(1 << 24), 1 << 24));
                c.lua_settop(L, -2);
            }
            if (c.lua_getfield(L, index, "view") != c.LUA_TNIL) options.view = checkId(L, -1);
            c.lua_settop(L, -2);
            if (c.lua_getfield(L, index, "color") != c.LUA_TNIL) options.color = parseColor(std.mem.span(c.luaL_checklstring(L, -1, null))) orelse {
                _ = c.luaL_error(L, "invalid rectangle color");
                return options;
            };
            c.lua_settop(L, -2);
            if (c.lua_getfield(L, index, "background") != c.LUA_TNIL) options.background = c.lua_toboolean(L, -1) != 0;
            c.lua_settop(L, -2);
            if (c.lua_getfield(L, index, "visible") != c.LUA_TNIL) options.visible = c.lua_toboolean(L, -1) != 0;
            c.lua_settop(L, -2);
            return options;
        }

        fn ctxRect(L: ?*c.lua_State) callconv(.c) c_int {
            const self = get(L);
            const options = rectOptions(L, 1);
            checkRegister(L);
            if (@hasDecl(Api, "visualCreate")) return resourceResult(L, Api.visualCreate(self.host, options), false);
            return failWith(L, "unsupported");
        }

        fn ctxRectUpdate(L: ?*c.lua_State) callconv(.c) c_int {
            const self = get(L);
            const id = checkId(L, 1);
            const options = rectOptions(L, 2);
            for (self.regs.items) |reg| if (reg.id == id and reg.plugin == owner(L) and reg.kind == .visual and self.live(reg)) {
                if (@hasDecl(Api, "visualUpdate")) {
                    if (Api.visualUpdate(self.host, reg.kind.visual, options)) {
                        c.lua_pushboolean(L, 1);
                        return 1;
                    }
                }
                return stale(L);
            };
            return stale(L);
        }

        /// ctx.workspace_create(output, name) -> id, or nil + "stale" | "bad_name" | "failed".
        /// The workspace belongs to this plugin (see workspace.zig).
        fn ctxWorkspaceCreate(L: ?*c.lua_State) callconv(.c) c_int {
            const self = get(L);
            const oid = checkId(L, 1);
            const name = std.mem.span(c.luaL_checklstring(L, 2, null));
            checkRegister(L);
            const wid = switch (Api.workspaceCreate(self.host, oid, name)) {
                .ok => |w| w,
                .stale => return stale(L),
                .bad_name => return failWith(L, "bad_name"),
                .failed => return failWith(L, "failed"),
            };
            _ = register(L, 0, .{ .workspace = wid });
            c.lua_settop(L, -2);
            c.lua_pushinteger(L, wid);
            return 1;
        }

        /// ctx.workspace_adopt(id) -> true, or nil + "stale" | "owned": takes
        /// over an orphaned workspace (after a reload or a plugin error).
        fn ctxWorkspaceAdopt(L: ?*c.lua_State) callconv(.c) c_int {
            const self = get(L);
            const wid = checkId(L, 1);
            checkRegister(L);
            switch (Api.workspaceAdopt(self.host, wid)) {
                .ok => {},
                .stale => return stale(L),
                .owned => return failWith(L, "owned"),
            }
            _ = register(L, 0, .{ .workspace = wid });
            c.lua_settop(L, -2);
            c.lua_pushboolean(L, 1);
            return 1;
        }

        fn failWith(L: ?*c.lua_State, why: [*:0]const u8) c_int {
            c.lua_pushnil(L);
            _ = c.lua_pushstring(L, why);
            return 2;
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
