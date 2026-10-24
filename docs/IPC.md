# Local desktop IPC v1

RayWM exposes a Linux Unix-stream socket at
`$XDG_RUNTIME_DIR/raywm-$WAYLAND_DISPLAY.sock`. The directory must belong
to the compositor's UID, have no group/other access and not be a symlink.
The socket has mode 0600; every accepted peer must have the same kernel
`SO_PEERCRED` UID. An existing path is never overwritten. Shutdown removes
only the socket inode the compositor created. A stale path after a crash
must be inspected and removed by its owner before reusing that display.

The interface is for trusted applications of the same desktop user.
Filesystem visibility must be restricted separately for sandboxed apps:
Wayland security-context labels do not label a Unix IPC connection.
Queries expose window titles and state even while locked; actions are
refused during session lock. IPC never evaluates Lua, runs commands,
loads plugins or reads arbitrary files.

## Wire contract

Each UTF-8 JSON object ends with one LF. Example:

```json
{"v":1,"id":1,"method":"windows","params":{"limit":64,"offset":0}}
```

Successful response:

```json
{"v":1,"id":1,"ok":true,"result":{"items":[],"next":null}}
```

An error has `ok:false` and an `err` string. Invalid/unknown IDs use null
in the error response. A request ID must be an integer in 0..9007199254740991;
booleans and floats are invalid. Unknown fields, duplicate JSON keys,
unsupported versions, wrong types and unknown methods are rejected.
Malformed requests do not execute a partial action. Responses to actions
have `result:null`. Future compatible v1 changes may add response fields;
consumers should ignore unknown response fields. Breaking contracts need
a new version. There is no unversioned fallback.

| Method | Parameters | Result |
|---|---|---|
| `windows` | Optional `offset=0`, `limit=64` | `items`, `next`; mapped windows in native order. |
| `outputs` | Same pagination | All outputs, including disabled ones. |
| `workspaces` | Same pagination | Native workspaces in creation order. |
| `focus` | `window`: window ID | Focus a mapped, focusable window; hidden/stale windows fail. |
| `workspace_activate` | `workspace`: workspace ID | Activate on its output and restore workspace focus. |
| `window_workspace` | `window`, `workspace` | Move a mapped window; workspace 0 removes membership. |
| `subscribe` | `events`: array of event names | Replace this connection's subscription; `[]` unsubscribes. |
| `perf` | none | Performance diagnostics (v0.2.1, read-only, also while locked); see below. |

IDs are native integer IDs, never pointers and never reused in a session.
They become invalid after destruction and are meaningless across compositor
restarts. A query page is a current snapshot, not a multi-page transaction;
clients must tolerate changes between pages. `limit` is 1..64. Use the
returned numeric `next` as the next `offset` until it is null. Lists have
the same 4096-item cap as the Lua API.

Window entries contain `id,x,y,w,h,title,app_id,workspace,output,focused,
visible,floating,fullscreen,maximized,minimized,urgent,xwayland,pid`.
Output entries contain `id,name,x,y,w,h,scale,transform,enabled,power,workspace`.
Workspace entries contain `id,name,output,active,urgent`.

`perf` (added in 0.2.1, additive to v1) returns `renderer` (`gles2`,
`pixman` or `other`), `render_node` (path or null), `renderer_timeline`,
`backend_timeline`, `explicit_sync`, `tearing_control`,
`animations_running`, `session_locked`, `ring_samples` and `outputs`. Each
output has `id,name,enabled,width,height,refresh_mhz,
max_refresh_mhz_at_size,adaptive_sync,allow_tearing,scanout_possible,
fullscreen_window,path` (`none`, `composited` or `scanout`: the last
successful commit), counters since startup `frames,idle_frames,commits,
scanout_commits,composited_commits,tearing_commits,tearing_rejected,failed,
presented,discarded,zero_copy`, and `frame_work_us` / `present_interval_us`
objects `{samples,p50,p99,max}` over the last `ring_samples` frames. It
contains no titles, application IDs or other client data. `raywmctl perf`
prints it.
Strings are valid UTF-8 and truncated at 512 bytes on a character boundary;
invalid native strings are replaced with `<invalid UTF-8>`.
Coordinates are logical layout coordinates. Visibility does not imply
that another window does not cover the surface. Zero represents no
workspace/output where relevant.

## Events and recovery

Subscription names are the events documented in [API.md](API.md#events).
An event is an unsolicited object, interleaved with responses:

```json
{"v":1,"event":"workspace_activate","subject":3,"args":[2],"seq":42}
```

`subject` is the first event argument, `args` holds additional arguments,
and `seq` increases in the compositor session. Filtered subscriptions may
observe sequence gaps. Events signal changes; a shell should query state
after connecting, after reconnecting and when it needs a complete snapshot.
Do not assume an ID still exists when handling an event. A subscription
made on one socket does not affect any other client.

Limits are 32 simultaneous peers, 64 KiB per request including LF,
128 KiB queued responses/events per peer, JSON nesting depth 32, five
seconds to complete an outstanding partial message, and 64 requests per
read callback. Flooding beyond that callback budget, an oversized message
or a full output queue disconnects that peer. Idle subscribers have no
timeout. Memory and fd usage stay bounded; slow subscribers must reconnect
and query rather than expecting an unlimited event backlog. Half-closing
the write side drains already queued responses before disconnection.

## Shell integration

`scripts/raywmctl` is a Python 3 standard-library client, installed as
`raywmctl` by the release archive. Queries automatically collect pages:

```sh
raywmctl windows
raywmctl outputs
raywmctl workspaces
raywmctl focus 11
raywmctl workspace_activate 3
raywmctl window_workspace 11 3
raywmctl subscribe workspace_activate view_focus view_state
```

Use `--socket PATH` or `RAYWM_SOCKET` to override the derived path. Each
subscription event is one JSON line on stdout; errors go to stderr with
a nonzero exit code. Qt/QML and Quickshell applications can use a local
socket client implementing this framing, or run `raywmctl` as a subprocess
and parse its JSON output. Waybar custom modules can use the same client
in a wrapper that formats Waybar's expected JSON. No shell-specific plugin
or arbitrary code-execution command is required. These are integration
entry points; a complete Quickshell/Waybar theme is not shipped.
