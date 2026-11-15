-- Innocent nested handler: it is not the one that hoarded the budget.
return {
  api = 1,
  setup = function(ctx)
    ctx.on("view_focus", function()
      local x = 0
      for i = 1, 600000 do x = x + i end
      raywm.spawn("inner_done")
    end)
  end,
  teardown = function() raywm.spawn("teardown:inner_busy") end,
}
