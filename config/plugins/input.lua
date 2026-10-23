-- Keyboard, mouse and touchpad settings, applied to every matching device
-- now and whenever one is plugged in.
--
-- Keys: "*" (every device), "type:keyboard", "type:pointer" (mice and
-- touchpads), "type:touchpad", or a device's name (raywm.input_devices()
-- lists them; libinput: `libinput list-devices`). More specific entries
-- override less specific ones, setting by setting. Anything not set keeps
-- its default: the XKB_DEFAULT_* environment variables for keyboards,
-- libinput's defaults for pointers. Removing a setting here and reloading
-- undoes it.
--
-- Keyboard: xkb_layout, xkb_variant, xkb_options, xkb_model, xkb_rules
--   (as in `setxkbmap`), repeat_rate (keys/s), repeat_delay (ms).
-- Pointer/touchpad (libinput, when the device supports it): accel_profile
--   ("flat" | "adaptive"), accel_speed (-1..1), natural_scroll,
--   left_handed, tap, tap_drag, drag_lock, dwt (disable while typing),
--   middle_emulation, scroll_method ("none" | "two_finger" | "edge" |
--   "button"), scroll_button, click_method ("none" | "button_areas" |
--   "clickfinger"), send_events ("enabled" | "disabled" |
--   "disabled_on_external_mouse").
local settings = {
  -- ["type:keyboard"] = { xkb_layout = "us,ru", xkb_options = "grp:alt_shift_toggle", repeat_rate = 30, repeat_delay = 300 },
  -- ["type:touchpad"] = { tap = true, natural_scroll = true, dwt = true },
  -- ["type:pointer"] = { accel_profile = "flat", accel_speed = 0 },
  -- ["Logitech G502"] = { accel_speed = -0.3 },
}

return {
  api = 1,
  setup = function()
    -- "*" first, then types, then device names (the core layers them
    -- that way anyway; the order only matters for the log).
    local keys = {}
    for k in pairs(settings) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
      local function rank(k) return k == "*" and 0 or k:sub(1, 5) == "type:" and 1 or 2 end
      if rank(a) ~= rank(b) then return rank(a) < rank(b) end
      return a < b
    end)
    for _, k in ipairs(keys) do
      local ok, err = raywm.input_configure(k, settings[k])
      if not ok then raywm.log(("input: %s not applied: %s"):format(k, tostring(err))) end
    end
  end,
  settings = settings,
}
