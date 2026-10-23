-- Owns workspaces. After a reload it adopts only the orphan named "one",
-- so "two" is released by the core once the config has run.
return {
  api = 1,
  setup = function(ctx)
    local adopted = 0
    for _, w in ipairs(raywm.workspaces()) do
      if w.orphan and w.name == "one" and ctx.workspace_adopt(w.id) then adopted = adopted + 1 end
    end
    raywm.spawn("adopted:" .. adopted)
    if adopted == 0 then
      local a = ctx.workspace_create(1, "one")
      local b = ctx.workspace_create(1, "two")
      raywm.spawn("created:" .. tostring(a) .. ":" .. tostring(b))
      raywm.spawn("stale:" .. tostring(ctx.workspace_create(9, "x")))
      local ok, why = ctx.workspace_create(1, "")
      raywm.spawn("badname:" .. tostring(ok) .. ":" .. tostring(why))
      local ok2, why2 = ctx.workspace_adopt(a)
      raywm.spawn("owned:" .. tostring(ok2) .. ":" .. tostring(why2))
    end
    ctx.on("view_title", function() error("die") end) -- crash on demand
    ctx.on("layout", function()
      local names = {}
      for _, w in ipairs(raywm.workspaces()) do names[#names + 1] = w.name .. (w.orphan and "*" or "") end
      raywm.spawn("list:" .. table.concat(names, ","))
    end)
  end,
}
