return {
  api = 1,
  setup = function(ctx)
    assert(ctx.rect({ x = 1, y = 2, w = 10, h = 20, color = "#ff0000" }))
    assert(ctx.animate(1, { from_opacity = 0, duration = 100 }))
    ctx.on("view_map", function() error("resource fault") end)
  end,
}
