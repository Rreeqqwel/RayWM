-- Torture suite (tests/stress): checks compositor invariants on request.
-- Every 50 ms it looks for $RAYWM_STRESS_DIR/audit-request; when present it
-- removes it and writes audit.txt (overwritten): a "window" line per view,
-- "VIOLATION ..." lines, then "audit done N". Invariants:
--   * every id of raywm.views() resolves with raywm.view();
--   * the focused window exists, is visible, not minimized, and is on a
--     shown workspace;
--   * tiled windows (managed, visible, not fullscreen/maximized/minimized)
--     on the same output and workspace do not overlap and lie inside the
--     output's usable area;
--   * every output shows exactly one workspace (with a workspace plugin);
--   * the number of mapped views equals $RAYWM_STRESS_DIR/expect-views
--     when that file exists.
local dir = assert(os.getenv("RAYWM_STRESS_DIR"))
local n = 0

-- The last geometry any plugin asked for, per window (diagnostics: shows
-- whether a wrong position comes from the layout or from the core).
local requested, boxes, seq = {}, {}, 0
local real_place, real_move = raywm.view_place, raywm.view_move
raywm.view_place = function(id, x, y, w, h)
  seq = seq + 1
  requested[id] = string.format("place#%d %d,%d %dx%d", seq, x, y, w, h)
  boxes[id] = { x = x, y = y, w = w, h = h }
  return real_place(id, x, y, w, h)
end
raywm.view_move = function(id, x, y)
  seq = seq + 1
  requested[id] = string.format("move#%d %d,%d", seq, x, y)
  if boxes[id] then boxes[id].x, boxes[id].y = x, y end
  return real_move(id, x, y)
end

local function exists(path)
  local f = io.open(path, "r")
  if f then f:close() return true end
  return false
end

local function shown(v)
  if not raywm.workspace or (v.workspace or 0) == 0 then return true end
  local w = raywm.workspace(v.workspace)
  return w ~= nil and w.active
end

