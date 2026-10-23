-- raywm.startup / raywm.spawn_once: order, errors, reload.
raywm.spawn("startup-returned:" .. tostring(raywm.startup(function() raywm.spawn("startup:1") end)))
raywm.load("starter")
raywm.startup(function() raywm.spawn("startup:3") end)
raywm.spawn("plain")
raywm.spawn("once-first:" .. tostring(raywm.spawn_once("once-cmd")))
raywm.spawn("once-second:" .. tostring(raywm.spawn_once("once-cmd")))
raywm.startup(function() error("startup boom") end)
raywm.startup(function() raywm.spawn("startup:after-error") end)
