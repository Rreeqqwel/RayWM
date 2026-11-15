return {
  api = 1,
  setup = function(ctx)
    ctx.on("view_map", function()
      local x = 0
      for i = 1, 600000 do x = x + i end
      raywm.spawn("chain_b")
    end)
  end,
  teardown = function() raywm.spawn("teardown:chain_b") end,
}
