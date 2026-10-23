-- Basic key bindings. Keys use the unshifted keysym name, so the binding
-- for Shift+1 is written "Super+Shift+1".
local terminal = os.getenv("TERMINAL") or "foot"

-- Toggles a state of the focused window with a raywm.view_* function.
local function toggle(field, set)
  return function()
    local id = raywm.focused()
    local v = id and raywm.view(id)
    if v then set(id, not v[field]) end
  end
end

return {
  api = 1,
  setup = function(ctx)
    ctx.bind("Super+Return", function() raywm.spawn(terminal) end)
    ctx.bind("Super+q", function()
      local id = raywm.focused()
      if id then raywm.view_close(id) end
    end)
    ctx.bind("Ctrl+Alt+r", raywm.reload)
    ctx.bind("Super+Shift+r", raywm.reload) -- alternative
    ctx.bind("Super+Shift+e", raywm.quit)
    if raywm.view_fullscreen then -- RayWM 0.2.0
      ctx.bind("Super+f", toggle("fullscreen", raywm.view_fullscreen))
      ctx.bind("Super+m", toggle("maximized", raywm.view_maximize))
    end
  end,
}
