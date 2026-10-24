-- Precompiled (binary) chunks are refused by every loader: Lua does not
-- check them, and a damaged one crashed the compositor (tests/stress lua
-- bytecode). Text chunks keep working, with and without an environment.
local bin = string.dump(function() return { api = 1, setup = function() end } end)
local function refused(err) return tostring(err and tostring(err):find("binary chunk", 1, true) ~= nil) end

local fn, err = load(bin)
raywm.spawn("load:" .. tostring(fn) .. ":" .. refused(err))
fn, err = load(bin, "explicit", "b")
raywm.spawn("loadb:" .. tostring(fn) .. ":" .. refused(err))

local path = os.tmpname()
local f = assert(io.open(path, "wb")); f:write(bin); f:close()
fn, err = loadfile(path)
raywm.spawn("loadfile:" .. tostring(fn) .. ":" .. refused(err))
fn, err = loadfile(path, "bt")
raywm.spawn("loadfilebt:" .. tostring(fn) .. ":" .. refused(err))
local ok, derr = pcall(dofile, path)
raywm.spawn("dofile:" .. tostring(ok) .. ":" .. refused(derr))
local dirname, base = path:match("^(.*)/([^/]+)$")
package.path = dirname .. "/?"
ok, derr = pcall(require, base)
raywm.spawn("require:" .. tostring(ok) .. ":" .. refused(derr))
os.remove(path)

-- A binary plugin file is refused like a broken one.
local plugin = raywm.config_dir .. "/plugins/binplugin.lua"
f = assert(io.open(plugin, "wb")); f:write(bin); f:close()
local loaded, lerr = raywm.load("binplugin")
os.remove(plugin)
raywm.spawn("plugin:" .. tostring(loaded) .. ":" .. refused(lerr))

-- Text still works.
raywm.spawn("text:" .. load("return 1 + 1")())
raywm.spawn("env:" .. load("return x", "n", "t", { x = 5 })())
-- An explicit nil environment is passed on (the chunk then fails to read globals).
raywm.spawn("envnil:" .. tostring(pcall(load("return print", "n", "t", nil))))
