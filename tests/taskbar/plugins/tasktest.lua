return {
  api = 1,
  setup = function(ctx)
    ctx.bind("Super+F9", function()
      for _, ws in ipairs(raywm.workspaces()) do
        if ws.name == "2" then raywm.workspace_rename(ws.id, "two") end
      end
    end)
    ctx.bind("Super+F10", function()
      for _, ws in ipairs(raywm.workspaces()) do
        if ws.name == "9" then raywm.workspace_remove(ws.id) end
      end
    end)
    ctx.bind("Super+F6", function()
      local outputs = raywm.outputs()
      if outputs[1] then ctx.workspace_create(outputs[1].id, "extra") end
    end)
    ctx.bind("Super+F8", function()
      for _, id in ipairs(raywm.views()) do
        raywm.view_floating(id, true)
        raywm.view_place(id, 1200, 100, 200, 150)
      end
    end)
    ctx.bind("Super+F7", function()
      for _, id in ipairs(raywm.views()) do raywm.view_urgent(id, true) end
    end)
  end,
}
