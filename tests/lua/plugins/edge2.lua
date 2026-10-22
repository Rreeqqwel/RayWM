-- Same binding as edge (registered later: edge wins), and a failing teardown.
return {
  api = 1,
  setup = function(ctx)
    ctx.bind("Super+Return", function() raywm.spawn("bind:edge2") end)
  end,
  teardown = function() error("teardown failed") end,
}
