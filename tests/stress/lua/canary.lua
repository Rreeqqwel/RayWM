-- Lua torture: the plugin that must keep working while others fail.
-- Every event and timer tick is written to $RAYWM_STRESS_DIR/canary.log with
-- this Lua state's generation (one per load), so that a handler surviving a
-- reload (an older generation writing after a newer one started) shows up.
local dir = assert(os.getenv("RAYWM_STRESS_DIR"))
local name = "canary" -- copies get their own files (tests/stress/cat/lua.sh)
local gen = 0
do
  local f = io.open(dir .. "/" .. name .. "-gen", "r")
  if f then gen = tonumber(f:read("l") or "0") or 0; f:close() end
  f = assert(io.open(dir .. "/" .. name .. "-gen", "w")); f:write(gen + 1, "\n"); f:close()
  gen = gen + 1
end
local out = assert(io.open(dir .. "/" .. name .. ".log", "a"))
out:setvbuf("line")
out:write("gen ", gen, " start\n")
return {
  api = 1,
  setup = function(ctx)
    for _, ev in ipairs({ "view_map", "view_unmap", "view_focus" }) do
      ctx.on(ev, function(id) out:write("gen ", gen, " ", ev, " ", id, "\n") end)
    end
    local ticks = 0
    local function tick()
      ticks = ticks + 1
      out:write("gen ", gen, " tick ", ticks, "\n")
      ctx.timer(100, tick)
    end
    ctx.timer(100, tick)
    ctx.bind("Super+F9", function() out:write("gen ", gen, " key\n") end)
  end,
  teardown = function() out:write("gen ", gen, " teardown\n") end,
}
