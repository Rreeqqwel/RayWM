-- Input-test probe: Super+F12 (sent by the virtual keyboard) appends the
-- geometry and focus of every window to $RAYWM_TEST_OUT.
-- Appends, and keeps numbering dumps across raywm.reload() (which runs
-- this file again).
local path = assert(os.getenv("RAYWM_TEST_OUT"))
local n = 0
local old = io.open(path, "r")
if old then
  for line in old:lines() do
    if line:match("^dump %d+$") then n = n + 1 end
  end
  old:close()
end
local out = assert(io.open(path, "a"))
out:setvbuf("line")

return {
  api = 1,
  setup = function(ctx)
    -- Declares the focused window managed (e.g. in the middle of a drag).
    ctx.bind("Super+F11", function()
      local id = raywm.focused()
      if id then ctx.manage(id) end
    end)
    ctx.bind("Super+F12", function()
      n = n + 1
      out:write("dump ", n, "\n")
      local ids = raywm.views()
      table.sort(ids)
      for _, id in ipairs(ids) do
        local v = raywm.view(id)
        out:write(string.format("view %d %d,%d %dx%d focused=%s\n", id, v.x, v.y, v.w, v.h, tostring(v.focused)))
        out:write(string.format("backend %d xwayland=%s pid=%d\n", id, tostring(v.xwayland), v.pid or 0))
        -- v0.2.0 state, on its own line so older expectations still match.
        out:write(string.format("state %d floating=%s fullscreen=%s maximized=%s visible=%s managed=%s ws=%d output=%d\n",
          id, tostring(v.floating), tostring(v.fullscreen), tostring(v.maximized), tostring(v.visible),
          tostring(v.managed), v.workspace or 0, v.output or 0))
        if raywm.view_minimize then
          out:write(string.format("shell %d minimized=%s urgent=%s decoration=%s\n", id, tostring(v.minimized),
            tostring(v.urgent), tostring(v.decoration)))
        end
        if raywm.workspace and v.workspace ~= 0 then
          local w = raywm.workspace(v.workspace)
          if w then out:write(string.format("where %d %s@%s\n", id, w.name, w.home)) end
        end
      end
      if raywm.output_configure then
        for _, o in ipairs(raywm.outputs({ all = true })) do
          out:write(string.format("output %s %d,%d %dx%d scale=%s transform=%s enabled=%s power=%s mode=%dx%d usable=%d,%d %dx%d\n",
            o.name, o.x, o.y, o.w, o.h, tostring(o.scale), o.transform, tostring(o.enabled), tostring(o.power),
            o.mode.w, o.mode.h, o.usable.x, o.usable.y, o.usable.w, o.usable.h))
        end
      end
      if raywm.workspaces then
        local names = {}
        for _, o in ipairs(raywm.outputs()) do names[o.id] = o.name end
        for _, w in ipairs(raywm.workspaces()) do
          out:write(string.format("ws %s@%s output=%s active=%s orphan=%s\n", w.name, w.home,
            names[w.output] or "none", tostring(w.active), tostring(w.orphan)))
          if w.urgent then out:write(string.format("urgent-ws %s@%s\n", w.name, w.home)) end
        end
      end
    end)
  end,
  teardown = function() out:close() end,
}
