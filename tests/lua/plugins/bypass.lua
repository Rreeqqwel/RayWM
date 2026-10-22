-- Runaway loops that try to swallow the instruction-budget error.
-- Created before any budget runs out (at load time). The budget then runs
-- out in a *nested* coroutine, while this one keeps catching the error.
local early = coroutine.create(function()
  while true do
    pcall(function()
      coroutine.resume(coroutine.create(function() while true do end end))
      while true do end
    end)
  end
end)

return {
  api = 1,
  setup = function(ctx)
    ctx.on("view_title", function() coroutine.resume(early) end)
    ctx.on("view_map", function()
      while true do pcall(function() while true do end end) end
    end)
    ctx.on("view_unmap", function()
      while true do coroutine.resume(coroutine.create(function() while true do end end)) end
    end)
  end,
}
