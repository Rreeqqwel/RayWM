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
raywm.load("screenshot") -- Print etc.; needs grim, slurp, wl-clipboard
```

### Key bindings (`plugins/binds.lua`, `plugins/dwindle.lua`, `plugins/screenshot.lua`)

| Keys | Action | Defined in |
|---|---|---|
| Super+Return | open a terminal (`$TERMINAL`, default `foot`) | binds.lua |
| Super+Q | close the focused window | binds.lua |
| Ctrl+Alt+R | reload the configuration | binds.lua |
| Super+Shift+R | reload (alternative) | binds.lua |
| Super+Shift+E | quit RayWM | binds.lua |
| Super+J / Super+K | focus the next / previous window | dwindle.lua |
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

### Dwindle options

Edit the top of `plugins/dwindle.lua`:

| Variable | Default | Meaning |
|---|---|---|
| `gap` | `8` | pixels between windows and around the edge of the usable area |
| `min_size` | `1` | smallest width/height ever requested |

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
from a terminal, or redirect it: `raywm -s foot 2>~/raywm.log`. Add `-d`
for verbose wlroots messages.

To test a configuration without touching your real one:

```sh
raywm -c /path/to/test/init.lua -s foot     # nested in your current session
```
