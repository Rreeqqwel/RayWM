-- Super+F9: tries bad output settings and records the answers in
-- $XDG_RUNTIME_DIR/outhelpers.log.
local log = assert(io.open(os.getenv("XDG_RUNTIME_DIR") .. "/outhelpers.log", "a"))
log:setvbuf("line")
return {
  api = 1,
  setup = function(ctx)
    -- Super+F10: disables HEADLESS-1, or enables it again, from Lua (no
    -- position given).
    ctx.bind("Super+F10", function()
      local on = false
      for _, o in ipairs(raywm.outputs({ all = true })) do
        if o.name == "HEADLESS-1" then on = not o.enabled end
      end
      local ok, err = raywm.output_configure("HEADLESS-1", { enabled = on })
      log:write(("%s %s %s\n"):format(on and "enable" or "disable", tostring(ok), tostring(err)))
    end)
    -- Super+F8: the focused window floats, moves to workspace "2" of
    -- HEADLESS-1 (not shown there) and then into HEADLESS-1's area while
    -- hidden: it has never been visible on that output.
    ctx.bind("Super+F8", function()
      local id = raywm.focused()
      if not id then return log:write("hide-move: no window\n") end
      local target
      for _, o in ipairs(raywm.outputs()) do
        if o.name == "HEADLESS-1" then target = o end
      end
      local ws
      for _, w in ipairs(raywm.workspaces()) do
        if w.name == "2" and target and w.output == target.id then ws = w.id end
      end
      if not ws then return log:write("hide-move: no workspace\n") end
      raywm.view_floating(id, true)
      raywm.view_workspace(id, ws)
      raywm.view_move(id, target.x + 100, target.y + 100)
      log:write(("hide-move %d to %d at %d\n"):format(id, ws, target.x + 100))
    end)
    ctx.bind("Super+F9", function()
      local function try(name, opts)
        local ok, a, b = pcall(raywm.output_configure, name, opts)
        log:write(("%s %s %s\n"):format(tostring(ok), tostring(a), tostring(b)))
      end
      try("HEADLESS-1", { scale = 0 })
      try("HEADLESS-1", { transform = "sideways" })
      try("HEADLESS-1", { mode = "abc" })
      try("NOPE-1", { scale = 2 })
      try("HEADLESS-1", { enabled = false })
      try("HEADLESS-1", { mode = { w = 0, h = 0 } })
    end)
  end,
  teardown = function() log:close() end,
}
