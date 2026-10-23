-- Tests config/plugins/screenshot.lua against a mock of the RayWM API, then
-- runs the commands it builds with /bin/sh and fake grim, slurp, wl-copy
-- and notify-send (the real tools are covered by tests/screenshot.sh).
-- Run from the repo root: XDG_RUNTIME_DIR=<tmpdir> lua5.4 tests/screenshot_test.lua
local plugin_path = "config/plugins/screenshot.lua"
local failures, checks = 0, 0

local function check(cond, msg)
  checks = checks + 1
  if not cond then
    failures = failures + 1
    io.stderr:write("FAIL: ", msg, "\n", debug.traceback("", 2), "\n")
  end
end

local function q(s) return "'" .. s:gsub("'", [['\'']]) .. "'" end

-- ---- mock runtime --------------------------------------------------------

local spawned = {}
raywm = {
  api_version = 1,
  spawn = function(cmd)
    assert(type(cmd) == "string")
    spawned[#spawned + 1] = cmd
  end,
  log = function() end,
  views = function() return {} end,
  outputs = function() return {} end,
  -- So that every plugin binds all its keys here (v0.2.0 API).
  workspaces = function() return {} end,
  pointer = function() return { x = 0, y = 0, busy = false } end,
  view_fullscreen = function() return true end,
  view_maximize = function() return true end,
  view = function() return nil, "stale" end,
  focused = function() return nil end,
  reload = function() end,
  quit = function() end,
}

-- Registrations by plugin name, like the core's per-plugin ownership.
local regs = {}
local function make_ctx(name)
  regs[name] = { binds = {} }
  return {
    bind = function(key, fn)
      assert(type(key) == "string" and type(fn) == "function", "bad bind")
      table.insert(regs[name].binds, { key = key, fn = fn })
      return #regs[name].binds
    end,
    on = function(_, fn) assert(type(fn) == "function") return 1 end,
    timer = function(_, fn) assert(type(fn) == "function") return 1 end,
    cancel = function() return true end,
    manage = function() return true end,
  }
end

-- os.getenv is replaced so the tests control the environment.
local real_getenv = os.getenv
local env = {}
os.getenv = function(k) return env[k] end

local function load(name, path)
  local mod = dofile(path)
  assert(mod.api == 1 and type(mod.setup) == "function", name .. ": bad module")
  return mod
end
local function unload(name, mod)
  if mod and mod.teardown then mod.teardown() end
  regs[name] = nil
end
local function setup(name, mod) mod.setup(make_ctx(name)) end

local function keyset(name)
  local r = {}
  for _, b in ipairs(regs[name].binds) do r[#r + 1] = b.key end
  table.sort(r)
  return table.concat(r, " | ")
end

-- "Ctrl+Shift+Print" -> "ctrl+shift+print" with modifiers in a fixed order.
local function normalize(spec)
  local parts = {}
  for p in spec:gmatch("[^+]+") do parts[#parts + 1] = p:lower() end
  local key = table.remove(parts)
  local alias = { logo = "super", mod4 = "super", control = "ctrl", mod1 = "alt" }
  for i, m in ipairs(parts) do parts[i] = alias[m] or m end
  table.sort(parts)
  parts[#parts + 1] = key
  return table.concat(parts, "+")
end

local function find_bind(name, key)
  for _, b in ipairs(regs[name].binds) do if b.key == key then return b.fn end end
end

-- ---- 1. bindings and conflicts ---------------------------------------------

env = { HOME = "/home/u" }
local shot = load("screenshot", plugin_path)
setup("screenshot", shot)
check(keyset("screenshot") == "Ctrl+Alt+p | Ctrl+Print | Ctrl+Shift+Print | Print | Shift+Print",
  "bindings: " .. keyset("screenshot"))

-- The shipped plugins together must not bind the same key twice.
env.XDG_RUNTIME_DIR = real_getenv("XDG_RUNTIME_DIR")
env.WAYLAND_DISPLAY = "raywm-screenshot-test"
local others = {}
local shipped = { "binds", "dwindle", "focus", "floating", "workspaces" }
for _, name in ipairs(shipped) do
  others[name] = load(name, "config/plugins/" .. name .. ".lua")
  setup(name, others[name])
end
local seen = {}
for _, name in ipairs({ "binds", "dwindle", "focus", "floating", "workspaces", "screenshot" }) do
  for _, b in ipairs(regs[name].binds) do
    local k = normalize(b.key)
    check(not seen[k], ("key %s bound by %s and %s"):format(b.key, seen[k] or "", name))
    seen[k] = name
  end
end
-- The core's fallback bindings and VT switching are not plugin bindings,
-- but must not be shadowed either.
for _, k in ipairs({ "super+return", "shift+super+e", "shift+super+r" }) do
  check(seen[k] ~= "screenshot", "screenshot shadows core binding " .. k)
end
for n = 1, 12 do check(not seen["alt+ctrl+f" .. n], "VT switch key bound") end

-- ---- 2. unload and reload ----------------------------------------------

local counts = {}
for name in pairs(others) do counts[name] = #regs[name].binds end
unload("screenshot", shot)
check(regs.screenshot == nil, "unload leaves bindings")
for name, n in pairs(counts) do
  check(#regs[name].binds == n and n > 0, "unloading screenshot touched plugin " .. name)
end
shot = load("screenshot", plugin_path)
setup("screenshot", shot)
check(#regs.screenshot.binds == 5, "reload: expected 5 bindings, got " .. #regs.screenshot.binds)
unload("binds", others.binds)
unload("dwindle", others.dwindle)
unload("focus", others.focus)
unload("floating", others.floating)
unload("workspaces", others.workspaces)

-- ---- 3. callbacks only build a command and spawn it ----------------------

local blocking = { "execute", "exit", "remove", "rename", "tmpname" }
local function guard(fn)
  local saved = {}
  for _, f in ipairs(blocking) do
    saved[f] = os[f]
    os[f] = function() error("blocking os." .. f .. " called from a callback", 2) end
  end
  local io_saved = io
  io = setmetatable({}, { __index = function(_, k) error("io." .. k .. " used in a callback", 2) end })
  local ok, err = pcall(fn)
  io = io_saved
  for f, v in pairs(saved) do os[f] = v end
  return ok, err
end

env = { HOME = "/home/u", XDG_PICTURES_DIR = "/home/u/Bilder" }
shot = load("screenshot", plugin_path)
local ok, err = guard(function() setup("screenshot", shot) end)
check(ok, "setup used blocking calls: " .. tostring(err))
for _, b in ipairs(regs.screenshot.binds) do
  spawned = {}
  ok, err = guard(b.fn)
  check(ok, b.key .. ": " .. tostring(err))
  check(#spawned == 1, b.key .. ": expected one spawn, got " .. #spawned)
  check(spawned[1] and spawned[1]:sub(1, 21) == "exec /bin/sh -c 'mode", b.key .. ": unexpected command start")
end

-- Expected arguments per binding.
local function args_of(cmd) return cmd:match("raywm%-screenshot (.*)$") end
local function run_key(key)
  spawned = {}
  find_bind("screenshot", key)()
  return spawned[1]
end
local stamp = "%d%d%d%d%-%d%d%-%d%d_%d%d%-%d%d%-%d%d"
check(args_of(run_key("Print")):match("^'save' 'full' '/home/u/Bilder/Screenshots/screenshot%-" .. stamp .. "%.png' 1$"),
  "Print args: " .. args_of(run_key("Print")))
check(args_of(run_key("Ctrl+Alt+p")):match("^'save' 'full' '/home/u/Bilder/Screenshots/"), "Ctrl+Alt+P is not a full save")
check(args_of(run_key("Shift+Print")):match("^'save' 'region' '/home/u/Bilder/Screenshots/"), "Shift+Print is not a region save")
check(args_of(run_key("Ctrl+Print")) == "'copy' 'full' '' 1", "Ctrl+Print args: " .. args_of(run_key("Ctrl+Print")))
check(args_of(run_key("Ctrl+Shift+Print")) == "'copy' 'region' '' 1", "Ctrl+Shift+Print args")

-- ---- 4. directory selection ---------------------------------------------

local function dir_with(e, opt_dir)
  env = e
  local m = load("screenshot", plugin_path)
  m._test.options.dir = opt_dir
  setup("screenshot", m)
  return m._test.dir()
end
check(dir_with({ HOME = "/h", XDG_PICTURES_DIR = "/p/" }) == "/p/Screenshots", "trailing slash in XDG_PICTURES_DIR")
check(dir_with({ HOME = "/h", XDG_PICTURES_DIR = "Pictures" }) == "/h/Pictures/Screenshots", "relative XDG_PICTURES_DIR not rejected")
check(dir_with({ HOME = "/h", XDG_PICTURES_DIR = "" }) == "/h/Pictures/Screenshots", "empty XDG_PICTURES_DIR not rejected")
check(dir_with({ HOME = "/h" }) == "/h/Pictures/Screenshots", "HOME fallback")
check(dir_with({}) == nil, "no HOME: no directory")
check(dir_with({ HOME = "/h" }, "/custom dir") == "/custom dir", "options.dir")
check(dir_with({ HOME = "/h" }, "relative") == nil, "relative options.dir accepted")
check(dir_with({ HOME = "/h" }, "/a\0b") == nil, "options.dir with a NUL byte accepted")

-- ---- 5. the commands, run by /bin/sh with fake tools --------------------

local runtime = assert(real_getenv("XDG_RUNTIME_DIR"), "XDG_RUNTIME_DIR must be set")
if runtime:sub(1, 1) ~= "/" then -- zig build passes its (relative) cache dir
  local pwd = io.popen("pwd")
  runtime = pwd:read("l") .. "/" .. runtime
  pwd:close()
end
local p = io.popen("mktemp -d " .. q(runtime .. "/raywm-screenshot-test.XXXXXX"))
local tmp = p:read("l")
p:close()
assert(tmp and tmp:sub(1, 1) == "/", "mktemp failed")
local function sh(cmd) return os.execute(cmd) end
local function read(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("a")
  f:close()
  return s
end
local function exists(path) return read(path) ~= nil end

local fakes = {
  grim = [[printf '%s\n' "$*" >>"$LOG/grim.args"
[ -n "$GRIM_FAIL" ] && exit 1
for out; do :; done
printf 'PNG %s' "$*" >"$out"]],
  slurp = [[[ -n "$SLURP_CANCEL" ] && { echo 'selection cancelled' >&2; exit 1; }
echo '10,20 30x40']],
  ["wl-copy"] = [[printf '%s\n' "$*" >>"$LOG/wl-copy.args"; cat >"$LOG/clipboard"]],
  ["notify-send"] = [[printf '%s\n' "$*" >>"$LOG/notify.log"]],
}
-- bin-all: every tool; bin-no-<tool>: all but one.
local function make_bin(name, skip)
  local d = tmp .. "/" .. name
  sh("mkdir -p " .. q(d))
  for tool, body in pairs(fakes) do
    if tool ~= skip then
      local f = assert(io.open(d .. "/" .. tool, "w"))
      f:write("#!/bin/sh\n", body, "\n")
      f:close()
      sh("chmod +x " .. q(d .. "/" .. tool))
    end
  end
  return d
end
local bins = { all = make_bin("bin-all") }
for tool in pairs(fakes) do bins[tool] = make_bin("bin-no-" .. tool, tool) end

local logdir = tmp .. "/log"
-- run(cmd, bin, opts): executes a spawned command like raywm.spawn does
-- (/bin/sh -c, scrubbed environment), with PATH = the fake tools in `bin`
-- plus a few coreutils, so the host's real grim etc. are never found.
-- Returns the exit status.
local function run_only(cmd, bin, extra)
  local o = extra or {}
-- Keep coreutils (mktemp, ln, mkdir, ...) but hide every real tool.
  local core = tmp .. "/core"
  if not exists(core .. "/.done") then
    sh("mkdir -p " .. q(core))
    for _, t in ipairs({ "mkdir", "mktemp", "ln", "mv", "rm", "cat", "printf" }) do
      sh("ln -sf \"$(command -v " .. t .. ")\" " .. q(core .. "/" .. t))
    end
    sh("touch " .. q(core .. "/.done"))
  end
  sh("rm -rf " .. q(logdir) .. " && mkdir -p " .. q(logdir))
  local vars = {
    "PATH=" .. q(bin .. ":" .. core),
    "LOG=" .. q(logdir),
    "XDG_RUNTIME_DIR=" .. q(tmp),
    "WAYLAND_DISPLAY=" .. q(o.no_display and "" or "raywm-test"),
  }
  if o.cancel then vars[#vars + 1] = "SLURP_CANCEL=1" end
  if o.grim_fail then vars[#vars + 1] = "GRIM_FAIL=1" end
  local _, _, code = os.execute("cd " .. q(tmp) .. " && env -i " .. table.concat(vars, " ") .. " /bin/sh -c "
    .. q(cmd) .. " 2>" .. q(tmp .. "/stderr"))
  return code
end
local function notes() return read(logdir .. "/notify.log") or "" end
local function stderr() return read(tmp .. "/stderr") or "" end

-- A plugin instance saving into `d`, with a fixed clock for file names.
local function plugin_for(d, opts)
  env = { HOME = tmp .. "/home" }
  local m = load("screenshot", plugin_path)
  m._test.options.dir = d
  for k, v in pairs(opts or {}) do m._test.options[k] = v end
  setup("screenshot", m)
  return m
end
local now = os.time({ year = 2026, month = 10, day = 22, hour = 12, min = 34, sec = 56 })
local name = "screenshot-2026-10-22_12-34-56"

-- 5a. Hostile directory names: the screenshot lands exactly there, and
-- nothing in the name is executed.
-- (printf is a shell builtin, so the payloads would work if they ran.)
local evil = tmp .. "/sh ots/it's \"q\"/$(printf x >PWNED1)/`printf x >PWNED2`/;printf x >PWNED3;/x\ny/-n/*"
local m = plugin_for(evil)
local code = run_only(m._test.command("save", "full", now), bins.all)
check(code == 0, "hostile dir: exit " .. tostring(code) .. ": " .. stderr())
check(exists(evil .. "/" .. name .. ".png"), "hostile dir: file not at the expected path")
for i = 1, 3 do check(not exists(tmp .. "/PWNED" .. i) and not exists(evil .. "/PWNED" .. i), "command injection " .. i) end
check(notes():find("Screenshot saved", 1, true) and notes():find(name, 1, true), "no success notification: " .. notes())

-- 5b. Unique names: a second shot in the same second, and an existing
-- file are never overwritten.
local plain = tmp .. "/plain"
m = plugin_for(plain)
local cmd = m._test.command("save", "full", now)
check(run_only(cmd, bins.all) == 0 and run_only(cmd, bins.all) == 0 and run_only(cmd, bins.all) == 0, "three saves")
check(exists(plain .. "/" .. name .. ".png") and exists(plain .. "/" .. name .. "-1.png") and exists(plain .. "/" .. name .. "-2.png"),
  "names are not unique")
local p2 = io.popen("ls -A " .. q(plain))
local listing = p2:read("a")
p2:close()
check(not listing:find(".raywm-screenshot", 1, true), "temporary files left: " .. listing)
local p3 = io.popen("stat -c %a " .. q(plain .. "/" .. name .. ".png"))
check(p3:read("l") == "600", "screenshot file is not private (0600)")
p3:close()

-- A directory with the target name is skipped, not written into.
sh("mkdir -p " .. q(plain .. "/screenshot-2026-10-22_12-35-56.png"))
check(run_only(m._test.command("save", "full", now + 60), bins.all) == 0, "save next to a directory")
check(exists(plain .. "/screenshot-2026-10-22_12-35-56-1.png"), "a directory with the target name was not skipped")

-- 5c. Region: slurp's geometry goes to grim; cancelling saves nothing.
code = run_only(m._test.command("save", "region", now + 90), bins.all)
check(code == 0 and (read(logdir .. "/grim.args") or ""):find("-g 10,20 30x40 -t png", 1, true), "region not passed to grim")
code = run_only(m._test.command("save", "region", now + 120), bins.all, { cancel = true })
check(code == 0, "cancel: exit " .. tostring(code))
check(not exists(plain .. "/screenshot-2026-10-22_12-36-56.png"), "cancel saved a file")
check(not exists(logdir .. "/grim.args"), "cancel still ran grim")
check(notes() == "", "cancel sent a notification: " .. notes())
check(stderr():find("selection cancelled", 1, true), "cancel not logged")

-- 5d. Copy to the clipboard: PNG data, typed, nothing saved.
code = run_only(m._test.command("copy", "full"), bins.all)
check(code == 0, "copy: exit " .. tostring(code) .. stderr())
check((read(logdir .. "/clipboard") or ""):find("^PNG"), "clipboard did not get grim's output")
check((read(logdir .. "/wl-copy.args") or ""):find("--type image/png", 1, true), "wl-copy without --type image/png")
check(notes():find("Screenshot copied", 1, true), "no copy notification")
code = run_only(m._test.command("copy", "region"), bins.all, { cancel = true })
check(code == 0 and not exists(logdir .. "/clipboard"), "cancelled copy touched the clipboard")

-- 5e. Missing tools: a clear error (log + notification), no partial output.
local function missing(tool, mode, area)
  code = run_only(m._test.command(mode, area, now + 600), bins[tool])
  check(code ~= 0, tool .. " missing: exit 0")
  check(stderr():find(tool .. " is not installed", 1, true), tool .. " missing: not logged: " .. stderr())
  check(notes():find("Screenshot failed", 1, true), tool .. " missing: no notification")
  check(not exists(plain .. "/screenshot-2026-10-22_12-44-56.png"), tool .. " missing: file created")
end
missing("grim", "save", "full")
missing("slurp", "save", "region")
missing("wl-copy", "copy", "full")
-- Without notify-send everything still works, silently.
code = run_only(m._test.command("save", "full", now + 900), bins["notify-send"])
check(code == 0 and exists(plain .. "/screenshot-2026-10-22_12-49-56.png"), "save without notify-send failed")

-- 5f. Errors: grim fails, no WAYLAND_DISPLAY, no directory.
code = run_only(m._test.command("save", "full", now + 1200), bins.all, { grim_fail = true })
check(code ~= 0 and notes():find("grim could not capture", 1, true), "grim failure not reported")
check(not exists(plain .. "/screenshot-2026-10-22_12-54-56.png"), "grim failure left a file")
code = run_only(m._test.command("save", "full", now), bins.all, { no_display = true })
check(code ~= 0 and stderr():find("WAYLAND_DISPLAY", 1, true), "missing WAYLAND_DISPLAY not reported")
env = {}
m = load("screenshot", plugin_path)
setup("screenshot", m)
code = run_only(m._test.command("save", "full", now), bins.all)
check(code ~= 0 and notes():find("no screenshot directory", 1, true), "no directory not reported")
-- notify = false: no notification at all.
m = plugin_for(plain, { notify = false })
code = run_only(m._test.command("save", "full", now + 1800), bins.all)
check(code == 0 and notes() == "", "notify=false still notified")

sh("rm -rf " .. q(tmp))
os.getenv = real_getenv
print(("screenshot plugin: %d checks, %d failures"):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
