-- Created at load time, before any budget has run out. This is the case a
-- thread could miss the hook if creation assumed a hook was already armed.
local early = coroutine.create(function() while true do end end)

return {
  api = 1,
  setup = function(ctx) ctx.on("view_workspace", function() coroutine.resume(early) end) end,
  teardown = function() raywm.spawn("teardown:co_early") end,
}
