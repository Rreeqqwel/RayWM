-- Allows tearing page flips on every output (tests/perf.sh only).
local function allow(id)
  assert(raywm.output_configure(id, { allow_tearing = true }))
end
return {
  api = 1,
  setup = function(ctx)
    for _, o in ipairs(raywm.outputs()) do allow(o.id) end
    ctx.on("output_add", allow)
  end,
}
