-- Exercises ctx.manage. View 1 plays a tiled window, view 2 a floating one.
return {
  api = 1,
  setup = function(ctx)
    local ok, err = ctx.manage(999)
    raywm.spawn("manage999:" .. tostring(ok) .. ":" .. tostring(err))
    ctx.on("layout", function() raywm.spawn("manage1:" .. tostring(ctx.manage(1))) end)
    ctx.on("view_title", function() ctx.manage(1, false) end)
    ctx.on("view_resized", function() error("die") end)
  end,
}
