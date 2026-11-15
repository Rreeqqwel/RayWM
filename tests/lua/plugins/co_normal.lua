-- Normal coroutines keep working: yield/resume, wrap, and an error raised
-- inside a coroutine is reported to its resumer, not to the runtime.
return {
  api = 1,
  setup = function(ctx)
    ctx.on("view_focus", function()
      local co = coroutine.create(function(a)
        local b = coroutine.yield(a + 1)
        return b * 2
      end)
      local ok, v = coroutine.resume(co, 1)
      raywm.spawn("create-yield:" .. tostring(ok) .. ":" .. tostring(v))
      local ok2, v2 = coroutine.resume(co, 10)
      raywm.spawn("create-done:" .. tostring(ok2) .. ":" .. tostring(v2))

      local run = coroutine.wrap(function(a)
        local b = coroutine.yield(a * 2)
        return b + 1
      end)
      raywm.spawn("wrap-yield:" .. tostring(run(5)))
      raywm.spawn("wrap-done:" .. tostring(run(7)))

      local bad = coroutine.create(function() error("co-boom") end)
      local ok3, err = coroutine.resume(bad)
      raywm.spawn("co-error:" .. tostring(ok3) .. ":" .. tostring(tostring(err):match("co%-boom") ~= nil))
    end)
  end,
  teardown = function() raywm.spawn("teardown:co_normal") end,
}
