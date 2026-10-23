-- rules.lua for tests/rules.sh (read by window-rules.lua).
return {
  { match = { app_id = "^float%-me$" }, float = true, size = { 400, 300 }, position = { 10, 20 }, opacity = 0.5 },
  { match = { app_id = "^ws3$" }, workspace = "3" },
  { match = { app_id = "^quiet$" }, focus = false },
  { match = { title = "^fs%-me$" }, fullscreen = true },
  { match = { app_id = "^tile%-me$" }, float = false },
  { match = { app_id = { "^half$", "^never$" } }, float = true, size = { "50%", "50%" } },
  { match = { app_id = "[" }, float = true }, -- a bad pattern: reported, ignored
}
