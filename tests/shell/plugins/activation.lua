-- workspaces.lua with activation = "switch" (the plugin is loaded under
-- another name so its options can be set before setup).
local ws = dofile(raywm.config_dir .. "/plugins/workspaces.lua")
ws.options.activation = "switch"
return ws
