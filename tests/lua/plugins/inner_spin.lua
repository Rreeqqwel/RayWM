return {
  api = 1,
  setup = function(ctx) ctx.on("view_focus", function() while true do end end) end,
  teardown = function() raywm.spawn("teardown:inner_spin") end,
}
