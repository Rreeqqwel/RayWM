-- Creates timers without bound inside one callback.
return {
  api = 1,
  setup = function(ctx)
    ctx.on("view_map", function()
      for _ = 1, 100000 do ctx.cancel(ctx.timer(1000, function() end)) end
    end)
  end,
}
