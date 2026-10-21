return {
  api = 1,
  setup = function(ctx)
    local second
    ctx.on("view_unmap", function()
      raywm.spawn("first")
      raywm.spawn("cancel:" .. tostring(ctx.cancel(second)))
    end)
    second = ctx.on("view_unmap", function() raywm.spawn("second") end)
  end,
}
