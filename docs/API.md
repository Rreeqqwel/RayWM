# RayWM Lua Plugin API v1

RayWM embeds Lua 5.4. All behaviour beyond the native core lives in
plugins: tiling, key bindings, window rules. This document is the
contract between the core and plugins. Everything here is checked
against `src/lua.zig` and `src/host.zig`, and most of it is covered by
`tests/lua_test.zig`.

- [Loading](#loading-the-one-contract)
- [Lifecycle and errors](#lifecycle-and-errors)
- [Limits and trust model](#limits-and-trust-model)
- [Ids](#ids)
- [`raywm` functions](#raywm-global)
- [Pointer and border (v0.1.2)](#pointer-and-border-v012)
- [`ctx` functions](#ctx-per-plugin)
- [Events](#events)
- [Examples](#examples)
- [Not supported in v0.1](#not-supported-in-v01)

## Loading: the one contract

1. On start, and on every reload, RayWM runs `init.lua`. The path is the
   one given with `-c`, otherwise `$XDG_CONFIG_HOME/raywm/init.lua`, or
   `~/.config/raywm/init.lua` when `XDG_CONFIG_HOME` is unset or empty.
2. `init.lua` loads plugins by name. `raywm.load("dwindle")` runs
   `plugins/dwindle.lua` from the directory that contains `init.lua`.
   - Names may only contain `[A-Za-z0-9_-]` and be 1–64 characters long.
   - Each name can be loaded once.
   - `raywm.load` may only be called while `init.lua` runs. A call from a
     callback is an error in the calling plugin.
3. A plugin file must return a table:

   ```lua
   return {
     api = 1,                        -- required; must equal raywm.api_version
     setup = function(ctx) end,      -- required
     teardown = function() end,      -- optional
   }
   ```

4. Plugins register everything through `ctx`, either in `setup` or later
   from their own callbacks. Every registration belongs to its plugin, so
   RayWM can release it when the plugin is unloaded.

`raywm.load(name)` returns `true` on success. It returns `nil, message`
when the plugin is rejected, for any of these reasons:
- the file cannot be loaded or raises an error;
- it does not return a table;
- `api` is not `1`;
- `setup` is missing, or `teardown` is not a function;
- `setup` raised an error.

A rejected plugin leaves nothing registered. A plugin whose `setup`
failed still has its `teardown` called (see below).

## Lifecycle and errors

- **Isolation.** Every callback, `setup` and `teardown` runs in protected
  mode. On error, the message and a traceback are logged as
  `[plugin] ...` and **only that plugin is unloaded**. Error objects that
  are not strings are logged as `(non-string error)`. Wrong argument
  types passed to API functions are errors like any other.
- **Deferred cleanup.** An unloaded plugin's callbacks stop immediately.
  Its `teardown` runs, and its handlers, bindings, timers and managed
  windows are released, once the event being dispatched has finished.
  Nothing is removed while RayWM is still iterating over registrations.
  Errors in `teardown` are only logged. A plugin whose `setup` failed
  also gets `teardown`, so `teardown` must cope with a partly
  initialised plugin.
- **Reload.** `raywm.reload()` (or a binding to it) runs after the
  current event:
  - every plugin is torn down and the Lua state is destroyed;
  - a fresh state is created and `init.lua` runs again.

  Calls made from `init.lua` or from a `teardown` are ignored with a
  warning, because they would loop forever. If a reload fails (Lua runs
  out of memory), Lua stays off until the next successful reload, and
  the fallback bindings apply.
- **Events during `init.lua`.** None are delivered while `init.lua`
  runs. Plugins should read the current state (`raywm.views()`,
  `raywm.outputs()`) in `setup`.
- **Nesting.** Host calls made from a handler can trigger more events;
  `raywm.view_focus` emits `view_focus`, for example. Nesting is
  limited to 8 levels: deeper events are dropped with a warning.
- **Fallback bindings.** While no live plugin has registered a key
  binding, the core provides three:
  - Super+Return opens `$TERMINAL` (default `foot`);
  - Super+Shift+E quits;
  - Super+Shift+R reloads.

  This covers a missing `init.lua` and an `init.lua` that fails before
  loading a binding plugin.

## Limits and trust model

**Plugins are trusted user code. They are not sandboxed.** They get the
Lua standard library, including `io`, `os` (`os.execute`, `os.exit`) and
`load`, and all plugins share one global environment. Use `local`
variables to avoid clashes. The limits below catch common mistakes, such
as an infinite loop or runaway memory use; they do not contain a hostile
plugin. See [SECURITY.md](../SECURITY.md).

| Limit | Default | Behaviour |
|---|---|---|
| Lua memory | 64 MiB, **shared by all plugins** | an allocation over the cap fails with a Lua memory error in whichever plugin is running, which need not be the plugin that used the memory |
| Instructions | about 200 M per top-level callback | the running plugin gets `instruction budget exceeded`. Catching it with `pcall`, in any coroutine, does not help: the error is raised again on every instruction, in every Lua thread, until control returns to RayWM |
| Registrations | 65 536 at once (all plugins together; registrations released during a callback count until it returns) | `too many registrations` |
| `debug` library, native modules | not available: no `debug`, no `package.loadlib`, no C module searchers | they could rewrite internal upvalues and the registry, or load native code |

## Ids

Windows, outputs and timers are plain integers:
- windows and outputs share one id space; registration ids (handlers,
  bindings, timers) have their own;
- ids are not reused within a session (they wrap only after 2³²);
- every call checks the id it is given.

A command on a window that no longer exists returns `nil, "stale"`; it
does not raise an error. Lua only sees **mapped** windows, i.e. windows
the user can currently see.

## `raywm` (global)

All geometry is the window's *content* geometry, without client-side
shadows, in layout coordinates (the global coordinate space spanning all
outputs).

| Function | Returns | Notes |
|---|---|---|
| `raywm.api_version` | `1` | constant |
| `raywm.load(name)` | `true` or `nil, err` | only during `init.lua` |
| `raywm.views()` | `{id, ...}` | mapped windows, most recently focused first (at most 4096) |
| `raywm.view(id)` | table or `nil, "stale"` | `{id, x, y, w, h, title, app_id, focused, output, visible}`. `output` is the output under the window's centre, or `0`. `title`/`app_id` are `""` when unset. `visible` is `false` after `view_show(id, false)` (since v0.1.2) |
| `raywm.focused()` | id or `nil` | the window with keyboard focus |
| `raywm.outputs()` | `{ {id, x, y, w, h, usable = {x, y, w, h}}, ... }` | at most 4096. `usable` excludes layer-shell exclusive zones (panels). Disabled or unplugged outputs are not listed |
| `raywm.view_move(id, x, y)` | `true` or `nil, "stale"` | immediate. Cancels a position waiting for a resize |
| `raywm.view_place(id, x, y, w, h)` | `true` or `nil, "stale"` | asynchronous, see below |
| `raywm.view_opacity(id, a)` | `true` or `nil, "stale"` | `a` is clamped to `0..1` |
| `raywm.view_raise(id)` | `true` or `nil, "stale"` | top of the window stack |
| `raywm.view_focus(id)` | `true` or `nil, "stale"` | keyboard focus, and raises the window. Has no effect on a hidden window, but still returns `true` |
| `raywm.view_close(id)` | `true` or `nil, "stale"` | asks the client to close; it may refuse or ask the user |
| `raywm.view_show(id, visible)` | `true` or `nil, "stale"` | a hidden window is not drawn and cannot be clicked. If it had focus, focus moves to the next visible window |
| `raywm.view_border(id, width, color)` | `true` or `nil, "stale"` | since v0.1.2; a solid border around the window, see [below](#pointer-and-border-v012) |
| `raywm.pointer()` | `{x, y, busy}` | since v0.1.2; see [below](#pointer-and-border-v012) |
| `raywm.pointer_warp(x, y)` | `true` or `nil, reason` | since v0.1.2; see [below](#pointer-and-border-v012) |
| `raywm.spawn(cmd)` | — | runs `cmd` with `/bin/sh -c` in a new session. The child is detached (it is never a zombie of RayWM) and has `WAYLAND_DISPLAY` set |
| `raywm.quit()` | — | stops the compositor |
| `raywm.reload()` | — | see [Lifecycle](#lifecycle-and-errors) |
| `raywm.log(msg)` | — | writes `msg` (converted with `tostring` rules) to the log |

**Coordinates** are clamped to ±2²⁴. Sizes passed to `view_place` are
clamped to `1..2²⁴`. Integer arguments outside the `i32` range are errors.

**`view_place` is a request.** The client chooses its final size, and
applies it when it acknowledges the configure; a terminal, for example,
rounds to whole character cells. The requested position is applied in the
same frame as that commit, so the window never shows a new position with
its old size. Once that has happened, `view_resized` fires and
`raywm.view(id)` reports the real geometry. If the size does not change,
the window simply moves. A second `view_place` before the client has
acknowledged the first one always sends a new request.

## Pointer and border (v0.1.2)

These were added in v0.1.2 without changing `api = 1`. A plugin that
must also run on v0.1.1 can test for them: `if raywm.pointer_warp then`.

**`raywm.pointer()`** returns `{x, y, busy}`: the cursor position in
layout coordinates (integers), and whether a grab owns the pointer. A
grab is a window being moved or resized, a held mouse button (the
implicit grab of the window that got the press, see
[ARCHITECTURE.md](ARCHITECTURE.md#pointer-input-and-grabs)) or a
client's popup grab.

**`raywm.pointer_warp(x, y)`** moves the cursor to `(x, y)` (layout
coordinates). Pointer focus follows (the window under the new position
gets `enter`); keyboard focus does not change. It returns `true`, or
`nil` and a reason:
- `"busy"`: a grab owns the pointer (as `pointer().busy`). Warping
  then would drag a window or pull a held interaction elsewhere;
- `"exclusive"`: an exclusive layer surface (a launcher or lock screen)
  holds the keyboard;
- `"outside"`: the position is not on any output.

**`raywm.view_border(id, width, color)`** draws a solid border of
`width` pixels (`0`–`64`) around the window, outside its geometry, in
`color` (`"#rrggbb"` or `"#rrggbbaa"`). `width = 0` removes it (the
color may be omitted). The border moves, hides and stacks with the
window, follows its size, and is drawn below its popups. It takes no
input: clicking it does nothing. A bad width or color is an error in the
calling plugin.

Borders are window state, like opacity: they stay until changed, also
after the plugin that drew them is unloaded. A plugin that draws borders
should remove them in its `teardown` (which also runs when the plugin is
unloaded after an error), as `config/plugins/focus.lua` does.

## `ctx` (per plugin)

| Function | Returns | Notes |
|---|---|---|
| `ctx.on(event, fn)` | registration id | `fn(id)`; unknown event names are an error |
| `ctx.bind(keys, fn)` | registration id | e.g. `"Super+Shift+Return"`; an invalid key spec is an error |
| `ctx.timer(ms, fn)` | registration id | one-shot after `ms` (0 .. 2³¹) milliseconds; re-arm inside `fn` to repeat |
| `ctx.cancel(id)` | `true` or `nil, "stale"` | cancels a handler, binding or timer of this plugin |
| `ctx.manage(view, on)` | `true` or `nil, "stale"` | `on` defaults to `true`; see below |

**Key syntax.** Modifiers are joined with `+` and followed by an xkb
keysym name, matched case-insensitively:
- `Super`, `Logo` or `Mod4`;
- `Shift`;
- `Ctrl` or `Control`;
- `Alt` or `Mod1`.

Bindings match the **unshifted** key, so Shift+1 is written
`"Super+Shift+1"`, not `"Super+exclam"`. Caps Lock and Num Lock are
ignored. The key events of a matched binding are not sent to any client.
When several bindings match, the one registered first wins; RayWM logs a
warning (once per plugin) when a plugin binds a key that is already
bound.

**Keyboard layouts.** The keysym comes from the active layout. When that
layout gives a non-Latin character for the key (Cyrillic, Greek, ...),
the key's Latin keysym from another layout of the keymap is used
instead: with `XKB_DEFAULT_LAYOUT=us,ru` and Russian active, the J key
still matches `"Super+j"`. Latin layouts keep their own keysyms (on a
German layout the key labelled Z is `z`). `raywm -d` logs, for each key
press with Super, Ctrl or Alt, the keysym and layout it was matched with
and whether a binding ran.

**Managed windows.** A layout plugin calls `ctx.manage(view)` for the
windows whose geometry it controls. While any live plugin manages a
window, the core refuses free interactive move and resize for it:
- Super+drag is refused, and behaves as a normal click (focus still works);
- the client's own xdg move/resize requests (client-side title bars) are
  refused;
- a drag already in progress stops changing the window.

Programmatic `view_move` and `view_place` are not affected. A window
stops being managed:
- with `ctx.manage(view, false)`;
- when it unmaps;
- when the managing plugin is unloaded or reloaded.

Windows that no plugin manages float, and can be moved and resized
freely. Managing a window twice is harmless, and repeated toggling does
not grow any internal list.

## Events

Every handler receives one integer id.

| Event | id | When |
|---|---|---|
| `view_map` | view | a window became visible. RayWM has already centred it on the output under the pointer. During this event, `raywm.focused()` still returns the previous window; afterwards the new window gets focus, unless a handler called `raywm.view_focus` |
| `view_unmap` | view | the window is gone; `raywm.view(id)` is already stale |
| `view_focus` | view, or `0` | keyboard focus changed; `0` means no window has focus |
| `view_title` | view | the title changed (mapped windows only) |
| `view_resized` | view | a size requested with `view_place` took effect |
| `output_add` / `output_remove` | output | a monitor appeared or disappeared |
| `layout` | output, or `0` | output geometry or usable area changed: a mode change, hotplug, or a panel appearing or disappearing |

When the focused window closes, `view_focus` (for the next window, or
`0`) fires before `view_unmap`.

## Examples

A minimal binding plugin, `plugins/keys.lua`:

```lua
return {
  api = 1,
  setup = function(ctx)
    ctx.bind("Super+Return", function() raywm.spawn("foot") end)
    ctx.bind("Super+q", function()
      local id = raywm.focused()
      if id then raywm.view_close(id) end
    end)
    ctx.bind("Ctrl+Alt+r", raywm.reload)
  end,
}
```

Log every new window and make terminals slightly transparent:

```lua
return {
  api = 1,
  setup = function(ctx)
    ctx.on("view_map", function(id)
      local v = raywm.view(id)
      if not v then return end -- already gone
      raywm.log(("new window %d: %s (%s) %dx%d"):format(id, v.title, v.app_id, v.w, v.h))
      if v.app_id == "foot" then raywm.view_opacity(id, 0.95) end
    end)
  end,
}
```

A repeating timer (timers are released automatically on unload):

```lua
return {
  api = 1,
  setup = function(ctx)
    local function tick()
      raywm.log("windows: " .. #raywm.views())
      ctx.timer(60000, tick)
    end
    tick()
  end,
}
```

A one-window-per-output "monocle" layout that manages its windows:

```lua
local function arrange(ctx)
  for _, out in ipairs(raywm.outputs()) do
    local u = out.usable
    for _, id in ipairs(raywm.views()) do
      local v = raywm.view(id)
      if v and v.output == out.id then
        ctx.manage(id)
        raywm.view_place(id, u.x, u.y, u.w, u.h)
      end
    end
  end
end

return {
  api = 1,
  setup = function(ctx)
    for _, ev in ipairs({ "view_map", "view_unmap", "layout" }) do
      ctx.on(ev, function() arrange(ctx) end)
    end
    arrange(ctx)
  end,
}
```

Highlight the focused window and keep the pointer on it (a reduced
`config/plugins/focus.lua`):

```lua
local bordered

local function mark(id)
  if bordered then raywm.view_border(bordered, 0) end -- may be stale: fine
  bordered = nil
  if id ~= 0 and raywm.view_border(id, 3, "#ff8800") then bordered = id end
end

return {
  api = 1,
  setup = function(ctx)
    ctx.on("view_focus", function(id)
      mark(id)
      local v, p = raywm.view(id), raywm.pointer()
      if v and not p.busy then raywm.pointer_warp(v.x + v.w // 2, v.y + v.h // 2) end
    end)
    mark(raywm.focused() or 0)
  end,
  teardown = function()
    if bordered then raywm.view_border(bordered, 0) end
  end,
}
```

The shipped `config/plugins/dwindle.lua` is a complete layout plugin,
and `config/plugins/focus.lua` a complete focus-navigation plugin.

## Not supported in v0.1

- Per-frame callbacks, animations and drawing other than window borders
  (rectangles, text, images). `on_frame` and more decorations are
  planned for v0.2.
- Pointer events in Lua (motion, buttons, focus-follows-mouse). The
  pointer can be read and warped, not observed.
- Blur, shadows, rounded corners and shaders. The wlroots scene renderer
  cannot do these; they would need a custom renderer.
- Workspaces; maximize and fullscreen (the requests are answered but
  ignored); Xwayland; touch; tablets.
- Reading screen contents from Lua. Screenshots are taken by external
  programs through the wlr-screencopy protocol; the shipped
  `config/plugins/screenshot.lua` starts them with `raywm.spawn`. API v1
  is unchanged by this.
- Docks and panels are separate programs that use layer-shell (waybar,
  yambar, fuzzel, swaybg, ...). They are not written in Lua.
