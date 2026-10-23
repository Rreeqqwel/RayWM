-- Tests config/plugins/window-rules.lua against a mock RayWM API: matching
-- (patterns, lists, parent, output, workspace, fixed size, fn), the dialog
-- test, rule order, rules.lua in the config directory, bad rules.
-- Run from the repo root: lua5.4 tests/rules_test.lua
local plugin_path = "config/plugins/window-rules.lua"

local views, calls, focused, handlers, logs, config_dir
local outputs = { { id = 1, name = "DP-1", x = 0, y = 0, w = 1920, h = 1080, workspace = 5,
  usable = { x = 0, y = 30, w = 1920, h = 1050 } } }
local workspaces = { { id = 5, name = "1", home = "DP-1", output = 1 }, { id = 6, name = "2", home = "DP-1", output = 1 } }

local function reset()
  views, calls, focused, handlers, logs = {}, {}, nil, {}, {}
end

local function view(id)
  local v = views[id]
  if not v then return nil, "stale" end
  local r = {}
  for k, x in pairs(v) do r[k] = x end
  r.id = id
  return r
end

raywm = {
  api_version = 1,
  outputs = function() return outputs end,
  workspaces = function() return workspaces end,
  workspace = function(id)
    for _, w in ipairs(workspaces) do if w.id == id then return w end end
    return nil, "stale"
  end,
  view = view,
  focused = function() return focused end,
  pointer = function() return { x = 1000, y = 500, busy = false } end,
  view_floating = function(id, on) calls[#calls + 1] = "floating " .. tostring(on); views[id].floating = on; return true end,
  view_workspace = function(id, ws) calls[#calls + 1] = "workspace " .. ws; views[id].workspace = ws; return true end,
  view_place = function(id, x, y, w, h)
    calls[#calls + 1] = ("place %d,%d %dx%d"):format(x, y, w, h)
    views[id].x, views[id].y, views[id].w, views[id].h = x, y, w, h
    return true
  end,
  view_move = function(id, x, y) calls[#calls + 1] = ("move %d,%d"):format(x, y); views[id].x, views[id].y = x, y; return true end,
  view_opacity = function(_, a) calls[#calls + 1] = "opacity " .. a; return true end,
  view_fullscreen = function(_, on) calls[#calls + 1] = "fullscreen " .. tostring(on); return true end,
  view_maximize = function(_, on) calls[#calls + 1] = "maximize " .. tostring(on); return true end,
  view_focus = function(id) calls[#calls + 1] = "focus " .. id; focused = id; return true end,
  log = function(msg) logs[#logs + 1] = msg end,
}

local plugin
local function load(rules, opts)
  plugin = dofile(plugin_path)
  for k, v in pairs(opts or {}) do plugin.options[k] = v end
  raywm.config_dir = config_dir
  plugin.setup({ on = function(ev, fn) handlers[ev] = fn end })
  if rules then plugin.set_rules(rules) end
end

-- A new window, default: an app with no limits, 400x300 at 760,390, no parent.
local next_id = 10
local function new(fields)
  next_id = next_id + 1
  local v = { x = 760, y = 390, w = 400, h = 300, app_id = "app", title = "Title", parent = 0, output = 1, workspace = 5,
    min_w = 0, min_h = 0, max_w = 0, max_h = 0, floating = false, xwayland = false }
  for k, x in pairs(fields or {}) do v[k] = x end
  views[next_id] = v
  calls = {}
  handlers.view_new(next_id)
  return next_id, table.concat(calls, "; ")
end

local tests, order = {}, {}
local function test(name, fn) tests[name] = fn; order[#order + 1] = name end
local function eq(a, b, msg) if a ~= b then error((msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end end

test("an ordinary window: no rule, nothing done", function()
  load({})
  local _, c = new()
  eq(c, "", "calls")
end)

test("dialogs float centred over their parent; fixed-size windows only when small", function()
  load({})
  local parent = new({ x = 100, y = 130, w = 1000, h = 800 })
  local _, c = new({ parent = parent, w = 200, h = 100 })
  eq(c, "floating true; move 500,480", "dialog over its parent")
  _, c = new({ min_w = 300, min_h = 200, max_w = 300, max_h = 200 })
  eq(c, "floating true", "small fixed size")
  _, c = new({ min_w = 1920, min_h = 1080, max_w = 1920, max_h = 1080 })
  eq(c, "", "screen-sized fixed size is not a dialog")
  _, c = new({ min_w = 300, min_h = 200 }) -- a minimum only
  eq(c, "", "minimum size alone")
  load({}, { auto_float = false })
  _, c = new({ parent = parent })
  eq(c, "", "auto_float off")
end)

test("patterns, lists of patterns and title", function()
  load({
    { match = { app_id = "^foot$" }, opacity = 0.9 },
    { match = { app_id = { "^mpv$", "^vlc$" } }, float = true },
    { match = { title = "Picture%-in%-Picture" }, focus = false },
  })
  local _, c = new({ app_id = "foot" })
  eq(c, "opacity 0.9")
  _, c = new({ app_id = "vlc" })
  eq(c, "floating true")
  _, c = new({ app_id = "footclient" })
  eq(c, "")
  focused = 3
  _, c = new({ title = "Picture-in-Picture" })
  eq(c, "focus 3", "keeps the keyboard where it was")
end)

test("later rules override earlier ones; float = false beats the dialog test", function()
  load({
    { match = { app_id = "^x$" }, float = true, opacity = 0.5 },
    { match = { app_id = "^x$" }, float = false },
  })
  local _, c = new({ app_id = "x", min_w = 300, min_h = 200, max_w = 300, max_h = 200 })
  eq(c, "floating false; opacity 0.5")
end)

test("size and position: pixels, percentages, center, cursor; only when floating", function()
  load({
    { match = { app_id = "^a$" }, float = true, size = { 800, 600 } },
    { match = { app_id = "^b$" }, float = true, size = { "50%", "50%" }, position = { 10, "10%" } },
    { match = { app_id = "^c$" }, float = true, position = "cursor" },
    { match = { app_id = "^d$" }, size = { 800, 600 } }, -- tiled: the layout decides
  })
  local _, c = new({ app_id = "a" })
  eq(c, "floating true; place 560,255 800x600", "centred in the usable area")
  _, c = new({ app_id = "b" })
  eq(c, "floating true; place 10,135 960x525", "percentages")
  _, c = new({ app_id = "c" })
  eq(c, "floating true; place 800,350 400x300", "at the cursor")
  _, c = new({ app_id = "d" })
  eq(c, "", "size of a tiled window is the layout's")
end)

test("parent, output, workspace, fixed_size, xwayland and fn conditions", function()
  load({
    { match = { parent_app_id = "^gimp$" }, opacity = 0.8 },
    { match = { output = "^DP%-1$", workspace = "^1$" }, maximize = true },
    { match = { xwayland = true }, fullscreen = true },
    { match = { fn = function(v) return v.w > 1000 end }, opacity = 0.7 },
  })
  local p = new({ app_id = "gimp", workspace = 6 })
  local _, c = new({ parent = p, workspace = 6, w = 100, h = 100 })
  eq(c, "floating true; move 910,490; opacity 0.8", "parent app id") -- over the 400x300 parent at 760,390
  _, c = new()
  eq(c, "maximize true", "output and workspace")
  _, c = new({ workspace = 6, xwayland = true })
  eq(c, "fullscreen true")
  _, c = new({ workspace = 6, w = 1200 })
  eq(c, "opacity 0.7")
end)

test("workspace and output actions", function()
  load({ { match = { app_id = "^w$" }, workspace = "2" }, { match = { app_id = "^o$" }, output = "HDMI-A-1" } })
  local _, c = new({ app_id = "w" })
  eq(c, "workspace 6")
  _, c = new({ app_id = "o" })
  eq(c, "", "no such output")
  eq(logs[#logs], "window-rules: no output named HDMI-A-1")
end)

test("bad rules are reported and dropped, the others kept", function()
  load({ { match = { app_id = "[" }, float = true }, { match = { app_id = 5 } }, "nope", { match = { app_id = "^ok$" }, float = true } })
  eq(#logs, 3, "three bad rules reported")
  local _, c = new({ app_id = "ok" })
  eq(c, "floating true")
end)

test("rules.lua in the config directory: rules and options", function()
  config_dir = os.getenv("TMPDIR") or "/tmp"
  config_dir = config_dir .. "/raywm-rules-test-" .. tostring(os.time()) .. tostring(math.random(1e6))
  os.execute("mkdir -p '" .. config_dir .. "'")
  local f = assert(io.open(config_dir .. "/rules.lua", "w"))
  f:write('return { options = { dialog_max = 0.1 }, rules = { { match = { app_id = "^from%-file$" }, opacity = 0.4 } } }')
  f:close()
  load(nil)
  local _, c = new({ app_id = "from-file" })
  eq(c, "opacity 0.4", "rule from the file")
  _, c = new({ min_w = 300, min_h = 200, max_w = 300, max_h = 200 })
  eq(c, "", "options from the file: dialog_max 0.1")
  -- A broken file is reported, not fatal.
  f = assert(io.open(config_dir .. "/rules.lua", "w"))
  f:write("return 42")
  f:close()
  logs = {}
  load(nil)
  assert(logs[1] and logs[1]:find("rules.lua ignored"), "broken rules.lua reported")
  os.remove(config_dir .. "/rules.lua")
  os.remove(config_dir)
  config_dir = nil
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
