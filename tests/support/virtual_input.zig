//! TEST-ONLY. Compiled into raywm only with `zig build -Dtest-input`.
//!
//! Exposes the wlroots virtual pointer and virtual keyboard protocols, so
//! tests/input.sh can drive real pointer and keyboard input inside an
//! isolated headless compositor. Release builds never contain this: any
//! client could otherwise inject input.
//!
//! Also: SIGUSR2 unplugs the output named in $XDG_RUNTIME_DIR/raywm-test-unplug,
//! so tests/screenshot.sh can remove an output while a capture is pending.
const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");

/// `add` hands a new input device to the compositor's normal input path.
pub fn install(comptime S: type, server: *S, wl_server: *wl.Server, comptime add: fn (*S, *wlr.InputDevice) void) !void {
    const State = struct {
        server: *S,
        new_pointer: wl.Listener(*wlr.VirtualPointerManagerV1.event.NewPointer) = .init(newPointer),
        new_keyboard: wl.Listener(*wlr.VirtualKeyboardV1) = .init(newKeyboard),
        pointer_mgr_destroy: wl.Listener(*wlr.VirtualPointerManagerV1) = .init(pointerMgrDestroy),
        keyboard_mgr_destroy: wl.Listener(*wlr.VirtualKeyboardManagerV1) = .init(keyboardMgrDestroy),

        fn newPointer(l: *wl.Listener(*wlr.VirtualPointerManagerV1.event.NewPointer), ev: *wlr.VirtualPointerManagerV1.event.NewPointer) void {
            const st: *@This() = @fieldParentPtr("new_pointer", l);
            add(st.server, &ev.new_pointer.pointer.base);
        }
        fn newKeyboard(l: *wl.Listener(*wlr.VirtualKeyboardV1), kb: *wlr.VirtualKeyboardV1) void {
            const st: *@This() = @fieldParentPtr("new_keyboard", l);
            add(st.server, &kb.keyboard.base);
        }
        // wlroots asserts that no listeners remain when a manager is destroyed.
        fn pointerMgrDestroy(l: *wl.Listener(*wlr.VirtualPointerManagerV1), _: *wlr.VirtualPointerManagerV1) void {
            const st: *@This() = @fieldParentPtr("pointer_mgr_destroy", l);
            st.new_pointer.link.remove();
            st.pointer_mgr_destroy.link.remove();
        }
        fn unplugOutput(_: c_int, srv: *S) c_int {
            var path: [4096]u8 = undefined;
            const dir = std.c.getenv("XDG_RUNTIME_DIR") orelse return 0;
            const p = std.fmt.bufPrintZ(&path, "{s}/raywm-test-unplug", .{dir}) catch return 0;
            const fd = std.c.open(p, .{});
            if (fd < 0) return 0;
            defer _ = std.c.close(fd);
            var buf: [64]u8 = undefined;
            const n = std.c.read(fd, &buf, buf.len);
            if (n <= 0) return 0;
            const name = std.mem.trimEnd(u8, buf[0..@intCast(n)], "\n");
            var it = srv.outputs.iterator(.forward);
            while (it.next()) |o| if (std.mem.eql(u8, std.mem.span(o.wlr_output.name), name)) {
                std.log.warn("TEST BUILD: unplugging output {s}", .{name});
                o.wlr_output.destroy();
                return 0;
            };
            return 0;
        }
        fn keyboardMgrDestroy(l: *wl.Listener(*wlr.VirtualKeyboardManagerV1), _: *wlr.VirtualKeyboardManagerV1) void {
            const st: *@This() = @fieldParentPtr("keyboard_mgr_destroy", l);
            st.new_keyboard.link.remove();
            st.keyboard_mgr_destroy.link.remove();
        }
    };
    // Lives for the rest of the process (the managers die with the display).
    const st = try std.heap.c_allocator.create(State);
    st.* = .{ .server = server };
    const pointer_mgr = try wlr.VirtualPointerManagerV1.create(wl_server);
    const keyboard_mgr = try wlr.VirtualKeyboardManagerV1.create(wl_server);
    pointer_mgr.events.new_virtual_pointer.add(&st.new_pointer);
    pointer_mgr.events.destroy.add(&st.pointer_mgr_destroy);
    keyboard_mgr.events.new_virtual_keyboard.add(&st.new_keyboard);
    keyboard_mgr.events.destroy.add(&st.keyboard_mgr_destroy);
    // The source lives as long as the event loop, like the managers.
    _ = try wl_server.getEventLoop().addSignal(*S, @intFromEnum(std.posix.SIG.USR2), State.unplugOutput, server);
    std.log.warn("TEST BUILD: virtual pointer/keyboard protocols are enabled", .{});
}
