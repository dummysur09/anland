#!/bin/bash
#
# startup.sh — launch KDE Plasma with the Anland backend on KDE neon
#
# Source this or run it inside your Droidspaces KDE neon container session.
#
export ANLAND_SOCKET="${ANLAND_SOCKET:-/run/display.sock}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DISPLAY=:5
export WAYLAND_DISPLAY=wayland-0

# Ensure runtime dir exists
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

exec kwin_wayland \
    --backend anland \
    --xwayland \
    -- startplasma-wayland
