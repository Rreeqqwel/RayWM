-- Optional visual API example: an input-transparent marker per output.
-- Load after focus/layout plugins. Every rectangle belongs to this plugin.
local options = { size = 8, margin = 12, active = "#80c0ff", idle = "#666666" }
return {
  api = 1,
  setup = function(ctx)
    assert(ctx.rect, "focus-indicator requires RayWM 0.2")
    local markers = {}
    local function refresh()
      local focused = raywm.focused()
      local view = focused and raywm.view(focused)
      local present = {}
      for _, output in ipairs(raywm.outputs()) do
        present[output.id] = true
        local shape = {
          x = output.x + output.w - options.margin - options.size,
          y = output.y + options.margin, w = options.size, h = options.size,
          color = view and view.output == output.id and options.active or options.idle,
        }
        if markers[output.id] then
          ctx.rect_update(markers[output.id], shape)
        else
          markers[output.id] = ctx.rect(shape)
        end
      end
      for id, marker in pairs(markers) do
        if not present[id] then ctx.cancel(marker); markers[id] = nil end
      end
    end
    for _, event in ipairs({"view_focus", "layout", "output_add", "output_remove"}) do
      ctx.on(event, refresh)
    end
    refresh()
  end,
}
