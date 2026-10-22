-- Input-test probe: Super+F12 (sent by the virtual keyboard) appends the
-- geometry and focus of every window to $RAYWM_TEST_OUT.
local out = assert(io.open(assert(os.getenv("RAYWM_TEST_OUT")), "w"))
out:setvbuf("line")
local n = 0

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
      end
    end)
  end,
  teardown = function() out:close() end,
}
