-- Lua torture: one plugin per failure mode, chosen by its file name
-- (failing_<mode>.lua: a copy of this file with @MODE@ replaced). Each records "<mode> alive"
-- in $RAYWM_STRESS_DIR/failing.log from every callback it registered, so a
-- callback that still runs after the core unloaded the plugin is caught.
local dir = assert(os.getenv("RAYWM_STRESS_DIR"))
local mode = "@MODE@" -- substituted per copy by tests/stress/cat/lua.sh
local out = assert(io.open(dir .. "/failing.log", "a"))
out:setvbuf("line")
local function alive(what) out:write(mode, " alive ", what, "\n") end

local function spin() local x = 0 while true do x = x + 1 end end
local function hog() local t = {} for i = 1, 1e9 do t[i] = string.rep("x", 1024) .. i end end
local function deep(n) return deep(n + 1) + 1 end
local function boom(kind)
  if kind == "error" then error("torture: expected failure") end
  if kind == "table_error" then error({ code = 42 }) end
  if kind == "nil_error" then error(nil) end
  if kind == "spin" then spin() end
  if kind == "hog" then hog() end
  if kind == "stack" then deep(1) end
  if kind == "pcall_spin" then while true do pcall(spin) end end
  if kind == "coroutine_spin" then
    while true do local co = coroutine.create(spin); coroutine.resume(co) end
  end
  if kind == "gc_error" then
    setmetatable({}, { __gc = function() error("torture: error in __gc") end })
    collectgarbage("collect")
    error("torture: after __gc")
  end
  if kind == "bad_api" then raywm.view_place("x", {}, nil) end
  if kind == "bad_bind" then return "bad_bind" end
end

local where, kind = mode:match("^([a-z]+)_(.+)$")
if where == "load" then boom(kind) end
return {
  api = 1,
  setup = function(ctx)
    if where == "setup" then
      if kind == "bad_bind" then ctx.bind("Super+NoSuchKey+", function() end) end
      boom(kind)
    end
    ctx.on("view_map", function(id)
      alive("view_map")
      if where == "event" then boom(kind) end
    end)
    ctx.on("view_focus", function() alive("view_focus") end)
    local function tick()
      alive("timer")
      if where == "timer" then boom(kind) end
      ctx.timer(20, tick)
    end
    ctx.timer(20, tick)
  end,
  teardown = function()
    out:write(mode, " teardown\n")
    if where == "teardown" then boom(kind) end
  end,
}
