-- Edge cases of the API contract (see tests/lua_test.zig).
return {
  api = 1,
  setup = function(ctx)
    raywm.spawn("debug:" .. tostring(debug) .. ":" .. tostring(package.loaded.debug))
    ctx.bind("Super+Return", function() raywm.spawn("bind:edge") end)
    ctx.bind("Super+x", function() raywm.reload() end)
    ctx.on("layout", function()
      -- Host calls from inside a coroutine.
      local co = coroutine.create(function() return raywm.view_focus(1) end)
      local ok, r = coroutine.resume(co)
      raywm.spawn("co:" .. tostring(ok) .. ":" .. tostring(r))
      -- Ids that can never exist.
      for _, id in ipairs({ 0, -1, 1 << 40 }) do
        local v, e = raywm.view(id)
        raywm.spawn("id:" .. tostring(v) .. ":" .. tostring(e))
      end
    end)
    -- Nested dispatch: focusing emits view_focus again (fake host), forever.
    ctx.on("view_focus", function(id)
      raywm.spawn("focus:" .. id)
      raywm.view_focus(1)
    end)
    -- Toggling manage must not grow the registration list.
    ctx.on("view_title", function()
      for _ = 1, 200000 do
        ctx.manage(1, false)
        ctx.manage(1)
      end
      raywm.spawn("toggled")
    end)
    -- A wrong argument type is an error in this plugin, not a crash.
    ctx.on("view_resized", function() raywm.view("abc") end)
    ctx.on("output_remove", function() error({}) end)
  end,
  teardown = function() raywm.spawn("teardown:edge") end,
}
