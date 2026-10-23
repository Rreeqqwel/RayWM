-- Floating windows, for any layout plugin:
--
--   Super+Shift+Space    toggle the focused window between tiled and floating
--
-- Floating is window state kept by the core (raywm.view_floating), so it
-- survives raywm.reload() and layout plugins see it: dwindle stops tiling
-- a floating window and tiles it again when it stops floating. A window
-- floats at the place and size it last had while floating; the first time,
-- centred at the size it chose itself. Floating windows stay above tiled
-- ones and can be moved with Super + left drag and resized with
-- Super + right drag (or their own title bar and edges).
--
-- Window rules (window-rules.lua) decide which windows start floating.

local options = {
  keys = {
    toggle = { "Super+Shift+space" },
  },
}

local function toggle()
  local id = raywm.focused()
  local v = id and raywm.view(id)
  if v then raywm.view_floating(id, not v.floating) end
end

return {
  api = 1,
  setup = function(ctx)
    for _, k in ipairs(options.keys.toggle or {}) do ctx.bind(k, toggle) end
  end,
  -- For tests only.
  options = options,
  toggle = toggle,
}
