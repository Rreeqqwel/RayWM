//! Seat-local text-input-v3 / input-method-v2 relay. Native resources stay
//! owned by wlroots; wrappers own only listeners and popup scene trees.
//! All IME traffic is gated by keyboard focus and the enabled text input.
const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const srv = @import("server.zig");
const input = @import("input.zig");
const gpa = srv.gpa;

extern fn wlr_input_device_get_virtual_keyboard(device: *wlr.InputDevice) ?*wlr.VirtualKeyboardV1;

pub const Relay = struct {
    server: *srv.Server,
    texts: *wlr.TextInputManagerV3,
    methods: *wlr.InputMethodManagerV2,
    virtual: *wlr.VirtualKeyboardManagerV1,
    entries: wl.list.Head(Entry, .link) = undefined,
    popups: wl.list.Head(Popup, .link) = undefined,
    active: ?*Entry = null,
    method: ?*wlr.InputMethodV2 = null,
    new_text: wl.Listener(*wlr.TextInputV3) = .init(onNewText),
    new_method: wl.Listener(*wlr.InputMethodV2) = .init(onNewMethod),
    new_virtual: wl.Listener(*wlr.VirtualKeyboardV1) = .init(onVirtual),
    focus: wl.Listener(*wlr.Seat.event.KeyboardFocusChange) = .init(onFocus),
    method_commit: wl.Listener(void) = .init(onMethodCommit),
    method_destroy: wl.Listener(void) = .init(onMethodDestroy),
    method_popup: wl.Listener(*wlr.InputPopupSurfaceV2) = .init(Popup.create),
    method_grab: wl.Listener(*wlr.InputMethodV2.KeyboardGrab) = .init(onGrab),

    pub fn init(r: *Relay, server: *srv.Server) !void {
        r.* = .{
            .server = server,
            .texts = try wlr.TextInputManagerV3.create(server.wl_server),
            .methods = try wlr.InputMethodManagerV2.create(server.wl_server),
            .virtual = try wlr.VirtualKeyboardManagerV1.create(server.wl_server),
        };
        r.entries.init();
        r.popups.init();
        r.texts.events.new_text_input.add(&r.new_text);
        r.methods.events.new_input_method.add(&r.new_method);
        r.virtual.events.new_virtual_keyboard.add(&r.new_virtual);
        server.seat.keyboard_state.events.focus_change.add(&r.focus);
    }

    pub fn deinit(r: *Relay) void {
        // Server destroys clients first, so wrappers and methods are gone.
        std.debug.assert(r.entries.length() == 0 and r.method == null and r.popups.length() == 0);
        inline for (.{ "new_text", "new_method", "new_virtual", "focus" }) |name| @field(r, name).link.remove();
    }

    fn eligible(r: *Relay, entry: *Entry) bool {
        const ti = entry.native;
        return !r.server.session_lock.locked() and ti.seat == r.server.seat and ti.current_enabled and ti.focused_surface != null and ti.focused_surface == r.server.seat.keyboard_state.focused_surface;
    }

    fn deactivate(r: *Relay) void {
        r.active = null;
        if (r.method) |im| if (im.active) {
            im.sendDeactivate();
            im.sendDone();
        };
        r.positionPopups();
    }

    fn update(r: *Relay, entry: *Entry) void {
        if (!r.eligible(entry)) {
            if (r.active == entry) r.deactivate();
            return;
        }
        if (r.active != entry) r.deactivate();
        r.active = entry;
        const im = r.method orelse return;
        if (!im.active) im.sendActivate();
        const ti = entry.native;
        if (ti.active_features.surrounding_text) im.sendSurroundingText(ti.current.surrounding.text orelse "", ti.current.surrounding.cursor, ti.current.surrounding.anchor);
        if (ti.active_features.content_type) im.sendContentType(ti.current.content_type.hint, ti.current.content_type.purpose);
        im.sendTextChangeCause(ti.current.text_change_cause);
        im.sendDone();
        r.positionPopups();
    }

    fn onFocus(listener: *wl.Listener(*wlr.Seat.event.KeyboardFocusChange), event: *wlr.Seat.event.KeyboardFocusChange) void {
        const r: *Relay = @fieldParentPtr("focus", listener);
        r.deactivate();
        var it = r.entries.iterator(.forward);
        while (it.next()) |entry| {
            const ti = entry.native;
            if (ti.focused_surface != null) ti.sendLeave();
            if (!r.server.session_lock.locked()) if (event.new_surface) |surface| {
                if (ti.seat == r.server.seat and ti.resource.getClient() == surface.resource.getClient()) ti.sendEnter(surface);
            };
        }
    }

    fn onNewText(listener: *wl.Listener(*wlr.TextInputV3), native: *wlr.TextInputV3) void {
        const r: *Relay = @fieldParentPtr("new_text", listener);
        const entry = gpa.create(Entry) catch return;
        entry.* = .{ .relay = r, .native = native };
        r.entries.append(entry);
        native.events.enable.add(&entry.enable);
        native.events.commit.add(&entry.commit);
        native.events.disable.add(&entry.disable);
        native.events.destroy.add(&entry.destroy);
        if (!r.server.session_lock.locked()) if (r.server.seat.keyboard_state.focused_surface) |surface| {
            if (native.seat == r.server.seat and native.resource.getClient() == surface.resource.getClient()) native.sendEnter(surface);
        };
    }

    fn onNewMethod(listener: *wl.Listener(*wlr.InputMethodV2), im: *wlr.InputMethodV2) void {
        const r: *Relay = @fieldParentPtr("new_method", listener);
        if (im.seat != r.server.seat or r.method != null) return im.sendUnavailable(); // frees im
        r.method = im;
        im.events.commit.add(&r.method_commit);
        im.events.destroy.add(&r.method_destroy);
        im.events.new_popup_surface.add(&r.method_popup);
        im.events.grab_keyboard.add(&r.method_grab);
        if (r.active) |entry| r.update(entry);
    }

    fn onMethodDestroy(listener: *wl.Listener(void)) void {
        const r: *Relay = @fieldParentPtr("method_destroy", listener);
        r.method = null;
        inline for (.{ "method_commit", "method_destroy", "method_popup", "method_grab" }) |name| @field(r, name).link.remove();
    }

    fn onMethodCommit(listener: *wl.Listener(void)) void {
        const r: *Relay = @fieldParentPtr("method_commit", listener);
        const entry = r.active orelse return;
        if (!r.eligible(entry)) return;
        const im = r.method orelse return;
        if (!im.active) return;
        const ti = entry.native;
        const state = im.current;
        if (state.preedit.text) |text| ti.sendPreeditString(text, state.preedit.cursor_begin, state.preedit.cursor_end);
        if (state.commit_text) |text| ti.sendCommitString(text);
        if (state.delete.before_length != 0 or state.delete.after_length != 0) ti.sendDeleteSurroundingText(state.delete.before_length, state.delete.after_length);
        ti.sendDone();
    }

    fn onVirtual(listener: *wl.Listener(*wlr.VirtualKeyboardV1), kb: *wlr.VirtualKeyboardV1) void {
        const r: *Relay = @fieldParentPtr("new_virtual", listener);
        if (kb.seat == r.server.seat) input.addDevice(r.server, &kb.keyboard.base);
    }

    fn onGrab(listener: *wl.Listener(*wlr.InputMethodV2.KeyboardGrab), grab: *wlr.InputMethodV2.KeyboardGrab) void {
        const r: *Relay = @fieldParentPtr("method_grab", listener);
        grab.setKeyboard(r.server.seat.getKeyboard());
    }

    fn grabFor(r: *Relay, kb: *wlr.Keyboard) ?*wlr.InputMethodV2.KeyboardGrab {
        const entry = r.active orelse return null;
        if (!r.eligible(entry)) return null;
        const im = r.method orelse return null;
        if (!im.active) return null;
        // The IME reinjects unhandled keys through its virtual keyboard;
        // sending them back into its own grab would form a feedback loop.
        if (wlr_input_device_get_virtual_keyboard(&kb.base)) |virtual| if (virtual.resource.getClient() == im.resource.getClient()) return null;
        return im.keyboard_grab;
    }

    pub fn forwardKey(r: *Relay, kb: *wlr.Keyboard, event: *wlr.Keyboard.event.Key) bool {
        const grab = r.grabFor(kb) orelse return false;
        grab.setKeyboard(kb);
        grab.sendKey(event.time_msec, event.keycode, event.state);
        return true;
    }

    pub fn forwardModifiers(r: *Relay, kb: *wlr.Keyboard) bool {
        const grab = r.grabFor(kb) orelse return false;
        grab.setKeyboard(kb);
        grab.sendModifiers(&kb.modifiers);
        return true;
    }

    pub fn positionPopups(r: *Relay) void {
        var it = r.popups.iterator(.forward);
        while (it.next()) |popup| popup.position();
    }
};

