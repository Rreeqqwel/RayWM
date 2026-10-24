-- Dwindle tiling, in the spirit of Hyprland.
--
-- Every space has a binary tree. A space is a workspace (when a workspace
-- plugin such as workspaces.lua is loaded) or else an output. A leaf holds
-- one window. A split node holds a direction ("h": side by side, "v":
-- stacked), a ratio and two children. A new window splits the focused
-- window's leaf (or the last leaf of its space), along the longer side of
-- that leaf's area, and then gets focus from the core, so windows spiral
-- inwards. When a window closes, its sibling takes over the parent's area.
--
-- Floating and minimized windows are not tiled (a minimized window is
-- tiled again, like a new one, when it is restored). Fullscreen and
-- maximized windows keep their tile: the core restores them there
-- afterwards. Only spaces on screen are laid out.
--
-- Only geometry is recomputed on changes; the tree itself is edited in
-- place. Across raywm.reload() the tree shape is kept in a small file in
-- $XDG_RUNTIME_DIR (Lua state does not survive a reload).

local options = {
  -- Pixels between windows, and around the edge of the usable area.
  gaps_in = 8,
  gaps_out = 8,
  -- How far Super+Ctrl+H/J/K/L move a split, in pixels.
  resize_step = 40,
  -- Key bindings per action; an empty list disables the action.
  keys = {
    resize_left = { "Super+Ctrl+h" },
    resize_down = { "Super+Ctrl+j" },
    resize_up = { "Super+Ctrl+k" },
    resize_right = { "Super+Ctrl+l" },
    swap_left = { "Super+Shift+h" },
    swap_down = { "Super+Shift+j" },
    swap_up = { "Super+Shift+k" },
    swap_right = { "Super+Shift+l" },
    -- Turn the focused window's split from side by side to stacked.
    toggle_split = { "Super+t" },
    -- Focus cycling in tree order (Super+J/K before v0.1.2). Unbound by
    -- default: focus.lua provides Super+H/J/K/L and Super+Tab.
    focus_next = {},
    focus_prev = {},
  },
}
local min_size = 1 -- smallest width/height ever passed to view_place
local min_ratio, max_ratio = 0.05, 0.95

-- Only in the per-user runtime directory (mode 0700); never in /tmp.
local runtime_dir = os.getenv("XDG_RUNTIME_DIR")
local snapshot_path = runtime_dir and (runtime_dir .. "/raywm-dwindle-" .. (os.getenv("WAYLAND_DISPLAY") or "unknown") .. ".txt")
local snapshot_max_bytes = 1 << 20
local snapshot_max_depth = 4096

-- Leaf:  { view = id, parent = node|nil, rect = {x,y,w,h} }
-- Split: { split = "h"|"v", ratio = 0..1, a = node, b = node, parent, rect }
-- Space keys: "o<output id>" or "w<workspace id>"; root.space = key.
local trees = {} -- space key -> root node
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

-- The space a window belongs to: its workspace, else its output.
local function space_of(v)
  if v.workspace and v.workspace ~= 0 then return "w" .. v.workspace end
  if v.output and v.output ~= 0 then return "o" .. v.output end
  return nil
end

-- Output info of a space that is on screen, nil if it is not shown.
local function space_output(key, by_id)
  local kind, id = key:sub(1, 1), math.tointeger(tonumber(key:sub(2)))
  if kind == "o" then return by_id[id] end
  if kind ~= "w" or not raywm.workspace then return nil end
  local ws = raywm.workspace(id)
  if not ws or not ws.active then return nil end
  return by_id[ws.output]
end

-- Windows that tiling leaves alone.
local function tileable(v)
  return v and not v.floating and not v.minimized
end

-- Replaces `old` by `new` in old's parent, or as the root of `space`.
local function replace(old, new, space)
  local p = old.parent
  new.parent = p
  if not p then
    new.space = space
    trees[space] = new
  elseif p.a == old then
    p.a = new
  else
    p.b = new
  end
end

local function insert(id, space, target)
  local leaf = { view = id }
  leaves[id] = leaf
  manage(id) -- no free Super+drag move/resize for tiled windows
  local root = trees[space]
  if not root then
    leaf.space = space
    trees[space] = leaf
    return
  end
  if not target or root_of(target) ~= root then target = last_leaf(root) end
  local r = target.rect
  local split = { split = (not r or r.w >= r.h) and "h" or "v", ratio = 0.5 }
  replace(target, split, root.space)
  split.a, split.b = target, leaf
  target.parent, leaf.parent = split, split
end

