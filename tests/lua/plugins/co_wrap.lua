-- coroutine.wrap returns a function: the hidden thread must be armed before
-- the first call, and the wrapper must keep resume's error behaviour.
return {
  api = 1,
  setup = function(ctx)
    ctx.on("view_app_id", function()
      local run = coroutine.wrap(function() while true do end end)
      run()
    end)
  end,
  teardown = function() raywm.spawn("teardown:co_wrap") end,
}
