-- ~60% of a 2M budget, then synchronously emits view_focus.
return {
  api = 1,
  setup = function(ctx)
    ctx.on("view_title", function()
      local x = 0
      for i = 1, 600000 do x = x + i end
      raywm.view_focus(1)
    end)
  end,
  teardown = function() raywm.spawn("teardown:outer_hog") end,
}
