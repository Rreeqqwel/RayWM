# Configuring RayWM

RayWM's configuration is Lua. `init.lua` loads plugins, and the plugins
do everything else: tiling, key bindings, window rules. The plugin API
is described in [API.md](API.md).

## Where the configuration lives

| Path | Used when |
|---|---|
| file given with `raywm -c FILE` | always, if given |
| `$XDG_CONFIG_HOME/raywm/init.lua` | `XDG_CONFIG_HOME` is set and not empty |
| `~/.config/raywm/init.lua` | otherwise |

Plugins are loaded from `plugins/` in the same directory as `init.lua`.

```
~/.config/raywm/
├── init.lua
└── plugins/
    ├── dwindle.lua
    ├── binds.lua
    ├── focus.lua
    └── screenshot.lua
```

To start from the example, copy it from the repository or the release
archive. Do not copy over a configuration you want to keep; compare
first with `diff -ru config ~/.config/raywm`.

```sh
cp -r config ~/.config/raywm
```

## The example configuration

`config/init.lua`:

```lua
raywm.load("dwindle")
raywm.load("binds")
raywm.load("focus") -- Super+H/J/K/L, Super+Tab, focus border
raywm.load("screenshot") -- Print etc.; needs grim, slurp, wl-clipboard
```

### Key bindings (`plugins/binds.lua`, `plugins/focus.lua`, `plugins/screenshot.lua`)

| Keys | Action | Defined in |
|---|---|---|
| Super+Return | open a terminal (`$TERMINAL`, default `foot`) | binds.lua |
| Super+Q | close the focused window | binds.lua |
| Ctrl+Alt+R | reload the configuration | binds.lua |
| Super+Shift+R | reload (alternative) | binds.lua |
| Super+Shift+E | quit RayWM | binds.lua |
| Super+H / Super+L | focus the window to the left / right | focus.lua |
| Super+J / Super+K | focus the window below / above | focus.lua |
| Super+Tab / Super+Shift+Tab | focus the next / previous window | focus.lua |
| Print | save a screenshot of all outputs | screenshot.lua |
| Shift+Print | select a region with the mouse, save it | screenshot.lua |
| Ctrl+Print | copy a screenshot of all outputs to the clipboard | screenshot.lua |
| Ctrl+Shift+Print | select a region, copy it to the clipboard | screenshot.lua |
| Ctrl+Alt+P | save a screenshot (same as Print) | screenshot.lua |
| Super + left drag | move a floating window | core |
| Super + right drag | resize a floating window | core |
| Ctrl+Alt+F1..F12 | switch VT (only when started from a TTY) | core |

