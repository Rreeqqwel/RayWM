const std = @import("std");
pub const c = @cImport({
    @cInclude("lua.h");
    @cInclude("lualib.h");
    @cInclude("lauxlib.h");
});

test "lua 5.4 links and runs" {
    const L = c.luaL_newstate() orelse return error.OutOfMemory;
    defer c.lua_close(L);
    c.luaL_openlibs(L);
    try std.testing.expectEqual(@as(c_int, c.LUA_OK), c.luaL_loadstring(L, "return 40 + 2"));
    try std.testing.expectEqual(@as(c_int, c.LUA_OK), c.lua_pcallk(L, 0, 1, 0, 0, null));
    try std.testing.expectEqual(@as(c.lua_Integer, 42), c.lua_tointegerx(L, -1, null));
    try std.testing.expectEqual(@as(c.lua_Number, 504), c.LUA_VERSION_NUM);
}
