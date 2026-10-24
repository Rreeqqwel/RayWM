# Installing RayWM

RayWM is an experimental Wayland compositor. It is safe to
install next to your current desktop:
- nothing replaces your window manager or login screen;
- nothing writes to an existing configuration;
- no root is needed for the release archive.

- [Install a Stable release (pacman)](#install-a-stable-release-pacman)
- [Install a Beta release (source, built into a pacman package)](#install-a-beta-release-source-built-into-a-pacman-package)
- [Updates: raywm-update](#updates-raywm-update)
- [1. Runtime requirements](#1-runtime-requirements)
- [2. Install the release archive (Arch Linux, releases up to v0.2.1)](#2-install-the-release-archive-arch-linux-releases-up-to-v021)
- [3. Build from source](#3-build-from-source)
- [4. First start](#4-first-start)
- [5. Uninstall](#5-uninstall)
- [Troubleshooting](#troubleshooting)

## Install a Stable release (pacman)

Stable releases (`vX.Y.Z-stable`) carry `raywm-X.Y.Z-1-x86_64.pkg.tar.zst`,
built with `makepkg` from `packaging/arch/PKGBUILD.in` (ReleaseSafe,
baseline x86-64 CPU, no test-only code). pacman installs the dependencies
listed in the package:

```sh
sha256sum -c raywm-X.Y.Z-1-x86_64.pkg.tar.zst.sha256
sudo pacman -U raywm-X.Y.Z-1-x86_64.pkg.tar.zst
cp -r /usr/share/raywm/config ~/.config/raywm   # first install only
```

The package installs `/usr/bin/raywm`, `/usr/bin/raywmctl`,
`/usr/bin/raywm-update`, the default configuration (`raywm.conf`, `init.lua`)
and plugins in `/usr/share/raywm/config`, a session entry for display
managers (`/usr/share/wayland-sessions/raywm.desktop`) and the
documentation; it never changes `~/.config/raywm`. On the first install it
creates `/etc/raywm/update.conf` with `channel=stable` (see
[Updates](#updates-raywm-update)). Remove it with `sudo pacman -R raywm`.

## Install a Beta release (source, built into a pacman package)

Beta releases (`vX.Y.Z-beta[.N]`, GitHub Pre-releases) carry
`raywm-vX.Y.Z-beta[.N].tar.gz`: the sources, configuration, plugins,
packaging and the pinned Zig dependencies (`zig-pkg/`). On Arch Linux,
build a pacman package from it as your normal user (never as root; needs
`base-devel`, `wayland-protocols` and `pkgconf`; the build downloads the
checksum-pinned Zig 0.16.0 from ziglang.org) and install that:

```sh
sha256sum -c raywm-v0.2.2-beta.tar.gz.sha256
tar -xzf raywm-v0.2.2-beta.tar.gz
raywm-v0.2.2-beta/scripts/arch-package.sh v0.2.2-beta raywm-v0.2.2-beta.tar.gz pkg
sudo pacman -U pkg/raywm-0.2.2beta-1-x86_64.pkg.tar.zst
[ -e ~/.config/raywm ] || cp -r /usr/share/raywm/config ~/.config/raywm
```

This is exactly what `raywm-update --install` does for a Beta. The first
install creates `/etc/raywm/update.conf` with `channel=beta`. Later Betas
and Stables then come through `raywm-update`.

Without pacman (other distributions), build it like any checkout, with Zig
0.16.0 and the build dependencies of section 3; `raywm-update` is for
pacman-based systems only:

```sh
cd raywm-v0.2.2-beta
zig build -Doptimize=ReleaseSafe -p out
install -Dm755 out/bin/raywm ~/.local/bin/raywm
install -Dm755 scripts/raywmctl ~/.local/bin/raywmctl
[ -e ~/.config/raywm ] || cp -r config ~/.config/raywm
```

Releases up to v0.2.1 use the binary archive described in section 2.

## Updates: raywm-update

`raywm-update` (installed with the package, since v0.2.2) checks GitHub
Releases and installs updates through pacman. It runs only when you call
it: there is no daemon and no timer.

| Command | What it does |
|---|---|
| `raywm-update --check` | lists releases, keeps those offered to your channel and newer than the installed package, shows the newest. Installs nothing. Exit status 0: an update is available; 2: up to date; 1: error. |
| `raywm-update --install` | the same selection, then shows version, channel, type and SHA256, asks, downloads, verifies and installs (see below). |
| `raywm-update --channel` | shows the subscribed channel and where it comes from. |
| `sudo raywm-update --set-channel beta` / `stable` | changes the subscription. Installs nothing; run `--check` afterwards. Without sudo it asks for it. |
| `raywm-update --version` | the version of raywm-update and of the installed package. |
| `raywm-update --help` | usage. |

Options: `--yes` (or `--noconfirm`) installs without asking, for scripts;
without it, `--install` refuses to run without a terminal. `--dry-run`
selects, downloads and verifies, prints the commands it would run, and
installs nothing (with `--set-channel`: prints what it would write).
`--verbose` also lists the releases it ignored and why.

Examples:

```sh
raywm-update --check                    # anything new for my channel?
raywm-update --install                  # install it (asks before pacman runs)
raywm-update --install --dry-run        # download and verify only
raywm-update --channel                  # beta or stable?
sudo raywm-update --set-channel stable  # only Stable releases from now on
sudo raywm-update --set-channel beta    # Beta and Stable releases
```

### Channel and installed version are different things

The channel is a setting of the installation, stored in
`/etc/raywm/update.conf` (`channel=beta` or `channel=stable`), separately from
`raywm.conf` and from the installed version:

- **beta** receives Beta *and* Stable releases. Installing
  `v0.2.2-stable` from the beta channel keeps you on beta, so `v0.2.3-beta`
  is offered next: `v0.2.1-beta.2 → v0.2.1-stable → v0.2.2-beta → v0.2.2-stable`.
- **stable** receives Stable releases only, never a Beta. A Stable
  subscriber who runs a Beta build gets the next Stable once it is newer.

Versions are compared with pacman's `vercmp` on the package versions
(`0.2.1beta < 0.2.1beta.2 < 0.2.1 < 0.2.2beta < 0.2.2`), never as strings, and
only newer versions are offered: raywm-update never downgrades.

The package does not own `/etc/raywm/update.conf`. Its install scriptlet
creates it once, when it is missing (the first install, or the first
upgrade from v0.2.1 or older), from the channel of the version being
installed, and never touches an existing file. Upgrades between Beta and
Stable packages in any order, reinstalls and `pacman -R` therefore keep
the subscription (remove the file by hand after uninstalling if you
want). If the file is missing, raywm-update assumes the channel of the
installed version and says so; if it is malformed or unreadable,
raywm-update stops and tells you to run `--set-channel` rather than
guessing.

### What --install does

1. Lists the releases (all pages of the GitHub API; `/releases/latest` is
   not used, because Betas are Pre-releases and historical releases still
   exist). Releases whose tag is not `vX.Y.Z-beta[.N]` / `vX.Y.Z-stable`
   (v0.1.0 … v0.2.1), drafts, releases whose Pre-release flag contradicts
   the tag, and releases without the expected asset or
   `raywm-release.json` are ignored.
2. Picks the newest eligible release and checks its `raywm-release.json`:
   schema 1, tag, channel(s), version, `pkgver`, `pacman_version` and the
   asset's name, kind and size must agree with the tag and with GitHub's
   listing; otherwise it tries the next older one.
3. Downloads the asset (HTTPS only, size-limited) into a private directory
   under `~/.cache/raywm-update/` and checks size and SHA256.
4. **Stable:** that file is the package. **Beta:** checks that every
   archive member lies inside `raywm-<tag>/`, extracts it and runs the
   archive's `scripts/arch-package.sh` (makepkg) as you; it refuses to
   build as root.
5. Checks the package with `pacman -Qip`/`-Qlp`: name `raywm`, the expected
   version, x86_64, and only files under RayWM's own paths in `/usr`.
6. Runs `sudo pacman -U <package>` (pacman asks again unless `--yes`). This
   is the only privileged step; pacman replaces the old package atomically.
7. Removes the working directory, also after any failure. A failed
   download, checksum, build or check never reaches step 6, so the
   installed RayWM stays as it was. `~/.config/raywm` is never touched.

Requirements: `curl` and `tar` (package dependencies), pacman's `vercmp`,
`sudo`; for Beta builds `base-devel`, `wayland-protocols`, `pkgconf`, and
network access to ziglang.org. GitHub allows 60 unauthenticated API
requests per hour; raywm-update reports when that limit is hit.

### What SHA256 verification guarantees

The checksum proves the downloaded file is the one the release's
`raywm-release.json` describes: it detects corrupted, truncated or swapped
downloads and mirrors serving different files. It does **not** prove who
made the release: the metadata comes from the same GitHub release as the
asset, over HTTPS, so the trust anchor is GitHub's TLS certificate and the
security of the RayWM GitHub repository and its release workflow. Releases
are not signed. A Beta build additionally runs the archive's build scripts
(build.zig, PKGBUILD) as your user, as any source build does.

## 1. Runtime requirements

The release binary is `x86_64` Linux and dynamically linked, built on
Arch Linux. It needs:

| Shared library (exact soname) | Arch Linux package | Notes |
|---|---|---|
| `libwlroots-0.20.so` | `wlroots0.20` | wlroots **0.20.x**; 0.19 and 0.21 are not ABI compatible |
| `liblua5.4.so.5.4` | `lua54` | Lua **5.4**. Other distributions may use a different soname (for example `liblua5.4.so.0`); build from source there |
| `libwayland-server.so.0` | `wayland` | |
| `libxkbcommon.so.0` | `libxkbcommon` | |
| `libpixman-1.so.0`, `libinput.so.10` | `pixman`, `libinput` | Direct native dependencies |
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

## 2. Install the release archive (Arch Linux, releases up to v0.2.1)

```sh
sudo pacman -S --needed wlroots0.20 lua54 wayland libxkbcommon foot   # runtime
sudo pacman -S --needed grim slurp wl-clipboard libnotify             # optional: screenshots

# obtain the prepared archive and SHA256SUMS; publication is a separate step
sha256sum -c SHA256SUMS                                               # must print: OK
tar -xzf raywm-v0.2.0-linux-x86_64.tar.gz
cd raywm-v0.2.0
./install.sh
```

What `install.sh` does:
- copies `bin/raywm` and `bin/raywmctl` to `~/.local/bin/`
  - change the location with `--prefix DIR`;
  - an existing binary there is only replaced with `--force`, and is
    backed up first;
- copies the example configuration to `~/.config/raywm/`, **only if that
  directory does not exist yet**. An existing configuration is never
  touched; `install.sh` prints the `diff` command to compare it with the
  example. **Upgrading:** run `./install.sh --force` to replace the
  binary (the old one is kept as `raywm.bak`, then numbered backups); your configuration stays
  as it is and keeps working.
  - from v0.1.1: to get directional focus (Super+H/J/K/L), the focus
    cycle (Super+Tab) and the focus border, copy
    `config/plugins/focus.lua` and `config/plugins/dwindle.lua` to
    `~/.config/raywm/plugins/` and add `raywm.load("focus")` to your
    `init.lua` (details: [CONFIGURATION.md](CONFIGURATION.md#upgrading-from-v011));
  - from v0.1.0: also copy `config/plugins/screenshot.lua` and add
    `raywm.load("screenshot")` to get screenshots;
- preflights both executable destinations, refuses symlink targets, and checks
  with `ldd` that all shared libraries are present.
- `raywmctl` requires optional Python 3; X11 applications require Xwayland.

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
The output mode can be set with `RAYWM_OUTPUT_MODE=1920x1080@240`; see
[CONFIGURATION.md](CONFIGURATION.md#output-mode-resolution-and-refresh-rate).

## 5. Uninstall

```sh
rm ~/.local/bin/raywm ~/.local/bin/raywmctl            # or PREFIX/bin/raywm
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

## Reproducible local packaging

After committing tracked changes, run `scripts/package.sh v0.2.0`. It builds
ReleaseSafe with test input disabled, strips the binary, stages only committed
config/docs/scripts, fixes archive ordering/ownership/mtime to the commit time,
and writes `dist/raywm-v0.2.0-linux-x86_64.tar.gz`, its `.sha256` sidecar and
`dist/SHA256SUMS`. Existing artifacts are preserved; a differing archive at
the same path is refused. Repeating with the same commit/toolchain must produce
identical bytes. The payload includes `COMMIT`, `BUILD-INFO` and
`MANIFEST.sha256`; validate the manifest from the extracted top-level directory.
Build dependencies/tool versions and architecture must match to reproduce a
binary archive. Packaging does not push, tag, merge or publish anything.
