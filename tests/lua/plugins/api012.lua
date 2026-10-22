-- API additions of v0.1.2: pointer, pointer_warp, view_border, view().visible.
return {
  api = 1,
  setup = function(ctx)
    local p = raywm.pointer()
    raywm.spawn(("pointer:%d,%d,%s"):format(p.x, p.y, tostring(p.busy)))
    raywm.spawn("warp:" .. tostring(raywm.pointer_warp(5, 6)))
    local ok, why = raywm.pointer_warp(-1, 0)
    raywm.spawn("warpfail:" .. tostring(ok) .. ":" .. tostring(why))
    raywm.spawn("visible:" .. tostring(raywm.view(1).visible))
    raywm.spawn("border:" .. tostring(raywm.view_border(1, 2, "#ff000080")))
    raywm.spawn("noborder:" .. tostring(raywm.view_border(1, 0)))
    raywm.spawn("staleborder:" .. tostring(raywm.view_border(7, 1, "#000000")))
    -- Bad arguments are errors in the caller (caught here).
    for _, bad in ipairs({ { 65, "#000000" }, { -1, "#000000" }, { 2, "red" }, { 2, "#12345" }, { 2, nil }, { 2, "#gg0000" } }) do
      raywm.spawn("bad:" .. tostring((pcall(raywm.view_border, 1, bad[1], bad[2]))))
    end
    raywm.spawn("badwarp:" .. tostring((pcall(raywm.pointer_warp, "x", 1))))
  end,
}
