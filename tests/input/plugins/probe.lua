-- Input-test probe: Super+F12 (sent by the virtual keyboard) appends the
-- geometry and focus of every window to $RAYWM_TEST_OUT.
-- Appends, and keeps numbering dumps across raywm.reload() (which runs
-- this file again).
local path = assert(os.getenv("RAYWM_TEST_OUT"))
local n = 0
local old = io.open(path, "r")
if old then
  for line in old:lines() do
    if line:match("^dump %d+$") then n = n + 1 end
  end
  old:close()
end
local out = assert(io.open(path, "a"))
out:setvbuf("line")

return {
  api = 1,
  setup = function(ctx)
    -- Declares the focused window managed (e.g. in the middle of a drag).
    ctx.bind("Super+F11", function()
      local id = raywm.focused()
      if id then ctx.manage(id) end
    end)
    ctx.bind("Super+F12", function()
      n = n + 1
      out:write("dump ", n, "\n")
      local ids = raywm.views()
      table.sort(ids)
      for _, id in ipairs(ids) do
        local v = raywm.view(id)
        out:write(string.format("view %d %d,%d %dx%d focused=%s\n", id, v.x, v.y, v.w, v.h, tostring(v.focused)))
        -- v0.2.0 state, on its own line so older expectations still match.
        out:write(string.format("state %d floating=%s fullscreen=%s maximized=%s visible=%s managed=%s ws=%d output=%d\n",
          id, tostring(v.floating), tostring(v.fullscreen), tostring(v.maximized), tostring(v.visible),
          tostring(v.managed), v.workspace or 0, v.output or 0))
      end
    end)
  end,
  teardown = function() out:close() end,
}
