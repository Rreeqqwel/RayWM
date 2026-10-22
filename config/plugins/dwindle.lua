-- Dwindle tiling, in the spirit of Hyprland.
--
-- Each output has a binary tree. A leaf holds one window. A split node
-- holds a direction ("h": side by side, "v": stacked), a ratio and two
-- children. A new window splits the focused window's leaf (or the last
-- leaf of the output), along the longer side of that leaf's area, and then
-- gets focus from the core, so windows spiral inwards. When a
-- window closes, its sibling takes over the parent's area.
--
-- Only geometry is recomputed on changes; the tree itself is edited in
-- place. Across raywm.reload() the tree shape is kept in a small file in
-- $XDG_RUNTIME_DIR (Lua state does not survive a reload).

local gap = 8 -- outer margin and space between windows, in pixels
local min_size = 1 -- smallest width/height ever passed to view_place

local runtime_dir = os.getenv("XDG_RUNTIME_DIR") or "/tmp"
local snapshot_path = runtime_dir .. "/raywm-dwindle-" .. (os.getenv("WAYLAND_DISPLAY") or "unknown") .. ".lua"

-- Leaf:  { view = id, parent = node|nil, rect = {x,y,w,h} }
-- Split: { split = "h"|"v", ratio = 0..1, a = node, b = node, parent, rect }
local trees = {} -- output id -> root node (root.out = output id)
local leaves = {} -- view id -> leaf
local placed = {} -- view id -> last requested geometry, to skip no-op requests

local function root_of(node)
  while node.parent do node = node.parent end
  return node
end

local function last_leaf(node)
  while not node.view do node = node.b end
  return node
end

local function each_leaf(node, fn)
  if node.view then return fn(node) end
  each_leaf(node.a, fn)
  each_leaf(node.b, fn)
end

local function current_outputs()
  local list, by_id = raywm.outputs(), {}
  for _, o in ipairs(list) do by_id[o.id] = o end
  return list, by_id
end

-- Replaces `old` by `new` in old's parent, or as the root of output `out`.
local function replace(old, new, out)
  local p = old.parent
  new.parent = p
  if not p then
    new.out = out
    trees[out] = new
  elseif p.a == old then
    p.a = new
  else
    p.b = new
  end
end

local function insert(id, out, target)
  local leaf = { view = id }
  leaves[id] = leaf
  local root = trees[out]
  if not root then
    leaf.out = out
    trees[out] = leaf
    return
  end
  if not target or root_of(target) ~= root then target = last_leaf(root) end
  local r = target.rect
  local split = { split = (not r or r.w >= r.h) and "h" or "v", ratio = 0.5 }
  replace(target, split, root.out)
  split.a, split.b = target, leaf
  target.parent, leaf.parent = split, split
end

-- Removes a window's leaf; its sibling takes the parent's place.
-- Returns the output id whose tree changed.
local function remove(id)
  local leaf = leaves[id]
  if not leaf then return nil end
  leaves[id], placed[id] = nil, nil
  local out = root_of(leaf).out
  local p = leaf.parent
  if not p then
    trees[out] = nil
    return out
  end
  replace(p, p.a == leaf and p.b or p.a, out)
  return out
end

local function place(id, x, y, w, h)
  w, h = math.max(min_size, w), math.max(min_size, h)
  local key = x .. "," .. y .. "," .. w .. "," .. h
  if placed[id] == key then return true end
  placed[id] = key
  return raywm.view_place(id, x, y, w, h)
end

