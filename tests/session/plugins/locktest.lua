-- Records what plugins see while the session is locked, in
-- $XDG_RUNTIME_DIR/locktest.log.
local out = assert(io.open(os.getenv("XDG_RUNTIME_DIR") .. "/locktest.log", "a"))
out:setvbuf("line")
return {
  api = 1,
  setup = function(ctx)
    ctx.on("session_lock", function()
      local before = raywm.focused()
      for _, id in ipairs(raywm.views()) do raywm.view_focus(id) end
      out:write(("lock locked=%s focus_kept=%s\n"):format(tostring(raywm.locked()), tostring(raywm.focused() == before)))
      local ok, why = raywm.pointer_warp(10, 10)
      out:write(("warp %s %s\n"):format(tostring(ok), tostring(why)))
    end)
    ctx.on("session_unlock", function()
      out:write(("unlock locked=%s\n"):format(tostring(raywm.locked())))
    end)
  end,
  teardown = function() out:close() end,
}
