local out = assert(io.open(assert(os.getenv("RAYWM_TEST_OUT")), "w"))
out:setvbuf("line")

local function describe(id)
  local v = raywm.view(id)
  if not v then return "stale" end
  return string.format("%s %dx%d+%d+%d", v.title, v.w, v.h, v.x, v.y)
end

return {
  api = 1,
  setup = function(ctx)
    out:write("setup outputs=", #raywm.outputs(), "\n")
    for _, ev in ipairs({ "view_map", "view_unmap", "view_focus", "view_title", "view_resized" }) do
      ctx.on(ev, function(id) out:write(ev, " ", id, " ", describe(id), "\n") end)
    end
    ctx.bind("Super+Return", function() end)
  end,
  teardown = function()
    out:write("teardown\n")
    out:close()
  end,
}
