//! Calls into C with a `bool` argument.
//!
//! Zig 0.16.0's LLVM backend passes `bool` arguments of extern functions
//! without zero extension (https://codeberg.org/ziglang/zig/issues/35373,
//! fixed for Zig 0.17): C may receive a byte such as 0xfe for `false` and
//! read it as true. Debug builds produce such bytes for `!x`, optimized
//! builds for bools taken out of packed structs.
//!
//! Until RayWM requires Zig 0.17, a bool that is not a constant is never
//! passed to C directly: `call` branches on it and passes a constant in
//! each arm. tests/lint.sh flags direct calls with other arguments.

/// `f(args..., on)`, with `on` passed as a constant. `f` takes the bool as
/// its last parameter (true of every wlroots setter RayWM uses).
pub inline fn call(on: bool, comptime f: anytype, args: anytype) ReturnOf(f) {
    return if (on) @call(.auto, f, args ++ .{true}) else @call(.auto, f, args ++ .{false});
}

fn ReturnOf(comptime f: anytype) type {
    return @typeInfo(@TypeOf(f)).@"fn".return_type.?;
}