To change a binding, edit the `ctx.bind(...)` lines; the key syntax is
described in [API.md](API.md#ctx-per-plugin). For example:

```lua
ctx.bind("Super+d", function() raywm.spawn("fuzzel") end)
ctx.bind("Super+Shift+1", function() raywm.spawn("firefox") end)   -- unshifted key name
```

### Keyboard layouts

The layout comes from the xkb environment variables, for example:

```sh
XKB_DEFAULT_LAYOUT=us,ru XKB_DEFAULT_OPTIONS=grp:alt_shift_toggle raywm -s foot
```

Bindings are written with Latin key names and work in every layout of
the keymap: with Russian active, Super+J is still Super+J. (Before
v0.1.2 they did not; see [Upgrading from v0.1.1](#upgrading-from-v011).)
In a nested session the keymap comes from the outer compositor.

### Focus navigation (`plugins/focus.lua`)

- **Super+H/J/K/L** focus the window to the left, below, above or to the
  right of the focused one, by position on screen. A window counts as
  "to the right" only if it lies further right with both edges; windows
  directly beside the focused one win over diagonal ones; then the
  nearest one, then the best aligned, then the one focused most
  recently. Windows on the same output come first; another output is
  used only if it lies in that direction. If there is no window in that
  direction, nothing happens.
- **Super+Tab / Super+Shift+Tab** go through all windows in a fixed
  order: outputs from left to right, and on each output the windows in
  the order they were opened. It wraps around.
- Hidden windows are skipped. Windows are never moved or resized.

Edit the `options` table at the top of `plugins/focus.lua`:

| Option | Default | Meaning |
|---|---|---|
| `keys.left` / `down` / `up` / `right` | `{ "Super+h" }` / `{ "Super+j" }` / `{ "Super+k" }` / `{ "Super+l" }` | directional focus; add e.g. `"Super+Left"` for arrow keys |
| `keys.next` / `keys.prev` | `{ "Super+Tab" }` / `{ "Super+Shift+Tab" }` | focus cycle |
| `cross_output` | `true` | continue onto the next output in that direction when the current output has no window there |
| `warp` | `false` | move the pointer to the centre of the window chosen with these keys (see below) |
| `border.width` | `2` | border around the focused window, in pixels; `0` disables it |
| `border.color` | `"#5294e2"` | `"#rrggbb"` or `"#rrggbbaa"` |

An empty key list disables an action.

**Pointer warp** (`warp = true`) moves the pointer only when the focus
really changed and the pointer is not already inside the new window. It
is skipped while a mouse button is held or a window is being dragged
(the pointer belongs to that interaction), and while a launcher or lock
screen holds the keyboard.

The v0.1.1 order of Super+J/K (dwindle's tree order) is still available
in `plugins/dwindle.lua`, unbound by default.

### Dwindle options

Edit the top of `plugins/dwindle.lua`:

| Variable | Default | Meaning |
|---|---|---|
| `gap` | `8` | pixels between windows and around the edge of the usable area |
| `min_size` | `1` | smallest width/height ever requested |
| `keys.focus_next` / `keys.focus_prev` | `{}` / `{}` | cycle focus in tree order (the v0.1.1 Super+J/K). To use it, bind keys here and remove them from `focus.lua`, e.g. `focus_next = { "Super+Tab" }` |

How dwindle works:
- each output has its own binary tree;
- a new window splits the focused window's area in two, along that
  area's longer side, and takes focus;
- closing a window gives its area to its sibling;
- windows are placed inside the output's usable area, i.e. without
  panel exclusive zones;
- the tree shape survives a reload (unless one spiral is deeper than
  4096 windows; then the tree is rebuilt). It is stored in
  `$XDG_RUNTIME_DIR/raywm-dwindle-$WAYLAND_DISPLAY.txt`, read once, and
  ignored in a new session. Without `XDG_RUNTIME_DIR` the tree shape is
  simply not kept.

### Screenshots (`plugins/screenshot.lua`)

The plugin runs external programs: `grim` captures, `slurp` selects a
region, `wl-copy` (wl-clipboard) fills the clipboard, and `notify-send`
reports results when it is installed. RayWM only provides the
wlr-screencopy and xdg-output protocols these tools use. Every action
runs in the background, so the compositor never waits for a capture or
a selection.

Edit the `options` table at the top of `plugins/screenshot.lua`:

| Option | Default | Meaning |
|---|---|---|
| `dir` | `nil` | where files are saved. `nil` means `$XDG_PICTURES_DIR/Screenshots` if `XDG_PICTURES_DIR` is an absolute path, otherwise `~/Pictures/Screenshots`. Must be absolute; created when needed |
| `prefix` | `"screenshot"` | file names are `<prefix>-YYYY-MM-DD_HH-MM-SS.png` |
| `notify` | `true` | show notifications with `notify-send` (skipped if it is not installed) |
| `keys.full` | `{ "Print", "Ctrl+Alt+p" }` | save all outputs |
| `keys.region` | `{ "Shift+Print" }` | save a selected region |
| `keys.copy_full` | `{ "Ctrl+Print" }` | copy all outputs to the clipboard |
| `keys.copy_region` | `{ "Ctrl+Shift+Print" }` | copy a selected region |

An empty key list disables an action. Behaviour:
- **Unique names:** an existing file is never overwritten; `-1`, `-2`,
  ... is appended instead. Files are created with mode `0600` (only you
  can read them); change it with `chmod` if needed.
- **Cancel:** Escape in slurp cancels the selection.
  Nothing is saved, copied or reported; the log says
  `raywm screenshot: selection cancelled`.
- **Errors** (a missing program, a directory that cannot be created,
  grim failing) are written to the RayWM log as
  `raywm screenshot: ...` and shown as a critical notification.
- **Nested sessions:** the outer compositor (sway, for example) may
  keep Print for itself; Ctrl+Alt+P works there.
- **XDG_PICTURES_DIR** is read from the environment only; RayWM does
  not parse `~/.config/user-dirs.dirs`. Set `dir` instead if needed.
- Plugin messages go to RayWM's standard error, like all its logs.
- On file systems without hard links (FAT, exFAT, some FUSE mounts)
  the "never overwritten" guarantee is weaker: two shots in the same
  second may race for one name. A failing slurp (not only Escape) is
  logged as a cancelled selection.
- **Fallback bindings:** the core's fallback keys (Super+Return,
  Super+Shift+R, Super+Shift+E) are active only while *no* plugin binds
  a key. With the example config, if `binds.lua` fails but
  `screenshot.lua` loads, the Print keys count as bindings and the
  fallback keys are off. Fix `binds.lua` and restart RayWM (or switch VT
  / close the nested window), or comment out `raywm.load("screenshot")`
  while you repair the config.

**Privacy.** The screen capture protocol is available to every client
of RayWM's Wayland socket, whether this plugin is loaded or not. See
[SECURITY.md](../SECURITY.md).

To remove the plugin, delete `raywm.load("screenshot")` from
`init.lua` and reload: its bindings disappear, the other plugins keep
working.

### Panels, docks, wallpapers, launchers

These are separate programs that use the layer-shell protocol, and they
are started like any other program. For example:

```sh
raywm -s 'waybar & swaybg -i ~/wall.png'
```

or from a binding with `raywm.spawn(...)`. Exclusive zones (for example
a bar's height) are subtracted from the usable area that dwindle uses.

## Mouse

- **Click** a window to focus it. Clicking a launcher-like layer surface
  that accepts the keyboard gives it the keyboard.
- **While a button is held**, the window that got the press keeps
  receiving the pointer, even outside its area and across outputs:
  selections, scrollbars and slurp regions continue until the release.
  Other windows get the pointer again after the last button is released.
- **Super + left/right drag** moves/resizes a floating window (see
  below). It starts only on the first button of an interaction: if you
  already hold a button in a window, Super+click goes to that window.

## Floating and managed windows

- A window that no plugin has claimed is **floating**. Move it with
  Super + left drag or with the client's own title bar; resize it with
  Super + right drag or its edges.
- A layout plugin can **manage** a window with `ctx.manage(id)`. Dwindle
  does this for every window it tiles. Managed windows cannot be dragged
  or resized interactively, so they cannot leave their tile. Clicking
  them still focuses them.
- A window stops being managed when the plugin releases it, when it
  closes, and when the plugin is unloaded or reloaded.

To keep some windows floating while dwindle tiles the rest, the plugin
would have to skip them. Floating rules are not part of v0.1.

## Reloading

Ctrl+Alt+R (example config), Super+Shift+R (fallback), or
`raywm.reload()` from Lua. A reload:
1. calls every plugin's `teardown`;
2. releases all plugin registrations (bindings, handlers, timers,
   managed windows);
3. destroys the Lua state;
4. runs `init.lua` again in a fresh state.

Windows stay open and keep their positions. Dwindle restores its tree.

## When the configuration is broken

RayWM is designed so that a broken configuration is not a dead end:

- **Syntax error or runtime error in `init.lua`.** The error is logged.
  Plugins loaded before the error keep working.
- **Error in a plugin.** Only that plugin is unloaded (the log line
  starts with `[plugin-name]`). Everything else keeps working.
- **No plugin binds any key** (no config, or the binding plugin failed).
  The core's **fallback bindings** are active:
  - Super+Return opens a terminal;
  - Super+Shift+R reloads;
  - Super+Shift+E quits.
- **Infinite loop in a plugin.** The instruction budget stops it and
  unloads the plugin.

Fix the file in the terminal, then reload. To see the log, start RayWM
from a terminal, or redirect it: `raywm -s foot 2>~/raywm.log`.

### Diagnosing key bindings

The normal log shows one line per plugin with its number of bindings,
and warns about keys that do nothing:

```
info(lua): loaded plugin focus (6 key bindings)
warning(lua): plugin focus: key Super+j is already bound by plugin dwindle, whose binding is used
warning(lua): no plugin registered key bindings: only the built-in Super+Return, Super+Shift+E and Super+Shift+R work
```

Start with `-d` to see what each key press with Super, Ctrl or Alt was
matched as (plain typing is never logged; `-d` also makes wlroots very
verbose):

```
info(input): key: Super+j (keycode 36, layout 1 "Russian") -> binding
info(input): key: Super+x (keycode 45, layout 0 "English (US)") -> no binding
```

If a key shows up as `-> binding` but nothing seems to happen, the
binding ran: focus may have moved to a window you did not notice (the
focus border shows it). If the key does not appear at all, RayWM never
got it: in a nested session the outer compositor may keep it (many
desktops bind Super+letter combinations). Try it from a TTY, or change
the binding.

## Upgrading from v0.1.1

`install.sh` never modifies an existing `~/.config/raywm`, so after an
upgrade your configuration behaves exactly as with v0.1.1 (including
dwindle's Super+J/K), with these improvements from the core: the
implicit pointer grab, and bindings that work with non-Latin layouts.

To get directional focus, the focus cycle and the focus border, update
two plugins and load the new one (from the extracted release directory
or the repository):

```sh
cd ~/.config/raywm
cp plugins/dwindle.lua plugins/dwindle.lua.v011      # keep your old copy
cp /path/to/raywm-v0.1.2/config/plugins/focus.lua plugins/
cp /path/to/raywm-v0.1.2/config/plugins/dwindle.lua plugins/
echo 'raywm.load("focus")' >> init.lua
```

Then reload (Ctrl+Alt+R). If you had changed `dwindle.lua` (for example
`gap`), copy your changes into the new file; compare with
`diff -u plugins/dwindle.lua.v011 plugins/dwindle.lua`. The other
plugins (`binds.lua`, `screenshot.lua`) did not change.

If you copy `focus.lua` but keep the old `dwindle.lua`, the log says
`plugin focus: key Super+j is already bound by plugin dwindle`: the old
Super+J/K keep the tree order, and Super+H/L, Super+Tab and the border
work. Update `dwindle.lua` to get the new Super+J/K.

If Super+J/K did not work for you with v0.1.1, the likely causes are:
- a non-Latin keyboard layout was active (fixed in v0.1.2);
- the outer compositor kept the keys in a nested session (see
  [Diagnosing key bindings](#diagnosing-key-bindings));
- `~/.config/raywm` was missing or incomplete, so only the fallback keys
  worked (the log now warns about this);
- the focus did move, but nothing showed it (v0.1.2 draws a border).

## Testing a configuration

To test a configuration without touching your real one:

```sh
raywm -c /path/to/test/init.lua -s foot     # nested in your current session
```
