//! Protocols that wlroots implements and RayWM only has to create, or
//! connect with a few lines: buffers and scaling (viewporter, single-pixel
//! buffers, fractional scale, alpha modifier, linux-dmabuf, presentation
//! time), selections (primary selection, data control for clipboard
//! managers), xdg-foreign (portal dialogs), cursor shapes, window
//! decorations and activation (handed to the view), and the filter that
//! hides privileged globals from sandboxed clients.
//!
//! The wlr_scene does the per-surface work for several of them: it sends
//! fractional and integer preferred scales as surfaces enter outputs,
//! presentation feedback, dmabuf feedback, and applies alpha modifiers.
//!
//! Security: data control lets any client read and replace the clipboard
//! at any time (that is what clipboard managers do), like screencopy lets
//! it read the screen. Clients started in a sandbox that uses
//! security-context-v1 (Flatpak) do not see these and other privileged
//! globals (see `privileged`); ordinary clients of the socket see all.
const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const srv = @import("server.zig");
const Server = srv.Server;
const View = @import("view.zig").View;
const log = std.log.scoped(.protocols);

/// Globals a sandboxed client (security-context-v1) never sees: they
/// read the screen or the clipboard, inject input, or manage outputs,
/// windows or the session.
pub const privileged = [_][]const u8{
    "zwlr_screencopy_manager_v1",
    "ext_image_copy_capture_manager_v1",
    "ext_output_image_capture_source_manager_v1",
    "zwlr_data_control_manager_v1",
    "ext_data_control_manager_v1",
    "zwlr_output_manager_v1",
    "zwlr_output_power_manager_v1",
    "zwlr_gamma_control_manager_v1",
    "zwlr_foreign_toplevel_manager_v1",
    "ext_foreign_toplevel_list_v1",
    "ext_workspace_manager_v1",
    "ext_session_lock_manager_v1",
    "zwp_virtual_keyboard_manager_v1",
    "zwlr_virtual_pointer_manager_v1",
    "zwp_input_method_manager_v2",
    "zwlr_layer_shell_v1",
    "wp_security_context_manager_v1",
};

pub fn isPrivileged(interface: []const u8) bool {
    for (privileged) |name| if (std.mem.eql(u8, name, interface)) return true;
    return false;
}

/// A short-lived grant for an actual forwarded key/button press. Client
/// destruction clears the entry before its pointer can become stale.
const InputGrant = struct {
    client: ?*wl.Client = null,
    serial: u32 = 0,
    deadline: u64 = 0,
    destroy: wl.Listener(*wl.Client) = .init(handleDestroy),

    fn clear(g: *InputGrant) void {
        if (g.client != null) g.destroy.link.remove();
        g.client = null;
    }

    fn handleDestroy(listener: *wl.Listener(*wl.Client), _: *wl.Client) void {
        const g: *InputGrant = @fieldParentPtr("destroy", listener);
        g.clear();
    }
};

/// Keep verification outside token.data, which remains available to other
/// compositor integrations. wlroots destroys tokens on use, expiry or
/// shutdown; the listener clears our pointer in every case.
const TokenGrant = struct {
    token: ?*wlr.XdgActivationTokenV1 = null,
    destroy: wl.Listener(void) = .init(handleDestroy),

    fn clear(g: *TokenGrant) void {
        if (g.token != null) g.destroy.link.remove();
        g.token = null;
    }

    fn handleDestroy(listener: *wl.Listener(void)) void {
        const g: *TokenGrant = @fieldParentPtr("destroy", listener);
        g.clear();
    }
};

