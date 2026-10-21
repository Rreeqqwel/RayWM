return {
  api = 1,
  setup = function(ctx)
    ctx.on("view_map", function() error("boom") end)
    ctx.bind("Super+x", function() end)
  end,
  teardown = function() raywm.spawn("teardown:crashy") end,
}
