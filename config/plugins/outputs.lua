-- Monitor settings: mode, refresh rate, scale, rotation, position, on or
-- off. Applied when RayWM starts (and on reload) and whenever a listed
-- monitor appears (hotplug).
--
-- An entry matches an output by `name` (as wlr-randr shows it, e.g.
-- "DP-1") or by a piece of its `description` (make, model and serial,
-- e.g. "Dell Inc. DELL U2720Q"). Fields, all optional:
--   mode = "2560x1440@143.97" or "1920x1080" (the highest refresh rate)
--   scale = 1.5
--   transform = "normal" | "90" | "180" | "270" | "flipped" | "flipped-90" | ...
--   position = { x, y } or "auto" (to the right of the others)
--   enabled = false
--   adaptive_sync = true
--
-- A setting the monitor or driver refuses is logged and nothing is
-- changed; RayWM never lets a configuration disable every output. Other
-- tools (wlr-randr, kanshi) can still change outputs at any time.

local outputs = {
  -- { name = "DP-1", mode = "2560x1440@143.97", scale = 1.25, position = { 0, 0 } },
  -- { name = "HDMI-A-1", mode = "1920x1080@60", position = { 2048, 0 } },
  -- { description = "Dell Inc. DELL U2720Q", scale = 1.5 },
  -- { name = "eDP-1", enabled = false },
}

local fields = { "mode", "scale", "transform", "position", "enabled", "adaptive_sync" }

local function matches(entry, o)
  if entry.name and entry.name ~= o.name then return false end
  if entry.description and not o.description:find(entry.description, 1, true) then return false end
  return entry.name ~= nil or entry.description ~= nil
end

local function apply(o)
  for _, entry in ipairs(outputs) do
    if matches(entry, o) then
      local opts = {}
      for _, k in ipairs(fields) do opts[k] = entry[k] end
      local ok, err = raywm.output_configure(o.id, opts)
      if not ok then raywm.log(("outputs: %s not configured: %s"):format(o.name, tostring(err))) end
    end
  end
end

return {
  api = 1,
  setup = function(ctx)
    for _, o in ipairs(raywm.outputs({ all = true })) do apply(o) end
    ctx.on("output_add", function(id)
      for _, o in ipairs(raywm.outputs({ all = true })) do
        if o.id == id then apply(o) end
      end
    end)
  end,
  -- For tests only.
  outputs = outputs,
}
