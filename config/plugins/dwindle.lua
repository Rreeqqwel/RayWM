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

-- Only in the per-user runtime directory (mode 0700); never in /tmp.
local runtime_dir = os.getenv("XDG_RUNTIME_DIR")
local snapshot_path = runtime_dir and (runtime_dir .. "/raywm-dwindle-" .. (os.getenv("WAYLAND_DISPLAY") or "unknown") .. ".txt")
local snapshot_max_bytes = 1 << 20
local snapshot_max_depth = 4096

-- Leaf:  { view = id, parent = node|nil, rect = {x,y,w,h} }
-- Split: { split = "h"|"v", ratio = 0..1, a = node, b = node, parent, rect }
local trees = {} -- output id -> root node (root.out = output id)
local leaves = {} -- view id -> leaf
local placed = {} -- view id -> last requested geometry, to skip no-op requests
local manage = function() end -- ctx.manage once setup has run

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
  manage(id) -- no free Super+drag move/resize for tiled windows
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

-- Skips a request only if it was already sent and the window really is at
-- that position (something else may have moved it). The size is not
-- compared: clients may round it, e.g. terminals to whole cells.
local function place(id, x, y, w, h)
  w, h = math.max(min_size, w), math.max(min_size, h)
  local key = x .. "," .. y .. "," .. w .. "," .. h
  if placed[id] == key then
    local v = raywm.view(id)
    if not v then return nil end
    if v.x == x and v.y == y then return true end
  end
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
  local avail = (horizontal and w or h) - gap
  if avail < 2 * min_size then
    -- Too small to split: both children share the area (they overlap, but
    -- never leave it). Only reachable with very many windows.
    apply(node.a, x, y, w, h, stale)
    apply(node.b, x, y, w, h, stale)
    return
  end
  local first = math.min(avail - min_size, math.max(min_size, math.floor(avail * node.ratio)))
  local second = avail - first
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
  for _, id in ipairs(gone) do
    remove(id)
    manage(id, false) -- in case it still exists
  end
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
-- Snapshot format (plain data, never executed), one token per line in
-- pre-order:  "output <id>", then "h <ratio>" / "v <ratio>" / "leaf <view>".

local function write_tree(node, lines)
  if node.view then
    lines[#lines + 1] = "leaf " .. node.view
    return
  end
  lines[#lines + 1] = string.format("%s %.6f", node.split, node.ratio)
  write_tree(node.a, lines)
  write_tree(node.b, lines)
end

local function save_snapshot()
  if not snapshot_path then return end
  local lines = { "raywm-dwindle 1" }
  for out, root in pairs(trees) do
    lines[#lines + 1] = "output " .. out
    write_tree(root, lines)
  end
  local f = io.open(snapshot_path, "w")
  if not f then return end
  f:write(table.concat(lines, "\n"), "\n")
  f:close()
end

-- Parses one subtree starting at lines[i]. Returns node (nil if all its
-- windows are gone) and the next index, or false on malformed input.
-- Leaves are collected in `seen`; nothing global is touched.
local function parse_tree(lines, i, depth, alive, seen)
  local kind, value = (lines[i] or ""):match("^(%a+) (%S+)$")
  if depth > snapshot_max_depth then return false end
  if kind == "leaf" then
    local id = math.tointeger(tonumber(value))
    if not id then return false end
    if not alive[id] or seen[id] then return nil, i + 1 end
    local leaf = { view = id }
    seen[id] = leaf
    return leaf, i + 1
  elseif kind == "h" or kind == "v" then
    local ratio = tonumber(value)
    if not ratio then return false end
    local node = { split = kind, ratio = math.min(0.9, math.max(0.1, ratio)) }
    local a, j = parse_tree(lines, i + 1, depth + 1, alive, seen)
    if a == false then return false end
    local b, k = parse_tree(lines, j, depth + 1, alive, seen)
    if b == false then return false end
    if a and b then
      node.a, node.b, a.parent, b.parent = a, b, node, node
      return node, k
    end
    return a or b, k -- a window vanished: collapse
  end
  return false
end

local function load_snapshot(alive)
  if not snapshot_path then return end
  local f = io.open(snapshot_path, "r")
  if not f then return end
  local text = f:read(snapshot_max_bytes + 1)
  f:close()
  os.remove(snapshot_path) -- consumed once; never reused by a later session
  if next(alive) == nil or not text or #text > snapshot_max_bytes then return end
  local lines = {}
  for line in text:gmatch("[^\n]+") do lines[#lines + 1] = line end
  if lines[1] ~= "raywm-dwindle 1" then return end
  local _, by_id = current_outputs()
  local parsed, seen, i = {}, {}, 2
  while lines[i] do
    local out = math.tointeger(tonumber((lines[i]:match("^output (%S+)$"))))
    if not out or parsed[out] then return end
    local root, j = parse_tree(lines, i + 1, 1, alive, seen)
    if root == false then return end -- malformed: ignore the whole snapshot
    if root and by_id[out] then parsed[out] = root end
    i = j
  end
  -- Only a fully valid snapshot is applied.
  for out, root in pairs(parsed) do
    root.out = out
    trees[out] = root
    each_leaf(root, function(l)
      leaves[l.view] = l
      manage(l.view)
    end)
  end
end

return {
  api = 1,
  setup = function(ctx)
    manage = ctx.manage
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
  -- For tests/dwindle_test.lua only: read access to the internal state.
  inspect = function() return trees, leaves end,
}
