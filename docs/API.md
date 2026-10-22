# RayWM Lua API v1

RayWM embeds Lua 5.4. All behaviour beyond the native core (layout,
key bindings, window rules) lives in plugins.

## Loading: the one contract

1. On start (and on reload) RayWM runs `init.lua`, by default
   `$XDG_CONFIG_HOME/raywm/init.lua` (or `~/.config/raywm/init.lua`, or
   the path given with `-c`).
2. `init.lua` loads plugins by name: `raywm.load("dwindle")` runs
   `plugins/dwindle.lua` next to `init.lua`. Names use `[A-Za-z0-9_-]`.
   Each name can be loaded once. `raywm.load` is only allowed while
   `init.lua` runs.
3. A plugin file must return a table:

   ```lua
   return {
     api = 1,                        -- required, must equal raywm.api_version
     setup = function(ctx) ... end,  -- required
     teardown = function() ... end,  -- optional
   }
   ```

4. Plugins register everything through `ctx` inside `setup` (or later,
   from their own callbacks). Each registration belongs to its plugin, so
   RayWM can release it when the plugin is unloaded.

`raywm.load` returns `true` on success, or `nil, message` when the plugin
is rejected (bad file, wrong `api`, no `setup`, or an error in `setup`).
A rejected plugin leaves nothing registered.

## Lifecycle and errors

- Every callback runs in protected mode. If a callback, `setup` or
  `teardown` raises an error, the error and a traceback are logged and
  **that plugin is unloaded**. Other plugins keep running.
- Unloading happens after the current event has been fully dispatched.
  Then `teardown` is called (its own errors are only logged) and all of
  the plugin's handlers, bindings and timers are released.
- A plugin that fails in `setup` has its `teardown` called too, so
  `teardown` must cope with a partly initialised plugin.
- `raywm.reload()` (and the fallback binding Super+Shift+R) tears down
  every plugin, creates a fresh Lua state and runs `init.lua` again. This
  also happens only after the current event. Calls to `raywm.reload()`
  made from `init.lua` or from a `teardown` are ignored, with a warning.
  If a reload fails (out of memory), Lua stays off and the fallback
  bindings apply until the next reload.
- Events are not delivered while `init.lua` runs. Plugins should read
  the current state (`raywm.views()`, `raywm.outputs()`) in `setup`.
- Host calls made from a handler can trigger further events, for example
  `view_focus`. This nesting is limited to 8 levels; deeper events are
  dropped and a warning is logged.
- If `init.lua` is missing or fails, or no loaded plugin binds any key,
  the core keeps **fallback bindings** active:
  Super+Return opens `$TERMINAL` (default `foot`),
  Super+Shift+E quits, and Super+Shift+R reloads.
- Limits (bug containment, not security): about 64 MiB of Lua memory,
  **shared by all plugins**, and an instruction budget of about 200 M
  instructions for each top-level callback. When a limit is exceeded, an
  error is raised inside the plugin that was running. With the shared
  memory cap, a plugin that hoards memory can cause a different plugin's
  allocation to fail.

**Trust model.** Plugins are trusted user code with the full Lua standard
library (`io`, `os`, including `os.exit`) and one shared global
environment. Use `local` variables to avoid clashes between plugins. The
limits catch mistakes like infinite loops; they are not a sandbox.

## Ids

Windows, outputs and timers are plain integers. RayWM does not reuse an
id within a session (ids wrap only after 2³²), and every call checks it. Commands on a window that no
longer exists return `nil, "stale"` instead of failing. Only mapped
(visible to the user) windows are known to Lua.

## `raywm` (global)

| Function | Returns | Notes |
|---|---|---|
| `raywm.api_version` | `1` | |
| `raywm.load(name)` | `true` or `nil, err` | only during `init.lua` |
| `raywm.views()` | `{id, ...}` | most recently focused first (max 256) |
| `raywm.view(id)` | table or `nil, "stale"` | `{id, x, y, w, h, title, app_id, focused, output}` |
| `raywm.focused()` | id or `nil` | |
| `raywm.outputs()` | `{ {id, x, y, w, h, usable = {x, y, w, h}}, ... }` | layout coordinates; `usable` excludes panel exclusive zones |
| `raywm.view_move(id, x, y)` | `true` or `nil, "stale"` | immediate |
| `raywm.view_place(id, x, y, w, h)` | `true` or `nil, "stale"` | asynchronous, see below |
| `raywm.view_opacity(id, a)` | `true` or `nil, "stale"` | `0..1` |
| `raywm.view_raise(id)` | `true` or `nil, "stale"` | |
| `raywm.view_focus(id)` | `true` or `nil, "stale"` | also raises the window |
| `raywm.view_close(id)` | `true` or `nil, "stale"` | asks the client to close |
| `raywm.view_show(id, bool)` | `true` or `nil, "stale"` | hidden windows are not drawn and lose focus |
| `raywm.spawn(cmd)` | — | runs `cmd` with `/bin/sh -c` |
| `raywm.quit()` / `raywm.reload()` | — | |
| `raywm.log(msg)` | — | writes to the compositor log |

Geometry (`x, y, w, h`) is the window's *content* geometry (without
client-side shadows), in layout coordinates.

**`view_place` is a request.** The client picks its final size, for
example a terminal rounding to whole cells, and applies it when it acks
the configure. The new position is applied in the same frame. When that
happens, `view_resized` fires and `raywm.view(id)` shows the real
geometry.

## `ctx` (per plugin)

| Function | Returns | Notes |
|---|---|---|
| `ctx.on(event, fn)` | registration id | `fn(id)` |
| `ctx.bind(keys, fn)` | registration id | e.g. `"Super+Shift+Return"` |
| `ctx.timer(ms, fn)` | registration id | one-shot; re-arm inside `fn` to repeat |
| `ctx.cancel(id)` | `true` or `nil, "stale"` | cancels a handler, binding or timer |

Key syntax: modifiers `Super`/`Logo`/`Mod4`, `Shift`, `Ctrl`/`Control`,
`Alt`/`Mod1`, joined with `+`, followed by an xkb keysym name. Bindings
match the **unshifted** key, so Shift+1 is written `"Super+Shift+1"`,
not `"Super+exclam"`. Caps Lock and Num Lock are ignored. The key events
of a matched binding are not sent to clients. If two plugins bind the
same key, the plugin loaded first wins.

## Events

All handlers receive one integer id.

| Event | id | When |
|---|---|---|
| `view_map` | view | a window became visible; RayWM centred it first. `raywm.focused()` is still the previous window; afterwards the new window gets focus unless a handler called `raywm.view_focus` |
| `view_unmap` | view | it is gone, so `raywm.view(id)` is already stale |
| `view_focus` | view, or `0` | keyboard focus changed; `0` means no window has focus |
| `view_title` | view | title changed (mapped windows only) |
| `view_resized` | view | a `view_place` size took effect |
| `output_add` / `output_remove` | output | monitors |
| `layout` | output or `0` | output geometry or usable area changed |

When the focused window closes, `view_focus` for the next window (or `0`)
fires before `view_unmap`.

## Not supported in v0.1

- Per-frame callbacks, animations, drawing (rectangles, borders, text,
  images): planned for v0.2 (`on_frame`, decoration rectangles).
- Blur, shadows, rounded corners and shaders. wlroots' scene renderer
  cannot do these, and they would need a custom renderer.
- Workspaces, maximize/fullscreen (requests are answered but ignored),
  Xwayland, touch, tablets, screen capture protocols.
- Docks and panels are separate programs using layer-shell (waybar,
  yambar, fuzzel, swaybg, ...), not Lua.
