return {
  api = 1,
  setup = function(ctx)
    ctx.bind("Super+J", function()
      local f = assert(io.open(assert(os.getenv("RAYWM_TEST_OUT")), "a"))
      f:write("capture binding\n")
      f:close()
    end)
    ctx.bind("Super+W", function() raywm.pointer_warp(10, 10) end)
  end,
}
