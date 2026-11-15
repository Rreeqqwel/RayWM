-- About 60% of a 2M budget; the second handler must not get a fresh one.
return {
  api = 1,
  setup = function(ctx)
    ctx.on("view_map", function()
      local x = 0
      for i = 1, 600000 do x = x + i end
      raywm.spawn("chain_a")
    end)
  end,
  teardown = function() raywm.spawn("teardown:chain_a") end,
}
