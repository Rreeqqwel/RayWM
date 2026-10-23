-- API additions of v0.2.0 (window states and requests): minimize,
-- urgency, decorations, activation and minimize requests.
return {
  api = 1,
  setup = function(ctx)
    local v = raywm.view(1)
    raywm.spawn(("shellmeta:%s:%s:%s"):format(tostring(v.minimized), tostring(v.urgent), tostring(v.decoration)))
    raywm.spawn("min:" .. tostring(raywm.view_minimize(1, true)))
    raywm.spawn("minstale:" .. tostring(raywm.view_minimize(9, true)))
    raywm.spawn("urgent:" .. tostring(raywm.view_urgent(1, true)))
    raywm.spawn("deco:" .. tostring(raywm.view_decoration(1, "client")))
    raywm.spawn("decostale:" .. tostring(raywm.view_decoration(9, "auto")))
    local ok, err = pcall(raywm.view_decoration, 1, "fancy")
    raywm.spawn("decobad:" .. tostring(ok) .. ":" .. tostring(err:find('expected one of "auto", "server", "client"', 1, true) ~= nil))
    raywm.spawn("deconil:" .. tostring((pcall(raywm.view_decoration, 1))))
    ctx.on("view_request_activate", function(id, user)
      raywm.spawn(("activate:%d:%s"):format(id, tostring(user)))
    end)
    ctx.on("view_request_minimize", function(id, extra)
      raywm.spawn(("minreq:%d:%s"):format(id, tostring(extra)))
    end)
  end,
}
