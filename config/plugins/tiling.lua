-- Master/stack tiling: the first window takes the left half of the
-- output, the others share the right half. Windows keep their map order.
local gap = 8
local order = {} -- view ids in map order

local function index_of(id)
  for i, v in ipairs(order) do
    if v == id then return i end
  end
end

local function arrange()
  for _, out in ipairs(raywm.outputs()) do
    local ids = {}
    for _, id in ipairs(order) do
      local v = raywm.view(id)
      if v and v.output == out.id then ids[#ids + 1] = id end
    end
    local u, n = out.usable, #ids
    for i, id in ipairs(ids) do
      local x, y, w, h = u.x, u.y, u.w, u.h
      if n > 1 then
        w = u.w // 2
        if i > 1 then
          x = u.x + w
          w = u.w - w
          h = u.h // (n - 1)
          y = u.y + (i - 2) * h
          if i == n then h = u.h - (i - 2) * h end
        end
      end
      raywm.view_place(id, x + gap, y + gap, w - 2 * gap, h - 2 * gap)
    end
  end
end

local function focus_step(step)
  local cur = index_of(raywm.focused() or -1)
  if not cur or #order < 2 then return end
  raywm.view_focus(order[(cur - 1 + step) % #order + 1])
end

return {
  api = 1,
  setup = function(ctx)
    for _, id in ipairs(raywm.views()) do order[#order + 1] = id end
    ctx.on("view_map", function(id)
      order[#order + 1] = id
      arrange()
    end)
    ctx.on("view_unmap", function(id)
      local i = index_of(id)
      if i then table.remove(order, i) end
      arrange()
    end)
    ctx.on("layout", arrange)
    ctx.bind("Super+j", function() focus_step(1) end)
    ctx.bind("Super+k", function() focus_step(-1) end)
    -- Promote the focused window to master.
    ctx.bind("Super+Shift+Return", function()
      local i = index_of(raywm.focused() or -1)
      if i and i > 1 then
        table.insert(order, 1, table.remove(order, i))
        arrange()
      end
    end)
    arrange()
  end,
}
