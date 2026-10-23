-- Workspaces: nine per output (configurable).
--
--   Super+1..9                     show workspace 1..9 of the current output
--   Super+Shift+1..9               move the focused window to workspace 1..9
--   Super+Ctrl+Left / Right        show the previous / next workspace
--   Super+Shift+Ctrl+Left / Right  move the focused window there
--   Super+Alt+Left / Right         move the focused window to the output on
--                                  the left / right (onto the workspace
--                                  shown there)
--
-- The core keeps the workspaces (raywm.workspaces()). Each output shows one
-- of its workspaces; windows on the others are hidden and never have the
-- keyboard. New windows open on the workspace shown where they appear
-- (window rules may choose another one). Layouts tile every workspace on
-- its own (dwindle.lua).
--
-- This plugin creates the workspaces, binds the keys, and sends a
-- workspace back to its output when that output comes back after being
-- unplugged (meanwhile the core keeps it, with its windows, on another
-- output). The current output is the one of the focused window, else the
-- one last switched, else the one under the pointer. Across a reload the
-- workspaces, and which window is on which, are kept.

local options = {
  -- Workspaces per output, 1..10 (10 is bound to the key 0).
  count = 9,
  -- Names, e.g. { "web", "code" }; missing ones are "1", "2", ...
  names = {},
  -- After moving a window to another workspace, show that workspace.
  follow = false,
  keys = {
    -- "%d" is replaced by 1..count (the key 0 for 10).
    switch = "Super+%d",
    move = "Super+Shift+%d",
    prev = { "Super+Ctrl+Left" },
    next = { "Super+Ctrl+Right" },
    move_prev = { "Super+Shift+Ctrl+Left" },
    move_next = { "Super+Shift+Ctrl+Right" },
    output_left = { "Super+Alt+Left" },
    output_right = { "Super+Alt+Right" },
  },
}

local current_out -- output id last switched or focused

local function name_of(i)
  return options.names[i] or tostring(i)
end

local function outputs_by_id()
  local list, by_id = raywm.outputs(), {}
  for _, o in ipairs(list) do by_id[o.id] = o end
  return list, by_id
end

local function output_at(x, y)
  for _, o in ipairs(raywm.outputs()) do
    if x >= o.x and x < o.x + o.w and y >= o.y and y < o.y + o.h then return o end
  end
  return nil
end

-- The output keys act on (see the top of this file).
local function current_output()
  local list, by_id = outputs_by_id()
  local id = raywm.focused()
  local v = id and raywm.view(id)
  if v and by_id[v.output] then return by_id[v.output] end
  if current_out and by_id[current_out] then return by_id[current_out] end
  local p = raywm.pointer()
  return output_at(p.x, p.y) or list[1]
end

