-- Super+F12 starts 3 s of geometry changes every 2 ms on the focused window
-- (a floating one: it is released from dwindle first).
return {
  api = 1,
  setup = function(ctx)
    ctx.bind("Super+F12", function()
      local id = raywm.focused()
      if not id then return end
      ctx.manage(id, false)
      local n = 0
      local function step()
        n = n + 1
        if n > 1500 then return end
        raywm.view_place(id, 100 + n % 300, 100 + n % 200, 200 + n % 100, 150 + n % 80)
        ctx.timer(2, step)
      end
      step()
    end)
  end,
}
