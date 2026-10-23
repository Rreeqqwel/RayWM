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

pub const Protocols = struct {
    server: *Server,
    security: *wlr.SecurityContextManagerV1,
    cursor_shape: *wlr.CursorShapeManagerV1,
    decoration: *wlr.XdgDecorationManagerV1,
    activation: *wlr.XdgActivationV1,
    request_set_shape: wl.Listener(*wlr.CursorShapeManagerV1.event.RequestSetShape) = .init(handleSetShape),
    request_primary: wl.Listener(*wlr.Seat.event.RequestSetPrimarySelection) = .init(handleRequestPrimary),
    new_decoration: wl.Listener(*wlr.XdgToplevelDecorationV1) = .init(handleNewDecoration),
    request_activate: wl.Listener(*wlr.XdgActivationV1.event.RequestActivate) = .init(handleRequestActivate),

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
        display.setGlobalFilter(*Protocols, filter, p);
    }

    pub fn deinit(p: *Protocols) void {
        p.request_set_shape.link.remove();
        p.request_primary.link.remove();
        p.new_decoration.link.remove();
        p.request_activate.link.remove();
    }

    /// Returns constants only: libwayland reads the result as a C bool (see
    /// src/cabi.zig on computed bools crossing into C with Zig 0.16).
    fn filter(client: *const wl.Client, global: *const wl.Global, p: *Protocols) bool {
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
        log.debug("cursor shape {s}", .{name});
        server.cursor.setXcursor(server.cursor_mgr, name);
    }

    /// xdg-decoration: the view answers (see View.applyDecoration).
    fn handleNewDecoration(_: *wl.Listener(*wlr.XdgToplevelDecorationV1), deco: *wlr.XdgToplevelDecorationV1) void {
        const view = View.fromXdgToplevel(deco.toplevel) orelse return;
        view.attachDecoration(deco);
    }

    /// xdg-activation: wlroots only emits this for a valid token (known,
    /// not expired). A token with a seat was checked when it was made: its
    /// serial came from an input event of that client, and the surface
    /// that asked for it (if named) had keyboard or pointer focus.
    fn handleRequestActivate(_: *wl.Listener(*wlr.XdgActivationV1.event.RequestActivate), event: *wlr.XdgActivationV1.event.RequestActivate) void {
        const view = View.fromWlrSurface(event.surface) orelse return;
        log.debug("activation of view {d} (user: {})", .{ view.id, event.token.seat != null });
        view.requestActivate(event.token.seat != null);
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
