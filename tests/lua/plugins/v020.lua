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
    -- Outputs (configuration through the host; the fake logs it).
    raywm.output_configure("FAKE-1", { mode = "2560x1440@143.97", scale = 1.5, transform = "90", position = { 10, 20 } })
    raywm.output_configure(1, { mode = { w = 1920, h = 1080, refresh = 60 }, position = "auto" })
    raywm.output_configure(1, { mode = "1280x720" })
    local ok, why = raywm.output_configure("NOPE", { scale = 2 })
    raywm.spawn("outstale:" .. tostring(ok) .. ":" .. tostring(why))
    ok, why = raywm.output_configure(1, { enabled = false })
    raywm.spawn("outlast:" .. tostring(ok) .. ":" .. tostring(why))
    raywm.spawn("badmode:" .. tostring((pcall(raywm.output_configure, 1, { mode = "huge" }))))
    raywm.spawn("badpos:" .. tostring((pcall(raywm.output_configure, 1, { position = "left" }))))
    local modes = raywm.output_modes(1)
    raywm.spawn(("modes:%d:%dx%d@%d:%s"):format(#modes, modes[1].w, modes[1].h, modes[1].refresh, tostring(modes[1].preferred)))
    raywm.spawn("modesstale:" .. tostring(raywm.output_modes(9)))
    local all = raywm.outputs({ all = true })
    raywm.spawn(("outputs:%d:%s:%s"):format(#all, all[1].name, tostring(all[1].enabled)))
    ctx.on("view_state", function(id, a, b, c)
      raywm.spawn(("state:%d:%s:%s:%s"):format(id, tostring(a), tostring(b), tostring(c)))
    end)
    ctx.on("view_new", function(id) ctx.manage(id) end)
    ctx.on("view_app_id", function(id) ctx.manage(id, false) end)
  end,
}
