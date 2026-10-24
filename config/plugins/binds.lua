-- Basic key bindings. Keys use the unshifted keysym name, so the binding
-- for Shift+1 is written "Super+Shift+1".
-- raywm.conf [general] terminal (RayWM 0.2.2), else $TERMINAL, else foot.
local configured = raywm.settings and raywm.settings.general.terminal
local terminal = (configured and configured ~= "" and configured) or os.getenv("TERMINAL") or "foot"

-- Toggles a state of the focused window with a raywm.view_* function.
local function toggle(field, set)
  return function()
    local id = raywm.focused()
    local v = id and raywm.view(id)
    if v then set(id, not v[field]) end
  end
end

-- Minimized windows, in the order they were minimized (by Super+n, by
-- their own button, or by a taskbar).
local minimized = {}

local function forget(id)
  for i = #minimized, 1, -1 do
    if minimized[i] == id then table.remove(minimized, i) end
  end
end

local function remember(id)
  forget(id)
  minimized[#minimized + 1] = id
end

local function shown(v)
  local w = v.workspace ~= 0 and raywm.workspace and raywm.workspace(v.workspace)
  return v.workspace == 0 or (w and w.active)
end

-- Restores the most recently minimized window of the shown workspaces.
local function restore()
  for i = #minimized, 1, -1 do
    local id = minimized[i]
    local v = raywm.view(id)
    if v and v.minimized and shown(v) then
      table.remove(minimized, i)
      raywm.view_minimize(id, false)
      raywm.view_focus(id)
      return
    end
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
    if raywm.view_minimize then -- RayWM 0.2.0
      -- After a reload: windows that are still minimized.
      for _, id in ipairs(raywm.views()) do
        local v = raywm.view(id)
        if v and v.minimized then remember(id) end
      end
      ctx.on("view_state", function(id)
        local v = raywm.view(id)
        if v and v.minimized then
          if minimized[#minimized] ~= id then remember(id) end
        else
          forget(id)
        end
      end)
      ctx.on("view_unmap", forget)
      ctx.bind("Super+n", function()
        local id = raywm.focused()
        if id then raywm.view_minimize(id, true) end
      end)
      ctx.bind("Super+Shift+n", restore)
    end
  end,
}
