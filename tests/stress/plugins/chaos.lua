-- Torture suite (tests/stress): random window management from the
-- compositor side, seeded by RAYWM_CHAOS_SEED (plus the number of earlier
-- loads, so every reload continues with a new but reproducible stream).
-- Every RAYWM_CHAOS_PERIOD_MS (default 5) it picks one action on a random
-- window: focus, raise, float toggle, fullscreen, maximize, minimize and
-- restore, hide and show, opacity, a native animation, move to another
-- workspace, switch workspace, place, close, or (per mille
-- RAYWM_CHAOS_RELOAD) a reload. It stops for good when $RAYWM_STRESS_DIR/stop
-- exists, after undoing hide/minimize so that every window can be audited.
-- Actions go to $RAYWM_STRESS_DIR/chaos-plugin.log when RAYWM_CHAOS_LOG=1.
local dir = assert(os.getenv("RAYWM_STRESS_DIR"))
local period = tonumber(os.getenv("RAYWM_CHAOS_PERIOD_MS") or "5")
local reload_pm = tonumber(os.getenv("RAYWM_CHAOS_RELOAD") or "0")
local verbose = os.getenv("RAYWM_CHAOS_LOG") == "1"

local loads = 0
do
  local f = io.open(dir .. "/chaos-loads", "r")
  if f then loads = tonumber(f:read("l") or "0") or 0; f:close() end
  f = assert(io.open(dir .. "/chaos-loads", "w")); f:write(loads + 1, "\n"); f:close()
end
-- 31-bit LCG: same seed, same stream (Lua's math.random seeding differs by version).
local state = (tonumber(os.getenv("RAYWM_CHAOS_SEED") or "1") * 7919 + loads * 104729) % 2147483648
local function rand(n)
  state = (state * 1103515245 + 12345) % 2147483648
  return (state >> 8) % n
end

local log = verbose and assert(io.open(dir .. "/chaos-plugin.log", "a")) or nil
if log then log:setvbuf("line") end
local count = 0

local function exists(path)
  local f = io.open(path, "r")
  if f then f:close() return true end
  return false
end

local hidden = {}

-- RAYWM_CHAOS_ACTIONS=a,b: only these actions (for bisecting a failure).
local only
if os.getenv("RAYWM_CHAOS_ACTIONS") then
  only = {}
  for a in os.getenv("RAYWM_CHAOS_ACTIONS"):gmatch("[^,]+") do only[a] = true end
end

-- Each action: name, its share of 1000 (cumulative), and the code.
local actions = {
  { "focus", 150, function(id) raywm.view_focus(id) end },
  { "raise", 220, function(id) raywm.view_raise(id) end },
  { "floating", 300, function(id, v) raywm.view_floating(id, not v.floating) end },
  { "fullscreen", 370, function(id, v) raywm.view_fullscreen(id, not v.fullscreen) end },
  { "maximize", 430, function(id, v) raywm.view_maximize(id, not v.maximized) end },
  { "minimize", 490, function(id, v) raywm.view_minimize(id, not v.minimized) end },
  { "hide", 530, function(id) raywm.view_show(id, false); hidden[id] = true end },
  { "show", 580, function() for h in pairs(hidden) do raywm.view_show(h, true) end; hidden = {} end },
  { "opacity", 610, function(id) raywm.view_opacity(id, rand(101) / 100) end },
  { "animate", 650, function(id, _, ctx)
    ctx.animate(id, { duration = 20 + rand(200), x = rand(200) - 100, y = rand(200) - 100,
      from_opacity = 0, opacity = 1, snapshot = rand(4) == 0 })
  end },
  { "to_workspace", 720, function(id)
    local ws = raywm.workspaces and raywm.workspaces() or {}
    if #ws > 0 then raywm.view_workspace(id, ws[rand(#ws) + 1].id) end
  end },
  { "activate", 790, function()
    local ws = raywm.workspaces and raywm.workspaces() or {}
    if #ws > 0 then raywm.workspace_activate(ws[rand(#ws) + 1].id) end
  end },
  -- Geometry of floating windows only: tiled ones belong to the layout.
  { "place", 880, function(id, v)
    if not v.managed then raywm.view_place(id, rand(2000) - 300, rand(1200) - 200, 1 + rand(2000), 1 + rand(1500)) end
  end },
  { "move", 900, function(id, v) if not v.managed then raywm.view_move(id, rand(3000) - 1000, rand(3000) - 1000) end end },
  { "close", 940, function(id) raywm.view_close(id) end },
  { "urgent", 970, function(id) raywm.view_urgent(id, rand(2) == 1) end },
  { "pointer", 1000, function() raywm.pointer_warp(rand(1280), rand(720)) end },
}

local function act(ctx)
  local ids = raywm.views()
  local id = #ids > 0 and ids[rand(#ids) + 1] or nil
  local r = rand(1000)
  local what = "none"
  if r < reload_pm then
    what = "reload"
    if not only or only.reload then raywm.reload() end
  elseif id then
    for _, a in ipairs(actions) do
      if r < a[2] then
        what = a[1]
        local v = raywm.view(id)
        if v and (not only or only[what]) then a[3](id, v, ctx) end
        break
      end
    end
  end
  count = count + 1
  if log then log:write(count, " ", what, " ", tostring(id), "\n") end
end

-- Undo what would make windows invisible to the audit.
local function restore()
  for h in pairs(hidden) do raywm.view_show(h, true) end
  hidden = {}
  for _, id in ipairs(raywm.views()) do
    local v = raywm.view(id)
    if v and v.minimized then raywm.view_minimize(id, false) end
  end
  local f = io.open(dir .. "/chaos-stopped", "w")
  if f then f:write(count, "\n"); f:close() end
end

return {
  api = 1,
  setup = function(ctx)
    if exists(dir .. "/stop") then return restore() end
    local function tick()
      if exists(dir .. "/stop") then return restore() end
      act(ctx)
      ctx.timer(period, tick)
    end
    ctx.timer(period, tick)
  end,
  teardown = function()
    if log then log:write("teardown after ", count, "\n") end
  end,
}
