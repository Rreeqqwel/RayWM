-- Basic key bindings. Keys use the unshifted keysym name, so the binding
-- for Shift+1 is written "Super+Shift+1".
local terminal = os.getenv("TERMINAL") or "foot"

return {
  api = 1,
  setup = function(ctx)
    ctx.bind("Super+Return", function() raywm.spawn(terminal) end)
    ctx.bind("Super+q", function()
      local id = raywm.focused()
      if id then raywm.view_close(id) end
    end)
    ctx.bind("Super+Shift+r", raywm.reload)
    ctx.bind("Super+Shift+e", raywm.quit)
  end,
}
