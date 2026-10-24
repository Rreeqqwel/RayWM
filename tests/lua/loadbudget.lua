-- A plugin that runs away while loading (or in setup) fails alone: the rest
-- of init.lua and the plugins after it still load.
local ok1 = raywm.load("loadspin")
local ok2 = raywm.load("setupspin")
raywm.load("probe")
raywm.spawn("after:" .. tostring(ok1) .. ":" .. tostring(ok2))
