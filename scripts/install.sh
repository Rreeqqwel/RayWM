#!/bin/sh
# Installs RayWM from an extracted release archive, for the current user.
#   usage: ./install.sh [--prefix DIR] [--config-dir DIR] [--force]
#
# - Installs bin/raywm to PREFIX/bin (default: ~/.local/bin). An existing
#   raywm there is only replaced with --force (it is backed up first).
# - Copies the example config to ~/.config/raywm ONLY if that directory
#   does not exist. An existing configuration is never modified.
# - Needs no root, does not touch the running session or any other
#   window manager, and does not create login-manager entries.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
prefix="$HOME/.local"
config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/raywm"
force=0
while [ $# -gt 0 ]; do
    case "$1" in
        --prefix) prefix=$2; shift 2 ;;
        --config-dir) config_dir=$2; shift 2 ;;
        --force) force=1; shift ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "install: unknown option $1"; exit 2 ;;
    esac
done

[ -x "$here/bin/raywm" ] || { echo "install: run this from the extracted release directory"; exit 1; }

# Fail early if the runtime libraries are missing (wlroots 0.20, Lua 5.4, ...).
if command -v ldd >/dev/null 2>&1 && ldd "$here/bin/raywm" | grep -q "not found"; then
    echo "install: missing shared libraries:"
    ldd "$here/bin/raywm" | grep "not found"
    echo "see docs/INSTALL.md for the packages to install"
    exit 1
fi

target="$prefix/bin/raywm"
mkdir -p "$prefix/bin"
if [ -e "$target" ]; then
    if [ "$force" -ne 1 ]; then
        echo "install: $target exists; re-run with --force to replace it (a backup is kept)"
        exit 1
    fi
    cp -p "$target" "$target.bak"
    echo "install: backed up the previous binary to $target.bak"
fi
install -m 0755 "$here/bin/raywm" "$target"
echo "install: installed $target"

if [ -e "$config_dir" ]; then
    echo "install: $config_dir exists and was left untouched."
    echo "         The example config is in $here/config (compare with: diff -ru $here/config $config_dir)"
    echo "         Upgrading? CHANGELOG.md (\"Upgrading from ...\") lists the plugins to copy for new features."
else
    mkdir -p "$config_dir"
    cp -r "$here/config/." "$config_dir/"
    echo "install: copied the example config to $config_dir"
fi

case ":$PATH:" in *":$prefix/bin:"*) ;; *) echo "install: note: $prefix/bin is not in PATH" ;; esac
echo "install: done. Try it nested in your current session: raywm -s foot"
