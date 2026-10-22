# Installing RayWM

RayWM v0.1.2 is an experimental Wayland compositor. It is safe to
install next to your current desktop:
- nothing replaces your window manager or login screen;
- nothing writes to an existing configuration;
- no root is needed for the release archive.

- [1. Runtime requirements](#1-runtime-requirements)
- [2. Install the release archive (Arch Linux)](#2-install-the-release-archive-arch-linux)
- [3. Build from source](#3-build-from-source)
- [4. First start](#4-first-start)
- [5. Uninstall](#5-uninstall)
- [Troubleshooting](#troubleshooting)

## 1. Runtime requirements

The release binary is `x86_64` Linux and dynamically linked, built on
Arch Linux. It needs:

| Shared library (exact soname) | Arch Linux package | Notes |
|---|---|---|
| `libwlroots-0.20.so` | `wlroots0.20` | wlroots **0.20.x**; 0.19 and 0.21 are not ABI compatible |
| `liblua5.4.so.5.4` | `lua54` | Lua **5.4**. Other distributions may use a different soname (for example `liblua5.4.so.0`); build from source there |
| `libwayland-server.so.0` | `wayland` | |
| `libxkbcommon.so.0` | `libxkbcommon` | |
| `libc.so.6`, `ld-linux-x86-64.so.2` | `glibc` | glibc **2.36 or newer** |

wlroots itself pulls in its own dependencies (libinput, libdrm, mesa,
pixman, seatd/libseat, ...). Your package manager installs these with it.

Optional, but useful:
- `foot`, the default terminal of the fallback bindings and the example config;
- a panel such as `waybar`;
- a launcher such as `fuzzel`.

### Screenshot plugin (optional)

The example configuration loads `plugins/screenshot.lua`. RayWM itself
does not need these programs; only the plugin's actions do:

| Program | Arch Linux package | Needed for |
|---|---|---|
| `grim` | `grim` | every screenshot |
| `slurp` | `slurp` | region screenshots (Shift+Print, Ctrl+Shift+Print) |
| `wl-copy` | `wl-clipboard` | clipboard screenshots (Ctrl+Print, Ctrl+Shift+Print) |
| `notify-send` | `libnotify` | notifications (skipped when missing), plus a notification daemon such as `mako` |

Without them RayWM starts normally; a screenshot key then only logs
`raywm screenshot: grim is not installed (package: grim)` (and shows a
notification if it can). To drop the plugin, remove
`raywm.load("screenshot")` from `init.lua`.

The binary is **not** static. It is not built for distributions without
the libraries above (with these sonames).

## 2. Install the release archive (Arch Linux)

```sh
sudo pacman -S --needed wlroots0.20 lua54 wayland libxkbcommon foot   # runtime
sudo pacman -S --needed grim slurp wl-clipboard libnotify             # optional: screenshots

# download raywm-v0.1.2-linux-x86_64.tar.gz and SHA256SUMS from the release page
sha256sum -c SHA256SUMS                                               # must print: OK
tar -xzf raywm-v0.1.2-linux-x86_64.tar.gz
cd raywm-v0.1.2
./install.sh
```

What `install.sh` does:
- copies `bin/raywm` to `~/.local/bin/raywm`
  - change the location with `--prefix DIR`;
  - an existing binary there is only replaced with `--force`, and is
    backed up first;
- copies the example configuration to `~/.config/raywm/`, **only if that
  directory does not exist yet**. An existing configuration is never
  touched; `install.sh` prints the `diff` command to compare it with the
  example. **Upgrading:** run `./install.sh --force` to replace the
  binary (the old one is kept as `raywm.bak`); your configuration stays
  as it is and keeps working.
  - from v0.1.1: to get directional focus (Super+H/J/K/L), the focus
    cycle (Super+Tab) and the focus border, copy
    `config/plugins/focus.lua` and `config/plugins/dwindle.lua` to
    `~/.config/raywm/plugins/` and add `raywm.load("focus")` to your
    `init.lua` (details: [CONFIGURATION.md](CONFIGURATION.md#upgrading-from-v011));
  - from v0.1.0: also copy `config/plugins/screenshot.lua` and add
    `raywm.load("screenshot")` to get screenshots;
- checks with `ldd` that all shared libraries are present.

You can also skip the script and run `bin/raywm` directly from the
extracted directory.

## 3. Build from source

Needs Zig **0.16.0** exactly (newer Zig releases change the language and
build API), plus the development files of the libraries above and
`wayland-protocols`.

Arch Linux:

```sh
sudo pacman -S --needed git wlroots0.20 wayland wayland-protocols libxkbcommon pixman lua54 pkgconf

# Zig 0.16.0 from ziglang.org, checksum from https://ziglang.org/download/index.json
curl -LO https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz
echo "70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00  zig-x86_64-linux-0.16.0.tar.xz" | sha256sum -c
tar -xf zig-x86_64-linux-0.16.0.tar.xz          # use ./zig-x86_64-linux-0.16.0/zig below

git clone https://github.com/Rreeqqwel/RayWM && cd RayWM
zig build -Doptimize=ReleaseSafe                 # -> zig-out/bin/raywm
zig build test                                   # optional: unit tests
```

`zig build` downloads the pinned Zig dependencies (zig-wlroots 0.20.1,
zig-wayland 0.6.0, zig-xkbcommon 0.3.0, zig-pixman 0.3.0) and checks
them against the hashes in `build.zig.zon`.

**Other distributions.** You need the development packages for:
- wlroots 0.20 (`pkg-config --modversion wlroots-0.20` must work);
- wayland-server;
- wayland-protocols;
- xkbcommon;
- pixman-1;
- Lua 5.4 (`pkg-config lua5.4`).

Package names differ between distributions, so check yours. If your
distribution does not package wlroots 0.20 yet, build wlroots 0.20.x from
https://gitlab.freedesktop.org/wlroots/wlroots, which uses meson. A
missing `lua5.4.pc` is often provided as `lua54.pc` or `lua-5.4.pc`; in
that case the build fails and `build.zig` needs adjusting. Only Arch
Linux was tested.

LLVM/LLD are used to link by default, because the Zig 0.16 linker
rejects SFrame sections in recent GCC startup files. Pass
`-Dllvm=false` to use Zig's own linker on systems where that works.

Never distribute a build made with `-Dtest-input`. It contains test-only
virtual-input protocols that let any client inject input.

## 4. First start

**Nested, inside your current Wayland session.** This is the safest way
to try RayWM. It opens as a window, and closing it ends RayWM:

```sh
raywm -s foot
```

**From a TTY** (Ctrl+Alt+F3, log in, then run):

```sh
raywm -s foot
```

On a TTY, RayWM needs seat access through `systemd-logind` (the default
on Arch) or `seatd`. It takes over that VT until you quit. Quit with
Super+Shift+E, or with the binding from your config. Ctrl+Alt+F1..F12
switch VTs. TTY operation is not covered by the automated tests; see
[TESTING.md](TESTING.md).

Options:

| Option | Meaning |
|---|---|
| `-c FILE` | use FILE instead of `~/.config/raywm/init.lua` |
| `-s CMD` | run CMD (with `/bin/sh -c`) once the compositor is ready, e.g. `-s waybar` |
| `-d` | verbose wlroots logging |
| `-h` | help |

The keyboard layout comes from the standard xkb environment variables,
for example `XKB_DEFAULT_LAYOUT=us,ru XKB_DEFAULT_OPTIONS=grp:alt_shift_toggle raywm`.

## 5. Uninstall

```sh
rm ~/.local/bin/raywm            # or PREFIX/bin/raywm
rm -r ~/.config/raywm            # only if you no longer want the config
```

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `error while loading shared libraries: libwlroots-0.20.so` | wlroots 0.20 is not installed (`pacman -S wlroots0.20`), or your distribution ships another version: build from source |
| `liblua5.4.so.5.4: cannot open shared object file` | Lua 5.4 is missing, or packaged with another soname: build from source |
| `version 'GLIBC_2.36' not found` | glibc is too old: build from source |
| Black screen, nothing happens | no config yet: press Super+Return for a terminal (fallback binding) |
| `warning(lua): cannot open .../init.lua` | no config found: copy `config/` to `~/.config/raywm/` |
| A plugin error in the log | only that plugin was unloaded; fix the file and reload (Ctrl+Alt+R or Super+Shift+R) |
| `raywm screenshot: grim is not installed` | install `grim` (and `slurp`, `wl-clipboard` for regions and the clipboard) |
| Print does nothing in a nested session | the outer compositor may keep Print for itself: use Ctrl+Alt+P |
| From a TTY: `Could not get session` or similar | no seat access: make sure you are logged in on that VT with logind, or run `seatd` |
