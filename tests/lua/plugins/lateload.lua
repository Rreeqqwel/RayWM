return {
  api = 1,
  setup = function(ctx)
    ctx.on("view_title", function() raywm.load("probe") end)
  end,
  teardown = function() raywm.spawn("teardown:lateload") end,
}
