-- A nested coroutine must not escape the hook of its parent.
return {
  api = 1,
  setup = function(ctx)
    ctx.on("view_resized", function()
      coroutine.resume(coroutine.create(function()
        coroutine.resume(coroutine.create(function() while true do end end))
      end))
    end)
  end,
  teardown = function() raywm.spawn("teardown:co_nested") end,
}
