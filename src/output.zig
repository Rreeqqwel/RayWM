//! Outputs (monitors): modes, refresh rate, scale, transform, position,
//! enable/disable and hotplug. Configured by Lua (raywm.output_configure,
//! config/plugins/outputs.lua) and by clients through
//! wlr-output-management (wlr-randr, kanshi); both take the same path.
//! Also output power (DPMS, wlr-output-power-management) and gamma
//! control (gammastep, wlsunset), which wlroots' scene applies.
//!
//! An output is usable when it is in the layout (enabled and placed).
//! Plugins get output_add when an output becomes usable and output_remove
//! when it stops being usable: unplugged or disabled. Windows and
//! workspaces of an output that stops being usable move to another one
//! (server.layoutChange). An output that is only powered off (DPMS) stays
//! in the layout.
//!
//! Safety: a configuration is tested before it is committed (atomically
//! for all outputs it changes), and one that would leave no usable output
//! is refused, so a mistake cannot leave the session without a screen.
const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const srv = @import("server.zig");
const Server = srv.Server;
const layer_shell = @import("layer.zig");
const LayerSurface = layer_shell.LayerSurface;
const workspace = @import("workspace.zig");
const Workspace = workspace.Workspace;
const gpa = srv.gpa;
const cabi = @import("cabi.zig");
const log = std.log.scoped(.output);

