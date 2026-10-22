-- Tests config/plugins/focus.lua (directional focus, focus cycle, pointer
-- warp, focus border) against a mock of the RayWM API that follows the
-- core's rules: views() is most-recently-focused first, view_focus raises
-- the window to the front of that list and emits view_focus, hidden
-- windows cannot be focused. Run from the repo root: lua5.4 tests/focus_test.lua
local plugin_path = "config/plugins/focus.lua"

local views, mru, outputs, focused, pointer
local handlers, binds, warps, borders, focus_calls

local function reset()
  views, mru, outputs, focused = {}, {}, {}, nil
  pointer = { x = 0, y = 0, busy = false }
  handlers, binds, warps, borders, focus_calls = {}, {}, {}, {}, 0
end

local function emit(ev, id)
  for _, h in ipairs(handlers[ev] or {}) do h(id) end
end

raywm = {
  api_version = 1,
  views = function()
    local r = {}
    for i, id in ipairs(mru) do r[i] = id end
    return r
  end,
  view = function(id)
    local v = views[id]
    if not v then return nil, "stale" end
    return { id = id, x = v.x, y = v.y, w = v.w, h = v.h, output = v.output, visible = v.visible ~= false,
      focused = focused == id, title = "", app_id = "" }
  end,
  focused = function() return focused end,
  outputs = function()
    local r = {}
    for i, o in ipairs(outputs) do r[i] = { id = o.id, x = o.x, y = o.y, w = o.w, h = o.h, usable = o } end
    return r
  end,
  view_focus = function(id)
    local v = views[id]
    if not v then return nil, "stale" end
    focus_calls = focus_calls + 1
    if v.visible == false then return true end
    focused = id
    for i, x in ipairs(mru) do if x == id then table.remove(mru, i) break end end
    table.insert(mru, 1, id)
    emit("view_focus", id)
    return true
  end,
  view_border = function(id, width, color)
    assert(type(width) == "number")
    if width > 0 then assert(type(color) == "string" and color:match("^#%x%x%x%x%x%x%x?%x?$"), "bad color") end
    if not views[id] then return nil, "stale" end
    borders[id] = width > 0 and color or nil
    return true
  end,
  pointer = function() return { x = pointer.x, y = pointer.y, busy = pointer.busy } end,
  pointer_warp = function(x, y)
    if pointer.busy then return nil, "busy" end
    warps[#warps + 1] = x .. "," .. y
    pointer.x, pointer.y = x, y
    return true
  end,
  log = function() end,
}

local plugin
local function load_plugin()
  handlers, binds = {}, {}
  plugin = dofile(plugin_path)
  assert(plugin.api == 1)
  plugin.setup({
    bind = function(k, fn)
      assert(not binds[k], "key bound twice: " .. k)
      binds[k] = fn
      return 1
    end,
    on = function(ev, fn) handlers[ev] = handlers[ev] or {}; table.insert(handlers[ev], fn) return 1 end,
    timer = function() error("unused") end,
    cancel = function() return true end,
    manage = function() return true end,
  })
end

-- add(id, x, y, w, h [, output]) : a mapped window, focused last = front.
local function add(id, x, y, w, h, out)
  views[id] = { x = x, y = y, w = w, h = h, output = out or 1 }
  table.insert(mru, 1, id)
end
local function one_output() outputs = { { id = 1, x = 0, y = 0, w = 1280, h = 720 } } end
local function focus(id) raywm.view_focus(id) end
local function press(key) assert(binds[key], "no binding " .. key)() end

local tests, order = {}, {}
local function test(name, fn) tests[name] = fn; order[#order + 1] = name end
local function eq(a, b, msg) if a ~= b then error((msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end end

-- Dwindle with gap 8 on 1280x720:
--   2 windows: A 8,8 628x704 | B 644,8 628x704
--   3 windows: A left; B 644,8 628x348 (top right); C 644,364 628x348
--   4 windows: A; B top right; C 644,364 310x348; D 962,364 310x348
local function dwindle(n)
  one_output()
  add(2, 8, 8, 628, 704)
  if n == 2 then add(3, 644, 8, 628, 704) end
  if n >= 3 then add(3, 644, 8, 628, 348) end
  if n == 3 then add(4, 644, 364, 628, 348) end
  if n == 4 then add(4, 644, 364, 310, 348); add(5, 962, 364, 310, 348) end
  focused = mru[1]
end

test("default bindings", function()
  reset(); one_output(); load_plugin()
  for _, k in ipairs({ "Super+h", "Super+j", "Super+k", "Super+l", "Super+Tab", "Super+Shift+Tab" }) do
    assert(binds[k], "missing " .. k)
  end
  local n = 0
  for _ in pairs(binds) do n = n + 1 end
  eq(n, 6, "binding count")
end)

test("two tiled windows: left/right, nothing up/down", function()
  reset(); dwindle(2); load_plugin()
  eq(focused, 3)
  press("Super+h"); eq(focused, 2, "left")
  press("Super+h"); eq(focused, 2, "no window further left: unchanged")
  press("Super+k"); eq(focused, 2, "nothing above")
  press("Super+j"); eq(focused, 2, "nothing below")
  press("Super+l"); eq(focused, 3, "right")
end)

test("three tiled windows: up/down in the right column, ties by recency", function()
  reset(); dwindle(3); load_plugin()
  eq(focused, 4) -- C bottom right
  press("Super+k"); eq(focused, 3, "C up -> B")
  press("Super+j"); eq(focused, 4, "B down -> C")
  press("Super+h"); eq(focused, 2, "C left -> A")
  -- From A, B and C are equally near and aligned: the most recent (C).
  press("Super+l"); eq(focused, 4, "A right -> most recent of B/C")
  press("Super+k"); press("Super+h"); press("Super+l")
  eq(focused, 3, "A right -> B after visiting B last")
end)

test("four tiled windows (dwindle spiral)", function()
  reset(); dwindle(4); load_plugin()
  eq(focused, 5) -- D
  press("Super+h"); eq(focused, 4, "D left -> C")
  press("Super+k"); eq(focused, 3, "C up -> B")
  press("Super+j"); eq(focused, 4, "B down -> C (most recent of C/D)")
  press("Super+l"); eq(focused, 5, "C right -> D")
  press("Super+k"); eq(focused, 3, "D up -> B")
  press("Super+h"); eq(focused, 2, "B left -> A")
  press("Super+l"); eq(focused, 3, "A right -> B (most recent)")
end)

test("directly beside beats diagonal and nearer beats aligned", function()
  reset(); one_output()
  add(2, 100, 100, 100, 100) -- current
  add(3, 300, 400, 100, 100) -- right, below: diagonal only
  add(4, 600, 150, 100, 100) -- right, overlapping rows: wins though farther
  focused = 2; load_plugin()
  press("Super+l"); eq(focused, 4)
  reset(); one_output()
  add(2, 100, 100, 100, 100)
  add(3, 250, 180, 100, 100) -- overlapping rows, gap 50, offset 80
  add(4, 400, 100, 100, 100) -- overlapping rows, gap 200, aligned
  focused = 2; load_plugin()
  press("Super+l"); eq(focused, 3, "smaller gap first")
end)

test("only diagonal candidates: nearest by edge distance", function()
  reset(); one_output()
  add(2, 500, 300, 100, 100)
  add(3, 700, 0, 100, 100)   -- right and above: edge gaps 100 + 200
  add(4, 650, 500, 100, 100) -- right and below: edge gaps 50 + 100
  focused = 2; load_plugin()
  press("Super+l"); eq(focused, 4)
end)

test("windows that span or enclose the current one are not in a direction", function()
  reset(); one_output()
  add(2, 400, 300, 100, 100)
  add(3, 0, 500, 1280, 100) -- wide window below: down, but not left/right
  add(4, 350, 250, 300, 300) -- encloses 2 (floating, behind)
  focused = 2; load_plugin()
  press("Super+l"); eq(focused, 2, "no window right")
  press("Super+h"); eq(focused, 2, "no window left")
  press("Super+j"); eq(focused, 3, "down")
end)

test("hidden windows are skipped", function()
  reset(); dwindle(2); views[2].visible = false; load_plugin()
  press("Super+h"); eq(focused, 3, "hidden A is not a target")
  eq(focus_calls, 0, "no focus request at all")
end)

test("nothing focused: the most recent visible window", function()
  reset(); dwindle(3); focused = nil; views[4].visible = false; load_plugin()
  press("Super+l"); eq(focused, 3)
  reset(); one_output(); load_plugin()
  press("Super+l"); eq(focused, nil, "no windows: no-op")
  press("Super+Tab"); eq(focused, nil)
end)

local function two_outputs()
  outputs = { { id = 1, x = 0, y = 0, w = 1280, h = 720 }, { id = 10, x = 1280, y = 0, w = 1280, h = 720 } }
end

test("two outputs: same output first, then the next one in that direction", function()
  reset(); two_outputs()
  add(2, 8, 8, 628, 704, 1)
  add(3, 644, 8, 628, 704, 1)
  add(4, 1288, 8, 628, 348, 10)
  add(5, 1288, 364, 628, 348, 10)
  add(6, 1924, 8, 628, 704, 10)
  focused = 2; load_plugin()
  press("Super+l"); eq(focused, 3, "same output first")
  press("Super+l"); eq(focused, 5, "then the next output (aligned, most recent of 4/5 is 5)")
  press("Super+l"); eq(focused, 6)
  press("Super+l"); eq(focused, 6, "no output further right")
  press("Super+h"); press("Super+h"); eq(focused, 3, "back across the edge")
  press("Super+k"); eq(focused, 3, "up never jumps to another output")
  plugin.options.cross_output = false
  press("Super+l"); eq(focused, 3, "cross_output = false stays on the output")
end)

test("two outputs stacked vertically", function()
  reset()
  outputs = { { id = 1, x = 0, y = 0, w = 1280, h = 720 }, { id = 2, x = 0, y = 720, w = 1280, h = 720 } }
  add(3, 8, 8, 1264, 704, 1)
  add(4, 8, 728, 628, 704, 2)
  add(5, 644, 728, 628, 704, 2)
  focused = 3; load_plugin()
  press("Super+l"); eq(focused, 3, "nothing to the right")
  press("Super+j"); eq(focused, 5, "down onto the lower output (tie: most recent)")
  press("Super+k"); eq(focused, 3)
end)

test("cycle: outputs left to right, then opening order; wraps both ways", function()
  reset(); two_outputs()
  add(7, 1300, 10, 100, 100, 10)
  add(2, 10, 10, 100, 100, 1)
  add(5, 400, 10, 100, 100, 1)
  add(3, 1500, 10, 100, 100, 10)
  focused = 2; load_plugin()
  local seen = {}
  for _ = 1, 5 do press("Super+Tab"); seen[#seen + 1] = focused end
  eq(table.concat(seen, " "), "5 3 7 2 5")
  press("Super+Shift+Tab"); eq(focused, 2)
  press("Super+Shift+Tab"); eq(focused, 7)
end)

test("cycle: closed and hidden windows, nothing focused", function()
  reset(); one_output()
  add(2, 0, 0, 10, 10); add(3, 20, 0, 10, 10); add(4, 40, 0, 10, 10)
  focused = 3; load_plugin()
  views[4] = nil; table.remove(mru, 1) -- 4 closed
  press("Super+Tab"); eq(focused, 2, "skips the closed window")
  views[3].visible = false
  press("Super+Tab"); eq(focused, 2, "only one visible window: stays")
  focused = nil
  press("Super+Shift+Tab"); eq(focused, 2)
end)

test("warp: off by default", function()
  reset(); dwindle(2); load_plugin()
  press("Super+h"); eq(#warps, 0)
end)

test("warp: to the centre, only on a real change, never while busy", function()
  reset(); dwindle(2); load_plugin(); plugin.options.warp = true
  pointer.x, pointer.y = 900, 300 -- inside B
  press("Super+h"); eq(focused, 2); eq(table.concat(warps, " "), "322,360")
  press("Super+h"); eq(#warps, 1, "focus unchanged: no warp")
  pointer.x, pointer.y = 900, 300
  press("Super+Tab"); eq(focused, 3); eq(#warps, 1, "pointer already inside B: no warp")
  pointer.busy = true
  press("Super+h"); eq(focused, 2, "focus still moves during a grab"); eq(#warps, 1, "but the pointer does not")
  pointer.busy = false
  plugin.options.warp = false
end)

test("border follows focus and is removed on teardown", function()
  reset(); dwindle(2); load_plugin()
  eq(borders[3], "#5294e2", "focused window at setup")
  eq(borders[2], nil)
  press("Super+h")
  eq(borders[2], "#5294e2"); eq(borders[3], nil)
  emit("view_focus", 0)
  eq(next(borders), nil, "no focus: no border")
  focus(3)
  plugin.teardown()
  eq(next(borders), nil, "teardown removes it")
end)

test("border: the bordered window closing is harmless", function()
  reset(); dwindle(2); load_plugin()
  views[3] = nil; table.remove(mru, 1); borders[3] = nil
  focus(2)
  eq(borders[2], "#5294e2")
end)

test("reload: setup again registers the same bindings once", function()
  reset(); dwindle(2); load_plugin()
  plugin.teardown()
  load_plugin()
  local n = 0
  for _ in pairs(binds) do n = n + 1 end
  eq(n, 6)
  eq(#handlers.view_focus, 1)
end)

-- Property test: random floating layouts on two outputs. The chosen window
-- is visible, not the current one, lies strictly in that direction when it
-- is on the same output, is on the same output whenever a candidate there
-- exists, and is never on an output in another direction. The result is
-- deterministic (same input, same choice).
test("random layouts: choices are valid and deterministic", function()
  local seed = 12345
  local function rnd(n) seed = (seed * 1103515245 + 12345) % 2147483648; return seed % n end
  local dirs = { "left", "right", "up", "down" }
  for _ = 1, 400 do
    reset(); two_outputs(); load_plugin()
    local n = 2 + rnd(9)
    for i = 1, n do
      local out = rnd(2) == 0 and 1 or 10
      local base = out == 1 and 0 or 1280
      add(i + 1, base + rnd(1100), rnd(600), 20 + rnd(300), 20 + rnd(300), out)
      if rnd(7) == 0 then views[i + 1].visible = false end
    end
    local all = {}
    for id in pairs(views) do all[id] = raywm.view(id) end
    for id, v in pairs(all) do
      if v.visible then
        local vis = {}
        for k, w in pairs(all) do if w.visible then vis[k] = w; w.rank = 1 end end
        for _, d in ipairs(dirs) do
          local pick = plugin.pick(v, vis, d, raywm.outputs())
          eq(plugin.pick(v, vis, d, raywm.outputs()), pick, "deterministic")
          if pick then
            local p = all[pick]
            assert(pick ~= id and p.visible, "picked itself or a hidden window")
            local strict
            if d == "right" then strict = p.x > v.x and p.x + p.w > v.x + v.w
            elseif d == "left" then strict = p.x < v.x and p.x + p.w < v.x + v.w
            elseif d == "down" then strict = p.y > v.y and p.y + p.h > v.y + v.h
            else strict = p.y < v.y and p.y + p.h < v.y + v.h end
            if p.output == v.output then
              assert(strict, "same-output pick not in direction " .. d)
            else
              assert(d == (v.output == 1 and "right" or "left"), "jumped to an output in direction " .. d)
              for k, w in pairs(vis) do
                if k ~= id and w.output == v.output then
                  local ok
                  if d == "right" then ok = w.x > v.x and w.x + w.w > v.x + v.w
                  else ok = w.x < v.x and w.x + w.w < v.x + v.w end
                  assert(not ok, "left the output although a candidate existed")
                end
              end
            end
          end
        end
      end
    end
  end
end)

local passed = 0
for _, name in ipairs(order) do
  local ok, err = pcall(tests[name])
  if ok then
    passed = passed + 1
    print("PASS  " .. name)
  else
    print("FAIL  " .. name .. "\n      " .. tostring(err))
  end
end
print(("%d/%d passed"):format(passed, #order))
os.exit(passed == #order and 0 or 1)
