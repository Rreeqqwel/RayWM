return {
  api = 1,
  setup = function(ctx)
    ctx.on("view_map", function()
      local total = 0
      for i = 1, 6000000 do total = total + i end
      raywm.spawn("over-default-budget")
    end)
  end,
}
