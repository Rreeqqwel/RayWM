-- Keyboard focus navigation, independent of the layout (works with
-- dwindle and with floating windows):
--
--   Super+H/J/K/L        focus the window to the left/below/above/right
--   Super+Tab            focus the next window
--   Super+Shift+Tab      focus the previous window
--
-- plus an optional pointer warp and a border around the focused window.
--
-- Directional focus is geometric. From the focused window F, a window W is
-- a candidate for "right" if both of W's left and right edges lie further
-- right than F's (likewise for the other directions), so a window that
-- spans F or sits only above/below it is never "to the right". Among the
-- candidates, ones whose vertical extent overlaps F's (directly to the
-- right) always win over ones that are only diagonally to the right. Then,
-- in order: the smallest gap from F's edge, the smallest offset between
-- the centres (across the direction), the most recently focused, the
-- lowest id. Only visible windows on F's output are considered first; if
-- there is none in that direction, the nearest output in that direction
-- is used (cross_output), never an output in another direction. With no
-- candidate the focus stays where it is. Each key press costs O(n) for n
-- windows; nothing runs per frame or per pointer motion.
--
-- The cycle order is fixed and independent of focus history: outputs from
-- left to right (then top to bottom), and on each output the windows in
-- the order they were opened. It wraps around.

local options = {
  -- Key bindings per action; an empty list disables the action.
  keys = {
    left = { "Super+h" },
    down = { "Super+j" },
    up = { "Super+k" },
    right = { "Super+l" },
    next = { "Super+Tab" },
    prev = { "Super+Shift+Tab" },
  },
  -- Continue onto the next output in the same direction when the current
  -- output has no window there.
  cross_output = true,
  -- Move the pointer to the centre of the window chosen with these keys.
  -- Skipped when the focus did not change, when the pointer is already
  -- inside that window, while a mouse button is held or a window is being
  -- dragged, and while a launcher or lock screen holds the keyboard.
  warp = false,
  -- Border around the focused window. width = 0 disables it. color is
  -- "#rrggbb" or "#rrggbbaa".
  border = { width = 2, color = "#5294e2" },
}

-- Directions: p = primary axis (position, size), q = cross axis.
local axes = {
  left = { p = "x", ps = "w", q = "y", qs = "h", sign = -1 },
  right = { p = "x", ps = "w", q = "y", qs = "h", sign = 1 },
  up = { p = "y", ps = "h", q = "x", qs = "w", sign = -1 },
  down = { p = "y", ps = "h", q = "x", qs = "w", sign = 1 },
}

-- Sort key of rectangle r seen from rectangle c in direction d, or nil
-- if r does not lie in that direction. Smaller is better. Integers only.
local function score(c, r, d, strict)
  local a = axes[d]
  local c0, c1 = c[a.p], c[a.p] + c[a.ps]
  local r0, r1 = r[a.p], r[a.p] + r[a.ps]
  local gap
  if a.sign > 0 then
    if strict and not (r0 > c0 and r1 > c1) then return nil end
    gap = r0 - c1
  else
    if strict and not (r1 < c1 and r0 < c0) then return nil end
    gap = c0 - r1
  end
  if gap < 0 then gap = 0 end -- overlapping floating windows
  local q0, q1 = c[a.q], c[a.q] + c[a.qs]
  local s0, s1 = r[a.q], r[a.q] + r[a.qs]
  local overlap = math.min(q1, s1) - math.max(q0, s0)
  if overlap > 0 then
    -- Directly in that direction: nearest first, then best aligned
    -- (doubled centre offset, to stay in integers).
    return { 0, gap, math.abs((s0 + s1) - (q0 + q1)) }
  end
  -- Only diagonally: by the distance between the closest edges.
  return { 1, gap - overlap, gap }
end

local function better(a, b)
  for i = 1, #a do
    if a[i] ~= b[i] then return a[i] < b[i] end
  end
  return false
end

