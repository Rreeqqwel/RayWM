-- API additions of v0.2.0 (foundation): raywm.version, view metadata,
-- extra event arguments, view_floating, managed-state changes.
return {
  api = 1,
  setup = function(ctx)
    raywm.spawn("version:" .. tostring(raywm.version))
    local v = raywm.view(1)
    raywm.spawn(("meta:%s:%s:%d:%d:%s:%s:%d"):format(tostring(v.floating), tostring(v.fullscreen), v.parent,
      v.min_w, tostring(v.managed), tostring(v.xwayland), v.workspace))
    raywm.spawn("floating:" .. tostring(raywm.view_floating(1, true)))
    raywm.spawn("floatingstale:" .. tostring(raywm.view_floating(9, true)))
    raywm.spawn("fs:" .. tostring(raywm.view_fullscreen(1, true, 7)))
    raywm.spawn("fsdefault:" .. tostring(raywm.view_fullscreen(1, true)))
    raywm.spawn("max:" .. tostring(raywm.view_maximize(1, true)))
    raywm.spawn("badfs:" .. tostring((pcall(raywm.view_fullscreen, 1, true, "x"))))
    ctx.on("view_state", function(id, a, b, c)
      raywm.spawn(("state:%d:%s:%s:%s"):format(id, tostring(a), tostring(b), tostring(c)))
    end)
    ctx.on("view_new", function(id) ctx.manage(id) end)
    ctx.on("view_app_id", function(id) ctx.manage(id, false) end)
  end,
}
