-- Runaway loops that try to swallow the instruction-budget error.
return {
  api = 1,
  setup = function(ctx)
    ctx.on("view_map", function()
      while true do pcall(function() while true do end end) end
    end)
    ctx.on("view_unmap", function()
      while true do coroutine.resume(coroutine.create(function() while true do end end)) end
    end)
  end,
}