fn monotonicMs() u64 {
    const ts = srv.timestamp();
    return @as(u64, @intCast(ts.sec)) * std.time.ms_per_s + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

pub const Protocols = struct {
    server: *Server,
    security: *wlr.SecurityContextManagerV1,
    cursor_shape: *wlr.CursorShapeManagerV1,
    decoration: *wlr.XdgDecorationManagerV1,
    activation: *wlr.XdgActivationV1,
    /// At most 64 input grants and 64 verified tokens, with no allocations
    /// on input paths. Older entries are conservatively downgraded to
    /// urgency-only activation if the bounded ring wraps.
    input_grants: [64]InputGrant = @splat(.{}),
    token_grants: [64]TokenGrant = @splat(.{}),
    next_input_grant: usize = 0,
    next_token_grant: usize = 0,
    request_set_shape: wl.Listener(*wlr.CursorShapeManagerV1.event.RequestSetShape) = .init(handleSetShape),
    request_primary: wl.Listener(*wlr.Seat.event.RequestSetPrimarySelection) = .init(handleRequestPrimary),
    new_decoration: wl.Listener(*wlr.XdgToplevelDecorationV1) = .init(handleNewDecoration),
    request_activate: wl.Listener(*wlr.XdgActivationV1.event.RequestActivate) = .init(handleRequestActivate),
    new_token: wl.Listener(*wlr.XdgActivationTokenV1) = .init(handleNewToken),

    pub fn init(p: *Protocols, server: *Server) !void {
        const display = server.wl_server;
        p.* = .{
            .server = server,
            .security = try wlr.SecurityContextManagerV1.create(display),
            .cursor_shape = try wlr.CursorShapeManagerV1.create(display, 1),
            .decoration = try wlr.XdgDecorationManagerV1.create(display),
            .activation = try wlr.XdgActivationV1.create(display),
        };
        _ = try wlr.Viewporter.create(display);
        _ = try wlr.SinglePixelBufferManagerV1.create(display);
        _ = try wlr.FractionalScaleManagerV1.create(display, 1);
        _ = try wlr.Presentation.create(display, server.backend, 2);
        _ = try wlr.AlphaModifierV1.create(display);
        _ = try wlr.XdgForeignV2.create(display, try wlr.XdgForeignRegistry.create(display));
        _ = try wlr.PrimarySelectionDeviceManagerV1.create(display);
        _ = try wlr.DataControlManagerV1.create(display);
        _ = try wlr.ExtDataControlManagerV1.create(display, 1);
        p.cursor_shape.events.request_set_shape.add(&p.request_set_shape);
        server.seat.events.request_set_primary_selection.add(&p.request_primary);
        p.decoration.events.new_toplevel_decoration.add(&p.new_decoration);
        p.activation.events.request_activate.add(&p.request_activate);
        p.activation.events.new_token.add(&p.new_token);
        display.setGlobalFilter(*Protocols, filter, p);
    }

    pub fn deinit(p: *Protocols) void {
        p.request_set_shape.link.remove();
        p.request_primary.link.remove();
        p.new_decoration.link.remove();
        p.request_activate.link.remove();
        p.new_token.link.remove();
        for (&p.input_grants) |*g| g.clear();
        for (&p.token_grants) |*g| g.clear();
    }

    /// Returns constants only: libwayland reads the result as a C bool (see
    /// src/cabi.zig on computed bools crossing into C with Zig 0.16).
    fn filter(client: *const wl.Client, global: *const wl.Global, p: *Protocols) bool {
        if (std.mem.eql(u8, std.mem.span(global.getInterface().name), "xwayland_shell_v1")) {
            if (p.server.xwayland.ownsClient(client)) return true;
            return false;
        }
        if (p.security.lookupClient(client) == null) return true;
        if (isPrivileged(std.mem.span(global.getInterface().name))) return false;
        return true;
    }

    /// wp_cursor_shape_v1: a named cursor instead of a client buffer, from
    /// the client that has the pointer.
    fn handleSetShape(listener: *wl.Listener(*wlr.CursorShapeManagerV1.event.RequestSetShape), event: *wlr.CursorShapeManagerV1.event.RequestSetShape) void {
        const p: *Protocols = @fieldParentPtr("request_set_shape", listener);
        const server = p.server;
        if (event.device_type != .pointer) return;
        if (event.seat_client != server.seat.pointer_state.focused_client) return;
        // During a compositor grab the compositor's cursor stays.
        if (server.grab.mode != .none) return;
        const name = wlr.CursorShapeManagerV1.shapeName(event.shape);
        server.cursor.setXcursor(server.cursor_mgr, name);
        // -d diagnostics must remain available in ReleaseSafe builds,
        // where Zig removes debug-level logging at compile time.
        if (srv.verbose) log.info("cursor shape {s}", .{name});
    }

    /// xdg-decoration: the view answers (see View.applyDecoration).
    fn handleNewDecoration(_: *wl.Listener(*wlr.XdgToplevelDecorationV1), deco: *wlr.XdgToplevelDecorationV1) void {
        const view = View.fromXdgToplevel(deco.toplevel) orelse return;
        view.attachDecoration(deco);
    }

    /// Called only for presses actually forwarded to the seat. A grant
    /// must be exchanged for a token within five seconds, exactly once.
    pub fn recordInput(p: *Protocols, client: *wl.Client, serial: u32) void {
        if (serial == 0 or p.server.session_lock.locked()) return;
        const g = &p.input_grants[p.next_input_grant];
        p.next_input_grant = (p.next_input_grant + 1) % p.input_grants.len;
        g.clear();
        g.client = client;
        g.serial = serial;
        g.deadline = monotonicMs() + 5000;
        client.addDestroyListener(&g.destroy);
    }

    /// wlroots validates seat serials broadly (including enter/leave).
    /// RayWM additionally requires a recent, forwarded key/button press
    /// from this client and a supplied source surface still holding
    /// keyboard/pointer focus when the token is committed.
    fn handleNewToken(listener: *wl.Listener(*wlr.XdgActivationTokenV1), token: *wlr.XdgActivationTokenV1) void {
        const p: *Protocols = @fieldParentPtr("new_token", listener);
        if (p.server.session_lock.locked() or token.seat != p.server.seat) return;
        const surface = token.surface orelse return;
        const seat = p.server.seat;
        if (surface != seat.keyboard_state.focused_surface and surface != seat.pointer_state.focused_surface) return;
        const client = surface.resource.getClient();
        const now = monotonicMs();
        for (&p.input_grants) |*g| {
            if (g.client != client or g.serial != token.serial) continue;
            const fresh = now <= g.deadline;
            g.clear(); // one input serial can grant only one token
            if (!fresh) return;
            const verified = &p.token_grants[p.next_token_grant];
            p.next_token_grant = (p.next_token_grant + 1) % p.token_grants.len;
            verified.clear();
            verified.token = token;
            token.events.destroy.add(&verified.destroy);
            return;
        }
    }

    /// wlroots consumes known, unexpired tokens after this callback. Only
    /// one exchanged from a native input grant can authorize focus.
    fn handleRequestActivate(listener: *wl.Listener(*wlr.XdgActivationV1.event.RequestActivate), event: *wlr.XdgActivationV1.event.RequestActivate) void {
        const p: *Protocols = @fieldParentPtr("request_activate", listener);
        const view = View.fromWlrSurface(event.surface) orelse return;
        const user = for (&p.token_grants) |*g| {
            if (g.token != event.token) continue;
            g.clear();
            break true;
        } else false;
        log.debug("activation of view {d} (user: {})", .{ view.id, user });
        view.requestActivate(user);
    }

    /// Middle-click paste: like the clipboard, set by the focused client.
    fn handleRequestPrimary(listener: *wl.Listener(*wlr.Seat.event.RequestSetPrimarySelection), event: *wlr.Seat.event.RequestSetPrimarySelection) void {
        const p: *Protocols = @fieldParentPtr("request_primary", listener);
        p.server.seat.setPrimarySelection(event.source, event.serial);
    }
};

/// linux-dmabuf (GPU buffers) when the renderer can import them, given to
/// the scene for per-surface feedback (direct scanout). With pixman there
/// is none; clients then use shared memory.
pub fn initBuffers(server: *Server) !void {
    try server.renderer.initWlShm(server.wl_server);
    if (server.renderer.getTextureFormats(@intCast(@intFromEnum(wlr.BufferCap.dmabuf))) != null and server.renderer.getDrmFd() >= 0) {
        const dmabuf = try wlr.LinuxDmabufV1.createWithRenderer(server.wl_server, 5, server.renderer);
        server.scene.setLinuxDmabufV1(dmabuf);
    } else log.info("no linux-dmabuf with this renderer: clients use shared memory", .{});
}
