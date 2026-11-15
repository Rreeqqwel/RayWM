-- One runtime for the coroutine instruction-hook tests (see lua_test.zig).
raywm.load("co_main")
raywm.load("co_create")
raywm.load("co_wrap")
raywm.load("co_nested")
raywm.load("co_early")
raywm.load("co_normal")
