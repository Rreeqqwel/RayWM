local old, target, armed
return {
  api = 1,
  setup = function(ctx)
    local output = raywm.outputs()[1].id
    old = assert(ctx.workspace_create(output, "old"))
    target = assert(ctx.workspace_create(output, "target"))
    ctx.on("view_map", function(id) assert(raywm.view_workspace(id, old)) end)
    ctx.on("view_focus", function(id)
      if id == 0 and armed then
        armed = false
        assert(raywm.workspace_remove(old))
      end
    end)
    ctx.on("workspace_activate", function(id, previous)
      if id == target then
        assert(previous == old, "previous workspace id changed after destruction")
        local file = assert(io.open(os.getenv("XDG_RUNTIME_DIR") .. "/reentrant-ok", "w"))
        file:write("ok\n"); file:close()
      end
    end)
    ctx.bind("Super+t", function()
      armed = true
      assert(raywm.workspace_activate(target))
    end)
  end,
}
