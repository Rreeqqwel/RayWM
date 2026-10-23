# Writing RayWM plugins

Plugins are trusted Lua 5.4 code beside `init.lua`, in `plugins/NAME.lua`.
Start with a small API v1 module:

```lua
return {
  api = 1,
  setup = function(ctx)
    ctx.on("view_map", function(id)
      local view = raywm.view(id)
      if view then raywm.log("mapped: " .. view.app_id) end
    end)
    ctx.bind("Super+d", function() raywm.spawn("fuzzel") end)
  end,
}
```

Load it using `raywm.load("NAME")` from `init.lua`. Names use letters,
digits, hyphens and underscores, with no path traversal. API v1 remains
compatible with the original plugin contract; 0.2 adds functions and
event arguments. Check `ctx.animate`/`ctx.rect` before using new features
in a plugin that also supports older hosts. `raywm.version` is the
release version, while `raywm.api_version` is the contract version.

## Ownership and lifecycle

Use the `ctx` supplied to your own setup/callback. Handlers, bindings,
timers, managed-view declarations, workspaces, animations and rectangles
are registrations of that plugin. `ctx.cancel(registration)` cannot
cancel another plugin's registration. Do not exchange native resource
IDs or keep a context from another plugin. View/output/workspace IDs
are lookup keys, not pointers; re-query after callbacks or later timers.
An unmap event makes the view stale, even if the client later remaps.

Cancelled registrations are marked dead immediately and swept after
dispatch, so cancellation from a callback cannot invalidate an iterator.
Native animations and visuals use separate generation handles. Their
retirement releases Lua registrations without a per-frame Lua callback.
View unmap removes its transforms and attached rectangles; snapshots own
their buffers independently. A plugin fault removes all of its resources,
including global overlay nodes. `teardown`, if supplied, is for resources
Lua opened itself, such as files; native registration cleanup is automatic
even when teardown raises an error.

`raywm.reload()` retires the old configuration and reloads files; it does
not restart the compositor or clients. Bind Ctrl+Alt+R with the supplied
`binds` plugin. Keep teardown idempotent and do not attempt registration
during teardown. Timers are one-shot; repeat by registering the next timer
inside the callback. Heavy per-window work should run on changes, not an
idle polling timer. Native animations are the supported frame-driven path.

Workspaces are special: unload orphans them to preserve windows and state.
The replacement plugin should `ctx.workspace_adopt(id)` before creating
new ones. Unadopted orphans dissolve after reload, making their windows
workspace-less and visible. See `workspaces.lua` for the complete pattern.
Autostart commands should use `startup` or `spawn_once`, so reload does not
start duplicate session services.

## Policy and composition

Load output/input/workspace policy before window rules and layout. Rules
run at `view_new`, before `view_map` assigns the layout. Layout plugins
use `ctx.manage` to protect tiled windows from free move/resize. Native
fullscreen, workspace visibility, locking and input-grab correctness
remain enforced by the core. Event handlers may call back into the core,
so a nested event can change state before the outer handler returns.

The first registered matching key binding wins; duplicate keys are logged.
Choose keys that do not collide with another loaded plugin. Runtime errors
are attributed to the plugin and isolate its registrations; a bad init
file can still leave only the successfully loaded plugins. Fallback keys
apply when no live plugin supplies bindings. Lua memory/instruction limits
help contain mistakes, but standard file/process libraries remain trusted
and a blocking system call can block the compositor. Never load untrusted
plugins; see [SECURITY.md](../SECURITY.md).

## Examples and verification

- `focus.lua`: event-driven border and directional navigation.
- `window-rules.lua`: metadata policy before layout.
- `workspaces.lua`: ownership, adoption and hotplug recovery.
- `animations.lua`: optional map/close/workspace transitions; native easing.
- `focus-indicator.lua`: optional input-transparent rectangles on outputs.
- `screenshot.lua`: external tools with file/process policy in Lua.

Examples expose an editable local `options` table where applicable. Copy
the file into your configuration and edit that table; there is no global
plugin-options setter. The shipped `init.lua` leaves visual effects off.

Check syntax with `luac5.4 -p plugins/NAME.lua`, then run a disposable
nested session with `raywm -c /path/to/test/init.lua -d -s foot`. Reload
repeatedly, remove the plugin, destroy a target window during a callback
and deliberately raise an error. Confirm bindings, timers and scene nodes
are released and other plugins remain usable. Test on a headless test
build only when injecting virtual pointer events. Never install that
test build into the real session.

[API.md](API.md) is the full function/event contract;
[EFFECTS.md](EFFECTS.md) documents resource limits and effects;
[IPC.md](IPC.md) is for external programs that need desktop state/actions
without running code inside the compositor.
