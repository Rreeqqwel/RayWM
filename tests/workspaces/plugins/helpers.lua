-- Test helpers for tests/workspaces.sh:
--   windows with app id "raywm-test-ws2" open on workspace "2" (a rule);
--   Super+F9 tries to focus every hidden window (must be refused).
return {
  api = 1,
  setup = function(ctx)
    ctx.on("view_new", function(id)
      local v = raywm.view(id)
      if not v or v.app_id ~= "raywm-test-ws2" then return end
      for _, w in ipairs(raywm.workspaces()) do
        if w.name == "2" and w.output == v.output then raywm.view_workspace(id, w.id) end
      end
    end)
    -- Super+F10: the window with app id "raywm-test-fs" goes fullscreen,
    -- wherever it is (here: on a hidden workspace).
    ctx.bind("Super+F10", function()
      for _, id in ipairs(raywm.views()) do
        local v = raywm.view(id)
        if v and v.app_id == "raywm-test-fs" then raywm.view_fullscreen(id, true) end
      end
    end)
    ctx.bind("Super+F9", function()
      for _, id in ipairs(raywm.views()) do
        local v = raywm.view(id)
        if v and not v.visible then raywm.view_focus(id) end
      end
    end)
  end,
}
