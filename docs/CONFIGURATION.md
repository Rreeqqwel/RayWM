# Configuring RayWM

RayWM has two configuration files, each the only authority for its part:

- **`raywm.conf`** (since v0.2.2): the compositor's basic settings: focus,
  gaps, borders, the drag modifier, Xwayland. A small INI-like file, read
  and validated by the core; it never runs code.
- **`init.lua` and plugins** (Lua): which plugins are loaded, and
  everything they do: tiling, key bindings, window rules, outputs, input
  devices, autostart. The plugin API is described in [API.md](API.md).

## raywm.conf

```ini
# ~/.config/raywm/raywm.conf
[general]
focus_new_windows = true
terminal = kitty

[appearance]
inner_gaps = 4
outer_gaps = 12
border_width = 2
border_active = #88c0d0
border_inactive = #3b4252

[input]
mouse_modifier = alt
focus_follows_mouse = true
```

The complete example with every setting and its default is
[config/raywm.conf](../config/raywm.conf) (installed as
`/usr/share/raywm/config/raywm.conf`).

### Format

- `[section]` lines, then `key = value` lines; spaces around `=` are optional.
- Comments are whole lines starting with `#` or `;` (a `#` inside a value
  is part of it: colours are `#rrggbb`).
- Booleans: `true`/`false`, `yes`/`no`, `on`/`off`, `1`/`0`.
- Integers: decimal, each setting has a range.
- Strings: the rest of the line; optional `"..."` or `'...'` quotes;
  no control characters; at most 256 bytes.
- Colours: `#rrggbb` or `#rrggbbaa` (alpha; `ff` is opaque).
- The same key twice: the last one wins (with a warning).

### Settings

