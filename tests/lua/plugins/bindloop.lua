-- Binds one key many times, and then many distinct keys: one warning for
-- the duplicates, and no quadratic native scan (tests/lua_test.zig).
return {
  api = 1,
  setup = function(ctx)
    for _ = 1, 3000 do ctx.bind("Super+x", function() end) end
    for i = 1, 20000 do ctx.bind(("Super+U%04X"):format(0x4E00 + i), function() end) end
  end,
}
