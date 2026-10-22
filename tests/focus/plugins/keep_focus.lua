-- Re-focuses the previously focused window whenever a new one maps. The
-- core must respect this explicit choice and not focus the new window.
return {
  api = 1,
  setup = function(ctx)
    ctx.on("view_map", function()
      local prev = raywm.focused()
      if prev then raywm.view_focus(prev) end
    end)
  end,
}
