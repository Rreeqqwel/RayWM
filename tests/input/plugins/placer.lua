-- Shortly after map (the test client is then acking configures): an
-- out-of-range move and place (must be clamped, not overflow), then two
-- places before the client acks: the second one must win.
return {
  api = 1,
  setup = function(ctx)
    ctx.on("view_map", function(id)
      ctx.timer(200, function()
        raywm.view_move(id, math.maxinteger >> 32, -(1 << 31))
        raywm.view_place(id, 2147483647, 2147483647, 2147483647, 2147483647)
        raywm.view_place(id, 100, 100, 300, 200)
        raywm.view_place(id, 100, 100, 200, 150) -- back to the current size
      end)
    end)
  end,
}
