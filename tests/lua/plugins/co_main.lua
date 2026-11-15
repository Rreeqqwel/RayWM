-- Runaway loop in a top-level callback: the baseline the coroutine cases
-- are compared against.
return {
  api = 1,
  setup = function(ctx) ctx.on("view_map", function() while true do end end) end,
  teardown = function() raywm.spawn("teardown:co_main") end,
}
