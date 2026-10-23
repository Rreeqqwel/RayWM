local ctx, rect, animation
local function rectangle(color)
  return { x = 550, y = 300, w = 60, h = 60, color = color }
end
return {
  api = 1,
  setup = function(context)
    ctx = context
    rect = assert(ctx.rect(rectangle("#ff0000")))
    ctx.bind("Super+F7", function() assert(ctx.rect_update(rect, rectangle("#00ff00"))) end)
    ctx.bind("Super+F8", function() assert(ctx.cancel(rect)); rect = nil end)
    ctx.bind("Super+F9", function()
      animation = assert(ctx.animate(assert(raywm.focused()), { x = 200, opacity = 0, duration = 800, easing = "linear" }))
    end)
    ctx.bind("Super+F10", function() assert(ctx.cancel(animation)); animation = nil end)
    ctx.bind("Super+t", function()
      animation = assert(ctx.animate(assert(raywm.focused()), { duration = 200 }))
    end)
    ctx.on("view_map", function(id)
      -- A view-owned shape is released even if this plugin retains its id.
      local shape = assert(ctx.rect({ view = id, x = -10, y = 0, w = 5, h = 30, color = "#334455" }))
      ctx.on("view_unmap", function(gone)
        if gone == id then
          local ok, why = ctx.rect_update(shape, rectangle("#ffffff"))
          assert(ok == nil and why == "stale")
        end
      end)
    end)
    -- Invalid numeric values must remain Lua errors.
    assert(not pcall(ctx.animate, 1, { x = 0/0 }))
    assert(not pcall(ctx.animate, 1, { duration = -1 }))
    assert(not pcall(ctx.rect, { color = "broken" }))
  end,
}
