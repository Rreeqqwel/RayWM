-- RayWM example config. Copy this directory to ~/.config/raywm/.
-- Every plugin lives in plugins/<name>.lua and is loaded by name.
raywm.load("outputs") -- monitor modes, scale, positions (empty list)
raywm.load("input") -- keyboard layout, repeat, touchpad (empty list)
raywm.load("workspaces") -- Super+1..9; before the layout, which tiles each one
raywm.load("window-rules") -- dialogs float; your rules are in rules.lua
raywm.load("dwindle")
raywm.load("floating") -- Super+Shift+Space: tiled <-> floating
raywm.load("binds")
raywm.load("focus") -- Super+H/J/K/L, Super+Tab, focus border
raywm.load("screenshot") -- Print etc.; needs grim, slurp, wl-clipboard
raywm.load("autostart") -- programs started with the session (empty list)
