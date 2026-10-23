-- Optional native scene transitions. No timers or per-frame Lua callbacks.
local options = { duration = 180, distance = 24, easing = "out_quad" }
local function incoming(ctx, id)
  local v = raywm.view(id)
  if v and not v.fullscreen then
    ctx.animate(id, { from_y = options.distance, from_opacity = 0,
      duration = options.duration, easing = options.easing })
  end
end
return {
  api = 1,
  options = options,
  setup = function(ctx)
    assert(ctx.animate, "animations require RayWM 0.2")
    ctx.on("view_map", function(id) incoming(ctx, id) end)
    ctx.on("view_will_unmap", function(id)
      ctx.animate(id, { snapshot = true, y = -options.distance, opacity = 0,
        duration = options.duration, easing = options.easing })
    end)
    ctx.on("workspace_will_activate", function(_, old)
      for _, id in ipairs(raywm.views()) do
        local v = raywm.view(id)
        if v and v.workspace == old and v.visible then
          ctx.animate(id, { snapshot = true, x = -options.distance, opacity = 0,
            duration = options.duration, easing = options.easing })
        end
      end
    end)
    ctx.on("workspace_activate", function(workspace)
      for _, id in ipairs(raywm.views()) do
        local v = raywm.view(id)
        if v and v.workspace == workspace and v.visible then incoming(ctx, id) end
      end
    end)
  end,
}
