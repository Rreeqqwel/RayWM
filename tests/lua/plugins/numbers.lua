return {
  api = 1,
  setup = function()
    for _, value in ipairs({ 0 / 0, math.huge, -math.huge }) do
      assert(not pcall(raywm.output_configure, 1, { mode = { w = 800, h = 600, refresh = value } }))
      assert(not pcall(raywm.output_configure, 1, { scale = value }))
      assert(not pcall(raywm.view_opacity, 1, value))
      assert(not pcall(raywm.input_configure, "*", { accel_speed = value }))
    end
    -- Large finite values are clamped before conversion to f32.
    assert(raywm.view_opacity(1, 1e300))
    assert(raywm.view_opacity(1, -1e300))
    -- Missing refresh retains the documented automatic-mode selection.
    assert(raywm.output_configure(1, { mode = { w = 800, h = 600 } }))
    raywm.spawn("numbers:ok")
  end,
}
