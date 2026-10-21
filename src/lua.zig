//! Lua plugin host (stage 2). Stage 1 only defines the interface the core uses.
const std = @import("std");
pub const c = @cImport({
    @cInclude("lua.h");
    @cInclude("lualib.h");
    @cInclude("lauxlib.h");
});

pub const Event = enum { view_map, view_unmap, view_focus, view_title, view_resized, output_add, output_remove, layout };

pub const Runtime = struct {
    pub fn emit(_: *Runtime, _: Event, _: u32) void {}
    pub fn frame(_: *Runtime, _: u32, _: std.posix.timespec) void {}
    pub fn key(_: *Runtime, _: u32, _: u32) bool {
        return false;
    }
    pub fn configured(_: *Runtime) bool {
        return false;
    }
    pub fn requestReload(_: *Runtime) void {}
};