| Section | Key | Default | Values | Effect | Reload |
|---|---|---|---|---|---|
| `general` | `focus_new_windows` | `true` | boolean | A new window takes the keyboard focus. With `false`, only a dialog of the focused window, or a window appearing while nothing has focus, takes it. A plugin that chooses focus in `view_map` still decides. | yes |
| `general` | `terminal` | empty | string | Command for Super+Return (the core's fallback key and `binds.lua`), run with `/bin/sh -c`. Empty: `$TERMINAL`, else `foot`. | yes |
| `general` | `xwayland` | `true` | boolean | Start Xwayland (lazily) for X11 programs. `RAYWM_XWAYLAND=0` also turns it off. | **restart** |
| `appearance` | `inner_gaps` | `8` | 0..500 | Pixels between tiled windows (`dwindle.lua`). | yes |
| `appearance` | `outer_gaps` | `8` | 0..500 | Pixels between tiled windows and the edge of the usable area. | yes |
| `appearance` | `border_width` | `2` | 0..64 | Border width (`focus.lua`); `0`: no borders. | yes |
| `appearance` | `border_active` | `#5294e2` | colour | Border of the focused window. | yes |
| `appearance` | `border_inactive` | `none` | colour or `none` | Border of the other windows. | yes |
| `input` | `mouse_modifier` | `super` | `super`, `alt`, `ctrl`, `shift` | Hold it and drag a floating window: left button moves, right button resizes. | yes |
| `input` | `focus_follows_mouse` | `false` | boolean | Moving the pointer into a window focuses (and raises) it, once per entry: keyboard focus moved elsewhere is not taken back while the pointer stays in the same window. Never while a button is held, during a drag, with a lock screen or a launcher holding the keyboard, or when the window is covered by a fullscreen one. Only real pointer motion counts, not windows moving under a still pointer. | yes |

Defaults are the behaviour of v0.2.1, so a missing file changes nothing.
`[plugins]` and layout selection are deliberately not here: `init.lua`
decides which plugins run (one authority for plugin loading).

### Where it is read, and in which order

1. Built-in defaults.
2. The system file `/usr/share/raywm/config/raywm.conf` (installed by the
   package; replaced by upgrades, so do not edit it).
3. Your file `raywm.conf` **next to `init.lua`**: `~/.config/raywm/raywm.conf`
   (`$XDG_CONFIG_HOME/raywm/raywm.conf`), or, with `raywm -c DIR/init.lua`,
   `DIR/raywm.conf`.
4. Then Lua: `init.lua` and the plugins, which read the result as
   `raywm.settings` (see [API.md](API.md#raywmsettings)).

Later files override earlier ones key by key: your file only needs the
keys you change. Packages never write to `~/.config/raywm`.

### Errors

A file with a syntax error or an invalid value is **ignored as a whole**,
never applied in part, and the log says where:

```
error(conf): /home/me/.config/raywm/raywm.conf:7: [appearance] outer_gaps = fifty: expected a whole number
error(conf): /home/me/.config/raywm/raywm.conf ignored: fix the errors above (raywm -t checks it)
```

At startup RayWM then runs with the defaults and the system file; on a
reload it keeps the settings it had (`raywm.conf has errors: keeping the
previous settings`). Unknown sections and keys are only warnings, so a file
written for a newer RayWM still loads.

Check a file without starting RayWM (exit status 1 if a file is rejected):

```sh
raywm -t                                # ~/.config/raywm/raywm.conf
raywm -t -c /path/to/test/init.lua      # /path/to/test/raywm.conf
```

`raywm -t` prints every effective setting, then `configuration OK` or the
errors. **Recovering from an invalid configuration:** run `raywm -t`, fix the
line it names (or move the file away: `mv ~/.config/raywm/raywm.conf{,.broken}`
gives you the defaults), then reload with Ctrl+Alt+R.

### Reloading

Ctrl+Alt+R (or Super+Shift+R, `raywm.reload()`) re-reads `raywm.conf`
before the Lua plugins are set up again, so the plugins see the new values
at once. Everything marked "yes" above changes on reload; `xwayland` needs a
restart (the log says so when it changed).

### Plugins and raywm.conf

The shipped `dwindle.lua`, `focus.lua` and `binds.lua` take their defaults
from `raywm.conf`. A plain number written into a plugin's option table
instead (for example `gaps_in = 4` at the top of `dwindle.lua`) overrides
`raywm.conf` for that plugin. Plugins copied from v0.2.1 or older do not
read `raywm.conf` at all and keep their own values; everything else keeps
working. To use `raywm.conf` for gaps and borders, update those plugin
files from `/usr/share/raywm/config/plugins/`.

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

### Output mode (resolution and refresh rate)

By default each output uses the mode its monitor marks as preferred,
which is often 60 Hz even on faster monitors. To pick another mode, set
`RAYWM_OUTPUT_MODE=WIDTHxHEIGHT@HZ` before starting RayWM:

```sh
RAYWM_OUTPUT_MODE=1920x1080@240 raywm -s foot
```

- The mode applies to every output that has it; other outputs keep
  their preferred mode.
- `HZ` may have decimals (`59.95`). The nearest mode within 1 Hz is
  used, since monitors rarely report exact values (240 Hz is often
  240.0007 Hz).
- If the driver rejects the mode, RayWM logs a warning and uses the
  preferred mode.
- Modes the monitor supports are listed by
  `edid-decode /sys/class/drm/card*-*/edid` or, in another compositor,
  `wlr-randr`. The mode is chosen once, when the output appears; there
  is no runtime switching yet.

`plugins/outputs.lua` sets modes per monitor (and can be reloaded); RayWM
also logs when an output runs below the highest refresh rate its monitor
offers at that resolution. For games, see [GAMING.md](GAMING.md):
`adaptive_sync` and the opt-in `allow_tearing` are per-output settings
there, and `raywmctl perf` shows the mode actually in use.

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
| `border.width` | `raywm.conf` `border_width` (2) | border width in pixels; `0` disables borders |
| `border.color` | `raywm.conf` `border_active` (`"#5294e2"`) | focused window: `"#rrggbb"` or `"#rrggbbaa"` |
| `border.inactive` | `raywm.conf` `border_inactive` (`nil`) | other windows; `nil`: no border |

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
| `gaps_in` / `gaps_out` | `raywm.conf` `inner_gaps` / `outer_gaps` (8) | pixels between windows / around the edge of the usable area |
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
1. re-reads `raywm.conf` (kept unchanged if it has errors);
2. calls every plugin's `teardown`;
3. releases all plugin registrations (bindings, handlers, timers,
   managed windows);
4. destroys the Lua state;
5. runs `init.lua` again in a fresh state.

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

## Upgrading to v0.2.2

No change is required: without `raywm.conf` RayWM behaves as v0.2.1. To use
it, copy the example and edit it: `cp /usr/share/raywm/config/raywm.conf
~/.config/raywm/` (or from the source archive's `config/`). Gaps and borders
from `raywm.conf` need the v0.2.2 `dwindle.lua` and `focus.lua`; your older
copies keep their own option values. Updates now come through
`raywm-update` (see [INSTALL.md](INSTALL.md#updates-raywm-update)).

## Upgrading to v0.2.1

A patch release: no configuration change is required. New, optional:
`allow_tearing` in `outputs.lua` entries, `raywmctl perf`, and
`RAYWM_EXPLICIT_SYNC=0` to turn off explicit synchronization. The installer
keeps your configuration; the shipped `outputs.lua` only gained a comment
and the `allow_tearing` field name in its list.

## Upgrading to v0.2.0

The installer preserves your configuration. Compare the shipped plugins
before copying over local edits. Load `outputs`, `input`, `workspaces`,
`window-rules` before `dwindle`, then `floating`, `binds`, `focus`,
`screenshot`, and `autostart`, as in the example `init.lua`. Configure
monitor/device/rule/autostart policy in the corresponding plugin's local
options or `rules.lua`. Existing API v1 plugins keep their loading contract.

Optional `animations` and `focus-indicator` plugins are supplied but not
loaded by default. See [EFFECTS.md](EFFECTS.md) and [PLUGINS.md](PLUGINS.md).
Use `RAYWM_XWAYLAND=0` to disable Xwayland; otherwise it starts lazily when
an X client connects, and children inherit its `DISPLAY`. Install Xwayland
for X11 applications. External programs can use `raywmctl`; [IPC.md](IPC.md)
describes its socket derivation and fixed actions.

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