-- Visible windows: { [id] = view } and ids by recency (most recent first).
local function visible_views()
  local by_id, order = {}, {}
  for rank, id in ipairs(raywm.views()) do
    local v = raywm.view(id)
    if v and v.visible then
      v.rank = rank
      by_id[id] = v
      order[#order + 1] = id
    end
  end
  return by_id, order
end

-- Best window of `views` from rectangle c in direction d.
local function best_view(c, views, d, strict, skip)
  local best, best_key
  for id, v in pairs(views) do
    if id ~= skip then
      local s = score(c, v, d, strict)
      if s then
        s[#s + 1] = v.rank
        s[#s + 1] = id
        if not best_key or better(s, best_key) then best, best_key = id, s end
      end
    end
  end
  return best
end

-- The window directional focus would choose from `cur` (a view table) in
-- direction d, among `views`; nil if none. Exposed for tests.
local function pick(cur, views, d, outputs)
  local same = {}
  for id, v in pairs(views) do
    if cur.output == 0 or v.output == cur.output then same[id] = v end
  end
  local id = best_view(cur, same, d, true, cur.id)
  if id or not options.cross_output or cur.output == 0 then return id end
  -- The nearest output in that direction, judged like windows.
  local here
  for _, o in ipairs(outputs) do
    if o.id == cur.output then here = o end
  end
  if not here then return nil end
  local others = {}
  for _, o in ipairs(outputs) do
    if o.id ~= here.id then others[o.id] = { x = o.x, y = o.y, w = o.w, h = o.h, rank = 0 } end
  end
  local target = best_view(here, others, d, true)
  if not target then return nil end
  local there = {}
  for vid, v in pairs(views) do
    if v.output == target then there[vid] = v end
  end
  -- Every window there lies in that direction; take the one nearest to
  -- the edge we cross, best aligned with the current window.
  return best_view(cur, there, d, false, cur.id)
end

-- Ids in cycle order (see the top of this file). Exposed for tests.
local function cycle_order(views, outputs)
  local out_rank = {}
  local sorted = {}
  for _, o in ipairs(outputs) do sorted[#sorted + 1] = o end
  table.sort(sorted, function(a, b)
    if a.x ~= b.x then return a.x < b.x end
    if a.y ~= b.y then return a.y < b.y end
    return a.id < b.id
  end)
  for i, o in ipairs(sorted) do out_rank[o.id] = i end
  local ids = {}
  for id in pairs(views) do ids[#ids + 1] = id end
  table.sort(ids, function(a, b)
    local ra = out_rank[views[a].output] or math.huge
    local rb = out_rank[views[b].output] or math.huge
    if ra ~= rb then return ra < rb end
    return a < b
  end)
  return ids
end

local function inside(p, v)
  return p.x >= v.x and p.x < v.x + v.w and p.y >= v.y and p.y < v.y + v.h
end

-- Focuses `id` and, if enabled, warps the pointer to it.
local function go(id)
  local before = raywm.focused()
  if not id or id == before then return end
  raywm.view_focus(id)
  if raywm.focused() ~= id then return end -- refused (e.g. hidden meanwhile)
  if not options.warp then return end
  local v, p = raywm.view(id), raywm.pointer()
  if not v or p.busy or inside(p, v) then return end
  raywm.pointer_warp(v.x + v.w // 2, v.y + v.h // 2)
end

local function focus_dir(d)
  local views, order = visible_views()
  local cur = views[raywm.focused() or 0]
  -- Nothing focused: start from the most recently focused visible window.
  if not cur then return go(order[1]) end
  go(pick(cur, views, d, raywm.outputs()))
end

local function focus_cycle(step)
  local views = visible_views()
  local ids = cycle_order(views, raywm.outputs())
  if #ids == 0 then return end
  local focused, at = raywm.focused(), nil
  for i, id in ipairs(ids) do
    if id == focused then at = i end
  end
  if not at then return go(step > 0 and ids[1] or ids[#ids]) end
  go(ids[(at - 1 + step) % #ids + 1])
end

-- ---- focus border -----------------------------------------------------------

local bordered -- window that has the border

local function mark(id)
  if bordered and bordered ~= id then raywm.view_border(bordered, 0) end -- may be stale: fine
  bordered = nil
  local b = options.border
  if id ~= 0 and b.width > 0 and raywm.view_border(id, b.width, b.color) then bordered = id end
end

return {
  api = 1,
  setup = function(ctx)
    local actions = {
      left = function() focus_dir("left") end,
      down = function() focus_dir("down") end,
      up = function() focus_dir("up") end,
      right = function() focus_dir("right") end,
      next = function() focus_cycle(1) end,
      prev = function() focus_cycle(-1) end,
    }
    for action, keys in pairs(options.keys) do
      for _, k in ipairs(keys) do ctx.bind(k, assert(actions[action], "unknown action " .. action)) end
    end
    if raywm.view_border then
      ctx.on("view_focus", mark)
      mark(raywm.focused() or 0)
    end
  end,
  teardown = function()
    if bordered then raywm.view_border(bordered, 0) end
    bordered = nil
  end,
  -- For tests/focus_test.lua only.
  pick = pick,
  cycle_order = cycle_order,
  options = options,
}
