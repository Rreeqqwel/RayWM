-- A legitimately short callback that wakes a runaway nested handler: the
-- runaway is unloaded, the caller stays.
raywm.load("outer_call")
raywm.load("inner_spin")
