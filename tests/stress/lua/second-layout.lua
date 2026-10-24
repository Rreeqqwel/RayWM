-- Lua torture: a second layout fighting dwindle over the same windows. It
-- manages every window it sees, places it in a cascade, and toggles
-- ctx.manage off and on; it also binds dwindle's keys (duplicate bindings).
local n = 0
return {
  api = 1,
  setup = function(ctx)
    ctx.bind("Super+h", function() end)
    ctx.bind("Super+Shift+h", function() end)
    local function grab(id)
      n = n + 1
      if ctx.manage(id) then raywm.view_place(id, 40 * (n % 10), 30 * (n % 10), 300, 200) end
    end
    ctx.on("view_map", grab)
    local flip = false
    local function tick()
      flip = not flip
      for _, id in ipairs(raywm.views()) do
        if flip then ctx.manage(id, false) else grab(id) end
      end
      ctx.timer(15, tick)
    end
    ctx.timer(15, tick)
  end,
}
