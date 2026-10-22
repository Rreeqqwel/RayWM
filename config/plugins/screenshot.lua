-- Screenshots with external tools:
--   grim       captures outputs (through RayWM's wlr-screencopy support);
--   slurp      lets you select a region;
--   wl-copy    (wl-clipboard) puts the PNG on the clipboard;
--   notify-send (libnotify) reports the result, if it is installed.
--
-- Every action runs in the background through raywm.spawn(), so the
-- compositor never waits for a capture or a selection. File and directory
-- names reach the shell only as single-quoted arguments of a fixed script,
-- so no name can run commands.

local options = {
  -- Where screenshots are saved. nil: $XDG_PICTURES_DIR/Screenshots if
  -- that variable is an absolute path, otherwise ~/Pictures/Screenshots.
  dir = nil,
  -- File names: <prefix>-YYYY-MM-DD_HH-MM-SS.png; an existing file is never
  -- overwritten (-1, -2, ... is appended instead). Files are mode 0600.
  prefix = "screenshot",
  -- Notifications through notify-send (silently skipped if missing).
  notify = true,
  -- Key bindings per action; an empty list disables the action.
  keys = {
    full = { "Print", "Ctrl+Alt+p" }, -- Ctrl+Alt+P: for nested sessions, where
                                      -- the outer compositor may keep Print
    region = { "Shift+Print" },
    copy_full = { "Ctrl+Print" },
    copy_region = { "Ctrl+Shift+Print" },
  },
}

-- Runs as: sh -c SCRIPT raywm-screenshot MODE AREA FILE NOTIFY
--   MODE save|copy, AREA full|region, FILE path to save to ("" if unknown
--   or when copying), NOTIFY 1|0. Messages go to RayWM's log (stderr).
local script = [=[
mode=$1 area=$2 file=$3 notify=$4
say() { printf 'raywm screenshot: %s\n' "$1" >&2; }
note() {
  [ "$notify" = 1 ] && command -v notify-send >/dev/null 2>&1 &&
    notify-send -a RayWM "$@" >/dev/null 2>&1
  return 0
}
fail() { say "$1"; note -u critical 'Screenshot failed' "$1"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "$1 is not installed (package: $2)"; }

need grim grim
[ "$area" = region ] && need slurp slurp
[ "$mode" = copy ] && need wl-copy wl-clipboard
[ -n "$WAYLAND_DISPLAY" ] || fail 'WAYLAND_DISPLAY is not set'

geom=
if [ "$area" = region ]; then
  # slurp exits non-zero when the selection is cancelled (Escape).
  geom=$(slurp) && [ -n "$geom" ] || { say 'selection cancelled'; exit 0; }
fi
shot() {
  if [ -n "$geom" ]; then grim -g "$geom" -t png "$1"; else grim -t png "$1"; fi
}

if [ "$mode" = copy ]; then
  tmp=$(mktemp "${XDG_RUNTIME_DIR:-/tmp}/raywm-screenshot.XXXXXX") || fail 'cannot create a temporary file'
  trap 'rm -f -- "$tmp"' EXIT
  shot "$tmp" || fail 'grim could not capture the screen'
  wl-copy --type image/png <"$tmp" || fail 'wl-copy could not set the clipboard'
  say 'copied to the clipboard'
  note 'Screenshot copied' 'The image is on the clipboard.'
  exit 0
fi

[ -n "$file" ] || fail 'no screenshot directory: set options.dir, XDG_PICTURES_DIR or HOME'
dir=${file%/*}
mkdir -p "$dir" || fail "cannot create $dir"
tmp=$(mktemp "$dir/.raywm-screenshot.XXXXXX") || fail "cannot write to $dir"
trap 'rm -f -- "$tmp"' EXIT
shot "$tmp" || fail 'grim could not capture the screen'
# ln does not replace an existing file, so concurrent shots never collide.
out=$file n=0
until ln "$tmp" "$out" 2>/dev/null; do
  if [ ! -e "$out" ]; then
    mv "$tmp" "$out" || fail "cannot write $out" # no hard links here
    break
  fi
  n=$((n + 1))
  [ "$n" -le 1000 ] || fail "no free file name for $file"
  out=${file%.png}-$n.png
done
say "saved $out"
note -i "$out" 'Screenshot saved' "$out"
]=]

local function quote(s)
  return "'" .. s:gsub("'", [['\'']]) .. "'"
end

-- An absolute path the shell can receive intact (no NUL byte).
local function valid_path(p)
  return type(p) == "string" and p:sub(1, 1) == "/" and not p:find("\0", 1, true) and #p < 4000
end

local function screenshot_dir()
  if options.dir ~= nil then
    if valid_path(options.dir) then return options.dir end
    raywm.log("screenshot: options.dir must be an absolute path; saving is disabled")
    return nil
  end
  local pictures = os.getenv("XDG_PICTURES_DIR")
  if valid_path(pictures) then return (pictures:gsub("/+$", "")) .. "/Screenshots" end
  local home = os.getenv("HOME")
  if valid_path(home) then return (home:gsub("/+$", "")) .. "/Pictures/Screenshots" end
  return nil
end

local function valid_prefix(p)
  return type(p) == "string" and p ~= "" and #p <= 64 and not p:find("[/%z]")
end

local dir -- resolved in setup

-- Builds the command for one action. Exposed for tests (see the module table).
local function command(mode, area, now)
  local file = ""
  if mode == "save" and dir then
    local prefix = valid_prefix(options.prefix) and options.prefix or "screenshot"
    file = dir .. "/" .. prefix .. "-" .. os.date("%Y-%m-%d_%H-%M-%S", now) .. ".png"
  end
  return "exec /bin/sh -c " .. quote(script) .. " raywm-screenshot " .. quote(mode) .. " " .. quote(area) .. " "
    .. quote(file) .. " " .. (options.notify and "1" or "0")
end

local actions = {
  full = { "save", "full" },
  region = { "save", "region" },
  copy_full = { "copy", "full" },
  copy_region = { "copy", "region" },
}

return {
  api = 1,
  setup = function(ctx)
    dir = screenshot_dir()
    for _, name in ipairs({ "full", "region", "copy_full", "copy_region" }) do
      local mode, area = actions[name][1], actions[name][2]
      for _, key in ipairs(options.keys[name] or {}) do
        ctx.bind(key, function() raywm.spawn(command(mode, area)) end)
      end
    end
  end,
  -- For tests only: not part of the plugin contract.
  _test = { options = options, command = command, quote = quote, dir = function() return dir end },
}
