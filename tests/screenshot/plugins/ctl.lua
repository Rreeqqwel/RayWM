-- Super+F12 reloads the configuration (sent by the virtual keyboard).
return {
  api = 1,
  setup = function(ctx) ctx.bind("Super+F12", raywm.reload) end,
}
