//! Compositor state: backend, scene, outputs, seat. Owns every native object;
//! Lua only ever sees integer ids (see host.zig).
const std = @import("std");
const posix = std.posix;
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const lua = @import("lua");
const View = @import("view.zig").View;
const input = @import("input.zig");
const host = @import("host.zig");
const layer_shell = @import("layer.zig");
const LayerSurface = layer_shell.LayerSurface;
const workspace = @import("workspace.zig");
const Workspace = workspace.Workspace;
const lock = @import("lock.zig");

pub const gpa = std.heap.c_allocator;
const log = std.log.scoped(.server);
/// `raywm -d`: also log diagnostics meant for debugging, like key bindings.
pub var verbose = false;

/// Stored in SceneNode.data of trees we own, to identify them on hit tests.
pub const Tag = enum { view, layer };

/// Scene layers, bottom to top. Windows a layout manages are `tiled`,
/// others `floating`. `popups` holds popups of layer surfaces, so a dock's
/// menu is never hidden behind windows.
pub const Layer = enum { background, bottom, tiled, floating, top, fullscreen, overlay, popups, unmanaged, drag, lock };

pub const Server = struct {
    /// Host functions for the Lua runtime.
    pub const Api = host;

    wl_server: *wl.Server,
    backend: *wlr.Backend,
    session: ?*wlr.Session,
    renderer: *wlr.Renderer,
    allocator: *wlr.Allocator,
    scene: *wlr.Scene,
    layers: [std.meta.fields(Layer).len]*wlr.SceneTree,
    output_layout: *wlr.OutputLayout,
    scene_layout: *wlr.SceneOutputLayout,
    xdg_shell: *wlr.XdgShell,
    layer_shell: *wlr.LayerShellV1,
    seat: *wlr.Seat,
    cursor: *wlr.Cursor,
    cursor_mgr: *wlr.XcursorManager,
    session_lock: lock.SessionLock = undefined,
    idle_notifier: *wlr.IdleNotifierV1 = undefined,
    idle_inhibit: *wlr.IdleInhibitManagerV1 = undefined,

    /// Mapped views, most recently focused first.
    views: wl.list.Head(View, .link) = undefined,
    /// Every view by id, mapped or not.
    view_ids: std.AutoHashMapUnmanaged(u32, *View) = .empty,
    /// In creation order (see workspace.zig).
    workspaces: wl.list.Head(Workspace, .link) = undefined,
    outputs: wl.list.Head(Output, .link) = undefined,
    keyboards: wl.list.Head(input.Keyboard, .link) = undefined,
    focused: ?*View = null,
    /// Counts focus() calls, so map can tell whether a plugin chose focus.
    focus_requests: u32 = 0,
    /// Layer surface (launcher, lock-like overlay) holding keyboard focus.
    layer_focus: ?*LayerSurface = null,
    grab: input.Grab = .{},
    /// Scene node of the pointer-focused surface (see input.zig).
    pointer_node: input.PointerNode = .{},
    next_id: u32 = 1,
    /// Set once the Lua host is running; null during startup and teardown.
    rt: ?*host.Runtime = null,
    /// Single event-loop timer backing all Lua timers.
    timer: ?*wl.EventSource = null,

    new_output: wl.Listener(*wlr.Output) = .init(newOutput),
    layout_change: wl.Listener(*wlr.OutputLayout) = .init(layoutChange),
    new_toplevel: wl.Listener(*wlr.XdgToplevel) = .init(View.create),
    new_popup: wl.Listener(*wlr.XdgPopup) = .init(newPopup),
    new_layer_surface: wl.Listener(*wlr.LayerSurfaceV1) = .init(LayerSurface.create),
    new_input: wl.Listener(*wlr.InputDevice) = .init(input.newInput),
    new_inhibitor: wl.Listener(*wlr.IdleInhibitorV1) = .init(IdleInhibitor.create),
    /// Live idle inhibitors (see IdleInhibitor).
    inhibitors: wl.list.Head(IdleInhibitor, .link) = undefined,
    request_cursor: wl.Listener(*wlr.Seat.event.RequestSetCursor) = .init(input.requestCursor),
    request_selection: wl.Listener(*wlr.Seat.event.RequestSetSelection) = .init(input.requestSelection),
    cursor_motion: wl.Listener(*wlr.Pointer.event.Motion) = .init(input.motion),
    cursor_motion_abs: wl.Listener(*wlr.Pointer.event.MotionAbsolute) = .init(input.motionAbsolute),
    cursor_button: wl.Listener(*wlr.Pointer.event.Button) = .init(input.button),
    cursor_axis: wl.Listener(*wlr.Pointer.event.Axis) = .init(input.axis),
    cursor_frame: wl.Listener(*wlr.Cursor) = .init(input.frame),

    pub fn init(server: *Server) !void {
        const wl_server = try wl.Server.create();
        errdefer wl_server.destroy();
        var session: ?*wlr.Session = null;
        const backend = try wlr.Backend.autocreate(wl_server.getEventLoop(), &session);
        const renderer = try wlr.Renderer.autocreate(backend);
        const scene = try wlr.Scene.create();
        const output_layout = try wlr.OutputLayout.create(wl_server);
        server.* = .{
            .wl_server = wl_server,
            .backend = backend,
            .session = session,
            .renderer = renderer,
            .allocator = try wlr.Allocator.autocreate(backend, renderer),
            .scene = scene,
            .layers = undefined,
            .output_layout = output_layout,
            .scene_layout = try scene.attachOutputLayout(output_layout),
            .xdg_shell = try wlr.XdgShell.create(wl_server, 2),
            .layer_shell = try wlr.LayerShellV1.create(wl_server, 4),
            .seat = try wlr.Seat.create(wl_server, "seat0"),
            .cursor = try wlr.Cursor.create(),
            .cursor_mgr = try wlr.XcursorManager.create(null, 24),
        };
        for (&server.layers) |*tree| tree.* = try scene.tree.createSceneTree();

        try renderer.initServer(wl_server);
        _ = try wlr.Compositor.create(wl_server, 6, renderer);
        _ = try wlr.Subcompositor.create(wl_server);
        _ = try wlr.DataDeviceManager.create(wl_server);
        // Screen capture (grim, slurp's clients, ...): EVERY client of this
        // socket may read the screen, see SECURITY.md. xdg-output gives
        // capture tools output names and layout positions. wlroots frees
        // both with the display; pending frames fail if their output dies.
        _ = try wlr.ScreencopyManagerV1.create(wl_server);
        _ = try wlr.XdgOutputManagerV1.create(wl_server, output_layout);

        server.views.init();
        server.outputs.init();
        server.keyboards.init();
        server.workspaces.init();
        try server.session_lock.init(server);
        server.idle_notifier = try wlr.IdleNotifierV1.create(wl_server);
        server.idle_inhibit = try wlr.IdleInhibitManagerV1.create(wl_server);
        server.idle_inhibit.events.new_inhibitor.add(&server.new_inhibitor);
        server.inhibitors.init();
        backend.events.new_output.add(&server.new_output);
        output_layout.events.change.add(&server.layout_change);
        server.xdg_shell.events.new_toplevel.add(&server.new_toplevel);
        server.xdg_shell.events.new_popup.add(&server.new_popup);
        server.layer_shell.events.new_surface.add(&server.new_layer_surface);
        backend.events.new_input.add(&server.new_input);
        server.seat.events.request_set_cursor.add(&server.request_cursor);
        server.seat.events.request_set_selection.add(&server.request_selection);

        server.cursor.attachOutputLayout(output_layout);
        try server.cursor_mgr.load(1);
        server.cursor.events.motion.add(&server.cursor_motion);
        server.cursor.events.motion_absolute.add(&server.cursor_motion_abs);
        server.cursor.events.button.add(&server.cursor_button);
        server.cursor.events.axis.add(&server.cursor_axis);
        server.cursor.events.frame.add(&server.cursor_frame);
        server.timer = try wl_server.getEventLoop().addTimer(*Server, onTimer, server);
        // Test builds only (zig build -Dtest-input): virtual input for tests.
        if (@import("build_options").test_input)
            try @import("test_input").install(Server, server, wl_server, input.addDevice);
    }

    fn onTimer(server: *Server) c_int {
        if (server.rt) |rt| rt.runTimers();
        return 0;
    }

    /// Teardown order follows wlroots' tinywl.c. The Lua host must already be
    /// gone (server.rt == null) so destroy events are not forwarded to it.
    pub fn deinit(server: *Server) void {
        std.debug.assert(server.rt == null);
        if (server.timer) |t| t.remove();
        server.timer = null;
        server.wl_server.destroyClients();
        inline for (.{
            "new_output",        "layout_change",  "new_toplevel",      "new_popup",
            "new_input",         "request_cursor", "request_selection", "cursor_motion",
            "cursor_motion_abs", "cursor_button",  "cursor_axis",       "cursor_frame",
            "new_layer_surface", "new_inhibitor",
        }) |name| @field(server, name).link.remove();
        server.scene.tree.node.destroy();
        server.view_ids.deinit(gpa);
        workspace.deinitAll(server);
        server.cursor_mgr.destroy();
        server.cursor.destroy();
        server.allocator.destroy();
        server.renderer.destroy();
        server.backend.destroy();
        server.wl_server.destroy();
    }

    pub fn layer(server: *Server, l: Layer) *wlr.SceneTree {
        return server.layers[@intFromEnum(l)];
    }

    pub fn emit(server: *Server, ev: lua.Event, id: u32) void {
        log.debug("event {s} id={d}", .{ @tagName(ev), id });
        if (server.rt) |rt| rt.emit(ev, id);
    }

    pub fn emitArgs(server: *Server, ev: lua.Event, id: u32, args: []const lua.Arg) void {
        log.debug("event {s} id={d}", .{ @tagName(ev), id });
        if (server.rt) |rt| rt.emitArgs(ev, id, args);
    }

    pub fn nextId(server: *Server) u32 {
        defer server.next_id = if (server.next_id == std.math.maxInt(u32)) 1 else server.next_id + 1;
        return server.next_id;
    }

    /// A mapped view by id.
    pub fn viewById(server: *Server, id: u32) ?*View {
        const v = server.view_ids.get(id) orelse return null;
        return if (v.mapped) v else null;
    }

    pub fn outputAt(server: *Server, x: i32, y: i32) ?*Output {
        const wlr_output = server.output_layout.outputAt(@floatFromInt(x), @floatFromInt(y)) orelse return null;
        var it = server.outputs.iterator(.forward);
        while (it.next()) |o| if (o.wlr_output == wlr_output) return o;
        return null;
    }

    /// Most recently focused visible view.
    pub fn firstVisible(server: *Server) ?*View {
        var it = server.views.iterator(.forward);
        while (it.next()) |v| if (v.visible()) return v;
        return null;
    }

    /// May get keyboard focus: visible and not behind a fullscreen window.
    pub fn focusable(server: *Server, v: *View) bool {
        return v.visible() and !server.coveredByFullscreen(v);
    }

    /// Where keyboard focus goes when `gone` loses it (closed, hidden): the
    /// most recently focused focusable view on the same output, else any.
    pub fn focusFallback(server: *Server, gone: *View) ?*View {
        const g = gone.geometry();
        const out = server.outputAt(g.x +| @divTrunc(g.width, 2), g.y +| @divTrunc(g.height, 2));
        if (out) |o| {
            var it = server.views.iterator(.forward);
            while (it.next()) |v| {
                if (v == gone or !server.focusable(v)) continue;
                const vg = v.geometry();
                if (server.outputAt(vg.x +| @divTrunc(vg.width, 2), vg.y +| @divTrunc(vg.height, 2)) == o) return v;
            }
        }
        var it = server.views.iterator(.forward);
        while (it.next()) |v| if (v != gone and server.focusable(v)) return v;
        return null;
    }

    pub fn outputByWlr(server: *Server, wlr_output: ?*wlr.Output) ?*Output {
        var it = server.outputs.iterator(.forward);
        while (it.next()) |o| if (o.wlr_output == wlr_output) return o;
        return null;
    }

    pub fn outputById(server: *Server, id: u32) ?*Output {
        var it = server.outputs.iterator(.forward);
        while (it.next()) |o| if (o.id == id) return o;
        return null;
    }

    /// A visible fullscreen window covers `v` (on the same output, and
    /// `v` is neither it nor one of its dialogs).
    pub fn coveredByFullscreen(server: *Server, v: *View) bool {
        if (v.isFullscreen()) return false;
        const out = v.output() orelse return false;
        var it = server.views.iterator(.forward);
        while (it.next()) |f| {
            if (f == v or f.fullscreen_output != out.id or !f.visible()) continue;
            if (!v.isDescendantOf(f)) return true;
        }
        return false;
    }

    /// Moves keyboard focus to `view` (must be mapped) or clears it. A
    /// window hidden behind a fullscreen one never gets it: the fullscreen
    /// window keeps the keyboard until it leaves fullscreen.
    pub fn focus(server: *Server, view: ?*View) void {
        server.focus_requests +%= 1;
        // A locked session gives the keyboard to lock surfaces only.
        if (server.session_lock.locked()) return;
        if (view) |v| if (server.coveredByFullscreen(v)) return;
        if (view != null and view == server.focused) {
            // Clicking the focused window takes the keyboard back from an
            // on-demand layer surface (but never from an exclusive one).
            const ls = server.layer_focus orelse return;
            if (ls.wlr_layer.current.keyboard_interactive == .exclusive) return;
            server.layer_focus = null;
            return server.keyboardEnter(view.?.surface());
        }
        if (server.focused) |old| old.setActivated(false);
        server.focused = view;
        const v = view orelse {
            if (server.layer_focus == null) server.seat.keyboardNotifyClearFocus();
            server.emit(.view_focus, 0);
            return;
        };
        std.debug.assert(v.mapped);
        v.link.remove();
        server.views.prepend(v);
        v.raise();
        v.setActivated(true);
        // An exclusive layer surface (e.g. a launcher) keeps the keyboard;
        // an on-demand one gives it up when a window is chosen.
        if (server.layer_focus) |ls| {
            if (ls.wlr_layer.current.keyboard_interactive == .exclusive) return server.emit(.view_focus, v.id);
            server.layer_focus = null;
        }
        server.keyboardEnter(v.surface());
        server.emit(.view_focus, v.id);
    }

    /// Gives the keyboard to a layer surface, or back to the focused view.
    pub fn focusLayer(server: *Server, ls: ?*LayerSurface) void {
        if (server.session_lock.locked()) return;
        server.layer_focus = ls;
        if (ls) |l| return server.keyboardEnter(l.wlr_layer.surface);
        if (server.focused) |v| server.keyboardEnter(v.surface()) else server.seat.keyboardNotifyClearFocus();
    }

    /// After an unlock: the keyboard goes back to where it was.
    pub fn restoreKeyboard(server: *Server) void {
        if (server.layer_focus) |ls| return server.keyboardEnter(ls.wlr_layer.surface);
        const v = server.focused orelse return server.focus(server.firstVisible());
        if (!server.focusable(v)) return server.focus(server.focusFallback(v));
        server.keyboardEnter(v.surface());
    }

    fn keyboardEnter(server: *Server, surface: *wlr.Surface) void {
        if (server.seat.getKeyboard()) |kb| {
            var buf: [32]u32 = undefined;
            server.seat.keyboardNotifyEnter(surface, input.heldKeys(server, kb, &buf), &kb.modifiers);
        } else {
            server.seat.keyboardNotifyEnter(surface, &.{}, null);
        }
    }

    /// The output under the cursor, falling back to the first output.
    pub fn activeOutput(server: *Server) ?*Output {
        if (server.output_layout.outputAt(server.cursor.x, server.cursor.y)) |wo| if (server.outputByWlr(wo)) |o| return o;
        var it = server.outputs.iterator(.forward);
        while (it.next()) |o| if (o.inLayout()) return o;
        return null;
    }

    /// After windows were hidden or shown: the keyboard leaves a window
    /// that is hidden now; the pointer follows what is under it.
    pub fn afterVisibilityChange(server: *Server) void {
        if (server.focused) |f| if (!f.visible()) server.focus(server.focusFallback(f));
        input.refocusPointer(server);
        server.updateIdleInhibit();
    }

    /// `ws` was just shown: its most recently focused window gets the
    /// keyboard; an empty workspace takes it from the hidden windows.
    pub fn focusWorkspace(server: *Server, ws: *Workspace) void {
        var it = server.views.iterator(.forward);
        while (it.next()) |v| if (v.workspace == ws and server.focusable(v)) return server.focus(v);
        if (server.focused) |f| if (!f.visible()) server.focus(null);
    }

    /// Idle notifications are held back while a visible surface has an
    /// idle inhibitor. Called when inhibitors or visibility change.
    pub fn updateIdleInhibit(server: *Server) void {
        var on = false;
        var it = server.inhibitors.iterator(.forward);
        while (it.next()) |ii| if (ii.active()) {
            on = true;
            break;
        };
        server.idle_notifier.setInhibited(on);
    }

    /// Fullscreen and maximized windows follow output and panel changes.
    pub fn refitViews(server: *Server) void {
        var it = server.views.iterator(.forward);
        while (it.next()) |v| v.refit();
    }

    /// Box of the output under the cursor, falling back to the first output.
    pub fn activeOutputBox(server: *Server) ?wlr.Box {
        const out = server.output_layout.outputAt(server.cursor.x, server.cursor.y) orelse blk: {
            var it = server.outputs.iterator(.forward);
            while (it.next()) |o| if (o.inLayout()) break :blk o.wlr_output;
            return null;
        };
        var box: wlr.Box = undefined;
        server.output_layout.getBox(out, &box);
        return box;
    }

    fn newOutput(listener: *wl.Listener(*wlr.Output), wlr_output: *wlr.Output) void {
        const server: *Server = @fieldParentPtr("new_output", listener);
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
        Output.create(server, wlr_output) catch {
            log.err("failed to set up output {s}", .{wlr_output.name});
            wlr_output.destroy();
        };
    }

    /// Fires on output add/remove/mode change. Views left outside every
    /// output (e.g. after unplugging) are moved onto a visible one.
    fn layoutChange(listener: *wl.Listener(*wlr.OutputLayout), _: *wlr.OutputLayout) void {
        const server: *Server = @fieldParentPtr("layout_change", listener);
        var outs = server.outputs.iterator(.forward);
        // A dying output is still listed here: wlroots removes it from the
        // layout (firing this event) before our destroy handler runs.
        while (outs.next()) |o| if (o.inLayout()) o.arrangeLayers();
        // Workspaces of an output that left move with their windows first.
        workspace.rescue(server);
        if (server.session_lock.locked()) server.session_lock.arrange();
        if (server.activeOutputBox()) |box| {
            var it = server.views.iterator(.forward);
            while (it.next()) |v| {
                const geo = v.geometry();
                const cx: f64 = @floatFromInt(geo.x +| @divTrunc(geo.width, 2));
                const cy: f64 = @floatFromInt(geo.y +| @divTrunc(geo.height, 2));
                if (server.output_layout.outputAt(cx, cy) == null) v.move(box.x, box.y);
            }
        }
        server.refitViews();
        server.emit(.layout, 0);
    }

    fn newPopup(_: *wl.Listener(*wlr.XdgPopup), xdg_popup: *wlr.XdgPopup) void {
        // Popups of layer surfaces have no xdg parent yet; layer.zig handles them.
        const parent = wlr.XdgSurface.tryFromWlrSurface(xdg_popup.parent orelse return) orelse return;
        // No tree: the parent's role is gone (the client has not seen its
        // popup_done yet). The popup is never configured or shown.
        const Popup = @import("view.zig").Popup;
        Popup.create(xdg_popup, Popup.treeOf(parent) orelse return);
    }
};

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
        // Listed before joining the layout, so `layout` handlers already see it.
        server.outputs.append(output);
        errdefer output.link.remove();
        const layout_output = try server.output_layout.addAuto(wlr_output);
        server.scene_layout.addOutput(layout_output, scene_output);
        wlr_output.events.frame.add(&output.frame);
        wlr_output.events.present.add(&output.present);
        wlr_output.events.request_state.add(&output.request_state);
        wlr_output.events.destroy.add(&output.destroy);
        // Appears blank while the session is locked.
        server.session_lock.prepareOutput(output);
        server.emit(.output_add, output.id);
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
    fn handleFrame(listener: *wl.Listener(*wlr.Output), _: *wlr.Output) void {
        const output: *Output = @fieldParentPtr("frame", listener);
        var now = timestamp();
        _ = output.scene_output.commit(null);
        output.scene_output.sendFrameDone(&now);
    }

    fn handlePresent(listener: *wl.Listener(*wlr.Output.event.Present), event: *wlr.Output.event.Present) void {
        const output: *Output = @fieldParentPtr("present", listener);
        if (event.presented) output.server.session_lock.presented(output, event.commit_seq);
    }

    fn handleRequestState(listener: *wl.Listener(*wlr.Output.event.RequestState), event: *wlr.Output.event.RequestState) void {
        const output: *Output = @fieldParentPtr("request_state", listener);
        _ = output.wlr_output.commitState(event.state);
    }

    fn handleDestroy(listener: *wl.Listener(*wlr.Output), _: *wlr.Output) void {
        const output: *Output = @fieldParentPtr("destroy", listener);
        layer_shell.closeAll(output);
        workspace.outputGone(output.server, output);
        if (output.lock_bg) |r| r.node.destroy();
        output.frame.link.remove();
        output.present.link.remove();
        output.request_state.link.remove();
        output.destroy.link.remove();
        output.link.remove();
        output.server.emit(.output_remove, output.id);
        gpa.destroy(output);
    }
};

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