pub const Output = struct {
    server: *Server,
    wlr_output: *wlr.Output,
    scene_output: *wlr.SceneOutput,
    link: wl.list.Link = undefined,
    id: u32,
    /// Area left for windows, output-local (layer-shell exclusive zones removed).
    usable: wlr.Box = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    /// The workspace shown here (see workspace.zig).
    active_ws: ?*Workspace = null,
    /// While the session is locked (see lock.zig): an opaque background,
    /// the commit count when locking started, and whether a frame
    /// committed since then was presented.
    lock_bg: ?*wlr.SceneRect = null,
    lock_seq: u32 = 0,
    lock_presented: bool = false,
    layers: wl.list.Head(LayerSurface, .link) = undefined,
    /// Plugins were told it is usable (output_add, not yet output_remove).
    announced: bool = false,
    /// Where it was in the layout, kept while it is disabled: reported to
    /// output-management clients and used when it is enabled again.
    last_pos: ?[2]i32 = null,
    /// Without a backend DRM device there is no scanout target for
    /// linux-dmabuf feedback. Keep renderer import/composition available.
    force_composite: bool = false,
    /// Opt-in (raywm.output_configure { allow_tearing = true }): a visible
    /// fullscreen window that asks for async presentation (tearing-control)
    /// may get tearing page flips. Never on by default.
    allow_tearing: bool = false,
    /// Frame diagnostics (raywmctl perf): fixed size, updated once per
    /// output frame, never per client commit.
    stats: Stats = .{},

    frame: wl.Listener(*wlr.Output) = .init(handleFrame),
    present: wl.Listener(*wlr.Output.event.Present) = .init(handlePresent),
    request_state: wl.Listener(*wlr.Output.event.RequestState) = .init(handleRequestState),
    destroy: wl.Listener(*wlr.Output) = .init(handleDestroy),

    /// On error the caller destroys wlr_output, which cleans up the layout
    /// and scene output entries.
    fn create(server: *Server, wlr_output: *wlr.Output) !void {
        const output = try gpa.create(Output);
        errdefer gpa.destroy(output);
        const scene_output = try server.scene.createSceneOutput(wlr_output);
        output.* = .{ .server = server, .wlr_output = wlr_output, .scene_output = scene_output, .id = server.nextId() };
        output.layers.init();
        wlr_output.events.frame.add(&output.frame);
        wlr_output.events.present.add(&output.present);
        wlr_output.events.request_state.add(&output.request_state);
        wlr_output.events.destroy.add(&output.destroy);
        // Listed before joining the layout, so `layout` handlers already see it.
        server.outputs.append(output);
        errdefer {
            output.link.remove();
            inline for (.{ "frame", "present", "request_state", "destroy" }) |name| @field(output, name).link.remove();
        }
        try output.joinLayout(null);
        if (wlr_output.backend.getDrmFd() < 0) {
            wlr_output.lockAttachRender(true);
            output.force_composite = true;
        }
        // Appears blank while the session is locked.
        server.session_lock.prepareOutput(output);
    }

    /// Places the output in the layout: at `pos`, or automatically (to the
    /// right of the others). Fires the layout change (server.layoutChange).
    fn joinLayout(output: *Output, pos: ?[2]i32) !void {
        const server = output.server;
        const was = output.inLayout();
        // wlroots puts automatically placed outputs to the right of the
        // rightmost placed one: pin them first, so placing this output
        // never moves another.
        if (pos != null) pinAuto(server, output);
        const lo = if (pos) |p| try server.output_layout.add(output.wlr_output, p[0], p[1]) else try server.output_layout.addAuto(output.wlr_output);
        if (!was) server.scene_layout.addOutput(lo, output.scene_output);
    }

    /// Whether wlroots places this output (it was added without a position).
    fn autoPlaced(output: *Output) bool {
        const lo = output.server.output_layout.get(output.wlr_output) orelse return false;
        return lo.auto_configured;
    }

    pub fn inLayout(output: *Output) bool {
        return output.server.output_layout.get(output.wlr_output) != null;
    }

    pub fn arrangeLayers(output: *Output) void {
        layer_shell.arrange(output);
    }

    pub fn box(output: *Output) wlr.Box {
        var b: wlr.Box = undefined;
        output.server.output_layout.getBox(output.wlr_output, &b);
        return b;
    }

    pub fn layoutLockBackground(output: *Output) void {
        const r = output.lock_bg orelse return;
        if (!output.inLayout()) return r.node.setEnabled(false);
        const b = output.box();
        r.node.setEnabled(true);
        r.node.setPosition(b.x, b.y);
        r.setSize(b.width, b.height);
    }

    /// The usable area in layout coordinates.
    pub fn usableBox(output: *Output) wlr.Box {
        const b = output.box();
        return .{ .x = b.x + output.usable.x, .y = b.y + output.usable.y, .width = output.usable.width, .height = output.usable.height };
    }

    /// wlroots only emits frame when the output needs a repaint (damage or
    /// an explicit schedule), so an idle desktop does no work here.
    ///
    /// This is wlr_scene_output_commit() split into its two documented
    /// halves, build_state and commit_state, so RayWM can see whether the
    /// scene chose direct scanout, count failures and, when allowed, ask
    /// for a tearing page flip. The scene still decides everything else
    /// (damage, scanout eligibility, explicit-sync fences).
    fn handleFrame(listener: *wl.Listener(*wlr.Output), _: *wlr.Output) void {
        const output: *Output = @fieldParentPtr("frame", listener);
        var now = srv.timestamp();
        const ns = nsOf(now);
        const animating = output.server.animations.frame(ns);
        output.stats.frames += 1;
        if (output.scene_output.needsFrame()) output.render(ns) else output.stats.idle += 1;
        output.scene_output.sendFrameDone(&now);
        if (animating) output.wlr_output.scheduleFrame();
    }

    fn render(output: *Output, began: u64) void {
        const st = &output.stats;
        var state = wlr.Output.State.init();
        defer state.finish();
        if (!output.scene_output.buildState(&state, null)) {
            st.failed += 1;
            st.path = .none;
            return;
        }
        const path = classify(output, &state);
        if (output.wantsTearing()) {
            state.tearing_page_flip = true;
            if (!output.wlr_output.testState(&state)) {
                // The backend cannot flip asynchronously now (driver,
                // kernel, legacy KMS or this buffer): stay synchronized.
                state.tearing_page_flip = false;
                st.tearing_rejected += 1;
            }
        }
        if (!output.wlr_output.commitState(&state)) {
            st.failed += 1;
            st.path = .none;
            if (st.failed == 1 or st.failed % 1000 == 0) log.warn("output {s}: commit failed ({d} so far)", .{ output.wlr_output.name, st.failed });
            return;
        }
        st.commits += 1;
        st.path = path;
        switch (path) {
            .scanout => st.scanout += 1,
            .composited => st.composited += 1,
            .none => {},
        }
        if (state.tearing_page_flip) st.tearing += 1;
        st.frame_work.push(nsOf(srv.timestamp()) -| began);
    }

    /// Direct scanout hands the client's buffer to the output; composition
    /// renders into one of the output's own swapchain buffers.
    fn classify(output: *Output, state: *const wlr.Output.State) Path {
        if (!state.committed.buffer) return .none;
        const buffer = state.buffer orelse return .none;
        const swapchain = output.wlr_output.swapchain orelse return .scanout;
        return if (wlr_swapchain_has_buffer(swapchain, buffer)) .composited else .scanout;
    }

    /// A visible fullscreen window on this output whose surface asked for
    /// async presentation, on an output where the user allowed tearing.
    fn wantsTearing(output: *Output) bool {
        if (!output.allow_tearing) return false;
        const server = output.server;
        const manager = server.protocols.tearing orelse return false;
        if (server.session_lock.locked()) return false;
        const v = server.fullscreenOn(output) orelse return false;
        return manager.hintFromSurface(v.surface()) == .async;
    }

    fn handlePresent(listener: *wl.Listener(*wlr.Output.event.Present), event: *wlr.Output.event.Present) void {
        const output: *Output = @fieldParentPtr("present", listener);
        const st = &output.stats;
        if (!event.presented) {
            st.discarded += 1;
            return;
        }
        st.presented += 1;
        if (event.flags.zero_copy) st.zero_copy += 1;
        const when = nsOf(event.when);
        if (st.last_present != 0 and when > st.last_present) st.present_interval.push(when - st.last_present);
        st.last_present = when;
        output.server.session_lock.presented(output, event.commit_seq);
    }

    /// Nested backends (Wayland, X11 windows) ask for new sizes.
    fn handleRequestState(listener: *wl.Listener(*wlr.Output.event.RequestState), event: *wlr.Output.event.RequestState) void {
        const output: *Output = @fieldParentPtr("request_state", listener);
        _ = output.wlr_output.commitState(event.state);
    }

    fn handleDestroy(listener: *wl.Listener(*wlr.Output), _: *wlr.Output) void {
        const output: *Output = @fieldParentPtr("destroy", listener);
        if (output.force_composite) output.wlr_output.lockAttachRender(false);
        const server = output.server;
        layer_shell.closeAll(output);
        workspace.outputGone(server, output);
        if (output.lock_bg) |r| r.node.destroy();
        inline for (.{ "frame", "present", "request_state", "destroy" }) |name| @field(output, name).link.remove();
        output.link.remove();
        // Normally already told by the layout change that removed it.
        if (output.announced) server.emit(.output_remove, output.id);
        gpa.destroy(output);
        server.updateOutputManager();
    }
};

