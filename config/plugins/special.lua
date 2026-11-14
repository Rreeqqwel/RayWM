-- Special workspace: one hidden overlay per output, usually used as a
-- scratchpad (a terminal, notes, a music player).
--
--   Super+S                 show/hide the special workspace of the current
--                           output over the workspace shown there
--   Super+Shift+S           move the focused window to it (hidden by default;
--                           see show_on_move)
--
-- A special workspace is never the output's active workspace: while shown
-- its windows float above the normal ones, and switching to a normal
-- workspace hides it (the core does that). Windows on it keep their layout
-- (dwindle tiles it like any other workspace) and survive reloads.
--
-- This plugin creates the workspace (`ctx.workspace_create(output, name,
-- true)`, API addition after v0.2.2), toggles it (`raywm.workspace_toggle`)
-- and gives it back to its home output after a monitor is replugged. The
-- numbered workspaces stay in workspaces.lua; the two plugins ignore each
-- other's workspaces by the `special` field.

local options = {
  -- Workspace name. It is not one of the numbered workspaces.
  name = "special",
  -- Show the overlay when a window is moved into it.
  show_on_move = false,
  keys = {
    toggle = { "Super+s" },
    move = { "Super+Shift+s" },
  },
}

local current_out -- output id last switched or focused

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

-- The output the keys act on: the focused window's, else the one last
-- switched, else the one under the pointer.
local function current_output()
  local list, by_id = outputs_by_id()
  local id = raywm.focused()
  local v = id and raywm.view(id)
  if v and by_id[v.output] then return by_id[v.output] end
  if current_out and by_id[current_out] then return by_id[current_out] end
  local p = raywm.pointer()
  return output_at(p.x, p.y) or list[1]
end

-- The special workspace of output `o`: one created there (home), else one
-- that was moved there by an output hotplug.
local function find(o)
  local other
  for _, w in ipairs(raywm.workspaces()) do
    if w.special and w.name == options.name and w.output == o.id then
      if w.home == o.name then return w end
      other = other or w
    end
  end
  return other
end

local function ensure(ctx, o)
  local have
  for _, w in ipairs(raywm.workspaces()) do
    if w.special and w.home == o.name and w.name == options.name then
      have = w
      if w.output ~= o.id then raywm.workspace_set_output(w.id, o.id) end
    end
  end
  if have then return have end
  local id, err = ctx.workspace_create(o.id, options.name, true)
  if not id then
    raywm.log(("special: cannot create workspace on %s: %s"):format(o.name, tostring(err)))
    return nil
  end
  return raywm.workspace(id)
end

local function toggle()
  local o = current_output()
  local w = o and find(o)
  if not w then return end
  current_out = o.id
  raywm.workspace_toggle(w.id)
end

local function move()
  local id = raywm.focused()
  local o = current_output()
  local w = o and find(o)
  if not (id and w) then return end
  current_out = o.id
  raywm.view_workspace(id, w.id)
  local now = raywm.workspace(w.id)
  if options.show_on_move and now and not now.active then raywm.workspace_toggle(w.id) end
end

return {
  api = 1,
  setup = function(ctx)
    if not raywm.workspace_toggle then
      raywm.log("special: this RayWM has no special-workspace support")
      return
    end
    -- After a reload special workspaces are orphans: take ours back.
    for _, w in ipairs(raywm.workspaces()) do
      if w.orphan and w.special then ctx.workspace_adopt(w.id) end
    end
    for _, o in ipairs(raywm.outputs()) do ensure(ctx, o) end

    ctx.on("output_add", function(id)
      local _, by_id = outputs_by_id()
      if by_id[id] then ensure(ctx, by_id[id]) end
    end)
    ctx.on("view_focus", function(id)
      local v = id ~= 0 and raywm.view(id)
      if v and v.output ~= 0 then current_out = v.output end
    end)

    for _, k in ipairs(options.keys.toggle or {}) do ctx.bind(k, toggle) end
    for _, k in ipairs(options.keys.move or {}) do ctx.bind(k, move) end
  end,
  -- For tests only.
  options = options,
  find = find,
}
