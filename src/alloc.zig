//! The allocator of the compositor and the Lua host. Normally libc malloc.
//! TEST ONLY: `zig build -Dleak-check` uses std.heap.DebugAllocator instead,
//! which reports double frees, fills freed memory so that use-after-free
//! shows up, and lists every allocation still alive at exit (see
//! `finish`, called by main after full teardown). Never distribute it.
const std = @import("std");
const options = @import("alloc_options");

pub const leak_check = options.leak_check;

var debug: std.heap.DebugAllocator(.{ .stack_trace_frames = 10 }) = .init;

pub const gpa: std.mem.Allocator = if (leak_check) debug.allocator() else std.heap.c_allocator;

/// After everything was freed: false (and a log of each leak) if memory is
/// still allocated. Always true without -Dleak-check.
pub fn finish() bool {
    if (!leak_check) return true;
    return debug.deinit() == .ok;
}
