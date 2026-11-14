-- Programs started with the session: panels, wallpaper, notifications...
--
-- The commands live in ray.conf (no longer in this plugin):
--
--   [autostart]
--   exec = waybar
--   exec = swaybg -i ~/Pictures/wallpaper.png -m fill
--   exec = mako
--
-- Each command runs once per RayWM start, through /bin/sh in the background
-- (raywm.spawn_once), in file order. raywm.reload() does not start them
-- again; a command added to ray.conf starts at the next reload. (A command
-- started with -s on the command line is separate.) Errors, such as
-- "waybar: not found", appear in RayWM's log.
--
-- For code that should run once at startup, use raywm.startup(fn) in
-- init.lua or in a plugin's setup.

return {
  api = 1,
  setup = function()
    local settings = raywm.settings and raywm.settings.autostart
    local commands = settings and settings.exec or {}
    for _, cmd in ipairs(commands) do
      assert(type(cmd) == "string", "autostart: ray.conf commands must be strings")
      assert(#cmd > 0, "autostart: empty command in ray.conf")
      raywm.spawn_once(cmd)
    end
  end,
}