-- Assigns rectangles top-down and requests the window geometry.
local function apply(node, x, y, w, h, stale)
  node.rect = { x = x, y = y, w = w, h = h }
  if node.view then
    if not place(node.view, x, y, w, h) then stale[#stale + 1] = node.view end
    return
  end
  local horizontal = node.split == "h"
  local size = horizontal and w or h
  local avail = math.max(0, size - gap)
  local first = math.max(min_size, math.floor(avail * node.ratio))
  local second = math.max(min_size, avail - first)
  if horizontal then
    apply(node.a, x, y, first, h, stale)
    apply(node.b, x + first + gap, y, second, h, stale)
  else
    apply(node.a, x, y, w, first, stale)
    apply(node.b, x, y + first + gap, w, second, stale)
  end
end

local function arrange_output(out, info)
  local root = trees[out]
  if not root or not info then return end
  local u = info.usable
  local stale = {}
  apply(root, u.x + gap, u.y + gap, math.max(min_size, u.w - 2 * gap), math.max(min_size, u.h - 2 * gap), stale)
  -- A window can vanish between events; drop it after the traversal.
  for _, id in ipairs(stale) do remove(id) end
  if #stale > 0 then arrange_output(out, info) end
end

-- Moves trees of outputs that disappeared onto the first remaining output.
local function sync_outputs()
  local list, by_id = current_outputs()
  if #list == 0 then return end
  local orphans = {}
  for out, root in pairs(trees) do
    if not by_id[out] then
      each_leaf(root, function(l) orphans[#orphans + 1] = l.view end)
      trees[out] = nil
    end
  end
  for _, id in ipairs(orphans) do
    leaves[id] = nil
    insert(id, list[1].id, nil)
  end
end

-- Drops leaves of windows the compositor no longer knows (defensive:
-- view_unmap normally removes them first).
local function sync_views()
  local alive = {}
  for _, id in ipairs(raywm.views()) do alive[id] = true end
  local gone = {}
  for id in pairs(leaves) do
    if not alive[id] then gone[#gone + 1] = id end
  end
  for _, id in ipairs(gone) do remove(id) end
end

local function arrange_all()
  sync_views()
  sync_outputs()
  local _, by_id = current_outputs()
  for out in pairs(trees) do arrange_output(out, by_id[out]) end
end

-- Output for a new window: the focused window's output, else its own.
local function target_for(id)
  local focused = raywm.focused()
  local fl = focused and focused ~= id and leaves[focused]
  if fl then return root_of(fl).out, fl end
  local v = raywm.view(id)
  if v and v.output ~= 0 then return v.output, nil end
  local list = raywm.outputs()
  return list[1] and list[1].id, nil
end

local function add_view(id)
  if leaves[id] then return end
  local out, target = target_for(id)
  if not out then return end
  insert(id, out, target)
  local _, by_id = current_outputs()
  arrange_output(out, by_id[out])
end

local function focus_step(step)
  local order, cur = {}, nil
  for _, o in ipairs(raywm.outputs()) do
    if trees[o.id] then each_leaf(trees[o.id], function(l) order[#order + 1] = l.view end) end
  end
  local focused = raywm.focused()
  for i, id in ipairs(order) do
    if id == focused then cur = i end
  end
  if #order == 0 then return end
  local next = cur and order[(cur - 1 + step) % #order + 1] or order[1]
  raywm.view_focus(next)
end

-- ---- reload support -------------------------------------------------------

local function serialize(node)
  if node.view then return "{v=" .. node.view .. "}" end
  return string.format("{s=%q,r=%.6f,a=%s,b=%s}", node.split, node.ratio, serialize(node.a), serialize(node.b))
end

local function save_snapshot()
  local parts = {}
  for out, root in pairs(trees) do parts[#parts + 1] = "[" .. out .. "]=" .. serialize(root) end
  local f = io.open(snapshot_path, "w")
  if not f then return end
  f:write("return {", table.concat(parts, ","), "}\n")
  f:close()
end

-- Rebuilds trees from a snapshot, keeping only windows that still exist.
local function build(t, parent, alive)
  if type(t) ~= "table" then return nil end
  if math.type(t.v) == "integer" then
    if not alive[t.v] or leaves[t.v] then return nil end
    local leaf = { view = t.v, parent = parent }
    leaves[t.v] = leaf
    return leaf
  end
  if t.s ~= "h" and t.s ~= "v" then return nil end
  local node = { split = t.s, ratio = math.min(0.9, math.max(0.1, tonumber(t.r) or 0.5)), parent = parent }
  node.a, node.b = build(t.a, node, alive), build(t.b, node, alive)
  if node.a and node.b then return node end
  local only = node.a or node.b -- a window vanished: collapse
  if only then only.parent = parent end
  return only
end

local function load_snapshot(alive)
  local f = io.open(snapshot_path, "r")
  if not f then return end
  local text = f:read("a")
  f:close()
  os.remove(snapshot_path) -- consumed once; never reused by a later session
  if next(alive) == nil then return end -- fresh session: ignore
  local chunk = load(text, "dwindle-snapshot", "t", {})
  local ok, data = pcall(chunk or error)
  if not ok or type(data) ~= "table" then return end
  local _, by_id = current_outputs()
  for out, t in pairs(data) do
    if math.type(out) == "integer" and by_id[out] and not trees[out] then
      local root = build(t, nil, alive)
      if root then
        root.out = out
        trees[out] = root
      end
    end
  end
end

return {
  api = 1,
  setup = function(ctx)
    local alive, views = {}, raywm.views()
    for _, id in ipairs(views) do alive[id] = true end
    load_snapshot(alive)
    -- Windows not in the snapshot: oldest focus first.
    for i = #views, 1, -1 do add_view(views[i]) end
    arrange_all()

    -- raywm.focused() is still the previous window here; the core focuses
    -- the new one afterwards, so the next window splits it.
    ctx.on("view_map", add_view)
    ctx.on("view_unmap", function(id)
      local out = remove(id)
      if out then
        local _, by_id = current_outputs()
        arrange_output(out, by_id[out])
      end
    end)
    ctx.on("layout", arrange_all)
    ctx.on("output_remove", arrange_all)
    ctx.bind("Super+j", function() focus_step(1) end)
    ctx.bind("Super+k", function() focus_step(-1) end)
  end,
  teardown = save_snapshot,
}
