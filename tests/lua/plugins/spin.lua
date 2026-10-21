return {
  api = 1,
  setup = function(ctx) ctx.on("view_map", function() while true do end end) end,
  teardown = function() raywm.spawn("teardown:spin") end,
}
