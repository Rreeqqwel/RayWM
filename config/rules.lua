-- Window rules, read by plugins/window-rules.lua when a window opens.
-- Return a list of rules (or { rules = {...}, options = {...} }). The
-- fields are described at the top of plugins/window-rules.lua; patterns
-- are Lua patterns ("%-" for a literal "-"). Find a window's app id and
-- title with a plugin that logs them (docs/API.md has one), or
-- `raywmctl windows` (docs/IPC.md).
return {
  -- { match = { app_id = "^pavucontrol$" }, float = true, size = { 800, 500 } },
  -- { match = { app_id = "^firefox$", title = "^Picture%-in%-Picture$" }, float = true, focus = false },
  -- { match = { app_id = "^mpv$" }, workspace = "5" },
  -- { match = { app_id = "^foot$" }, opacity = 0.95 },
  -- { match = { app_id = "^org%.kde%." }, decoration = "client" },
  -- { match = { app_id = "^steam_app_%d+$" }, fullscreen = true },
}