/// True when `serial` is at or past `want`, tolerant of u32 wrap-around.
pub fn serialReached(serial: u32, want: u32) bool {
    return @as(i32, @bitCast(serial -% want)) >= 0;
}

pub fn timestamp() posix.timespec {
    var ts: posix.timespec = undefined;
    switch (posix.errno(posix.system.clock_gettime(posix.CLOCK.MONOTONIC, &ts))) {
        .SUCCESS => return ts,
        else => @panic("CLOCK_MONOTONIC not supported"),
    }
}

extern "c" fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

/// Runs `cmd` via /bin/sh in a new session. Double fork so the child is
/// reparented to init and never becomes a zombie of the compositor.
pub fn spawn(cmd: [*:0]const u8) void {
    const pid = std.c.fork();
    if (pid < 0) return log.err("fork failed", .{});
    if (pid == 0) {
        _ = std.c.setsid();
        const pid2 = std.c.fork();
        if (pid2 == 0) {
            // signalfd (wl_event_loop_add_signal) blocked SIGINT/SIGTERM in
            // the compositor; the mask survives exec, so clear it.
            const empty = posix.sigemptyset();
            posix.sigprocmask(posix.SIG.SETMASK, &empty, null);
            const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", cmd };
            _ = execv("/bin/sh", &argv);
            std.c._exit(127);
        }
        std.c._exit(if (pid2 < 0) 1 else 0);
    }
    while (std.c.waitpid(pid, null, 0) < 0 and std.c._errno().* == @intFromEnum(posix.E.INTR)) {}
}

