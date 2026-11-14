local path = assert(os.getenv("XDG_RUNTIME_DIR")) .. "/animation-slots.log"
return {
  api = 1,
  setup = function(ctx)
    local ids, handles = {}, {}
    local started = false
    local function next_animation()
      local n = #handles + 1
      if n > 260 then
        -- The oldest completed registration still owns its final transform.
        local ok, why = ctx.cancel(handles[1])
        local stale, stale_reason = ctx.cancel(handles[1])
        local replacement, replacement_error = ctx.animate(ids[260], { x = 7, duration = 1000 })
        local old, old_reason = ctx.cancel(handles[260])
        local other = ctx.cancel(handles[2])
        local cancelled = replacement and ctx.cancel(replacement)
        -- Cancellation is swept after this callback returns.
        ctx.timer(1, function()
          -- Reclamation must not relax the limit for concurrent animations.
          local active = {}
          for i = 1, 256 do
            local id = ctx.animate(ids[i], { x = 9, duration = 10000 })
            if not id then break end
            active[#active + 1] = id
          end
          local over, over_reason = ctx.animate(ids[257], { x = 9, duration = 10000 })
          -- Replacing an active job at capacity reuses its slot.
          local interrupted = ctx.animate(ids[1], { x = 11, duration = 10000 })
          local interrupted_old, interrupted_reason = ctx.cancel(active[1])
          if interrupted then active[1] = interrupted end
          -- A failed replacement must not discard the previous owner.
          local preserved = ctx.cancel(handles[257])
          for _, id in ipairs(active) do assert(ctx.cancel(id)) end
          local out = assert(io.open(path, "w"))
          if ok and not stale and stale_reason == "stale" and replacement and
              not old and old_reason == "stale" and other and cancelled and
              #active == 256 and not over and over_reason == "limit" and preserved and
              interrupted and not interrupted_old and interrupted_reason == "stale" then
            out:write("ok\n")
          else
            out:write(("ownership failed: %s %s %s %s %s %s active=%d limit=%s preserved=%s interrupted=%s old=%s\n"):format(
              tostring(why), tostring(stale_reason), tostring(replacement_error),
              tostring(old_reason), tostring(other), tostring(cancelled), #active, tostring(over_reason), tostring(preserved), tostring(interrupted), tostring(interrupted_reason)))
          end
          out:close()
        end)
        return
      end
      local id, why = ctx.animate(ids[n], { x = 5, opacity = 0.5, duration = 0 })
      if not id then
        local out = assert(io.open(path, "w"))
        out:write(("animation %d failed: %s\n"):format(n, tostring(why)))
        out:close()
        return
      end
      handles[n] = id
      ctx.timer(30, next_animation)
    end
    ctx.on("view_map", function(id)
      ids[#ids + 1] = id
      if #ids == 260 and not started then
        started = true
        -- Let all clients reveal before starting animation.
        ctx.timer(500, next_animation)
      end
    end)
  end,
}
