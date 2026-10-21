return {
  api = 1,
  setup = function(ctx)
    raywm.spawn("setup:probe")
    ctx.on("view_map", function(id) raywm.spawn("map:" .. id) end)
    ctx.bind("Super+Return", function() raywm.spawn("bind") end)
    ctx.on("layout", function()
      local v, e = raywm.view(999)
      local ok, e2 = raywm.view_move(999, 0, 0)
      raywm.spawn("stale:" .. tostring(v) .. ":" .. e .. ":" .. tostring(ok) .. ":" .. e2)
      local info = raywm.view(1)
      raywm.spawn("view1:" .. info.title .. ":" .. info.w .. ":" .. tostring(info.focused))
    end)
    ctx.on("output_add", function() ctx.timer(10, function() raywm.spawn("timer") end) end)
  end,
  teardown = function() raywm.spawn("teardown:probe") end,
}
