-- Tests config/plugins/dwindle.lua against a mock of the RayWM API that
-- mirrors the core's semantics (MRU view order, focus rules, stale ids,
-- output = output under the window centre, immediate client acks).
-- Run from the repo root: XDG_RUNTIME_DIR=<tmpdir> lua5.4 tests/dwindle_test.lua
local plugin_path = "config/plugins/dwindle.lua"

local outputs, views, mru, focused, handlers, binds, errors, place_calls
local focus_requests = 0 -- like the core's Server.focus_requests
local managed = {} -- view id -> true, as tracked by the runtime for ctx.manage
local views_cap -- truncates raywm.views() when set
local function reset_world()
  outputs = { { id = 1, x = 0, y = 0, w = 1280, h = 720, usable = { x = 0, y = 0, w = 1280, h = 720 } } }
  views, mru, focused, place_calls, managed, views_cap = {}, {}, nil, 0, {}, nil
end

local function output_at(x, y)
  for _, o in ipairs(outputs) do
    if x >= o.x and x < o.x + o.w and y >= o.y and y < o.y + o.h then return o.id end
  end
  return 0
end

local function copy(t)
  local r = {}
  for k, v in pairs(t) do r[k] = type(v) == "table" and copy(v) or v end
  return r
end

raywm = {
  api_version = 1,
  views = function()
    local r = {}
    for i, id in ipairs(mru) do
      if views_cap and i > views_cap then break end
      r[i] = id
    end
    return r
  end,
  focused = function() return focused end,
  outputs = function() return copy(outputs) end,
  view = function(id)
    local v = views[id]
    if not v then return nil, "stale" end
    return { id = id, x = v.x, y = v.y, w = v.w, h = v.h, title = "t", app_id = "a",
      focused = focused == id, output = output_at(v.x + v.w // 2, v.y + v.h // 2) }
  end,
  view_place = function(id, x, y, w, h)
    assert(math.type(x) == "integer" and math.type(w) == "integer", "non-integer geometry")
    assert(w >= 1 and h >= 1, ("view_place with size %dx%d"):format(w, h))
    place_calls = place_calls + 1
    local v = views[id]
    if not v then return nil, "stale" end
    v.x, v.y, v.w, v.h = x, y, w, h
    return true
  end,
  view_focus = function(id)
    if not views[id] then return nil, "stale" end
    focus_requests = focus_requests + 1
    focused = id
    for i, v in ipairs(mru) do if v == id then table.remove(mru, i) break end end
    table.insert(mru, 1, id)
    return true
  end,
  spawn = function() end,
  log = function() end,
}

local function emit(ev, id)
  for _, h in ipairs(handlers[ev] or {}) do
    local ok, err = pcall(h, id)
    if not ok then errors[#errors + 1] = err end
  end
end

local plugin
local function load_plugin()
  handlers, binds = {}, {}
  plugin = dofile(plugin_path)
  assert(plugin.api == 1 and type(plugin.setup) == "function")
  local ctx = {
    on = function(ev, fn) handlers[ev] = handlers[ev] or {}; table.insert(handlers[ev], fn) end,
    bind = function(k, fn) binds[k] = fn end,
    timer = function() error("unused") end,
    cancel = function() end,
    manage = function(id, on)
      if not views[id] then return nil, "stale" end
      managed[id] = (on == nil or on) or nil
      return true
    end,
  }
  plugin.setup(ctx)
end

local next_id = 2
local function map(out)
  local id = next_id
  next_id = next_id + 1
  local o = outputs[1]
  for _, x in ipairs(outputs) do if x.id == (out or 1) then o = x end end
  -- The core centres a new 200x150 window on the active output first.
  views[id] = { x = o.x + (o.w - 200) // 2, y = o.y + (o.h - 150) // 2, w = 200, h = 150 }
  table.insert(mru, 1, id)
  -- Core rule (src/view.zig handleMap): focus the new window unless a
  -- view_map handler chose focus itself.
  local requests = focus_requests
  emit("view_map", id)
  if focus_requests == requests then raywm.view_focus(id) end
  return id
end

local function unmap(id)
  views[id] = nil
  managed[id] = nil -- the runtime drops ctx.manage on view_unmap
  for i, v in ipairs(mru) do if v == id then table.remove(mru, i) break end end
  if focused == id then focused = mru[1] end
  emit("view_unmap", id)
end

local function geo(id)
  local v = views[id]
  return ("%d,%d %dx%d"):format(v.x, v.y, v.w, v.h)
end

local function expect(id, want, label)
  local got = geo(id)
  if got ~= want then error(("%s: view %d is %s, expected %s"):format(label, id, got, want), 2) end
end

-- Structural invariants of the plugin's trees (via plugin.inspect()):
-- parent links, unique leaves, leaves map == tree leaves == managed set,
-- every leaf is an existing window, traversal terminates.
local function check_tree(label)
  local trees, leaves = plugin.inspect()
  local seen, count = {}, 0
  for out, root in pairs(trees) do
    assert(root.parent == nil, label .. ": root has a parent")
    assert(root.out == out, label .. ": root.out mismatch")
    local stack, steps = { root }, 0
    while #stack > 0 do
      local node = table.remove(stack)
      steps = steps + 1
      assert(steps < 100000, label .. ": tree traversal does not terminate")
      if node.view then
        assert(not seen[node.view], label .. ": window " .. node.view .. " owned twice")
        seen[node.view] = true
        count = count + 1
        assert(leaves[node.view] == node, label .. ": leaves map out of sync for " .. node.view)
        assert(views[node.view], label .. ": leaf refers to missing window " .. node.view)
        assert(managed[node.view], label .. ": tiled window " .. node.view .. " not managed")
      else
        assert(node.split == "h" or node.split == "v", label .. ": bad split")
        assert(node.a and node.b, label .. ": split without two children")
        assert(node.a.parent == node and node.b.parent == node, label .. ": broken parent link")
        stack[#stack + 1] = node.a
        stack[#stack + 1] = node.b
      end
    end
  end
  for id in pairs(leaves) do assert(seen[id], label .. ": stale leaves entry " .. id) end
  for id in pairs(managed) do
    -- (the runtime drops ctx.manage of windows that are gone)
    if views[id] then assert(seen[id], label .. ": window " .. id .. " managed but not tiled") end
  end
  return count
end

-- No overlaps, everything inside the usable area (minus the outer gap).
local function check_invariants(label)
  check_tree(label)
  local ids = {}
  for id in pairs(views) do ids[#ids + 1] = id end
  for i, a in ipairs(ids) do
    local va = views[a]
    local o
    for _, x in ipairs(outputs) do if output_at(va.x, va.y) == x.id then o = x end end
    assert(o, label .. ": view " .. a .. " is outside every output")
    assert(va.w >= 1 and va.h >= 1, label .. ": size below 1")
    local u = o.usable
    if u.w <= 16 or u.h <= 16 then goto next_view end -- smaller than the gaps
    assert(va.x >= u.x + 8 and va.y >= u.y + 8 and va.x + va.w <= u.x + u.w - 8 and va.y + va.h <= u.y + u.h - 8,
      label .. ": view " .. a .. " (" .. geo(a) .. ") leaves the usable area")
    ::next_view::
    for j = i + 1, #ids do
      local vb = views[ids[j]]
      -- Areas too small to split are shared on purpose (very many windows).
      -- (smaller than gap + 2 px in some direction).
      if math.min(va.w, va.h, vb.w, vb.h) < 10 then goto continue end
      local overlap = va.x < vb.x + vb.w and vb.x < va.x + va.w and va.y < vb.y + vb.h and vb.y < va.y + va.h
      assert(not overlap, label .. ": views " .. a .. " and " .. ids[j] .. " overlap")
      ::continue::
    end
  end
  assert(#errors == 0, label .. ": Lua errors: " .. table.concat(errors, "; "))
end

local tests = {}

tests["tiled windows are managed (no free move/resize)"] = function()
  local a, b, c = map(), map(), map()
  assert(managed[a] and managed[b] and managed[c], "tiled windows must be managed")
  unmap(b)
  assert(managed[a] and managed[c] and not managed[b])
  plugin.teardown()
  managed = {} -- reload: the runtime released everything
  load_plugin()
  assert(managed[a] and managed[c], "restored windows must be managed again")
end

tests["a window moved from outside is put back on the next layout"] = function()
  local a, b = map(), map()
  views[a].x, views[a].y = 400, 300 -- e.g. another plugin or a client
  emit("layout", 1)
  expect(a, "8,8 628x704", "external move undone")
  -- Pending resize: same request, position not yet applied -> re-sent.
  local before = place_calls
  views[b].x = 0
  emit("layout", 1)
  assert(place_calls == before + 1, "stale position should re-send exactly one request")
  check_invariants("external move")
end

tests["1-5 windows spiral (dwindle) and focus follows new windows"] = function()
  local a = map()
  expect(a, "8,8 1264x704", "1 window")
  local b = map()
  expect(a, "8,8 628x704", "2 windows")
  expect(b, "644,8 628x704", "2 windows")
  local c = map()
  expect(b, "644,8 628x348", "3 windows")
  expect(c, "644,364 628x348", "3 windows")
  local d = map()
  expect(c, "644,364 310x348", "4 windows")
  expect(d, "962,364 310x348", "4 windows")
  local e = map()
  expect(d, "962,364 310x170", "5 windows")
  expect(e, "962,542 310x170", "5 windows")
  assert(focused == e, "new window should be focused")
  -- Each split targeted the window focused *before* the new one mapped.
  for i, v in ipairs(mru) do assert(v == ({ e, d, c, b, a })[i], "focus order") end
  check_invariants("5 windows")
end

tests["close middle, first and last window"] = function()
  local a, b, c, d, e = map(), map(), map(), map(), map()
  unmap(c) -- middle: the D/E subtree takes C's parent area
  expect(d, "644,364 628x170", "close middle")
  expect(e, "644,542 628x170", "close middle")
  check_invariants("close middle")
  unmap(a) -- first: the rest takes the whole area
  expect(b, "8,8 1264x348", "close first")
  check_invariants("close first")
  unmap(e) -- last: its sibling takes the parent area
  expect(d, "8,364 1264x348", "close last")
  unmap(b)
  expect(d, "8,8 1264x704", "single left")
  unmap(d)
  check_invariants("all closed")
end

tests["new window splits the focused leaf along its longer side"] = function()
  local a, b = map(), map()
  raywm.view_focus(a) -- a is 628x704: taller than wide -> vertical split
  local c = map()
  expect(a, "8,8 628x348", "split focused")
  expect(c, "8,364 628x348", "split focused")
  expect(b, "644,8 628x704", "untouched")
  check_invariants("split focused")
end

tests["output resize and panel exclusive zone"] = function()
  local a, b = map(), map()
  outputs[1].w, outputs[1].h = 1920, 1080
  outputs[1].usable = { x = 0, y = 0, w = 1920, h = 1080 }
  emit("layout", 1)
  expect(a, "8,8 948x1064", "resize")
  expect(b, "964,8 948x1064", "resize")
  outputs[1].usable = { x = 0, y = 30, w = 1920, h = 1050 } -- 30 px top panel
  emit("layout", 1)
  expect(a, "8,38 948x1034", "panel")
  check_invariants("panel")
  -- Repeated layout events with no change send no new requests.
  local before = place_calls
  emit("layout", 1)
  assert(place_calls == before, "unchanged layout re-sent geometry")
end

tests["tiny areas never produce sizes below 1"] = function()
  outputs[1].usable = { x = 0, y = 0, w = 20, h = 20 }
  local ids = {}
  for _ = 1, 5 do ids[#ids + 1] = map() end
  for _, id in ipairs(ids) do
    assert(views[id].w >= 1 and views[id].h >= 1, "size below 1")
  end
  assert(#errors == 0)
end

tests["two outputs, then unplugging one"] = function()
  outputs[2] = { id = 7, x = 1280, y = 0, w = 1280, h = 720, usable = { x = 1280, y = 0, w = 1280, h = 720 } }
  local a = map(1)
  focused = nil -- e.g. user clicked the empty second monitor
  local b = map(7)
  expect(b, "1288,8 1264x704", "second output")
  expect(a, "8,8 1264x704", "first output")
  table.remove(outputs, 2)
  emit("output_remove", 7)
  emit("layout", 0)
  expect(a, "8,8 628x704", "migrated")
  expect(b, "644,8 628x704", "migrated")
  check_invariants("unplug")
end

tests["stale window (vanished without unmap) is dropped"] = function()
  local a, b = map(), map()
  views[b] = nil -- the core already forgot it
  for i, v in ipairs(mru) do if v == b then table.remove(mru, i) end end
  emit("layout", 1)
  expect(a, "8,8 1264x704", "stale dropped")
  check_invariants("stale")
end

tests["reload keeps the tree shape"] = function()
  local a, b = map(), map()
  raywm.view_focus(a)
  local c = map() -- a and c share the left half
  local before = { geo(a), geo(b), geo(c) }
  plugin.teardown()
  load_plugin() -- fresh Lua state, as raywm.reload() does
  assert(geo(a) == before[1] and geo(b) == before[2] and geo(c) == before[3], "layout changed across reload")
  local d = map() -- tree still works: splits focused c
  expect(c, "8,364 310x348", "after reload")
  expect(d, "326,364 310x348", "after reload")
  check_invariants("reload")
end

tests["fresh session ignores a leftover snapshot"] = function()
  map()
  plugin.teardown() -- writes a snapshot, then the compositor quits
  reset_world()
  load_plugin() -- new session: no windows yet
  local a = map()
  expect(a, "8,8 1264x704", "fresh session")
  check_invariants("fresh")
end

tests["Super+j/k cycle focus in tree order"] = function()
  local a, b, c = map(), map(), map()
  assert(focused == c)
  binds["Super+j"]()
  assert(focused == a, "j wraps to first")
  binds["Super+k"]()
  assert(focused == c, "k wraps to last")
  binds["Super+k"]()
  assert(focused == b)
end

tests["10 and 20 windows keep every invariant"] = function()
  local first = map()
  for n = 2, 20 do
    map()
    check_invariants(n .. " windows")
    if n == 10 or n == 20 then
      expect(first, "8,8 628x704", n .. " windows") -- the first split never moves
    end
  end
  assert(check_tree("20") == 20)
end

tests["closing leaves in any order collapses the tree"] = function()
  for _, order in ipairs({ { 1, 2, 3, 4, 5, 6 }, { 6, 5, 4, 3, 2, 1 }, { 3, 1, 5, 2, 6, 4 }, { 2, 4, 6, 1, 3, 5 } }) do
    reset_world()
    errors = {}
    load_plugin()
    local ids = {}
    for i = 1, 6 do ids[i] = map() end
    for k, i in ipairs(order) do
      unmap(ids[i])
      check_invariants("close order step " .. k)
      local left = 6 - k
      assert(check_tree("count") == left)
      if left == 1 then
        for _, id in ipairs(ids) do
          if views[id] then expect(id, "8,8 1264x704", "last window takes the whole area") end
        end
      end
    end
  end
end

tests["randomized operation sequences (fixed seeds)"] = function()
  for seed = 1, 20 do
    reset_world()
    errors = {}
    load_plugin()
    math.randomseed(seed)
    local label = "seed " .. seed
    for step = 1, 300 do
      local r = math.random(100)
      local ids = {}
      for id in pairs(views) do ids[#ids + 1] = id end
      table.sort(ids)
      if r <= 35 or #ids == 0 then
        map(outputs[math.random(#outputs)].id)
      elseif r <= 60 then
        unmap(ids[math.random(#ids)])
      elseif r <= 72 then
        raywm.view_focus(ids[math.random(#ids)])
      elseif r <= 82 then -- panel appears/disappears or output resizes
        local o = outputs[math.random(#outputs)]
        local top = math.random(0, 1) * 30
        o.w, o.h = math.random(1, 4) * 320, math.random(1, 4) * 180
        o.usable = { x = o.x, y = o.y + top, w = o.w, h = o.h - top }
        emit("layout", o.id)
      elseif r <= 92 then -- plug or unplug a second output
        if #outputs == 1 then
          outputs[2] = { id = 100 + step, x = 5000, y = 0, w = 800, h = 600, usable = { x = 5000, y = 0, w = 800, h = 600 } }
          emit("output_add", outputs[2].id)
          emit("layout", 0)
        else
          local gone = table.remove(outputs, 2)
          -- The core moves windows off a dead output onto a visible one.
          for _, id in ipairs(ids) do
            local v = views[id]
            if v.x >= gone.x then v.x, v.y = 0, 0 end
          end
          emit("output_remove", gone.id)
          emit("layout", 0)
        end
      else -- reload
        plugin.teardown()
        managed = {}
        load_plugin()
      end
      check_invariants(label .. " step " .. step)
    end
  end
end

tests["malformed or hostile snapshots are ignored"] = function()
  local path = os.getenv("XDG_RUNTIME_DIR") .. "/raywm-dwindle-" .. os.getenv("WAYLAND_DISPLAY") .. ".txt"
  local deep = { "raywm-dwindle 1", "output 1" }
  for _ = 1, 10000 do deep[#deep + 1] = "h 0.5" end
  deep[#deep + 1] = "leaf 2"
  local cases = {
    "return {[1]={v=2}}\nwhile true do end", -- code is never executed
    "raywm-dwindle 1\noutput 1\nh 0.5\nleaf 2", -- truncated
    "raywm-dwindle 1\noutput 1\nleaf 2\nleaf 2", -- garbage after a tree
    "raywm-dwindle 1\noutput x\nleaf 2",
    table.concat(deep, "\n"), -- deeper than the limit
    string.rep("x", (1 << 20) + 10), -- too large
  }
  for i, text in ipairs(cases) do
    reset_world()
    errors = {}
    load_plugin()
    local a, b = map(), map()
    plugin.teardown() -- writes a valid snapshot ...
    local f = assert(io.open(path, "w"))
    f:write(text) -- ... which we replace
    f:close()
    managed = {}
    load_plugin()
    check_invariants("snapshot case " .. i)
    assert(check_tree("case " .. i) == 2, "case " .. i .. ": windows lost")
    assert(not io.open(path, "r"), "case " .. i .. ": snapshot not consumed")
  end
end

tests["a truncated views() list never leaves managed windows untiled"] = function()
  for _ = 1, 6 do map() end
  views_cap = 4
  emit("layout", 1) -- two windows look gone: removed from the tree and released
  check_tree("truncated")
  views_cap = nil
end

local names = {}
for name in pairs(tests) do names[#names + 1] = name end
table.sort(names)
local failed = 0
for _, name in ipairs(names) do
  reset_world()
  errors = {}
  load_plugin()
  local ok, err = pcall(tests[name])
  if ok then pcall(plugin.teardown) end
  os.remove((os.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/raywm-dwindle-" .. (os.getenv("WAYLAND_DISPLAY") or "unknown") .. ".txt")
  print((ok and "PASS  " or "FAIL  ") .. name .. (ok and "" or ("\n      " .. tostring(err))))
  if not ok then failed = failed + 1 end
end
print(("%d/%d passed"):format(#names - failed, #names))
os.exit(failed == 0 and 0 or 1)
