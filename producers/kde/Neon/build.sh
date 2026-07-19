#!/bin/bash
#
# build.sh — KDE neon (Ubuntu noble/24.04 LTS base) anland KWin + Xwayland build
#
# Adapted from:
#   - ubuntu2604_v5/build.sh  → .deb build system (apt source / dpkg-buildpackage)
#   - Fedora43_v5/kwin.patch  → patch targeting KWin 6.7.x (closest to neon 6.7.3)
#
# Run this INSIDE a KDE neon container (Droidspaces or chroot).
# Uses sudo for privileged steps; works as root or a user with sudo rights.
#
# What the patches fix on the kgsl/turnip (Snapdragon) stack:
#   kwin.patch      → Anland backend + Android keyboard commitText() bridge
#   xwayland.patch  → kgsl GBM NULL main_dev fallback + implicit-modifier wl_buffer fix
#
# The official package version from debian/changelog is kept untouched so the
# resulting .deb reinstalls cleanly over the neon package without confusing apt.
#
set -u

# ---- sudo helper -----------------------------------------------------------
if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
else
    SUDO="sudo"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="${WORKDIR:-$HOME/anland-kdneon-build}"
JOBS="$(nproc)"

# ---- helpers ---------------------------------------------------------------
find_patch() {
    local name="$1" explicit="${2:-}"
    if [ -n "$explicit" ] && [ -f "$explicit" ]; then
        printf '%s\n' "$explicit"; return 0
    fi
    local c
    for c in "$SCRIPT_DIR/$name" "./$name" "$SCRIPT_DIR/../$name"; do
        if [ -f "$c" ]; then printf '%s\n' "$c"; return 0; fi
    done
    local hit
    hit="$(find "$SCRIPT_DIR" "$PWD" -maxdepth 3 -name "$name" -type f 2>/dev/null | head -1)"
    if [ -n "$hit" ]; then printf '%s\n' "$hit"; return 0; fi
    return 1
}

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[error] %s\033[0m\n' "$*" >&2; exit 1; }

# ---- enable deb-src so `apt source` works ----------------------------------
ensure_deb_src() {
    # Ensure base directories exist and configure Neon repositories
    $SUDO apt-get update -qq
    $SUDO apt-get install -y --no-install-recommends ca-certificates gnupg wget >/dev/null 2>&1

    # Configure Neon repository if not present
    if [ ! -f /etc/apt/sources.list.d/neon.list ]; then
        log "Adding KDE Neon Noble repositories to APT sources"
        # Download Neon GPG key
        wget -qO- 'https://archive.neon.kde.org/public.key' | $SUDO gpg --dearmor -y -o /usr/share/keyrings/kde-neon-archive-keyring.gpg 2>/dev/null || \
        wget -qO- 'https://archive.neon.kde.org/public.key' | $SUDO gpg --dearmor -o /usr/share/keyrings/kde-neon-archive-keyring.gpg
        
        # Write repository sources
        echo "deb [signed-by=/usr/share/keyrings/kde-neon-archive-keyring.gpg] http://archive.neon.kde.org/user noble main" | $SUDO tee /etc/apt/sources.list.d/neon.list >/dev/null
        echo "deb-src [signed-by=/usr/share/keyrings/kde-neon-archive-keyring.gpg] http://archive.neon.kde.org/user noble main" | $SUDO tee -a /etc/apt/sources.list.d/neon.list >/dev/null
        
        # Set APT preferences pinning for Neon
        printf "Package: *\nPin: origin archive.neon.kde.org\nPin-Priority: 1100\n" | $SUDO tee /etc/apt/preferences.d/99-neon >/dev/null
    fi

    # Enable deb-src for standard Ubuntu repositories as well
    if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
        $SUDO sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/ubuntu.sources
    fi
    if [ -f /etc/apt/sources.list ]; then
        $SUDO sed -i '/^deb /{ h; s/^deb /deb-src /; H; g }' /etc/apt/sources.list
    fi

    $SUDO apt-get update -qq
}

# ---- pin built packages so apt upgrade won't overwrite them ----------------
apt_hold_pkg() {
    local pkg="$1"
    echo "${pkg} hold" | $SUDO dpkg --set-selections
}

# ---- build a single source package, apply patch, produce .deb --------------
build_pkg_deb() {
    local src="$1" patch="$2"

    log "Installing build tools"
    $SUDO apt-get install -y --no-install-recommends \
        build-essential devscripts equivs dpkg-dev patch curl wget \
        meson ninja-build \
        2>/dev/null

    log "Fetching source for '${src}'"
    rm -rf "${WORKDIR:?}/${src}"
    mkdir -p "$WORKDIR/$src"
    cd "$WORKDIR/$src"



    # Install build tools, compilers, and extra-cmake-modules manually first to ensure kf6 addon is loaded
    log "Installing base build environment and kf6 build helpers"
    $SUDO apt-get install -y --no-install-recommends \
        cmake debhelper extra-cmake-modules pkg-config \
        gcc-14 g++-14 \
        qt6-base-dev qt6-declarative-dev qt6-wayland-dev \
        libwayland-dev libdrm-dev libgbm-dev libinput-dev \
        libxkbcommon-dev libudev-dev libepoxy-dev || true

    # Install KWin/XWayland build dependencies manually to bypass breeze artwork conflicts
    log "Installing build dependencies manually"
    $SUDO apt-get install -y --no-install-recommends \
        kf6-extra-cmake-modules kf6-kconfig-dev kf6-kcoreaddons-dev kf6-kwindowsystem-dev \
        kf6-kcrash-dev kf6-ki18n-dev kf6-knotifications-dev kf6-kpackage-dev \
        kf6-kdeclarative-dev kf6-kio-dev kf6-kwidgetsaddons-dev kf6-ksvg-dev \
        kf6-kcolorscheme-dev kf6-kcompletion-dev kf6-kconfigwidgets-dev kf6-kservice-dev \
        kf6-kxmlgui-dev kf6-kcmutils-dev kf6-knewstuff-dev kf6-krunner-dev \
        kf6-kidletime-dev libdisplay-info-dev libseat-dev kscreenlocker-dev libkdecorations3-dev \
        libcap-dev libdrm-dev libgbm-dev libinput-dev libudev-dev libcanberra-dev libxcvt-dev \
        libpipewire-0.3-dev libkpipewire-dev liblcms2-dev libepoxy-dev libei-dev libeis-dev \
        libx11-xcb-dev libxcb-keysyms1-dev libxcb-randr0-dev libxcb-composite0-dev \
        libxcb-shape0-dev libxcb-xfixes0-dev libxcb-damage0-dev libxcb-sync-dev \
        libxcb-render0-dev libxcb-shm0-dev libxcb-glx0-dev libxcb-present-dev \
        libxcb-xinput-dev libxcb-xkb-dev libxkbcommon-dev libxkbcommon-x11-dev \
        libxcb1-dev libx11-dev hwdata libqaccessibilityclient-qt6-dev \
        gettext knighttime-dev kwayland-dev libcap2-bin libegl-dev \
        libfontconfig-dev libfreetype-dev libkirigami-dev libkf6activities-dev \
        libsystemd-dev libxcursor-dev libxi-dev pkgconf plasma-wayland-protocols \
        qt6-5compat-dev qt6-base-private-dev qt6-declarative-private-dev \
        qt6-sensors-dev qt6-svg-dev qt6-tools-dev qt6-wayland-private-dev \
        wayland-protocols xwayland libxcb-cursor-dev libxcb-image0-dev \
        libxcb-util-dev libxcb-xtest0-dev pkg-kde-tools libplasma-dev \
        libxkbfile-dev libbsd-dev libxfont-dev libxshmfence-dev \
        kglobalacceld-dev || true

    # Download the source
    log "Downloading source code for '${src}'"
    apt-get source "$src" 2>/dev/null || \
        die "apt-get source failed for '${src}'. Check that deb-src is enabled."

    # Enter the unpacked source tree
    local srcdir
    srcdir="$(find . -maxdepth 1 -mindepth 1 -type d | head -1)"
    [ -d "$srcdir" ] || die "Could not find unpacked source directory for '${src}'"
    cd "$srcdir"

    # Copy the custom backend source directory if building KWin
    if [ "$src" = "kwin" ]; then
        log "Copying custom backend source directory 'anland' to src/backends/"
        mkdir -p src/backends/anland
        cp -r "$SCRIPT_DIR/../anland_backend_v5/src/backends/anland/." src/backends/anland/
    fi

    log "Applying patch: ${patch}"
    patch -p1 < "$patch" || die "Patch failed to apply cleanly. May need manual adjustment for this KWin version."

    log "Building .deb packages (using ${JOBS} jobs with build-dep override)"
    DEB_BUILD_OPTIONS="nocheck parallel=${JOBS}" \
        dpkg-buildpackage -b -us -uc -j"$JOBS" -d \
        || die "dpkg-buildpackage failed for '${src}'"

    log "Collecting .deb files"
    find "$WORKDIR/$src" -maxdepth 1 -name "*.deb" | while read -r deb; do
        cp "$deb" "$WORKDIR/"
        log "  → $(basename "$deb")"
    done
}

# ---- main ------------------------------------------------------------------
main() {
    log "=== KDE neon Anland KWin + Xwayland build ==="
    log "Workdir: $WORKDIR"
    mkdir -p "$WORKDIR"

    # Locate patch files
    local kwin_patch xwayland_patch
    kwin_patch="$(find_patch kwin.patch "${KWIN_PATCH:-}")" \
        || die "kwin.patch not found. Place it next to this script or set KWIN_PATCH=..."
    xwayland_patch="$(find_patch xwayland.patch "${XWAYLAND_PATCH:-}")" \
        || die "xwayland.patch not found. Place it next to this script or set XWAYLAND_PATCH=..."

    log "kwin.patch     → $kwin_patch"
    log "xwayland.patch → $xwayland_patch"

    ensure_deb_src

    # ---- Step 1: build patched KWin ----------------------------------------
    log "--- Building patched kwin ---"
    build_pkg_deb "kwin" "$kwin_patch"

    # Hold kwin packages so neon's auto-updater won't overwrite them
    for pkg in kwin-common kwin-wayland kwin-x11 libkwin6 kwin-data; do
        apt_hold_pkg "$pkg" 2>/dev/null || true
    done

    # ---- Step 2: build patched Xwayland ------------------------------------
    log "--- Building patched xwayland ---"
    build_pkg_deb "xwayland" "$xwayland_patch"
    apt_hold_pkg "xwayland" 2>/dev/null || true

    # ---- Step 3: install all built .debs -----------------------------------
    log "--- Installing built packages ---"
    local debs
    debs="$(find "$WORKDIR" -maxdepth 1 -name "*.deb" | tr '\n' ' ')"
    if [ -z "$debs" ]; then
        die "No .deb files found in $WORKDIR — build may have failed."
    fi
    # shellcheck disable=SC2086
    $SUDO dpkg -i $debs || $SUDO apt-get install -f -y

    log ""
    log "✅ Done! Patched KWin + Xwayland installed on KDE neon."
    log "   Built .deb files are in: $WORKDIR"
    log ""
    log "   Restart your KDE session to load the Anland backend:"
    log "   kwin_wayland --backend anland --xwayland"
    log ""
    log "   Packages are held (pinned). To unhold later:"
    log "   sudo apt-mark unhold kwin-common kwin-wayland kwin-x11 libkwin6 kwin-data xwayland"
}

main "$@"
