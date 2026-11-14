-- Tests config/plugins/special.lua against a mock of the RayWM API that
-- follows the core's rules (src/workspace.zig): a special workspace is an
-- overlay, never the output's active workspace; at most one is shown per
-- output; switching to a normal workspace hides it; a redisplayed output
-- takes its workspaces home.
-- Run from the repo root: lua5.4 tests/special_test.lua
local plugin_path = "config/plugins/special.lua"

local outputs, workspaces, views, focused, pointer, binds, handlers, next_id, shown

local function reset()
  outputs, workspaces, views, focused = {}, {}, {}, nil
  pointer = { x = 0, y = 0 }
  binds, handlers, next_id, shown = {}, {}, 100, {}
end

local function out_by_id(id)
  for _, o in ipairs(outputs) do if o.id == id then return o end end
end
local function ws_by_id(id)
  for _, w in ipairs(workspaces) do if w.id == id then return w end end
end
local function ws_info(w)
  local o = out_by_id(w.output)
  local active = w.special and shown[w.output] == w.id or (o ~= nil and o.active == w.id)
  return { id = w.id, name = w.name, home = w.home, output = w.output, active = active,
    urgent = false, orphan = w.orphan or false, special = w.special or false }
end

local function emit(ev, ...)
  for _, h in ipairs(handlers[ev] or {}) do h(...) end
end

