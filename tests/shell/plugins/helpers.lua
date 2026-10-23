-- Test helpers for tests/shell.sh: windows with app id "raywm-test-ws2"
-- open on workspace "2"; Super+F9 sets "server" decorations for every
-- window, Super+F10 resets them to "auto".
return {
  api = 1,
  setup = function(ctx)
    ctx.on("view_new", function(id)
      local v = raywm.view(id)
      if not v or v.app_id ~= "raywm-test-ws2" then return end
      for _, w in ipairs(raywm.workspaces and raywm.workspaces() or {}) do
        if w.name == "2" and w.output == v.output then raywm.view_workspace(id, w.id) end
      end
    end)
    ctx.bind("Super+F9", function()
      for _, id in ipairs(raywm.views()) do raywm.view_decoration(id, "server") end
    end)
    ctx.bind("Super+F10", function()
      for _, id in ipairs(raywm.views()) do raywm.view_decoration(id, "auto") end
    end)
  end,
}
