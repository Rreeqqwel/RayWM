#!/bin/sh
# Install an extracted release for this user. No desktop/session changes.
# Usage: ./install.sh [--prefix DIR] [--config-dir DIR] [--force]
# Existing binaries need --force; numbered backups are preserved.
# Existing configuration directories are always left untouched.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
prefix="$HOME/.local"
config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/raywm"
force=0
while [ $# -gt 0 ]; do
    case "$1" in
        --prefix|--config-dir)
            [ $# -ge 2 ] && [ -n "$2" ] || { echo "install: $1 requires a directory"; exit 2; }
            if [ "$1" = --prefix ]; then prefix=$2; else config_dir=$2; fi
            shift 2 ;;
        --force) force=1; shift ;;
        -h|--help) sed -n '2,5p' "$0"; exit 0 ;;
        *) echo "install: unknown option $1"; exit 2 ;;
    esac
done
[ -x "$here/bin/raywm" ] && [ -x "$here/bin/raywmctl" ] || { echo 'install: use the extracted release directory'; exit 1; }
if command -v ldd >/dev/null 2>&1 && ldd "$here/bin/raywm" | grep -q 'not found'; then
    echo 'install: missing shared libraries (see docs/INSTALL.md):'
    ldd "$here/bin/raywm" | grep 'not found'
    exit 1
fi
# Check every destination before replacing either executable.
for name in raywm raywmctl; do
    target="$prefix/bin/$name"
    [ ! -L "$target" ] || { echo "install: refusing symlink $target"; exit 1; }
    if [ -e "$target" ]; then
        [ -f "$target" ] || { echo "install: $target is not a regular file"; exit 1; }
        [ "$force" -eq 1 ] || { echo "install: $target exists; use --force (a backup is kept)"; exit 1; }
    fi
done
mkdir -p "$prefix/bin"
for name in raywm raywmctl; do
    target="$prefix/bin/$name"
    if [ -e "$target" ]; then
        backup="$target.bak"
        n=0
        while [ -e "$backup" ] || [ -L "$backup" ]; do n=$((n + 1)); backup="$target.bak.$n"; done
        cp -p "$target" "$backup"
        echo "install: backup $backup"
    fi
    install -m 0755 "$here/bin/$name" "$target"
    echo "install: installed $target"
done
if [ -e "$config_dir" ] || [ -L "$config_dir" ]; then
    echo "install: kept existing $config_dir; compare with $here/config"
else
    mkdir -p "$config_dir"
    cp -r "$here/config/." "$config_dir/"
    echo "install: copied example config to $config_dir"
fi
case ":$PATH:" in *":$prefix/bin:"*) ;; *) echo "install: $prefix/bin is not in PATH" ;; esac
if ! command -v python3 >/dev/null 2>&1; then echo 'install: raywmctl needs optional Python 3'; fi
echo 'install: done; try a nested session: raywm -s foot'
