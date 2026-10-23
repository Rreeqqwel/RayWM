-- Window rules: where and how windows open.
--
-- Rules are checked once, when a window maps (the view_new event, before
-- layouts such as dwindle see it), so a window never shows up in one
-- place and then jumps: its workspace, output, floating state and
-- position are set before it is drawn, and a new size is drawn before the
-- window is shown (the core waits for it).
--
-- Every rule whose `match` fits is applied, in order; a later rule
-- overrides an earlier one. Before the rules, dialogs float (see
-- `auto_float`), centred over their parent window.
--
-- Your rules: in `rules` below, or (better, it survives upgrades of this
-- file) in rules.lua next to init.lua, which returns a list of rules, or
-- a table { rules = {...}, options = {...} }. Its rules come after these.
--
-- match (all given fields must fit; strings are Lua patterns, a list of
-- them fits if any does):
--   app_id, title         the window's app id (for X11 windows: the class)
--                         and title
--   parent = true|false   whether it is a dialog of another window
--   parent_app_id         app id of the window it is a dialog of
--   output                name of the output it opens on, e.g. "DP%-1"
--   workspace             name of the workspace it would open on
--   fixed_size = bool     its minimum and maximum size are the same
--   xwayland = bool       an X11 window
--   fn = function(view)   any test on the raywm.view() table
--
-- actions (all optional):
--   float = true|false    floating, or tiled even if it is a dialog
--   size = { w, h }       pixels, or strings like "50%" of the usable area
--   position = { x, y } | "center" | "cursor"
--                         { x, y }: pixels from the top-left of the usable
--                         area (only for floating windows)
--   opacity = 0..1
--   workspace = "name"    on the output it opens on (with workspaces.lua)
--   output = "name"       an output name; with workspaces, the workspace
--                         shown there
--   focus = false         do not take the keyboard from the focused window
--   fullscreen = bool, maximize = bool
--   decoration = "server" | "client" | "auto"
--                         who draws the title bar (xdg-decoration). RayWM
--                         draws none: "server" removes the client's own,
--                         "client" keeps it; "auto" (default) does what the
--                         client asks. Clients without xdg-decoration
--                         support (GTK) always draw their own.

local options = {
  -- Float dialogs: windows with a parent, and windows whose size is fixed
  -- (minimum = maximum) and at most `dialog_max` of the usable area in
  -- both directions. A fixed-size window as large as the screen (a game,
  -- a kiosk application) is not taken for a dialog.
  auto_float = true,
  dialog_max = 0.8,
}

-- Rules of this file. Your own are best kept in rules.lua (see above),
-- which has examples.
local rules = {}

local function fits(pattern, s)
  if type(pattern) == "table" then
    for _, p in ipairs(pattern) do
      if s:find(p) then return true end
    end
    return false
  end
  return s:find(pattern) ~= nil
end

local function outputs_by_id()
  local by_id = {}
  for _, o in ipairs(raywm.outputs()) do by_id[o.id] = o end
  return by_id
end

local function fixed(v)
  return v.min_w > 0 and v.min_h > 0 and v.min_w == v.max_w and v.min_h == v.max_h
end