-- Workspaces now on output `o`, in the core's order (creation order).
local function on_output(o)
  local r = {}
  for _, w in ipairs(raywm.workspaces()) do
    if w.output == o.id then r[#r + 1] = w end
  end
  return r
end

-- Workspace number i of output o: the one named so that belongs there
-- (home), else one named so that was moved there.
local function find(o, i)
  local name, other = name_of(i), nil
  for _, w in ipairs(on_output(o)) do
    if w.name == name then
      if w.home == o.name then return w end
      other = other or w
    end
  end
  return other
end

-- Every output gets its workspaces; workspaces of an output that came
-- back are moved home.
local function ensure(ctx, o)
  local have = {}
  for _, w in ipairs(raywm.workspaces()) do
    if w.home == o.name then
      have[w.name] = true
      if w.output ~= o.id then raywm.workspace_set_output(w.id, o.id) end
    end
  end
  for i = 1, options.count do
    if not have[name_of(i)] then ctx.workspace_create(o.id, name_of(i)) end
  end
end

-- Windows that are on no workspace go to the one shown on their output.
local function adopt_windows()
  local _, by_id = outputs_by_id()
  for _, id in ipairs(raywm.views()) do
    local v = raywm.view(id)
    local o = v and by_id[v.output]
    if v and v.workspace == 0 and o and o.workspace ~= 0 then raywm.view_workspace(id, o.workspace) end
  end
end

local function switch(i)
  local o = current_output()
  local w = o and find(o, i)
  if not w then return end
  current_out = o.id
  raywm.workspace_activate(w.id)
end

local function send(id, w)
  if not (id and w) then return end
  raywm.view_workspace(id, w.id)
  if options.follow then
    current_out = w.output
    raywm.workspace_activate(w.id)
  end
end

local function move(i)
  local id = raywm.focused()
  local o = current_output()
  send(id, o and find(o, i))
end

-- The workspace `step` places before/after the shown one on output o.
local function neighbour(o, step)
  local list = on_output(o)
  if #list == 0 then return nil end
  local at = 1
  for i, w in ipairs(list) do
    if w.active then at = i end
  end
  return list[(at - 1 + step) % #list + 1]
end

local function cycle(step)
  local o = current_output()
  local w = o and neighbour(o, step)
  if not w then return end
  current_out = o.id
  raywm.workspace_activate(w.id)
end

local function move_cycle(step)
  local id = raywm.focused()
  local o = current_output()
  send(id, o and neighbour(o, step))
end

-- The nearest output to the left (-1) or right (+1) of output o.
local function output_beside(o, dir)
  local best
  for _, x in ipairs(raywm.outputs()) do
    local beyond = dir > 0 and x.x >= o.x + o.w or dir < 0 and x.x + x.w <= o.x
    if x.id ~= o.id and beyond then
      local d = dir > 0 and x.x - (o.x + o.w) or o.x - (x.x + x.w)
      if not best or d < best.d then best = { o = x, d = d } end
    end
  end
  return best and best.o
end

local function to_output(dir)
  local id = raywm.focused()
  local o = current_output()
  local target = o and output_beside(o, dir)
  if not (id and target and target.workspace ~= 0) then return end
  raywm.view_workspace(id, target.workspace)
  -- The keyboard stays with the window, on its new output.
  current_out = target.id
  raywm.view_focus(id)
end

return {
  api = 1,
  setup = function(ctx)
    assert(options.count >= 1 and options.count <= 10, "options.count must be 1..10")
    -- After a reload the workspaces are orphans: take them all back.
    for _, w in ipairs(raywm.workspaces()) do
      if w.orphan then ctx.workspace_adopt(w.id) end
    end
    for _, o in ipairs(raywm.outputs()) do ensure(ctx, o) end
    adopt_windows()

    ctx.on("output_add", function(id)
      local _, by_id = outputs_by_id()
      if by_id[id] then ensure(ctx, by_id[id]) end
      adopt_windows()
    end)
    ctx.on("view_focus", function(id)
      local v = id ~= 0 and raywm.view(id)
      if v and v.output ~= 0 then current_out = v.output end
    end)

    local function key(spec, i)
      return (spec:gsub("%%d", tostring(i % 10)))
    end
    for i = 1, options.count do
      if options.keys.switch then ctx.bind(key(options.keys.switch, i), function() switch(i) end) end
      if options.keys.move then ctx.bind(key(options.keys.move, i), function() move(i) end) end
    end
    local actions = {
      prev = function() cycle(-1) end,
      next = function() cycle(1) end,
      move_prev = function() move_cycle(-1) end,
      move_next = function() move_cycle(1) end,
      output_left = function() to_output(-1) end,
      output_right = function() to_output(1) end,
    }
    for _, action in ipairs({ "prev", "next", "move_prev", "move_next", "output_left", "output_right" }) do
      for _, k in ipairs(options.keys[action] or {}) do ctx.bind(k, actions[action]) end
    end
  end,
  -- For tests only.
  options = options,
  find = find,
}