raywm = {
  api_version = 1,
  outputs = function()
    local r = {}
    for i, o in ipairs(outputs) do r[i] = { id = o.id, name = o.name, x = o.x, y = o.y, w = o.w, h = o.h, workspace = o.active or 0 } end
    return r
  end,
  workspaces = function()
    local r = {}
    for i, w in ipairs(workspaces) do r[i] = ws_info(w) end
    return r
  end,
  workspace = function(id)
    local w = ws_by_id(id)
    if not w then return nil, "stale" end
    return ws_info(w)
  end,
  workspace_toggle = function(id)
    local w = ws_by_id(id)
    if not w then return nil, "stale" end
    if not w.special then return nil, "not_special" end
    if shown[w.output] == id then
      shown[w.output] = nil
      return false
    end
    shown[w.output] = id
    return true
  end,
  workspace_set_output = function(id, oid)
    local w, o = ws_by_id(id), out_by_id(oid)
    if not (w and o) then return nil, "stale" end
    local old = out_by_id(w.output)
    w.output = oid
    if old and old.active == id then
      local f
      for _, x in ipairs(workspaces) do if x.output == old.id and not x.special then f = f or x end end
      old.active = f and f.id
    end
    if not w.special and not o.active then o.active = id end
    if shown[old and old.id] == id then shown[old.id] = nil end
    return true
  end,
  views = function()
    local r = {}
    for id in pairs(views) do r[#r + 1] = id end
    table.sort(r)
    return r
  end,
  view = function(id)
    local v = views[id]
    if not v then return nil, "stale" end
    return { id = id, output = v.output, workspace = v.workspace or 0, visible = true }
  end,
  view_workspace = function(id, wid)
    local v = views[id]
    if not v then return nil, "stale" end
    local w = ws_by_id(wid)
    v.workspace = wid
    if w then v.output = w.output end
    return true
  end,
  focused = function() return focused end,
  pointer = function() return { x = pointer.x, y = pointer.y, busy = false } end,
  log = function() end,
}

local function ctx_new()
  return {
    bind = function(k, fn)
      assert(not binds[k], "key bound twice: " .. k)
      binds[k] = fn
    end,
    on = function(ev, fn) handlers[ev] = handlers[ev] or {}; table.insert(handlers[ev], fn) end,
    workspace_create = function(oid, name, special)
      local o = out_by_id(oid)
      if not o then return nil, "stale" end
      next_id = next_id + 1
      workspaces[#workspaces + 1] = { id = next_id, name = name, home = o.name, output = oid, special = special }
      if not special and not o.active then o.active = next_id end
      return next_id
    end,
    workspace_adopt = function(id)
      local w = ws_by_id(id)
      if not w then return nil, "stale" end
      if not w.orphan then return nil, "owned" end
      w.orphan = false
      return true
    end,
  }
end

local plugin
local function load_plugin(opts)
  binds, handlers = {}, {}
  plugin = dofile(plugin_path)
  for k, v in pairs(opts or {}) do plugin.options[k] = v end
  plugin.setup(ctx_new())
end

local function reload()
  for _, w in ipairs(workspaces) do w.orphan = true end
  load_plugin()
end

local function press(k) assert(binds[k], "no binding " .. k)() end
local function special_on(oid)
  local n = 0
  for _, w in ipairs(workspaces) do if w.output == oid and w.special then n = n + 1 end end
  return n
end
local function special_of(oid)
  for _, w in ipairs(workspaces) do if w.output == oid and w.special then return w end end
end
local function active_name(oid)
  local w = ws_by_id(out_by_id(oid).active)
  return w and (w.name .. "@" .. w.home)
end

local tests, order = {}, {}
local function test(name, fn) tests[name] = fn; order[#order + 1] = name end
local function eq(a, b, msg) if a ~= b then error((msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end end

local function two_outputs()
  outputs = {
    { id = 1, name = "DP-1", x = 0, y = 0, w = 1280, h = 720, active = nil },
    { id = 2, name = "DP-2", x = 1280, y = 0, w = 1280, h = 720, active = nil },
  }
  -- The workspaces plugin already created the numbered ones.
  for _, o in ipairs(outputs) do
    next_id = next_id + 1
    o.active = next_id
    workspaces[#workspaces + 1] = { id = next_id, name = "1", home = o.name, output = o.id }
  end
end

test("one hidden special workspace per output, active workspace unchanged", function()
  two_outputs()
  load_plugin()
  eq(special_on(1), 1, "DP-1")
  eq(special_on(2), 1, "DP-2")
  eq(active_name(1), "1@DP-1", "the overlay is not the active workspace")
  eq(active_name(2), "1@DP-2", "the overlay is not the active workspace")
  assert(not special_of(1).orphan)
  assert(binds["Super+s"] and binds["Super+Shift+s"], "keys")
end)

test("Super+S toggles the overlay of the focused window's output", function()
  two_outputs()
  load_plugin()
  views[50] = { output = 2, workspace = out_by_id(2).active }
  focused = 50
  press("Super+s")
  assert(shown[2] == special_of(2).id, "shown on DP-2")
  assert(not shown[1], "DP-1 untouched")
  press("Super+s")
  assert(not shown[2], "hidden again")
end)

test("Super+Shift+S moves the focused window and leaves the overlay hidden", function()
  two_outputs()
  load_plugin()
  views[50] = { output = 1, workspace = out_by_id(1).active }
  focused = 50
  press("Super+Shift+s")
  eq(views[50].workspace, special_of(1).id)
  assert(not shown[1], "hidden by default")
  plugin.options.show_on_move = true
  press("Super+Shift+s")
  assert(shown[1] == special_of(1).id, "show_on_move")
  -- Moving another window in while it is shown keeps it shown.
  views[51] = { output = 1, workspace = out_by_id(1).active }
  focused = 51
  press("Super+Shift+s")
  assert(shown[1] == special_of(1).id, "already shown")
  plugin.options.show_on_move = false
end)

test("without focus the overlay acts on the last output, else the pointer", function()
  two_outputs()
  load_plugin()
  pointer = { x = 1500, y = 100 }
  press("Super+s")
  assert(shown[2], "pointer output")
  press("Super+s")
  pointer = { x = 10, y = 10 }
  press("Super+s")
  assert(shown[2], "the output switched last")
  press("Super+s")
end)

test("reload adopts the special workspace and creates none", function()
  two_outputs()
  load_plugin()
  local before = #workspaces
  reload()
  eq(#workspaces, before, "same workspaces after reload")
  assert(not special_of(1).orphan and not special_of(2).orphan, "adopted")
end)

test("a special workspace moved by hotplug returns to its home output", function()
  two_outputs()
  load_plugin()
  local gone = table.remove(outputs, 2)
  local w = special_of(1)
  -- The core moved DP-2's special workspace to DP-1.
  local moved
  for _, x in ipairs(workspaces) do if x.special and x.home == "DP-2" then moved = x end end
  moved.output = 1
  -- DP-2 comes back with a new id.
  outputs[2] = { id = 7, name = gone.name, x = 1280, y = 0, w = 1280, h = 720 }
  emit("output_add", 7)
  eq(moved.output, 7, "moved home")
  eq(special_on(7), 1, "DP-2 has exactly one")
  eq(special_on(1), 1, "DP-1 keeps its own")
  assert(w ~= moved, "two distinct special workspaces")
end)

test("a build without workspace_toggle is reported, not crashed", function()
  two_outputs()
  local saved = raywm.workspace_toggle
  raywm.workspace_toggle = nil
  load_plugin()
  assert(next(binds) == nil, "no keys without support")
  raywm.workspace_toggle = saved
end)

local failed = 0
for _, name in ipairs(order) do
  reset()
  local ok, err = pcall(tests[name])
  print((ok and "PASS  " or "FAIL  ") .. name .. (ok and "" or ("\n      " .. tostring(err))))
  if not ok then failed = failed + 1 end
end
print(("%d/%d passed"):format(#order - failed, #order))
os.exit(failed == 0 and 0 or 1)
