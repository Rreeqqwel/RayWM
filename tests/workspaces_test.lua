-- Tests config/plugins/workspaces.lua against a mock of the RayWM API that
-- follows the core's rules (src/workspace.zig): workspaces in creation
-- order, the first workspace of an output is shown, moving a workspace
-- shows it only on an output that showed none, orphans after a reload.
-- Run from the repo root: lua5.4 tests/workspaces_test.lua
local plugin_path = "config/plugins/workspaces.lua"

local outputs, workspaces, views, focused, pointer, binds, handlers, next_id

local function reset()
  outputs, workspaces, views, focused = {}, {}, {}, nil
  pointer = { x = 0, y = 0 }
  binds, handlers, next_id = {}, {}, 100
end

local function out_by_id(id)
  for _, o in ipairs(outputs) do if o.id == id then return o end end
end
local function ws_by_id(id)
  for _, w in ipairs(workspaces) do if w.id == id then return w end end
end
local function first_on(o)
  for _, w in ipairs(workspaces) do if w.output == o.id then return w end end
end
local function ws_info(w)
  local o = out_by_id(w.output)
  return { id = w.id, name = w.name, home = w.home, output = w.output, active = o ~= nil and o.active == w.id,
    urgent = false, orphan = w.orphan or false }
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
  workspace_activate = function(id)
    local w = ws_by_id(id)
    if not w then return nil, "stale" end
    out_by_id(w.output).active = id
    return true
  end,
  workspace_set_output = function(id, oid)
    local w, o = ws_by_id(id), out_by_id(oid)
    if not (w and o) then return nil, "stale" end
    local old = out_by_id(w.output)
    w.output = oid
    if old and old.active == id then
      local f = first_on(old)
      old.active = f and f.id
    end
    if not o.active then o.active = id end
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
    return { id = id, output = v.output, workspace = v.workspace or 0, visible = true, minimized = v.minimized or false }
  end,
  view_workspace = function(id, wid)
    local v = views[id]
    if not v then return nil, "stale" end
    local w = ws_by_id(wid)
    v.workspace = wid
    if w then v.output = w.output end
    return true
  end,
  view_focus = function(id) focused = id return true end,
  view_minimize = function(id, on)
    if not views[id] then return nil, "stale" end
    views[id].minimized = on
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
    workspace_create = function(oid, name)
      local o = out_by_id(oid)
      if not o then return nil, "stale" end
      next_id = next_id + 1
      workspaces[#workspaces + 1] = { id = next_id, name = name, home = o.name, output = oid }
      if not o.active then o.active = next_id end
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

-- A reload: every workspace is an orphan while the plugin starts again.
local function reload()
  for _, w in ipairs(workspaces) do w.orphan = true end
  load_plugin()
  -- The core then releases what nobody adopted.
  local kept = {}
  for _, w in ipairs(workspaces) do if not w.orphan then kept[#kept + 1] = w end end
  workspaces = kept
end

local function press(k) assert(binds[k], "no binding " .. k)() end
local function names_on(oid)
  local r = {}
  for _, w in ipairs(workspaces) do if w.output == oid then r[#r + 1] = w.name .. "@" .. w.home end end
  return table.concat(r, " ")
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
    { id = 1, name = "DP-1", x = 0, y = 0, w = 1280, h = 720 },
    { id = 2, name = "DP-2", x = 1280, y = 0, w = 1280, h = 720 },
  }
end

test("nine workspaces per output, the first one shown", function()
  two_outputs()
  load_plugin()
  eq(names_on(1), "1@DP-1 2@DP-1 3@DP-1 4@DP-1 5@DP-1 6@DP-1 7@DP-1 8@DP-1 9@DP-1", "DP-1")
  eq(active_name(1), "1@DP-1")
  eq(active_name(2), "1@DP-2")
  for i = 1, 9 do
    assert(binds["Super+" .. i] and binds["Super+Shift+" .. i], "keys for " .. i)
  end
end)

test("Super+N acts on the focused window's output", function()
  two_outputs()
  load_plugin()
  views[50] = { output = 2, workspace = out_by_id(2).active }
  focused = 50
  press("Super+3")
  eq(active_name(2), "3@DP-2", "focused output switched")
  eq(active_name(1), "1@DP-1", "other output untouched")
end)

test("without a focused window: the output last switched, else under the pointer", function()
  two_outputs()
  load_plugin()
  pointer = { x = 1500, y = 100 }
  press("Super+2")
  eq(active_name(2), "2@DP-2", "pointer output")
  pointer = { x = 10, y = 10 }
  press("Super+4") -- still the output switched last
  eq(active_name(2), "4@DP-2", "last switched output")
end)

test("Super+Shift+N moves the focused window; follow shows its workspace", function()
  outputs = { { id = 1, name = "DP-1", x = 0, y = 0, w = 1280, h = 720 } }
  load_plugin()
  views[50] = { output = 1, workspace = out_by_id(1).active }
  focused = 50
  press("Super+Shift+5")
  eq(ws_by_id(views[50].workspace).name, "5")
  eq(active_name(1), "1@DP-1", "no follow by default")
  plugin.options.follow = true
  press("Super+Shift+6")
  eq(active_name(1), "6@DP-1", "follow")
  plugin.options.follow = false
end)

test("prev/next cycle the workspaces of the output and wrap", function()
  outputs = { { id = 1, name = "DP-1", x = 0, y = 0, w = 1280, h = 720 } }
  load_plugin()
  press("Super+Ctrl+Left")
  eq(active_name(1), "9@DP-1", "wraps backwards")
  press("Super+Ctrl+Right")
  eq(active_name(1), "1@DP-1", "wraps forwards")
end)

test("a workspace moved off an unplugged output goes home when it returns", function()
  two_outputs()
  load_plugin()
  -- The core moves DP-2's workspaces to DP-1 when DP-2 goes away.
  local gone = table.remove(outputs, 2)
  for _, w in ipairs(workspaces) do if w.output == 2 then w.output = 1 end end
  -- On DP-1, Super+1 means DP-1's own "1", not the migrated one.
  press("Super+1")
  eq(active_name(1), "1@DP-1", "home workspace preferred")
  -- DP-2 comes back (same name, new id).
  outputs[2] = { id = 7, name = gone.name, x = 1280, y = 0, w = 1280, h = 720 }
  emit("output_add", 7)
  eq(names_on(7), "1@DP-2 2@DP-2 3@DP-2 4@DP-2 5@DP-2 6@DP-2 7@DP-2 8@DP-2 9@DP-2", "moved home")
  eq(names_on(1), "1@DP-1 2@DP-1 3@DP-1 4@DP-1 5@DP-1 6@DP-1 7@DP-1 8@DP-1 9@DP-1", "DP-1 keeps its own")
  eq(#workspaces, 18, "nothing created twice")
end)

test("a new output gets its own workspaces", function()
  outputs = { { id = 1, name = "DP-1", x = 0, y = 0, w = 1280, h = 720 } }
  load_plugin()
  outputs[2] = { id = 2, name = "HDMI-A-1", x = 1280, y = 0, w = 1920, h = 1080 }
  emit("output_add", 2)
  eq(#workspaces, 18)
  eq(active_name(2), "1@HDMI-A-1")
end)

test("reload adopts every workspace and creates none", function()
  two_outputs()
  load_plugin()
  local before = #workspaces
  views[50] = { output = 1, workspace = workspaces[3].id }
  reload()
  eq(#workspaces, before, "same workspaces after reload")
  for _, w in ipairs(workspaces) do assert(not w.orphan, "orphan left: " .. w.name) end
  eq(ws_by_id(views[50].workspace).name, "3", "the window keeps its workspace")
end)

test("windows on no workspace join the one shown on their output", function()
  outputs = { { id = 1, name = "DP-1", x = 0, y = 0, w = 1280, h = 720 } }
  views[50] = { output = 1, workspace = 0 } -- e.g. the plugin was just added
  load_plugin()
  eq(views[50].workspace, out_by_id(1).active)
end)

test("custom names, ten workspaces with the key 0", function()
  outputs = { { id = 1, name = "DP-1", x = 0, y = 0, w = 1280, h = 720 } }
  load_plugin({ count = 10, names = { "web", "code" } })
  eq(names_on(1), "web@DP-1 code@DP-1 3@DP-1 4@DP-1 5@DP-1 6@DP-1 7@DP-1 8@DP-1 9@DP-1 10@DP-1")
  press("Super+0")
  eq(active_name(1), "10@DP-1")
  press("Super+2")
  eq(active_name(1), "code@DP-1")
end)

test("activation: urgent by default; switch shows the workspace for user requests only", function()
  two_outputs()
  load_plugin()
  local w3 = plugin.find(out_by_id(2), 3)
  views[60] = { output = 2, workspace = w3.id, minimized = true }
  emit("view_request_activate", 60, true)
  eq(active_name(2), "1@DP-2", "default: the core marks it urgent, nothing switches")
  eq(focused, nil, "not focused")
  load_plugin({ activation = "switch" })
  emit("view_request_activate", 60, false)
  eq(active_name(2), "1@DP-2", "no user input: nothing switches")
  emit("view_request_activate", 60, true)
  eq(active_name(2), "3@DP-2", "user input: its workspace is shown")
  eq(focused, 60, "and it is focused")
  eq(views[60].minimized, false, "restored")
  -- On the shown workspace already: left to the core's default.
  focused = nil
  emit("view_request_activate", 60, true)
  eq(focused, nil, "the core decides")
  local ok = pcall(load_plugin, { activation = "steal" })
  assert(not ok, "a bad option is an error")
end)

test("Super+Alt+Right moves the window to the output on the right and keeps focus", function()
  two_outputs()
  load_plugin()
  views[50] = { output = 1, workspace = out_by_id(1).active }
  focused = 50
  press("Super+Alt+Right")
  eq(views[50].workspace, out_by_id(2).active, "onto the workspace shown there")
  eq(focused, 50)
  press("Super+Alt+Right") -- nothing further right
  eq(views[50].workspace, out_by_id(2).active)
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
