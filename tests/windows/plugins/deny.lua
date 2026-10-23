-- Refuses every client request to go fullscreen.
return {
  api = 1,
  setup = function(ctx)
    ctx.on("view_request_fullscreen", function(id, on)
      if on then raywm.view_fullscreen(id, false) end
    end)
  end,
}