-- Rules and options from rules.lua in the config directory, if any.
local function load_user_rules()
  local path = raywm.config_dir and (raywm.config_dir .. "/rules.lua")
  local f = path and io.open(path, "r")
  if not f then return end
  f:close()
  local chunk, err = loadfile(path)
  local ok, t = false, err
  if chunk then ok, t = pcall(chunk) end
  if not ok or type(t) ~= "table" then
    raywm.log(("window-rules: %s ignored: %s"):format(path, tostring(ok and "it must return a table" or t)))
    return
  end
  for k, v in pairs(t.options or {}) do options[k] = v end
  for _, r in ipairs(t.rules or t) do rules[#rules + 1] = r end
end

local function is_dialog(v, out)
  if v.parent ~= 0 then return true end
  if not fixed(v) or not out then return false end
  local u = out.usable
  return v.min_w <= u.w * options.dialog_max and v.min_h <= u.h * options.dialog_max
end

local function workspace_name(id)
  local w = id ~= 0 and raywm.workspace and raywm.workspace(id)
  return w and w.name or ""
end

local function matches(m, v, out)
  if m.app_id and not fits(m.app_id, v.app_id) then return false end
  if m.title and not fits(m.title, v.title) then return false end
  if m.parent ~= nil and (v.parent ~= 0) ~= m.parent then return false end
  if m.parent_app_id then
    local p = v.parent ~= 0 and raywm.view(v.parent)
    if not p or not fits(m.parent_app_id, p.app_id) then return false end
  end
  if m.output and not (out and fits(m.output, out.name)) then return false end
  if m.workspace and not fits(m.workspace, workspace_name(v.workspace)) then return false end
  if m.fixed_size ~= nil and fixed(v) ~= m.fixed_size then return false end
  if m.xwayland ~= nil and v.xwayland ~= m.xwayland then return false end
  if m.fn and not m.fn(v) then return false end
  return true
end

-- "50%" of `total`, or a number of pixels.
local function length(spec, total)
  if type(spec) == "string" then
    local pct = tonumber(spec:match("^(%d+%.?%d*)%%$"))
    return pct and math.floor(total * pct / 100) or nil
  end
  return math.tointeger(spec) or (type(spec) == "number" and math.floor(spec)) or nil
end

-- The workspace named `name` on output `out`, preferring the one that
-- belongs there.
local function find_workspace(out, name)
  if not raywm.workspaces then return nil end
  local other
  for _, w in ipairs(raywm.workspaces()) do
    if w.output == out.id and w.name == name then
      if w.home == out.name then return w end
      other = other or w
    end
  end
  return other
end

local function find_output(name)
  for _, o in ipairs(raywm.outputs()) do
    if o.name == name then return o end
  end
  return nil
end

-- Decides everything first, then applies it in an order that never shows
-- an intermediate state: place (output, workspace), floating, geometry,
-- looks, states, focus.
local function apply(id)
  local v = raywm.view(id)
  if not v then return end
  local by_id = outputs_by_id()
  local out = by_id[v.output]
  local d = {}
  if options.auto_float and is_dialog(v, out) then d.float = true end
  for _, r in ipairs(rules) do
    if matches(r.match or {}, v, out) then
      for _, k in ipairs({ "float", "size", "position", "opacity", "workspace", "output", "focus", "fullscreen", "maximize", "decoration" }) do
        if r[k] ~= nil then d[k] = r[k] end
      end
    end
  end

  if d.output then
    local target = find_output(d.output)
    if target and target.id ~= v.output then
      if target.workspace ~= 0 then
        raywm.view_workspace(id, target.workspace)
      else
        raywm.view_move(id, target.usable.x + (target.usable.w - v.w) // 2, target.usable.y + (target.usable.h - v.h) // 2)
      end
      out = target
    elseif not target then
      raywm.log(("window-rules: no output named %s"):format(d.output))
    end
  end
  if d.workspace and out then
    local w = find_workspace(out, tostring(d.workspace))
    if w then raywm.view_workspace(id, w.id) end
  end
  if d.float ~= nil then raywm.view_floating(id, d.float) end

  v = raywm.view(id) or v
  -- A floating dialog without a position of its own: over its parent.
  if v.floating and v.parent ~= 0 and not d.position and out then
    local p = raywm.view(v.parent)
    if p then
      local u = out.usable
      local x = math.max(u.x, math.min(u.x + u.w - v.w, p.x + (p.w - v.w) // 2))
      local y = math.max(u.y, math.min(u.y + u.h - v.h, p.y + (p.h - v.h) // 2))
      raywm.view_move(id, x, y)
      v = raywm.view(id) or v
    end
  end
  if (d.size or d.position) and v.floating and out then
    local u = out.usable
    local w = d.size and length(d.size[1], u.w) or v.w
    local h = d.size and length(d.size[2], u.h) or v.h
    w, h = math.max(1, w or v.w), math.max(1, h or v.h)
    local x, y = v.x, v.y
    if d.position == "center" or (d.size and not d.position) then
      x, y = u.x + (u.w - w) // 2, u.y + (u.h - h) // 2
    elseif d.position == "cursor" then
      local p = raywm.pointer()
      x = math.max(u.x, math.min(u.x + u.w - w, p.x - w // 2))
      y = math.max(u.y, math.min(u.y + u.h - h, p.y - h // 2))
    elseif type(d.position) == "table" then
      x = u.x + (length(d.position[1], u.w) or 0)
      y = u.y + (length(d.position[2], u.h) or 0)
    end
    raywm.view_place(id, x, y, w, h)
  end
  if d.opacity then raywm.view_opacity(id, d.opacity) end
  if d.decoration and raywm.view_decoration then raywm.view_decoration(id, d.decoration) end
  if d.fullscreen ~= nil then raywm.view_fullscreen(id, d.fullscreen) end
  if d.maximize ~= nil then raywm.view_maximize(id, d.maximize) end
  if d.focus == false then
    -- Keep the keyboard where it is: choosing focus ourselves (even the
    -- same window) tells the core not to focus the new window.
    local prev = raywm.focused()
    if prev and prev ~= id then raywm.view_focus(prev) end
  end
end

-- A bad pattern would stop the plugin on the first window: check them
-- once, and drop (and report) rules that do not work.
local function check_rules()
  local ok_rules = {}
  for i, r in ipairs(rules) do
    local ok, err = pcall(function()
      assert(type(r) == "table", "a rule must be a table")
      local deco = r.decoration
      assert(deco == nil or deco == "server" or deco == "client" or deco == "auto",
        'decoration must be "server", "client" or "auto"')
      for _, k in ipairs({ "app_id", "title", "parent_app_id", "output", "workspace" }) do
        local p = (r.match or {})[k]
        for _, s in ipairs(type(p) == "table" and p or { p }) do
          if s ~= nil then
            assert(type(s) == "string", k .. " must be a string or a list of strings")
            local _ = ("x"):find(s) -- raises on a malformed pattern
          end
        end
      end
    end)
    if ok then
      ok_rules[#ok_rules + 1] = r
    else
      raywm.log(("window-rules: rule %d ignored: %s"):format(i, tostring(err)))
    end
  end
  rules = ok_rules
end

return {
  api = 1,
  setup = function(ctx)
    load_user_rules()
    check_rules()
    ctx.on("view_new", apply)
  end,
  -- For tests only.
  options = options,
  set_rules = function(r)
    rules = r
    check_rules()
  end,
  is_dialog = is_dialog,
}