const Entry = struct {
    relay: *Relay,
    native: *wlr.TextInputV3,
    link: wl.list.Link = undefined,
    enable: wl.Listener(void) = .init(onEnable),
    commit: wl.Listener(void) = .init(onCommit),
    disable: wl.Listener(void) = .init(onDisable),
    destroy: wl.Listener(void) = .init(onDestroy),
    fn onEnable(listener: *wl.Listener(void)) void {
        const e: *Entry = @fieldParentPtr("enable", listener);
        e.relay.update(e);
    }
    fn onCommit(listener: *wl.Listener(void)) void {
        const e: *Entry = @fieldParentPtr("commit", listener);
        e.relay.update(e);
    }
    fn onDisable(listener: *wl.Listener(void)) void {
        const e: *Entry = @fieldParentPtr("disable", listener);
        if (e.relay.active == e) e.relay.deactivate();
    }
    fn onDestroy(listener: *wl.Listener(void)) void {
        const e: *Entry = @fieldParentPtr("destroy", listener);
        if (e.relay.active == e) e.relay.deactivate();
        e.link.remove();
        inline for (.{ "enable", "commit", "disable", "destroy" }) |name| @field(e, name).link.remove();
        gpa.destroy(e);
    }
};

const Popup = struct {
    relay: *Relay,
    native: *wlr.InputPopupSurfaceV2,
    tree: *wlr.SceneTree,
    link: wl.list.Link = undefined,
    destroy: wl.Listener(void) = .init(onDestroy),
    commit: wl.Listener(*wlr.Surface) = .init(onCommit),
    fn create(listener: *wl.Listener(*wlr.InputPopupSurfaceV2), native: *wlr.InputPopupSurfaceV2) void {
        const r: *Relay = @fieldParentPtr("method_popup", listener);
        const p = gpa.create(Popup) catch return;
        const tree = r.server.layer(.popups).createSceneTree() catch return gpa.destroy(p);
        _ = tree.createSceneSubsurfaceTree(native.surface) catch {
            tree.node.destroy();
            return gpa.destroy(p);
        };
        p.* = .{ .relay = r, .native = native, .tree = tree };
        r.popups.append(p);
        native.events.destroy.add(&p.destroy);
        native.surface.events.commit.add(&p.commit);
        p.position();
    }
    fn position(p: *Popup) void {
        const r = p.relay;
        const e = r.active orelse return p.tree.node.setEnabled(false);
        if (!r.eligible(e) or r.method == null or !r.method.?.active) return p.tree.node.setEnabled(false);
        const surface = e.native.focused_surface orelse return;
        const view = @import("view.zig").View.fromWlrSurface(surface);
        var x: i32 = 0;
        var y: i32 = 0;
        if (view) |v| {
            const g = v.geometry();
            const xdg = wlr.XdgSurface.tryFromWlrSurface(surface);
            x = g.x - (if (xdg) |s| s.geometry.x else 0);
            y = g.y - (if (xdg) |s| s.geometry.y else 0);
        } else {
            const native_layer = wlr.LayerSurfaceV1.tryFromWlrSurface(surface) orelse return p.tree.node.setEnabled(false);
            const layer: *@import("layer.zig").LayerSurface = @ptrCast(@alignCast(native_layer.data orelse return p.tree.node.setEnabled(false)));
            _ = layer.scene.tree.node.coords(&x, &y);
        }
        const rect = e.native.current.cursor_rectangle;
        var px = x +| rect.x;
        var py = y +| rect.y +| rect.height;
        if (r.server.outputAt(x +| rect.x, y +| rect.y)) |output| {
            const box = output.box();
            const width = p.native.surface.current.width;
            const height = p.native.surface.current.height;
            px = std.math.clamp(px, box.x, @max(box.x, box.x +| box.width -| width));
            if (py +| height > box.y +| box.height) py = y +| rect.y -| height;
            py = std.math.clamp(py, box.y, @max(box.y, box.y +| box.height -| height));
        }
        p.tree.node.setEnabled(true);
        p.tree.node.setPosition(px, py);
        var relative = rect;
        relative.x = x +| rect.x -| px;
        relative.y = y +| rect.y -| py;
        p.native.sendTextInputRectangle(&relative);
    }
    fn onCommit(listener: *wl.Listener(*wlr.Surface), _: *wlr.Surface) void {
        const p: *Popup = @fieldParentPtr("commit", listener);
        p.position();
    }
    fn onDestroy(listener: *wl.Listener(void)) void {
        const p: *Popup = @fieldParentPtr("destroy", listener);
        p.destroy.link.remove();
        p.commit.link.remove();
        p.link.remove();
        p.tree.node.destroy();
        gpa.destroy(p);
    }
};
