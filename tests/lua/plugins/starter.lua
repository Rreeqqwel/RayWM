return {
  api = 1,
  setup = function(ctx)
    raywm.startup(function() raywm.spawn("startup:2") end)
    ctx.on("layout", function()
      local ok = pcall(raywm.startup, function() end)
      raywm.spawn("late:" .. tostring(ok))
    end)
  end,
}
