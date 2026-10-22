-- setup fails: the plugin is rejected, and its teardown still runs.
return {
  api = 1,
  setup = function(ctx)
    ctx.bind("Super+Return", function() raywm.spawn("bind:badsetup") end)
    error("setup failed")
  end,
  teardown = function() raywm.spawn("teardown:badsetup") end,
}
