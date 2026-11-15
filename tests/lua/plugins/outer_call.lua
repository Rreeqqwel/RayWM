return {
  api = 1,
  setup = function(ctx)
    ctx.on("view_title", function()
      raywm.view_focus(1)
      raywm.spawn("outer_after")
    end)
  end,
  teardown = function() raywm.spawn("teardown:outer_call") end,
}
