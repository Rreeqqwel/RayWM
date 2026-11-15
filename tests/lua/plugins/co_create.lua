-- The budget must cover a coroutine started with coroutine.create.
return {
  api = 1,
  setup = function(ctx)
    ctx.on("view_title", function()
      coroutine.resume(coroutine.create(function() while true do end end))
    end)
  end,
  teardown = function() raywm.spawn("teardown:co_create") end,
}
