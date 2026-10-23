-- rules.lua for tests/shell.sh: a client-side decoration rule.
return {
  { match = { app_id = "^raywm%-test%-csd$" }, decoration = "client" },
}
