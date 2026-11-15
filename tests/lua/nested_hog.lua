-- The handler that emits a nested event spent most of the budget: the
-- nested handler it wakes must not be unloaded for it.
raywm.load("outer_hog")
raywm.load("inner_busy")