local function audit()
  n = n + 1
  local out = assert(io.open(dir .. "/audit.txt.tmp", "w"))
  local bad = 0
  local function violation(msg) bad = bad + 1; out:write("VIOLATION ", msg, "\n") end
  local ids = raywm.views()
  local views = {}
  for _, id in ipairs(ids) do
    local v = raywm.view(id)
    if not v then
      violation("views() lists " .. id .. " but view() has none")
    else
      views[#views + 1] = v
      v.id = id
      out:write(string.format("window %d %d,%d %dx%d out=%d ws=%d focused=%s visible=%s floating=%s fullscreen=%s maximized=%s minimized=%s managed=%s title=%q req=%s\n",
        id, v.x, v.y, v.w, v.h, v.output or 0, v.workspace or 0, tostring(v.focused), tostring(v.visible), tostring(v.floating),
        tostring(v.fullscreen), tostring(v.maximized), tostring(v.minimized), tostring(v.managed), v.title or "", requested[id] or "-"))
    end
  end
  local f = raywm.focused()
  if f then
    local v = raywm.view(f)
    if not v then violation("focused " .. f .. " does not exist")
    else
      if not v.visible then violation("focused " .. f .. " is not visible") end
      if v.minimized then violation("focused " .. f .. " is minimized") end
      if not shown(v) then violation("focused " .. f .. " is on a hidden workspace") end
    end
  end
  local outputs = {}
  for _, o in ipairs(raywm.outputs()) do outputs[o.id] = o end
  -- Tiling, in two parts that separate layout bugs from core bugs:
  --  * the boxes the layout requested (view_place) do not overlap and lie
  --    inside the usable area of the output that holds the window's
  --    workspace;
  --  * the window's real geometry is that box, its size clamped to the
  --    client's own min/max size hints (a client whose minimum is larger
  --    than its tile legitimately sticks out of it).
  local tiled = {}
  local no_tiling = os.getenv("RAYWM_AUDIT_NO_TILING") == "1" -- two layouts fight on purpose
  for _, v in ipairs(views) do
    if not no_tiling and v.managed and v.visible and not v.fullscreen and not v.maximized and not v.minimized and not v.floating and shown(v) then
      -- Requests made before this Lua state (a reload) are not recorded:
      -- the layout re-requests only what changes, so the window's own
      -- geometry stands in for its tile then.
      local b = boxes[v.id] or { x = v.x, y = v.y, w = v.w, h = v.h }
      do
        tiled[#tiled + 1] = { v = v, b = b }
        local function clamp(x, lo, hi)
          if hi and hi > 0 and x > hi then x = hi end
          if lo and lo > 0 and x < lo then x = lo end
          return x
        end
        -- The core asks for exactly that size; the shipped layout keeps the
        -- hints in mind but a client may still pick another size (xdg-shell
        -- allows it for min/max hints only): check against the request,
        -- and accept a size that the hints force.
        local ew, eh = b.w, b.h
        if v.w ~= ew and v.w == clamp(b.w, v.min_w, v.max_w) then ew = v.w end
        if v.h ~= eh and v.h == clamp(b.h, v.min_h, v.max_h) then eh = v.h end
        if v.x ~= b.x or v.y ~= b.y or v.w ~= ew or v.h ~= eh then
          violation(string.format("tiled %d is %d,%d %dx%d, expected %d,%d %dx%d (asked %dx%d, min %dx%d max %dx%d)",
            v.id, v.x, v.y, v.w, v.h, b.x, b.y, ew, eh, b.w, b.h, v.min_w or 0, v.min_h or 0, v.max_w or 0, v.max_h or 0))
        end
      end
    end
  end
  local ws_output = {}
  if raywm.workspaces then for _, w in ipairs(raywm.workspaces()) do ws_output[w.id] = w.output end end
  for _, t in ipairs(tiled) do
    local o = outputs[ws_output[t.v.workspace] or t.v.output]
    if o then
      local u, b = o.usable, t.b
      if b.x < u.x or b.y < u.y or b.x + b.w > u.x + u.w or b.y + b.h > u.y + u.h then
        violation(string.format("tile of %d %d,%d %dx%d outside usable %d,%d %dx%d", t.v.id, b.x, b.y, b.w, b.h, u.x, u.y, u.w, u.h))
      end
    end
  end
  for i = 1, #tiled do
    for j = i + 1, #tiled do
      local a, b = tiled[i], tiled[j]
      -- dwindle shares areas too small to split (under 10 px in a
      -- direction, with very many windows) on purpose, as its own tests do.
      local tiny = math.min(a.b.w, a.b.h, b.b.w, b.b.h) < 10
      if not tiny and a.v.workspace == b.v.workspace and (a.v.workspace ~= 0 or a.v.output == b.v.output) and
        a.b.x < b.b.x + b.b.w and b.b.x < a.b.x + a.b.w and a.b.y < b.b.y + b.b.h and b.b.y < a.b.y + a.b.h then
        violation(string.format("tiles of %d and %d overlap", a.v.id, b.v.id))
      end
    end
  end
  if raywm.workspaces then
    local active = {}
    for _, w in ipairs(raywm.workspaces()) do
      if w.active and (w.output or 0) ~= 0 then active[w.output] = (active[w.output] or 0) + 1 end
    end
    for id in pairs(outputs) do
      if (active[id] or 0) > 1 then violation("output " .. id .. " shows " .. active[id] .. " workspaces") end
    end
  end
  local ef = io.open(dir .. "/expect-views", "r")
  if ef then
    local want = tonumber(ef:read("l") or "")
    ef:close()
    if want and want ~= #views then violation("expected " .. want .. " mapped views, compositor has " .. #views) end
  end
  -- raywm.settings (raywm.conf as this Lua state sees it), sorted.
  if raywm.settings then
    local lines = {}
    for sec, t in pairs(raywm.settings) do
      for k, v in pairs(t) do lines[#lines + 1] = "setting " .. sec .. "." .. k .. "=" .. tostring(v) end
    end
    table.sort(lines)
    for _, l in ipairs(lines) do out:write(l, "\n") end
  end
  out:write("audit done ", n, " violations=", bad, "\n")
  out:close()
  -- audit-N.txt is kept; audit.txt is the latest.
  local src = io.open(dir .. "/audit.txt.tmp", "r")
  local text = src:read("a"); src:close()
  local keep = io.open(dir .. "/audit-" .. n .. ".txt", "w"); keep:write(text); keep:close()
  os.rename(dir .. "/audit.txt.tmp", dir .. "/audit.txt")
end

return {
  api = 1,
  setup = function(ctx)
    local function tick()
      if exists(dir .. "/audit-request") then
        os.remove(dir .. "/audit-request")
        audit()
      end
      ctx.timer(50, tick)
    end
    ctx.timer(50, tick)
  end,
}
