-- Fails on every view_map: unloaded each time, loaded again on reload.
return {
  api = 1,
  setup = function(ctx) ctx.on("view_map", function() error("crashy: expected failure") end) end,
}
