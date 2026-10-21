-- Asks for a reload from teardown: must be ignored, not loop.
return { api = 1, setup = function() end, teardown = function() raywm.reload() end }
