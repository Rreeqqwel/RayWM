-- Programs started with the session: panels, wallpaper, notifications...
--
-- Each command runs once per RayWM start, through /bin/sh in the
-- background (raywm.spawn_once), in this order. raywm.reload() does not
-- start them again; a command added to the list starts at the next
-- reload. (A command started with -s on the command line is separate.)
-- Errors, such as "waybar: not found", appear in RayWM's log.
--
-- For code that should run once at startup, use raywm.startup(fn) in
-- init.lua or in a plugin's setup.

local options = {
  commands = {
    -- "waybar",
    -- "swaybg -i ~/Pictures/wallpaper.png -m fill",
    -- "mako",
    -- "swayidle -w timeout 300 'swaylock -f' before-sleep 'swaylock -f'",
  },
}

return {
  api = 1,
  setup = function()
    for _, cmd in ipairs(options.commands) do
      assert(type(cmd) == "string", "autostart: commands must be strings")
      raywm.spawn_once(cmd)
    end
  end,
  options = options,
}
