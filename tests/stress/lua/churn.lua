-- Lua torture: rapid registration churn. Every 2 ms it registers and
-- cancels handlers, timers, bindings, rectangles and animations; it also
-- leaves some registrations alive and cancels them later, and keeps at most
-- a bounded number. The core must stay within its registration cap and
-- release everything on reload.
local dir = assert(os.getenv("RAYWM_STRESS_DIR"))
local out = assert(io.open(dir .. "/churn.log", "a"))
out:setvbuf("line")
return {
  api = 1,
  setup = function(ctx)
    local live, rounds = {}, 0
    local keys = { "Super+F5", "Super+F6", "Super+F7", "Super+F8" }
    local function step()
      rounds = rounds + 1
      local ids = {}
      for i = 1, 20 do
        ids[#ids + 1] = ctx.on("view_focus", function() end)
        ids[#ids + 1] = ctx.timer(1000 + i, function() end)
      end
      ids[#ids + 1] = ctx.bind(keys[rounds % #keys + 1], function() end)
      local rect = ctx.rect and ctx.rect({ x = rounds % 500, y = 10, w = 20, h = 20, color = "#ff000080" })
      if rect then ids[#ids + 1] = rect end
      local v = raywm.views()[1]
      if v and ctx.animate then
        local a = ctx.animate(v, { duration = 30, x = 5, from_x = 0 })
        if a then ids[#ids + 1] = a end
      end
      -- Cancel all but a few; cancel the oldest survivors when too many.
      for i = 1, #ids - 2 do ctx.cancel(ids[i]) end
      live[#live + 1] = ids[#ids - 1]; live[#live + 1] = ids[#ids]
      while #live > 400 do ctx.cancel(table.remove(live, 1)) end
      -- Cancelling twice, and cancelling what is gone, must be harmless.
      ctx.cancel(ids[1]); ctx.cancel(123456789)
      if rounds % 100 == 0 then out:write("rounds ", rounds, " live ", #live, "\n") end
      ctx.timer(2, step)
    end
    ctx.timer(2, step)
  end,
}