/// An idle inhibitor (idle-inhibit-unstable-v1: a video player keeping the
/// screen on). It holds back idle notifications (ext-idle-notify-v1) while
/// its surface is visible: a window that is shown, or a mapped layer
/// surface.
pub const IdleInhibitor = struct {
    server: *Server,
    wlr_inhibitor: *wlr.IdleInhibitorV1,
    link: wl.list.Link = undefined,
    destroy: wl.Listener(*wlr.Surface) = .init(handleDestroy),

    fn create(listener: *wl.Listener(*wlr.IdleInhibitorV1), wlr_inhibitor: *wlr.IdleInhibitorV1) void {
        const server: *Server = @fieldParentPtr("new_inhibitor", listener);
        const ii = gpa.create(IdleInhibitor) catch return log.err("out of memory", .{});
        ii.* = .{ .server = server, .wlr_inhibitor = wlr_inhibitor };
        server.inhibitors.append(ii);
        wlr_inhibitor.events.destroy.add(&ii.destroy);
        server.updateIdleInhibit();
    }

    fn handleDestroy(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
        const ii: *IdleInhibitor = @fieldParentPtr("destroy", listener);
        const server = ii.server;
        ii.destroy.link.remove();
        ii.link.remove();
        gpa.destroy(ii);
        server.updateIdleInhibit();
    }

    fn active(ii: *IdleInhibitor) bool {
        const root = ii.wlr_inhibitor.surface.getRootSurface();
        if (!root.mapped) return false;
        if (wlr.XdgSurface.tryFromWlrSurface(root)) |xs| {
            const tree = @import("view.zig").Popup.treeOf(xs) orelse return false;
            if (View.fromNode(&tree.node)) |v| return v.visible();
            return true;
        }
        return true; // a layer surface or another role: mapped is visible
    }
};
