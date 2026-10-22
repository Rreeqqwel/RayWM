-- Pointer-test layout: the n-th window to map is moved to
-- (100 + 400 * (n - 1), 100), so 200x150 windows sit side by side:
-- A 100..300, B 500..700, C 900..1100, D 1300..1500 (on a second output).
-- Super+F10 moves the first window 300 px to the right and Super+F9 moves
-- the second one to (100, 150): the scene changes under a held button.
local order = {}

return {
  api = 1,
  setup = function(ctx)
    ctx.on("view_map", function(id)
      order[#order + 1] = id
      raywm.view_move(id, 100 + 400 * (#order - 1), 100)
    end)
    ctx.bind("Super+F10", function()
      local v = order[1] and raywm.view(order[1])
      if v then raywm.view_move(v.id, v.x + 300, v.y) end
    end)
    ctx.bind("Super+F9", function()
      if order[2] then raywm.view_move(order[2], 100, 150) end
    end)
  end,
}
