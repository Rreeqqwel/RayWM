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
