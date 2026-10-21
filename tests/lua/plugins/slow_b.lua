-- Uses roughly 60% of a 1M instruction budget per event.
return {
  api = 1,
  setup = function(ctx)
    ctx.on("view_map", function()
      local x = 0
      for i = 1, 300000 do x = x + i end
      raywm.spawn("slow_b")
    end)
  end,
}