-- Removes a window's leaf; its sibling takes the parent's place.
-- Returns the space whose tree changed.
local function remove(id)
  local leaf = leaves[id]
  if not leaf then return nil end
  leaves[id], placed[id] = nil, nil
  local space = root_of(leaf).space
  local p = leaf.parent
  if not p then
    trees[space] = nil
    return space
  end
  replace(p, p.a == leaf and p.b or p.a, space)
  return space
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

-- Smallest size of a subtree that respects every client's minimum size.
local function min_of(node, mins)
  if node.view then
    local m = mins[node.view]
    return m and m[1] or 0, m and m[2] or 0
  end
  local aw, ah = min_of(node.a, mins)
  local bw, bh = min_of(node.b, mins)
  if node.split == "h" then return aw + options.gaps_in + bw, math.max(ah, bh) end
  return math.max(aw, bw), ah + options.gaps_in + bh
end

-- Assigns rectangles top-down and requests the window geometry.
local function apply(node, x, y, w, h, stale, mins)
  node.rect = { x = x, y = y, w = w, h = h }
  if node.view then
    if not place(node.view, x, y, w, h) then stale[#stale + 1] = node.view end
    return
  end
  local horizontal = node.split == "h"
  local avail = (horizontal and w or h) - options.gaps_in
  if avail < 2 * min_size then
    -- Too small to split: both children share the area (they overlap, but
    -- never leave it). Only reachable with very many windows.
    apply(node.a, x, y, w, h, stale, mins)
    apply(node.b, x, y, w, h, stale, mins)
    return
  end
  local first = math.floor(avail * node.ratio)
  -- Respect the clients' minimum sizes when both fit.
  local aw, ah = min_of(node.a, mins)
  local bw, bh = min_of(node.b, mins)
  local amin, bmin = horizontal and aw or ah, horizontal and bw or bh
  if amin + bmin <= avail then first = math.min(avail - bmin, math.max(amin, first)) end
  first = math.min(avail - min_size, math.max(min_size, first))
  local second = avail - first
  if horizontal then
    apply(node.a, x, y, first, h, stale, mins)
    apply(node.b, x + first + options.gaps_in, y, second, h, stale, mins)
  else
    apply(node.a, x, y, w, first, stale, mins)
    apply(node.b, x, y + first + options.gaps_in, w, second, stale, mins)
  end
end

local function arrange_space(key, info)
  local root = trees[key]
  if not root or not info then return end
  local mins = {}
  each_leaf(root, function(l)
    local v = raywm.view(l.view)
    if v and ((v.min_w or 0) > 0 or (v.min_h or 0) > 0) then mins[l.view] = { v.min_w or 0, v.min_h or 0 } end
  end)
  local u, g = info.usable, options.gaps_out
  local stale = {}
  apply(root, u.x + g, u.y + g, math.max(min_size, u.w - 2 * g), math.max(min_size, u.h - 2 * g), stale, mins)
  -- A window can vanish between events; drop it after the traversal.
  for _, id in ipairs(stale) do remove(id) end
  if #stale > 0 then arrange_space(key, info) end
end

local function arrange(key)
  local _, by_id = current_outputs()
  arrange_space(key, space_output(key, by_id))
end

-- Output spaces of outputs that disappeared: their windows go to the
-- first remaining output. (Workspaces are moved by the core instead.)
local function sync_outputs()
  local list, by_id = current_outputs()
  if #list == 0 then return end
  local orphans = {}
  for key, root in pairs(trees) do
    local kind, id = key:sub(1, 1), math.tointeger(tonumber(key:sub(2)))
    if kind == "o" and not by_id[id] then
      each_leaf(root, function(l) orphans[#orphans + 1] = l.view end)
      trees[key] = nil
    end
  end
  for _, id in ipairs(orphans) do
    leaves[id] = nil
    insert(id, "o" .. list[1].id, nil)
  end
end

-- Drops leaves of windows the compositor no longer knows (defensive:
-- view_unmap normally removes them first), or that float now; moves
-- windows whose space changed.
local function sync_views()
  local alive = {}
  for _, id in ipairs(raywm.views()) do alive[id] = true end
  local gone, moved = {}, {}
  for id, leaf in pairs(leaves) do
    local v = alive[id] and raywm.view(id)
    if not tileable(v) then
      gone[#gone + 1] = id
    else
      -- Moved to another workspace, or its workspace was removed. (A tile
      -- whose centre is on another output, e.g. while fullscreen there,
      -- stays in its output's tree.)
      local key, cur = space_of(v), root_of(leaf).space
      if key and key ~= cur and (key:sub(1, 1) == "w" or cur:sub(1, 1) == "w") then moved[#moved + 1] = { id, key } end
    end
  end
  for _, id in ipairs(gone) do
    remove(id)
    manage(id, false) -- in case it still exists
  end
  for _, m in ipairs(moved) do
    remove(m[1])
    insert(m[1], m[2], nil)
  end
end

local function arrange_all()
  sync_views()
  sync_outputs()
  local _, by_id = current_outputs()
  for key in pairs(trees) do arrange_space(key, space_output(key, by_id)) end
end

-- Space and target leaf for a new window. With workspaces, its own
-- workspace; else the focused window's output, else its own output.
local function target_for(id)
  local v = raywm.view(id)
  if v and v.workspace and v.workspace ~= 0 then
    local key = "w" .. v.workspace
    local focused = raywm.focused()
    local fl = focused and focused ~= id and leaves[focused]
    if fl and root_of(fl).space == key then return key, fl end
    return key, nil
  end
  local focused = raywm.focused()
  local fl = focused and focused ~= id and leaves[focused]
  if fl and root_of(fl).space:sub(1, 1) == "o" then return root_of(fl).space, fl end
  if v and v.output ~= 0 then return "o" .. v.output, nil end
  local list = raywm.outputs()
  return list[1] and ("o" .. list[1].id), nil
end

local function add_view(id)
  if leaves[id] then return end
  if not tileable(raywm.view(id)) then return end
  local key, target = target_for(id)
  if not key then return end
  insert(id, key, target)
  arrange(key)
end

local function drop_view(id)
  local key = remove(id)
  manage(id, false)
  if key then arrange(key) end
end

local function focus_step(step)
  local order, cur = {}, nil
  local _, by_id = current_outputs()
  local keys = {}
  for key in pairs(trees) do
    if space_output(key, by_id) then keys[#keys + 1] = key end
  end
  table.sort(keys)
  for _, key in ipairs(keys) do each_leaf(trees[key], function(l) order[#order + 1] = l.view end) end
  local focused = raywm.focused()
  for i, id in ipairs(order) do
    if id == focused then cur = i end
  end
  if #order == 0 then return end
  local next = cur and order[(cur - 1 + step) % #order + 1] or order[1]
  raywm.view_focus(next)
end

-- ---- resize, swap, split direction -------------------------------------------

local axis_of = { left = "h", right = "h", up = "v", down = "v" }
local sign_of = { left = -1, right = 1, up = -1, down = 1 }

-- Moves the split boundary next to the focused window towards `dir`: the
-- window's edge facing `dir` if it has a neighbour there (it grows), else
-- its opposite edge (it shrinks).
local function resize(dir)
  local leaf = leaves[raywm.focused() or 0]
  if not leaf then return end
  local axis, sign = axis_of[dir], sign_of[dir]
  -- Nearest ancestor with that axis where the window is on the side
  -- facing `dir`; else the nearest one with that axis at all.
  local grow, any
  local child, node = leaf, leaf.parent
  while node do
    if node.split == axis then
      any = any or node
      if (sign > 0 and node.a == child) or (sign < 0 and node.b == child) then
        grow = node
        break
      end
    end
    child, node = node, node.parent
  end
  local split = grow or any
  if not split or not split.rect then return end
  local avail = (axis == "h" and split.rect.w or split.rect.h) - options.gaps_in
  if avail <= 0 then return end
  local ratio = split.ratio + sign * options.resize_step / avail
  split.ratio = math.min(max_ratio, math.max(min_ratio, ratio))
  arrange(root_of(split).space)
end

-- The leaf of another window in direction `dir` from `leaf`, among the
-- leaves of the same space: lying strictly beyond it, overlapping it
-- across the direction if possible, nearest first.
local function neighbour(leaf, dir)
  local r = leaf.rect
  if not r then return nil end
  local horizontal = axis_of[dir] == "h"
  local sign = sign_of[dir]
  local best, best_key
  each_leaf(root_of(leaf), function(other)
    local o = other.rect
    if other == leaf or not o then return end
    local gap
    if horizontal then
      if sign > 0 and o.x >= r.x + r.w then gap = o.x - (r.x + r.w) end
      if sign < 0 and o.x + o.w <= r.x then gap = r.x - (o.x + o.w) end
    else
      if sign > 0 and o.y >= r.y + r.h then gap = o.y - (r.y + r.h) end
      if sign < 0 and o.y + o.h <= r.y then gap = r.y - (o.y + o.h) end
    end
    if not gap then return end
    local overlap
    if horizontal then
      overlap = math.min(r.y + r.h, o.y + o.h) - math.max(r.y, o.y)
    else
      overlap = math.min(r.x + r.w, o.x + o.w) - math.max(r.x, o.x)
    end
    local key = { overlap > 0 and 0 or 1, gap, -overlap, other.view }
    local better = not best_key
    if best_key then
      for i = 1, #key do
        if key[i] ~= best_key[i] then
          better = key[i] < best_key[i]
          break
        end
      end
    end
    if better then best, best_key = other, key end
  end)
  return best
end

-- Swaps the focused window with its neighbour in direction `dir`.
local function swap(dir)
  local leaf = leaves[raywm.focused() or 0]
  if not leaf then return end
  local other = neighbour(leaf, dir)
  if not other then return end
  leaf.view, other.view = other.view, leaf.view
  leaves[leaf.view], leaves[other.view] = leaf, other
  arrange(root_of(leaf).space)
end

local function toggle_split()
  local leaf = leaves[raywm.focused() or 0]
  local p = leaf and leaf.parent
  if not p then return end
  p.split = p.split == "h" and "v" or "h"
  arrange(root_of(p).space)
end

-- ---- reload support -------------------------------------------------------
-- Snapshot format (plain data, never executed), one token per line in
-- pre-order:  "space <key>" (v1: "output <id>"), then "h <ratio>" /
-- "v <ratio>" / "leaf <view>".

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
  local lines = { "raywm-dwindle 2" }
  for key, root in pairs(trees) do
    lines[#lines + 1] = "space " .. key
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
    local node = { split = kind, ratio = math.min(max_ratio, math.max(min_ratio, ratio)) }
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

-- A space key from a snapshot header line, or nil.
local function header_space(line, version)
  if version == 1 then
    local out = math.tointeger(tonumber((line:match("^output (%S+)$"))))
    return out and ("o" .. out)
  end
  local key = line:match("^space ([ow]%d+)$")
  return key
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
  local version = ({ ["raywm-dwindle 1"] = 1, ["raywm-dwindle 2"] = 2 })[lines[1]]
  if not version then return end
  local parsed, seen, i = {}, {}, 2
  while lines[i] do
    local key = header_space(lines[i], version)
    if not key or parsed[key] then return end
    local root, j = parse_tree(lines, i + 1, 1, alive, seen)
    if root == false then return end -- malformed: ignore the whole snapshot
    if root then parsed[key] = root end
    i = j
  end
  -- Only a fully valid snapshot is applied. A tree is kept only if all
  -- its windows are still tiled in that space; otherwise they are added
  -- again like new windows.
  for key, root in pairs(parsed) do
    local ok = true
    each_leaf(root, function(l)
      local v = raywm.view(l.view)
      ok = ok and tileable(v) and space_of(v) == key
    end)
    if ok then
      root.space = key
      trees[key] = root
      each_leaf(root, function(l)
        leaves[l.view] = l
        manage(l.view)
      end)
    end
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
      local key = remove(id)
      if key then arrange(key) end
    end)
    -- Floating or minimized changed: leave or join the tiling.
    ctx.on("view_state", function(id)
      local v = raywm.view(id)
      if not v then return end
      if leaves[id] and not tileable(v) then
        drop_view(id)
      elseif not leaves[id] and tileable(v) then
        add_view(id)
      end
    end)
    ctx.on("layout", arrange_all)
    ctx.on("output_remove", arrange_all)
    -- Workspaces shown, moved or removed; windows moved between them.
    if raywm.workspaces then
      for _, ev in ipairs({ "workspace_activate", "workspace_change", "workspace_remove", "view_workspace" }) do
        ctx.on(ev, arrange_all)
      end
    end

    local actions = {
      resize_left = function() resize("left") end,
      resize_down = function() resize("down") end,
      resize_up = function() resize("up") end,
      resize_right = function() resize("right") end,
      swap_left = function() swap("left") end,
      swap_down = function() swap("down") end,
      swap_up = function() swap("up") end,
      swap_right = function() swap("right") end,
      toggle_split = toggle_split,
      focus_next = function() focus_step(1) end,
      focus_prev = function() focus_step(-1) end,
    }
    for action in pairs(options.keys) do assert(actions[action], "unknown action in options.keys: " .. action) end
    -- A fixed order: registration order decides which of two equal
    -- bindings wins, and what a duplicate warning names.
    for _, action in ipairs({ "resize_left", "resize_down", "resize_up", "resize_right", "swap_left", "swap_down",
      "swap_up", "swap_right", "toggle_split", "focus_next", "focus_prev" }) do
      for _, k in ipairs(options.keys[action] or {}) do ctx.bind(k, actions[action]) end
    end
  end,
  teardown = save_snapshot,
  -- For tests/dwindle_test.lua only: read access to the internal state.
  inspect = function() return trees, leaves end,
  focus_step = focus_step,
  resize = resize,
  swap = swap,
  toggle_split = toggle_split,
  options = options,
}