extern fn wlr_swapchain_has_buffer(swapchain: *wlr.Swapchain, buffer: *wlr.Buffer) bool;

fn nsOf(ts: std.posix.timespec) u64 {
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

pub const Path = enum { none, composited, scanout };

/// The last `len` samples, in microseconds. Fixed storage.
pub const Ring = struct {
    pub const len = 256;
    buf: [len]u32 = undefined,
    count: u16 = 0,
    pos: u16 = 0,

    pub fn push(r: *Ring, ns: u64) void {
        r.buf[r.pos] = @intCast(@min(ns / std.time.ns_per_us, std.math.maxInt(u32)));
        r.pos = (r.pos + 1) % len;
        if (r.count < len) r.count += 1;
    }

    pub const Summary = struct { samples: u16 = 0, p50: u32 = 0, p99: u32 = 0, max: u32 = 0 };

    /// Sorts a copy, so it costs nothing until someone asks.
    pub fn summary(r: *const Ring) Summary {
        if (r.count == 0) return .{};
        var copy: [len]u32 = undefined;
        const s = copy[0..r.count];
        @memcpy(s, r.buf[0..r.count]);
        std.mem.sort(u32, s, {}, std.sort.asc(u32));
        return .{ .samples = r.count, .p50 = s[s.len / 2], .p99 = s[@min(s.len - 1, (s.len * 99) / 100)], .max = s[s.len - 1] };
    }
};

pub const Stats = struct {
    /// Frame events (wlroots emits them only when a repaint may be needed).
    frames: u64 = 0,
    /// Frame events with nothing to draw.
    idle: u64 = 0,
    /// Successful output commits, by presentation path.
    commits: u64 = 0,
    scanout: u64 = 0,
    composited: u64 = 0,
    /// Commits that were tearing (async) page flips, and tearing requests
    /// the backend rejected (fell back to a synchronized flip).
    tearing: u64 = 0,
    tearing_rejected: u64 = 0,
    /// Failed scene state builds or output commits.
    failed: u64 = 0,
    presented: u64 = 0,
    /// Commits the backend reported as not presented.
    discarded: u64 = 0,
    zero_copy: u64 = 0,
    /// Path of the last successful commit.
    path: Path = .none,
    /// Frame handler start to output commit done (build/render + commit).
    frame_work: Ring = .{},
    /// Between consecutive presentation timestamps.
    present_interval: Ring = .{},
    last_present: u64 = 0,
};

/// Turns automatically placed outputs (except `skip`) into placed ones at
/// their current positions.
fn pinAuto(server: *Server, skip: *Output) void {
    var it = server.outputs.iterator(.forward);
    while (it.next()) |o| {
        if (o == skip or !o.autoPlaced()) continue;
        const b = o.box();
        _ = server.output_layout.add(o.wlr_output, b.x, b.y) catch {};
    }
}

/// A new monitor: enabled with its preferred mode (or RAYWM_OUTPUT_MODE),
/// placed to the right of the others. Plugins configure it further on
/// output_add (config/plugins/outputs.lua).
pub fn handleNew(server: *Server, wlr_output: *wlr.Output) void {
    if (!wlr_output.initRender(server.allocator, server.renderer)) return;

    var state = wlr.Output.State.init();
    defer state.finish();
    state.setEnabled(true);
    const preferred = wlr_output.preferredMode();
    if (preferred) |mode| state.setMode(mode);
    if (requestedMode(wlr_output)) |mode| {
        state.setMode(mode);
        if (!wlr_output.testState(&state)) {
            log.warn("output {s}: mode {d}x{d}@{d}mHz rejected, using the preferred mode", .{ wlr_output.name, mode.width, mode.height, mode.refresh });
            if (preferred) |p| state.setMode(p);
        }
    }
    if (!wlr_output.commitState(&state)) {
        log.err("failed to enable output {s}", .{wlr_output.name});
        return;
    }
    hintRefresh(wlr_output);
    Output.create(server, wlr_output) catch {
        log.err("failed to set up output {s}", .{wlr_output.name});
        wlr_output.destroy();
    };
}

/// Monitors often mark a 60 Hz mode as preferred while also listing a
/// faster one at the same size. Mode choice stays with the configuration
/// (outputs.lua, RAYWM_OUTPUT_MODE); this only says that one exists.
fn hintRefresh(w: *wlr.Output) void {
    var best: i32 = 0;
    var it = w.modes.iterator(.forward);
    while (it.next()) |m| if (m.width == w.width and m.height == w.height) {
        best = @max(best, m.refresh);
    };
    if (best > w.refresh + 1000) log.info("output {s}: running {d}x{d} at {d}.{d:0>3} Hz; the monitor also offers {d}.{d:0>3} Hz (set `mode` in outputs.lua)", .{
        w.name,                               w.width,                                   w.height,
        @divTrunc(w.refresh, 1000),           @as(u32, @intCast(@mod(w.refresh, 1000))), @divTrunc(best, 1000),
        @as(u32, @intCast(@mod(best, 1000))),
    });
}

/// After a layout change: output_add / output_remove for outputs that
/// became usable or stopped being usable.
pub fn announce(server: *Server) void {
    var it = server.outputs.iterator(.forward);
    while (it.next()) |o| {
        const usable = o.inLayout();
        if (usable == o.announced) continue;
        o.announced = usable;
        server.emit(if (usable) .output_add else .output_remove, o.id);
    }
}

// ---- configuration ----------------------------------------------------------

pub const ModeReq = union(enum) {
    /// One of the output's modes.
    fixed: *wlr.Output.Mode,
    /// Width, height and refresh (mHz; 0: the best one of that size). A
    /// listed mode is used when one fits, else a custom mode.
    size: struct { width: i32, height: i32, refresh: i32 },
};

/// What to change; null fields stay as they are.
pub const Config = struct {
    enabled: ?bool = null,
    mode: ?ModeReq = null,
    scale: ?f32 = null,
    transform: ?wl.Output.Transform = null,
    /// Null: keep; `auto`: next to the others.
    position: ?union(enum) { auto, at: [2]i32 } = null,
    adaptive_sync: ?bool = null,
    /// RayWM policy, not output state: see Output.allow_tearing.
    allow_tearing: ?bool = null,
};

pub const Change = struct { output: *Output, config: Config };

pub const ConfigError = error{ NoOutputLeft, BadMode, BadScale, Rejected, Failed, OutOfMemory };

/// The output's listed mode for `req`, or null for a custom mode.
fn findMode(wlr_output: *wlr.Output, w: i32, h: i32, refresh: i32) ?*wlr.Output.Mode {
    var best: ?*wlr.Output.Mode = null;
    var best_d: u32 = std.math.maxInt(u32);
    var it = wlr_output.modes.iterator(.forward);
    while (it.next()) |m| {
        if (m.width != w or m.height != h) continue;
        if (refresh == 0) {
            // The highest refresh of that size.
            if (best == null or m.refresh > best.?.refresh) best = m;
            continue;
        }
        const d = modeDistance(.{ .width = w, .height = h, .refresh_mhz = refresh }, m.width, m.height, m.refresh) orelse continue;
        if (d < best_d) {
            best = m;
            best_d = d;
        }
    }
    return best;
}

/// Builds `state` with only what differs from the current state, so that
/// re-applying a configuration (a reload) changes nothing.
fn buildState(o: *Output, cfg: Config, state: *wlr.Output.State) ConfigError!bool {
    const w = o.wlr_output;
    var changed = false;
    const enable = cfg.enabled orelse o.inLayout();
    if (!enable) {
        if (w.enabled) {
            state.setEnabled(false);
            changed = true;
        }
        return changed;
    }
    if (!w.enabled) {
        state.setEnabled(true);
        changed = true;
        // Enabling needs a mode.
        if (cfg.mode == null) if (w.current_mode orelse w.preferredMode()) |m| state.setMode(m);
    }
    if (cfg.mode) |req| switch (req) {
        .fixed => |m| if (w.current_mode != m) {
            state.setMode(m);
            changed = true;
        },
        .size => |s| {
            if (s.width <= 0 or s.height <= 0 or s.width > 16384 or s.height > 16384 or s.refresh < 0) return error.BadMode;
            if (findMode(w, s.width, s.height, s.refresh)) |m| {
                if (w.current_mode != m) {
                    state.setMode(m);
                    changed = true;
                }
            } else if (w.width != s.width or w.height != s.height or (s.refresh != 0 and w.refresh != s.refresh)) {
                state.setCustomMode(s.width, s.height, s.refresh);
                changed = true;
            }
        },
    };
    if (cfg.scale) |sc| {
        if (!(sc >= 0.25 and sc <= 10)) return error.BadScale;
        if (w.scale != sc) {
            state.setScale(sc);
            changed = true;
        }
    }
    if (cfg.transform) |t| if (w.transform != t) {
        state.setTransform(t);
        changed = true;
    };
    if (cfg.adaptive_sync) |on| if ((w.adaptive_sync_status == .enabled) != on) {
        cabi.call(on, wlr.Output.State.setAdaptiveSyncEnabled, .{state});
        changed = true;
    };
    return changed;
}

/// Applies `changes` together: tested first, committed atomically, then
/// placed in (or taken out of) the layout. With `test_only` nothing
/// changes. Refuses a configuration that leaves no output usable.
pub fn configure(server: *Server, changes: []const Change, test_only: bool) ConfigError!void {
    // Outputs usable afterwards.
    var usable: usize = 0;
    var it = server.outputs.iterator(.forward);
    while (it.next()) |o| {
        var enabled = o.inLayout();
        for (changes) |c| if (c.output == o) if (c.config.enabled) |e| {
            enabled = e;
        };
        usable += @intFromBool(enabled);
    }
    if (usable == 0) return error.NoOutputLeft;

    const states = try gpa.alloc(wlr.Backend.OutputState, changes.len);
    defer gpa.free(states);
    var n: usize = 0;
    defer for (states[0..n]) |*s| s.base.finish();
    for (changes) |c| {
        states[n] = .{ .output = c.output.wlr_output, .base = wlr.Output.State.init() };
        n += 1;
        if (!try buildState(c.output, c.config, &states[n - 1].base)) {
            // Nothing to commit for this one.
            states[n - 1].base.finish();
            n -= 1;
        }
    }
    if (n > 0 and !server.backend.@"test"(states[0..n])) return error.Rejected;
    if (test_only) return;
    if (n > 0 and !server.backend.commit(states[0..n])) return error.Failed;

    for (changes) |c| {
        const o = c.output;
        if (c.config.allow_tearing) |on| o.allow_tearing = on;
        const enable = c.config.enabled orelse o.inLayout();
        if (!enable) {
            if (o.inLayout()) {
                const b = o.box();
                o.last_pos = .{ b.x, b.y };
                server.output_layout.remove(o.wlr_output);
            }
            continue;
        }
        if (c.config.position == null and !o.inLayout()) if (o.last_pos) |p| {
            // Enabled again: where it was.
            o.joinLayout(p) catch return error.OutOfMemory;
        };
        if (c.config.position) |p| switch (p) {
            .auto => o.joinLayout(null) catch return error.OutOfMemory,
            .at => |xy| {
                const b = o.box();
                if (!o.inLayout() or o.autoPlaced() or b.x != xy[0] or b.y != xy[1]) o.joinLayout(xy) catch return error.OutOfMemory;
            },
        } else if (!o.inLayout()) o.joinLayout(null) catch return error.OutOfMemory;
        // Cursor images for this scale.
        server.cursor_mgr.load(o.wlr_output.scale) catch {};
        o.wlr_output.scheduleFrame();
    }
    server.updateOutputManager();
}

// ---- wlr-output-management, output power, gamma -------------------------------

pub const Management = struct {
    server: *Server,
    manager: *wlr.OutputManagerV1,
    power: *wlr.OutputPowerManagerV1,
    apply: wl.Listener(*wlr.OutputConfigurationV1) = .init(handleApply),
    test_config: wl.Listener(*wlr.OutputConfigurationV1) = .init(handleTest),
    set_power: wl.Listener(*wlr.OutputPowerManagerV1.event.SetMode) = .init(handleSetPower),

    pub fn init(m: *Management, server: *Server) !void {
        m.* = .{
            .server = server,
            .manager = try wlr.OutputManagerV1.create(server.wl_server),
            .power = try wlr.OutputPowerManagerV1.create(server.wl_server),
        };
        m.manager.events.apply.add(&m.apply);
        m.manager.events.@"test".add(&m.test_config);
        m.power.events.set_mode.add(&m.set_power);
        // gammastep, wlsunset: the scene applies their gamma ramps.
        server.scene.setGammaControlManagerV1(try wlr.GammaControlManagerV1.create(server.wl_server));
    }

    pub fn deinit(m: *Management) void {
        m.apply.link.remove();
        m.test_config.link.remove();
        m.set_power.link.remove();
    }

    /// Tells output-management clients the current state of every output.
    pub fn update(m: *Management) void {
        const server = m.server;
        const config = wlr.OutputConfigurationV1.create() catch return log.err("out of memory", .{});
        var it = server.outputs.iterator(.forward);
        while (it.next()) |o| {
            const head = wlr.OutputConfigurationV1.Head.create(config, o.wlr_output) catch {
                config.destroy();
                return log.err("out of memory", .{});
            };
            // Enabled means usable here: in the layout (a powered-off
            // output still is).
            head.state.enabled = o.inLayout();
            if (o.inLayout()) {
                const b = o.box();
                head.state.x = b.x;
                head.state.y = b.y;
            } else if (o.last_pos) |p| {
                head.state.x = p[0];
                head.state.y = p[1];
            }
        }
        m.manager.setConfiguration(config);
    }

    fn handleApply(listener: *wl.Listener(*wlr.OutputConfigurationV1), config: *wlr.OutputConfigurationV1) void {
        const m: *Management = @fieldParentPtr("apply", listener);
        m.handle(config, false);
    }

    fn handleTest(listener: *wl.Listener(*wlr.OutputConfigurationV1), config: *wlr.OutputConfigurationV1) void {
        const m: *Management = @fieldParentPtr("test_config", listener);
        m.handle(config, true);
    }

    fn handle(m: *Management, config: *wlr.OutputConfigurationV1, test_only: bool) void {
        defer config.destroy();
        const server = m.server;
        var changes: std.ArrayList(Change) = .empty;
        defer changes.deinit(gpa);
        var it = config.heads.iterator(.forward);
        while (it.next()) |head| {
            const o = server.outputByWlr(head.state.output) orelse continue;
            const st = head.state;
            var cfg: Config = .{ .enabled = st.enabled };
            if (st.enabled) {
                cfg.mode = if (st.mode) |md| .{ .fixed = md } else .{ .size = .{ .width = st.custom_mode.width, .height = st.custom_mode.height, .refresh = st.custom_mode.refresh } };
                cfg.scale = st.scale;
                cfg.transform = st.transform;
                cfg.position = .{ .at = .{ st.x, st.y } };
                cfg.adaptive_sync = st.adaptive_sync_enabled;
            }
            changes.append(gpa, .{ .output = o, .config = cfg }) catch return config.sendFailed();
        }
        configure(server, changes.items, test_only) catch |err| {
            log.info("output configuration {s}: {s}", .{ if (test_only) "test failed" else "refused", @errorName(err) });
            config.sendFailed();
            if (!test_only) m.update();
            return;
        };
        config.sendSucceeded();
        if (!test_only) m.update();
    }

    /// DPMS: the output is powered off or on but stays in the layout.
    fn handleSetPower(listener: *wl.Listener(*wlr.OutputPowerManagerV1.event.SetMode), event: *wlr.OutputPowerManagerV1.event.SetMode) void {
        const m: *Management = @fieldParentPtr("set_power", listener);
        const w = event.output;
        if (m.server.outputByWlr(w) == null) return;
        const on = event.mode == .on;
        if (w.enabled == on) return;
        var state = wlr.Output.State.init();
        defer state.finish();
        cabi.call(on, wlr.Output.State.setEnabled, .{&state});
        if (on) if (w.current_mode orelse w.preferredMode()) |md| state.setMode(md);
        if (!w.commitState(&state)) return log.warn("output {s}: could not power it {s}", .{ w.name, if (on) "on" else "off" });
        log.info("output {s} powered {s}", .{ w.name, if (on) "on" else "off" });
        if (on) w.scheduleFrame();
    }
};

// ---- RAYWM_OUTPUT_MODE ---------------------------------------------------------

/// A mode asked for with `RAYWM_OUTPUT_MODE=WIDTHxHEIGHT@HZ`.
pub const ModeSpec = struct { width: i32, height: i32, refresh_mhz: i32 };

/// Parses "1920x1080@240" or "2560x1440@59.95"; null if malformed.
pub fn parseModeSpec(s: []const u8) ?ModeSpec {
    const x = std.mem.indexOfScalar(u8, s, 'x') orelse return null;
    const at = std.mem.indexOfScalarPos(u8, s, x + 1, '@') orelse return null;
    const w = std.fmt.parseUnsigned(u16, s[0..x], 10) catch return null;
    const h = std.fmt.parseUnsigned(u16, s[x + 1 .. at], 10) catch return null;
    const hz = std.fmt.parseFloat(f64, s[at + 1 ..]) catch return null;
    if (w == 0 or h == 0 or !(hz >= 1 and hz <= 1000)) return null;
    return .{ .width = w, .height = h, .refresh_mhz = @intFromFloat(@round(hz * 1000)) };
}

/// How far a mode's refresh is from `spec`, in mHz; null if the size
/// differs or the refresh is more than 1 Hz off (monitors report 240 Hz
/// as e.g. 240001 mHz).
pub fn modeDistance(spec: ModeSpec, width: i32, height: i32, refresh_mhz: i32) ?u32 {
    if (width != spec.width or height != spec.height) return null;
    const d = @abs(refresh_mhz - spec.refresh_mhz);
    return if (d <= 1000) d else null;
}

/// The output's mode nearest to RAYWM_OUTPUT_MODE, or null (variable
/// unset, malformed, or no such mode on this output).
fn requestedMode(wlr_output: *wlr.Output) ?*wlr.Output.Mode {
    const raw = std.c.getenv("RAYWM_OUTPUT_MODE") orelse return null;
    const text = std.mem.span(raw);
    if (text.len == 0) return null;
    const spec = parseModeSpec(text) orelse {
        log.warn("RAYWM_OUTPUT_MODE={s}: expected WIDTHxHEIGHT@HZ, e.g. 1920x1080@240", .{text});
        return null;
    };
    var best: ?*wlr.Output.Mode = null;
    var best_d: u32 = std.math.maxInt(u32);
    var it = wlr_output.modes.iterator(.forward);
    while (it.next()) |mode| {
        const d = modeDistance(spec, mode.width, mode.height, mode.refresh) orelse continue;
        if (d < best_d) {
            best = mode;
            best_d = d;
        }
    }
    if (best == null) log.info("output {s} has no mode {s}, using the preferred mode", .{ wlr_output.name, text });
    return best;
}

/// Transform names, as wlr-randr writes them.
pub const transform_names = [_][]const u8{ "normal", "90", "180", "270", "flipped", "flipped-90", "flipped-180", "flipped-270" };

pub fn parseTransform(name: []const u8) ?wl.Output.Transform {
    for (transform_names, 0..) |n, i| if (std.mem.eql(u8, n, name)) return @enumFromInt(i);
    return null;
}
