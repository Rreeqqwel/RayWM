-- Input-device suite helper: settings from the config, events and answers
-- in $XDG_RUNTIME_DIR/devtest.log.
local log = assert(io.open(os.getenv("XDG_RUNTIME_DIR") .. "/devtest.log", "a"))
log:setvbuf("line")
return {
  api = 1,
  setup = function(ctx)
    log:write("configure ", tostring(raywm.input_configure("type:keyboard", { repeat_rate = 40, repeat_delay = 300 })), "\n")
    ctx.on("input_add", function(id)
      for _, d in ipairs(raywm.input_devices()) do
        if d.id == id then log:write(("add %s %s virtual=%s\n"):format(d.type, d.name, tostring(d.virtual))) end
      end
    end)
    ctx.on("input_remove", function() log:write("remove\n") end)
    ctx.on("keyboard_layout", function(_, n) log:write("layout ", n, "\n") end)
    -- Super+F9: a layout that does not compile is refused.
    ctx.bind("Super+F9", function()
      local ok, why = raywm.input_configure("*", { xkb_layout = "nosuchlayout" })
      log:write(("badlayout %s %s\n"):format(tostring(ok), tostring(why)))
    end)
    -- Super+F10: switch to the second layout.
    ctx.bind("Super+F10", function()
      local ok = raywm.keyboard_set_layout(2)
      local l = raywm.keyboard_layout()
      log:write(("setlayout %s active=%d names=%s\n"):format(tostring(ok), l.active, table.concat(l.names, ",")))
    end)
  end,
  teardown = function() log:close() end,
}
